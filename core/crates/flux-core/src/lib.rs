//! Shared durable Flux domain core. Platform clients provide paths and secrets.

pub mod article;
mod article_thumbnail;
pub mod diagnostics;
pub mod domain;
mod feed_icon;
pub mod miniflux;
pub mod mutations;
pub mod queries;
pub mod storage;
pub mod sync;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};

use diagnostics::{CoreDiagnosticListener, Diagnostics};
use domain::{
    ArticleQuery, ArticleSummary, ArticleThumbnailResult, CoreError, CoreErrorKind, CoreEvent,
    DeliveryDisposition, DeliveryMode, FeedIcon, FeedIconVariant, MutationField, MutationResult,
    NavigationCatalog, RuntimeHealth, RuntimeHealthStatus, SaveToServiceResult, SyncCompleted,
    SyncFailure, SyncReason,
};
use miniflux::{MinifluxClient, RemoteSource};
use storage::Store;

/// Platform-provided roots and runtime-only Miniflux credentials.
#[derive(Clone, Debug)]
pub struct CoreConfig {
    pub persistent_data: PathBuf,
    pub cache: PathBuf,
    pub media: PathBuf,
    pub base_url: String,
    pub api_key: String,
}

/// Long-lived, thread-safe shared core. No API key is written to disk.
pub struct FluxCore {
    store: Arc<Store>,
    remote: Arc<dyn RemoteSource>,
    feed_icons: feed_icon::FeedIconService,
    article_thumbnails: article_thumbnail::ArticleThumbnailService,
    sync_gate: Mutex<()>,
    delivery_mode: Mutex<DeliveryMode>,
    runtime: Mutex<DeliveryRuntime>,
    listeners: Mutex<HashMap<u64, Arc<dyn CoreEventListener>>>,
    next_listener_id: std::sync::atomic::AtomicU64,
    diagnostics: Arc<Diagnostics>,
    diagnostic_dispatcher: tracing::Dispatch,
}

#[derive(Clone, Copy)]
struct DeliveryRuntime {
    health: RuntimeHealth,
    next_retry_at: Option<Instant>,
    next_retry_at_utc: Option<DateTime<Utc>>,
}
pub trait CoreEventListener: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}

impl FluxCore {
    pub fn initialize(config: CoreConfig) -> Result<Self, CoreError> {
        Self::initialize_with_diagnostics(config, None)
    }

    pub fn initialize_with_diagnostics(
        config: CoreConfig,
        listener: Option<Arc<dyn CoreDiagnosticListener>>,
    ) -> Result<Self, CoreError> {
        let diagnostics = Diagnostics::new();
        if let Some(listener) = listener {
            diagnostics.subscribe(listener);
        }
        let diagnostic_dispatcher = diagnostics.dispatcher();
        let result = tracing::dispatcher::with_default(&diagnostic_dispatcher, || {
            tracing::info!(target: "core", "core initialization started");
            validate_config(&config)?;
            let store = Arc::new(Store::open(
                &config.persistent_data,
                &config.cache,
                &config.media,
            )?);
            store.set_base_url(&config.base_url)?;
            let remote = Arc::new(MinifluxClient::new(&config.base_url, &config.api_key)?);
            let feed_icons = feed_icon::FeedIconService::new(config.cache.clone())?;
            let article_thumbnails =
                article_thumbnail::ArticleThumbnailService::new(config.cache.clone())?;
            Ok::<_, CoreError>((store, remote, feed_icons, article_thumbnails))
        });
        let (store, remote, feed_icons, article_thumbnails) = match result {
            Ok(result) => result,
            Err(error) => {
                tracing::dispatcher::with_default(
                    &diagnostic_dispatcher,
                    || tracing::error!(target: "core", "core initialization failed kind={:?}", error.kind),
                );
                diagnostics.flush();
                return Err(error);
            }
        };
        tracing::dispatcher::with_default(
            &diagnostic_dispatcher,
            || tracing::info!(target: "core", "core initialization completed"),
        );
        diagnostics.flush();
        Ok(Self {
            store,
            remote,
            feed_icons,
            article_thumbnails,
            sync_gate: Mutex::new(()),
            delivery_mode: Mutex::new(DeliveryMode::Deferred),
            runtime: Mutex::new(DeliveryRuntime {
                health: RuntimeHealth::Healthy,
                next_retry_at: None,
                next_retry_at_utc: None,
            }),
            listeners: Mutex::new(HashMap::new()),
            next_listener_id: std::sync::atomic::AtomicU64::new(1),
            diagnostics,
            diagnostic_dispatcher,
        })
    }

    /// Constructor for controlled sources in integration tests and embedders.
    pub fn with_remote(
        config: CoreConfig,
        remote: Arc<dyn RemoteSource>,
    ) -> Result<Self, CoreError> {
        let diagnostics = Diagnostics::new();
        let diagnostic_dispatcher = diagnostics.dispatcher();
        let store = tracing::dispatcher::with_default(&diagnostic_dispatcher, || {
            tracing::info!(target: "core", "core initialization started");
            validate_config(&config)?;
            let store = Arc::new(Store::open(
                &config.persistent_data,
                &config.cache,
                &config.media,
            )?);
            store.set_base_url(&config.base_url)?;
            let feed_icons = feed_icon::FeedIconService::new(config.cache.clone())?;
            let article_thumbnails =
                article_thumbnail::ArticleThumbnailService::new(config.cache.clone())?;
            Ok::<_, CoreError>((store, feed_icons, article_thumbnails))
        })?;
        let (store, feed_icons, article_thumbnails) = store;
        tracing::dispatcher::with_default(
            &diagnostic_dispatcher,
            || tracing::info!(target: "core", "core initialization completed"),
        );
        Ok(Self {
            store,
            remote,
            feed_icons,
            article_thumbnails,
            sync_gate: Mutex::new(()),
            delivery_mode: Mutex::new(DeliveryMode::Deferred),
            runtime: Mutex::new(DeliveryRuntime {
                health: RuntimeHealth::Healthy,
                next_retry_at: None,
                next_retry_at_utc: None,
            }),
            listeners: Mutex::new(HashMap::new()),
            next_listener_id: std::sync::atomic::AtomicU64::new(1),
            diagnostics,
            diagnostic_dispatcher,
        })
    }

    pub fn sync(&self, reason: SyncReason) -> Result<(), CoreError> {
        let result = tracing::dispatcher::with_default(&self.diagnostic_dispatcher, || {
            self.sync_inner(reason)
        });
        self.diagnostics.flush();
        result
    }

    fn sync_inner(&self, reason: SyncReason) -> Result<(), CoreError> {
        let started = Instant::now();
        tracing::info!(target: "sync", "sync started reason={reason:?}");
        let _sync = self
            .sync_gate
            .lock()
            .map_err(|_| CoreError::internal("sync gate poisoned"))?;
        if reason != SyncReason::Manual && self.in_backoff()? {
            tracing::info!(target: "sync", "sync skipped reason={reason:?} because runtime backoff is active");
            self.emit(CoreEvent::SyncCompleted(SyncCompleted {
                reason,
                new_articles: 0,
                updated_articles: 0,
                mutations_delivered: 0,
                data_changed: false,
                navigation_changed: false,
            }));
            return Ok(());
        }
        let mutations_delivered = match self.deliver_for_sync(reason) {
            Ok(count) => {
                tracing::info!(target: "mutation", "pending mutation delivery completed delivered={count}");
                count
            }
            Err(error) => {
                tracing::warn!(target: "sync", "sync stopped during pending delivery kind={:?}", error.kind);
                self.emit(CoreEvent::SyncFailed(SyncFailure {
                    reason,
                    error_kind: error.kind.clone(),
                    mutation_delivery_completed: false,
                    remote_fetch_started: false,
                    remote_fetch_completed: false,
                    mutations_delivered: 0,
                }));
                return Err(error);
            }
        };
        match sync::run(self.remote.as_ref(), self.store.as_ref(), reason) {
            Ok(data) => {
                tracing::info!(target: "sync", "sync completed new={} updated={} delivered={} elapsed_ms={}", data.new_articles, data.updated_articles, mutations_delivered, started.elapsed().as_millis());
                self.emit(CoreEvent::SyncCompleted(SyncCompleted {
                    reason,
                    new_articles: data.new_articles,
                    updated_articles: data.updated_articles,
                    mutations_delivered,
                    data_changed: data.data_changed,
                    navigation_changed: data.navigation_changed,
                }));
                Ok(())
            }
            Err(error) => {
                tracing::warn!(target: "sync", "sync failed kind={:?} elapsed_ms={}", error.kind, started.elapsed().as_millis());
                self.emit(CoreEvent::SyncFailed(SyncFailure {
                    reason,
                    error_kind: error.kind.clone(),
                    mutation_delivery_completed: true,
                    remote_fetch_started: true,
                    remote_fetch_completed: false,
                    mutations_delivered,
                }));
                Err(error)
            }
        }
    }

    pub fn query_articles(&self, query: ArticleQuery) -> Result<Vec<ArticleSummary>, CoreError> {
        self.store.query_articles(&query)
    }
    pub fn count_articles(&self, query: ArticleQuery) -> Result<u64, CoreError> {
        self.store.count_articles(&query)
    }
    pub fn navigation_catalog(&self) -> Result<NavigationCatalog, CoreError> {
        self.store.navigation_catalog()
    }
    pub fn feed_icon(
        &self,
        feed_id: i64,
        variant: FeedIconVariant,
    ) -> Result<Option<FeedIcon>, CoreError> {
        self.feed_icons.get(self.remote.as_ref(), feed_id, variant)
    }
    pub fn article_thumbnail(
        &self,
        article_id: i64,
        image_url: String,
    ) -> Result<ArticleThumbnailResult, CoreError> {
        self.article_thumbnails
            .get(self.remote.as_ref(), article_id, &image_url)
    }
    pub fn last_successful_sync_at(&self) -> Result<Option<String>, CoreError> {
        self.store.last_successful_sync_at()
    }

    pub fn database_path(&self) -> PathBuf {
        self.store.database_path()
    }
    pub fn set_delivery_mode(&self, mode: DeliveryMode) -> Result<(), CoreError> {
        *self
            .delivery_mode
            .lock()
            .map_err(|_| CoreError::internal("delivery mode lock poisoned"))? = mode;
        Ok(())
    }
    pub fn runtime_health(&self) -> Result<RuntimeHealthStatus, CoreError> {
        let state = self
            .runtime
            .lock()
            .map_err(|_| CoreError::internal("delivery runtime lock poisoned"))?;
        Ok(RuntimeHealthStatus {
            health: state.health,
            next_retry_at: state.next_retry_at_utc.map(|time| time.to_rfc3339()),
        })
    }
    pub fn delivery_health(&self) -> Result<RuntimeHealth, CoreError> {
        Ok(self.runtime_health()?.health)
    }
    pub fn set_read_state(&self, article_id: i64, read: bool) -> Result<MutationResult, CoreError> {
        self.set_state_bulk(&[article_id], MutationField::Read, read)
    }
    pub fn set_read_state_bulk(
        &self,
        article_ids: &[i64],
        read: bool,
    ) -> Result<MutationResult, CoreError> {
        self.set_state_bulk(article_ids, MutationField::Read, read)
    }
    pub fn set_starred_state(
        &self,
        article_id: i64,
        starred: bool,
    ) -> Result<MutationResult, CoreError> {
        self.set_state_bulk(&[article_id], MutationField::Starred, starred)
    }
    pub fn set_starred_state_bulk(
        &self,
        article_ids: &[i64],
        starred: bool,
    ) -> Result<MutationResult, CoreError> {
        self.set_state_bulk(article_ids, MutationField::Starred, starred)
    }
    pub fn save_to_service(&self, article_id: i64) -> Result<SaveToServiceResult, CoreError> {
        if article_id <= 0 {
            return Err(CoreError::data("article ID must be positive"));
        }
        let result = tracing::dispatcher::with_default(&self.diagnostic_dispatcher, || {
            self.remote.save_to_service(article_id)
        });
        self.diagnostics.flush();
        result
    }
    pub fn subscribe_events(&self, listener: Arc<dyn CoreEventListener>) -> Result<u64, CoreError> {
        let id = self
            .next_listener_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.listeners
            .lock()
            .map_err(|_| CoreError::internal("event listener lock poisoned"))?
            .insert(id, listener);
        Ok(id)
    }
    pub fn unsubscribe_events(&self, id: u64) -> Result<(), CoreError> {
        self.listeners
            .lock()
            .map_err(|_| CoreError::internal("event listener lock poisoned"))?
            .remove(&id);
        Ok(())
    }
    pub fn subscribe_diagnostics(&self, listener: Arc<dyn CoreDiagnosticListener>) -> u64 {
        let id = self.diagnostics.subscribe(listener);
        self.diagnostics.flush();
        id
    }
    pub fn unsubscribe_diagnostics(&self, id: u64) {
        self.diagnostics.unsubscribe(id);
    }
    fn set_state_bulk(
        &self,
        ids: &[i64],
        field: MutationField,
        desired: bool,
    ) -> Result<MutationResult, CoreError> {
        let result = tracing::dispatcher::with_default(&self.diagnostic_dispatcher, || {
            self.set_state_bulk_inner(ids, field, desired)
        });
        self.diagnostics.flush();
        result
    }
    fn set_state_bulk_inner(
        &self,
        ids: &[i64],
        field: MutationField,
        desired: bool,
    ) -> Result<MutationResult, CoreError> {
        let pending = self.store.set_state_bulk(ids, field, desired)?;
        tracing::debug!(target: "mutation", "mutation persisted field={field:?} desired={desired} count={}", pending.len());
        for item in &pending {
            self.emit(match field {
                MutationField::Read => CoreEvent::ArticleReadStateChanged {
                    article_id: item.article_id,
                    read: desired,
                },
                MutationField::Starred => CoreEvent::ArticleStarredStateChanged {
                    article_id: item.article_id,
                    starred: desired,
                },
            });
            self.emit(CoreEvent::MutationQueued {
                article_id: item.article_id,
                field,
            });
        }
        if *self
            .delivery_mode
            .lock()
            .map_err(|_| CoreError::internal("delivery mode lock poisoned"))?
            == DeliveryMode::Deferred
        {
            return Ok(MutationResult {
                disposition: DeliveryDisposition::Queued,
            });
        }
        let _gate = self
            .sync_gate
            .lock()
            .map_err(|_| CoreError::internal("sync gate poisoned"))?;
        if self.in_backoff()? {
            return Ok(MutationResult {
                disposition: DeliveryDisposition::DeferredByBackoff,
            });
        }
        match self.deliver_pending() {
            Ok(_) => Ok(MutationResult {
                disposition: DeliveryDisposition::Delivered,
            }),
            Err(error) if retryable(&error) => {
                self.record_failure(&error)?;
                Ok(MutationResult {
                    disposition: DeliveryDisposition::Queued,
                })
            }
            Err(_) => Ok(MutationResult {
                disposition: DeliveryDisposition::Queued,
            }),
        }
    }
    fn deliver_for_sync(&self, reason: SyncReason) -> Result<u32, CoreError> {
        if reason != SyncReason::Manual && self.in_backoff()? {
            return Ok(0);
        }
        match self.deliver_pending() {
            Ok(count) => Ok(count),
            Err(error) if retryable(&error) => {
                self.record_failure(&error)?;
                Err(error)
            }
            Err(error) => Err(error),
        }
    }
    fn deliver_pending(&self) -> Result<u32, CoreError> {
        mutations::deliver_pending(self.remote.as_ref(), self.store.as_ref(), &|event| {
            self.emit(event)
        })
        .map(|count| {
            self.clear_backoff().ok();
            count
        })
    }
    fn in_backoff(&self) -> Result<bool, CoreError> {
        Ok(self
            .runtime
            .lock()
            .map_err(|_| CoreError::internal("delivery runtime lock poisoned"))?
            .next_retry_at
            .is_some_and(|at| at > Instant::now()))
    }
    fn record_failure(&self, error: &CoreError) -> Result<(), CoreError> {
        let mut state = self
            .runtime
            .lock()
            .map_err(|_| CoreError::internal("delivery runtime lock poisoned"))?;
        state.health = if error.kind == CoreErrorKind::ServerTransient {
            RuntimeHealth::ServerDegraded
        } else {
            RuntimeHealth::ConnectivityDegraded
        };
        state.next_retry_at = Some(Instant::now() + Duration::from_secs(5));
        state.next_retry_at_utc = Some(Utc::now() + chrono::Duration::seconds(5));
        Ok(())
    }
    fn clear_backoff(&self) -> Result<(), CoreError> {
        let mut state = self
            .runtime
            .lock()
            .map_err(|_| CoreError::internal("delivery runtime lock poisoned"))?;
        state.health = RuntimeHealth::Healthy;
        state.next_retry_at = None;
        state.next_retry_at_utc = None;
        Ok(())
    }
    fn emit(&self, event: CoreEvent) {
        let listeners = self
            .listeners
            .lock()
            .map(|listeners| listeners.values().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        for listener in listeners {
            listener.on_event(event.clone());
        }
    }
}
fn retryable(error: &CoreError) -> bool {
    matches!(
        error.kind,
        CoreErrorKind::Connectivity | CoreErrorKind::ServerTransient
    )
}

fn validate_config(config: &CoreConfig) -> Result<(), CoreError> {
    if config.base_url.trim().is_empty() {
        return Err(CoreError::invalid_configuration("base URL is required"));
    }
    if config.api_key.is_empty() {
        return Err(CoreError::invalid_configuration("API key is required"));
    }
    for path in [&config.persistent_data, &config.cache, &config.media] {
        if path.as_os_str().is_empty() {
            return Err(CoreError::invalid_configuration(
                "storage roots are required",
            ));
        }
        std::fs::create_dir_all(path).map_err(|e| {
            CoreError::persistence(format!("create storage root {}: {e}", path.display()))
        })?;
    }
    Ok(())
}

#[allow(dead_code)]
fn _is_beneath(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::*;
    use crate::miniflux::{RemoteSnapshot, RemoteSource};
    use chrono::{Duration as ChronoDuration, Utc};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;
    use std::time::Duration;
    use tempfile::TempDir;

    struct Source {
        snapshot: RemoteSnapshot,
        calls: AtomicUsize,
        delay: Duration,
    }
    struct MutationSource {
        snapshot: Mutex<RemoteSnapshot>,
        read_calls: AtomicUsize,
        star_calls: AtomicUsize,
        fetch_calls: AtomicUsize,
        failure: Mutex<Option<CoreError>>,
        log: Mutex<Vec<&'static str>>,
        delay: Mutex<Duration>,
    }
    struct ReentrantListener {
        core: Mutex<Option<Arc<FluxCore>>>,
        events: Mutex<Vec<CoreEvent>>,
    }
    struct DiagnosticCollector {
        records: Mutex<Vec<diagnostics::DiagnosticRecord>>,
    }
    impl CoreEventListener for ReentrantListener {
        fn on_event(&self, event: CoreEvent) {
            if let Some(core) = self.core.lock().unwrap().as_ref() {
                core.query_articles(ArticleQuery::default()).unwrap();
            }
            self.events.lock().unwrap().push(event);
        }
    }
    impl CoreDiagnosticListener for DiagnosticCollector {
        fn on_diagnostic(&self, record: diagnostics::DiagnosticRecord) {
            self.records.lock().unwrap().push(record);
        }
    }
    impl RemoteSource for MutationSource {
        fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError> {
            self.fetch_calls.fetch_add(1, Ordering::SeqCst);
            self.log.lock().unwrap().push("fetch");
            Ok(self.snapshot.lock().unwrap().clone())
        }
        fn set_read_state(&self, ids: &[i64], read: bool) -> Result<(), CoreError> {
            self.read_calls.fetch_add(1, Ordering::SeqCst);
            self.log.lock().unwrap().push("read");
            thread::sleep(*self.delay.lock().unwrap());
            if let Some(error) = self.failure.lock().unwrap().clone() {
                return Err(error);
            }
            for article in &mut self.snapshot.lock().unwrap().articles {
                if ids.contains(&article.id) {
                    article.is_read = read;
                }
            }
            Ok(())
        }
        fn set_starred_state(&self, id: i64, starred: bool) -> Result<(), CoreError> {
            self.star_calls.fetch_add(1, Ordering::SeqCst);
            self.log.lock().unwrap().push("star");
            if let Some(error) = self.failure.lock().unwrap().clone() {
                return Err(error);
            }
            for article in &mut self.snapshot.lock().unwrap().articles {
                if article.id == id {
                    article.is_starred = starred;
                }
            }
            Ok(())
        }
    }
    impl RemoteSource for Source {
        fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            thread::sleep(self.delay);
            Ok(self.snapshot.clone())
        }
        fn set_read_state(&self, _article_ids: &[i64], _read: bool) -> Result<(), CoreError> {
            Ok(())
        }
        fn set_starred_state(&self, _article_id: i64, _starred: bool) -> Result<(), CoreError> {
            Ok(())
        }
    }
    fn article(id: i64, feed_id: i64, published_at: String, read: bool, starred: bool) -> Article {
        Article {
            id,
            feed_id,
            title: format!("article {id}"),
            url: format!("https://example.test/{id}"),
            comments_url: String::new(),
            published_at,
            is_read: read,
            is_starred: starred,
            raw_html_content: format!("<p>{id}</p>"),
            preview: id.to_string(),
            image_url: None,
        }
    }
    fn snapshot() -> RemoteSnapshot {
        let now = Utc::now();
        RemoteSnapshot {
            categories: vec![
                Category {
                    id: 1,
                    title: "News".into(),
                },
                Category {
                    id: 2,
                    title: "Other".into(),
                },
            ],
            feeds: vec![
                Feed {
                    id: 10,
                    category_id: 1,
                    title: "Feed A".into(),
                },
                Feed {
                    id: 20,
                    category_id: 2,
                    title: "Feed B".into(),
                },
            ],
            articles: vec![
                article(
                    1,
                    10,
                    (now - ChronoDuration::days(1)).to_rfc3339(),
                    false,
                    false,
                ),
                article(
                    2,
                    10,
                    (now - ChronoDuration::days(2)).to_rfc3339(),
                    true,
                    true,
                ),
                article(
                    3,
                    20,
                    (now - ChronoDuration::days(3)).to_rfc3339(),
                    true,
                    false,
                ),
            ],
        }
    }
    fn config(temp: &TempDir) -> CoreConfig {
        CoreConfig {
            persistent_data: temp.path().join("data"),
            cache: temp.path().join("cache"),
            media: temp.path().join("media"),
            base_url: "https://miniflux.example".into(),
            api_key: "test-secret".into(),
        }
    }
    fn core(temp: &TempDir, snapshot: RemoteSnapshot) -> (Arc<FluxCore>, Arc<Source>) {
        let source = Arc::new(Source {
            snapshot,
            calls: AtomicUsize::new(0),
            delay: Duration::ZERO,
        });
        let core = Arc::new(FluxCore::with_remote(config(temp), source.clone()).unwrap());
        (core, source)
    }
    fn mutation_core(temp: &TempDir) -> (Arc<FluxCore>, Arc<MutationSource>) {
        let source = Arc::new(MutationSource {
            snapshot: Mutex::new(snapshot()),
            read_calls: AtomicUsize::new(0),
            star_calls: AtomicUsize::new(0),
            fetch_calls: AtomicUsize::new(0),
            failure: Mutex::new(None),
            log: Mutex::new(vec![]),
            delay: Mutex::new(Duration::ZERO),
        });
        let core = Arc::new(FluxCore::with_remote(config(temp), source.clone()).unwrap());
        core.sync(SyncReason::Manual).unwrap();
        source.log.lock().unwrap().clear();
        (core, source)
    }

    #[test]
    fn initialization_creates_versioned_database_under_platform_root() {
        let temp = TempDir::new().unwrap();
        let (core, _) = core(&temp, snapshot());
        assert_eq!(core.database_path(), temp.path().join("data/flux.sqlite3"));
        assert!(core.database_path().exists());
        let conn = rusqlite::Connection::open(core.database_path()).unwrap();
        assert_eq!(
            conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            4
        );
        let bytes = std::fs::read(core.database_path()).unwrap();
        assert!(
            !bytes
                .windows(b"test-secret".len())
                .any(|w| w == b"test-secret")
        );
    }
    #[test]
    fn sync_persists_categories_feeds_and_articles() {
        let temp = TempDir::new().unwrap();
        let (core, source) = core(&temp, snapshot());
        core.sync(SyncReason::Manual).unwrap();
        assert_eq!(source.calls.load(Ordering::SeqCst), 1);
        let rows = core
            .query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].feed_title, "Feed A");
        assert_eq!(rows[0].category_id, 1);
    }
    #[test]
    fn diagnostics_are_structured_safe_and_advisory() {
        let temp = TempDir::new().unwrap();
        let (core, _) = core(&temp, snapshot());
        let collector = Arc::new(DiagnosticCollector {
            records: Mutex::new(vec![]),
        });
        let subscription = core.subscribe_diagnostics(collector.clone());
        let initialization_records = std::mem::take(&mut *collector.records.lock().unwrap());
        assert!(
            initialization_records
                .iter()
                .any(|record| record.target == "core" && record.message.contains("initialization"))
        );

        core.sync(SyncReason::Manual).unwrap();
        let records = std::mem::take(&mut *collector.records.lock().unwrap());
        assert!(
            records
                .iter()
                .any(|record| record.target == "sync" && record.message.contains("sync started"))
        );
        assert!(records.iter().any(|record| {
            record.target == "retention" && record.message.contains("cleanup completed")
        }));
        assert!(
            records
                .iter()
                .all(|record| !record.message.contains("test-secret"))
        );

        core.unsubscribe_diagnostics(subscription);
        core.sync(SyncReason::Manual).unwrap();
        assert!(collector.records.lock().unwrap().is_empty());
    }
    #[test]
    fn query_applies_scope_independent_state_filters_and_sorting() {
        let temp = TempDir::new().unwrap();
        let (core, _) = core(&temp, snapshot());
        core.sync(SyncReason::Manual).unwrap();
        let category = core
            .query_articles(ArticleQuery {
                scope: ArticleScope::Category(1),
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            category.iter().map(|a| a.id).collect::<Vec<_>>(),
            vec![1, 2]
        );
        let feed = core
            .query_articles(ArticleQuery {
                scope: ArticleScope::Feed(20),
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(feed.iter().map(|a| a.id).collect::<Vec<_>>(), vec![3]);
        let unread = core
            .query_articles(ArticleQuery {
                read_filter: ReadFilter::Unread,
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(unread.iter().map(|a| a.id).collect::<Vec<_>>(), vec![1]);
        let starred = core
            .query_articles(ArticleQuery {
                starred_filter: StarredFilter::Starred,
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(starred.iter().map(|a| a.id).collect::<Vec<_>>(), vec![2]);
        let oldest = core
            .query_articles(ArticleQuery {
                sort: ArticleSort::OldestFirst,
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            oldest.iter().map(|a| a.id).collect::<Vec<_>>(),
            vec![3, 2, 1]
        );
    }
    #[test]
    fn keyset_pagination_is_deterministic_for_identical_publication_times_and_zero_limit_is_all() {
        let temp = TempDir::new().unwrap();
        let time = Utc::now().to_rfc3339();
        let mut data = snapshot();
        data.articles = vec![
            article(3, 10, time.clone(), false, false),
            article(1, 10, time.clone(), false, false),
            article(2, 10, time, false, false),
        ];
        let (core, _) = core(&temp, data);
        core.sync(SyncReason::Manual).unwrap();
        let first = core
            .query_articles(ArticleQuery {
                limit: 2,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(first.iter().map(|a| a.id).collect::<Vec<_>>(), vec![3, 2]);
        let second = core
            .query_articles(ArticleQuery {
                limit: 2,
                cursor: Some(ArticleCursor {
                    published_at: first[1].published_at.clone(),
                    article_id: first[1].id,
                }),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(second.iter().map(|a| a.id).collect::<Vec<_>>(), vec![1]);
        assert_eq!(
            core.query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .len(),
            3
        );
    }
    #[test]
    fn sync_retention_removes_only_expired_unstarred_read_articles() {
        let temp = TempDir::new().unwrap();
        let old = (Utc::now() - ChronoDuration::days(91)).to_rfc3339();
        let mut data = snapshot();
        data.articles = vec![
            article(1, 10, old.clone(), false, false),
            article(2, 10, old.clone(), true, true),
            article(3, 10, old, true, false),
        ];
        let (core, _) = core(&temp, data);
        core.sync(SyncReason::AppStart).unwrap();
        assert_eq!(
            core.query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect::<Vec<_>>(),
            vec![2, 1]
        );
    }
    #[test]
    fn sync_keeps_existing_recent_read_articles_absent_from_remote_sets() {
        let temp = TempDir::new().unwrap();
        let mut remote = snapshot();
        remote.articles.clear();
        let (core, _) = core(&temp, remote.clone());
        let recent_read = article(
            4,
            10,
            (Utc::now() - ChronoDuration::days(89)).to_rfc3339(),
            true,
            false,
        );
        core.store
            .reconcile(&remote.categories, &remote.feeds, &[recent_read])
            .unwrap();

        core.sync(SyncReason::Manual).unwrap();

        assert_eq!(
            core.query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .iter()
            .map(|article| article.id)
            .collect::<Vec<_>>(),
            vec![4]
        );
    }
    #[test]
    fn sync_retention_preserves_old_unread_and_starred_local_articles() {
        let temp = TempDir::new().unwrap();
        let mut remote = snapshot();
        let old = (Utc::now() - ChronoDuration::days(91)).to_rfc3339();
        remote.articles = vec![
            article(5, 10, old.clone(), false, false),
            article(6, 10, old.clone(), true, true),
        ];
        let (core, _) = core(&temp, remote.clone());
        core.store
            .reconcile(
                &remote.categories,
                &remote.feeds,
                &[
                    article(4, 10, old.clone(), true, false),
                    article(5, 10, old.clone(), false, false),
                    article(6, 10, old, true, true),
                ],
            )
            .unwrap();

        core.sync(SyncReason::Manual).unwrap();

        assert_eq!(
            core.query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .iter()
            .map(|article| article.id)
            .collect::<Vec<_>>(),
            vec![6, 5]
        );
    }
    #[test]
    fn concurrent_syncs_are_serialized_while_queries_remain_safe() {
        let temp = TempDir::new().unwrap();
        let source = Arc::new(Source {
            snapshot: snapshot(),
            calls: AtomicUsize::new(0),
            delay: Duration::from_millis(80),
        });
        let core = Arc::new(FluxCore::with_remote(config(&temp), source.clone()).unwrap());
        let a = {
            let core = core.clone();
            thread::spawn(move || core.sync(SyncReason::Manual).unwrap())
        };
        let b = {
            let core = core.clone();
            thread::spawn(move || core.sync(SyncReason::Background).unwrap())
        };
        for _ in 0..5 {
            core.query_articles(ArticleQuery::default()).unwrap();
        }
        a.join().unwrap();
        b.join().unwrap();
        assert_eq!(source.calls.load(Ordering::SeqCst), 2);
    }
    #[test]
    fn local_read_star_and_deduplicated_bulk_mutations_are_effective_and_durable() {
        let temp = TempDir::new().unwrap();
        let (core, _) = mutation_core(&temp);
        core.set_read_state_bulk(&[1, 1, 3], true).unwrap();
        core.set_starred_state(1, true).unwrap();
        core.set_starred_state(2, false).unwrap();
        let rows = core
            .query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap();
        assert!(rows.iter().find(|a| a.id == 1).unwrap().is_read);
        assert!(rows.iter().find(|a| a.id == 1).unwrap().is_starred);
        assert!(!rows.iter().find(|a| a.id == 2).unwrap().is_starred);
        drop(core);
        let source = Arc::new(MutationSource {
            snapshot: Mutex::new(snapshot()),
            read_calls: AtomicUsize::new(0),
            star_calls: AtomicUsize::new(0),
            fetch_calls: AtomicUsize::new(0),
            failure: Mutex::new(None),
            log: Mutex::new(vec![]),
            delay: Mutex::new(Duration::ZERO),
        });
        let reopened = FluxCore::with_remote(config(&temp), source).unwrap();
        assert!(
            reopened
                .query_articles(ArticleQuery {
                    limit: 0,
                    ..Default::default()
                })
                .unwrap()
                .iter()
                .find(|a| a.id == 1)
                .unwrap()
                .is_read
        );
    }
    #[test]
    fn live_delivery_acknowledges_and_transient_failure_uses_backoff() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        core.set_delivery_mode(DeliveryMode::Live).unwrap();
        assert_eq!(
            core.set_read_state(1, true).unwrap().disposition,
            DeliveryDisposition::Delivered
        );
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 1);
        *source.failure.lock().unwrap() = Some(CoreError::connectivity("offline"));
        assert_eq!(
            core.set_read_state(1, false).unwrap().disposition,
            DeliveryDisposition::Queued
        );
        assert_eq!(
            core.delivery_health().unwrap(),
            RuntimeHealth::ConnectivityDegraded
        );
        core.set_read_state(1, true).unwrap();
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 2);
        *source.failure.lock().unwrap() = None;
        core.sync(SyncReason::Manual).unwrap();
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 3);
    }
    #[test]
    fn periodic_sync_delivers_deferred_mutations_and_respects_backoff() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        core.set_read_state(1, true).unwrap();
        core.sync(SyncReason::Periodic).unwrap();
        assert_eq!(*source.log.lock().unwrap(), vec!["read", "fetch"]);

        source.log.lock().unwrap().clear();
        *source.failure.lock().unwrap() = Some(CoreError::connectivity("offline"));
        core.set_delivery_mode(DeliveryMode::Live).unwrap();
        core.set_read_state(1, false).unwrap();
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 2);

        *source.failure.lock().unwrap() = None;
        core.sync(SyncReason::Periodic).unwrap();
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 2);
        assert_eq!(*source.log.lock().unwrap(), vec!["read"]);
        core.sync(SyncReason::Manual).unwrap();
        assert_eq!(source.read_calls.load(Ordering::SeqCst), 3);
    }
    #[test]
    fn stale_delivery_acknowledgement_cannot_overwrite_newer_intent() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        *source.delay.lock().unwrap() = Duration::from_millis(80);
        core.set_delivery_mode(DeliveryMode::Live).unwrap();
        let first = {
            let core = core.clone();
            thread::spawn(move || core.set_read_state(1, true).unwrap())
        };
        thread::sleep(Duration::from_millis(20));
        core.set_delivery_mode(DeliveryMode::Deferred).unwrap();
        core.set_read_state(1, false).unwrap();
        first.join().unwrap();
        assert!(
            !core
                .query_articles(ArticleQuery {
                    limit: 0,
                    ..Default::default()
                })
                .unwrap()
                .iter()
                .find(|a| a.id == 1)
                .unwrap()
                .is_read
        );
    }
    #[test]
    fn sync_delivers_before_fetch_and_aborts_fetch_on_delivery_failure() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        core.set_read_state(1, true).unwrap();
        core.sync(SyncReason::Manual).unwrap();
        assert_eq!(*source.log.lock().unwrap(), vec!["read", "fetch"]);
        core.set_read_state(1, false).unwrap();
        source.log.lock().unwrap().clear();
        *source.failure.lock().unwrap() = Some(CoreError::server_transient("down"));
        assert!(core.sync(SyncReason::Manual).is_err());
        assert_eq!(*source.log.lock().unwrap(), vec!["read"]);
    }
    #[test]
    fn events_are_advisory_and_listener_callbacks_can_query_safely() {
        let temp = TempDir::new().unwrap();
        let (core, _) = mutation_core(&temp);
        core.set_read_state(1, true).unwrap(); // No listener must not affect durable state.
        let listener = Arc::new(ReentrantListener {
            core: Mutex::new(Some(core.clone())),
            events: Mutex::new(vec![]),
        });
        let id = core.subscribe_events(listener.clone()).unwrap();
        core.set_starred_state(1, true).unwrap();
        core.unsubscribe_events(id).unwrap();
        assert!(listener.events.lock().unwrap().iter().any(|event| matches!(
            event,
            CoreEvent::ArticleStarredStateChanged {
                article_id: 1,
                starred: true
            }
        )));
    }
    #[test]
    fn reconciliation_preserves_pending_intent_and_accepts_unconflicted_remote_state() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        core.set_delivery_mode(DeliveryMode::Live).unwrap();
        *source.failure.lock().unwrap() = Some(CoreError::connectivity("offline"));
        core.set_read_state(1, true).unwrap();
        source
            .snapshot
            .lock()
            .unwrap()
            .articles
            .iter_mut()
            .find(|a| a.id == 1)
            .unwrap()
            .is_read = false;
        core.sync(SyncReason::Background).unwrap();
        assert!(
            core.query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .iter()
            .find(|a| a.id == 1)
            .unwrap()
            .is_read
        );
        *source.failure.lock().unwrap() = None;
        core.sync(SyncReason::Manual).unwrap();
        source
            .snapshot
            .lock()
            .unwrap()
            .articles
            .iter_mut()
            .find(|a| a.id == 1)
            .unwrap()
            .is_read = false;
        core.sync(SyncReason::Manual).unwrap();
        assert!(
            !core
                .query_articles(ArticleQuery {
                    limit: 0,
                    ..Default::default()
                })
                .unwrap()
                .iter()
                .find(|a| a.id == 1)
                .unwrap()
                .is_read
        );
    }
    #[test]
    fn navigation_catalog_is_complete_and_counts_use_effective_state() {
        let temp = TempDir::new().unwrap();
        let (core, _) = mutation_core(&temp);
        let catalog = core.navigation_catalog().unwrap();
        assert_eq!(catalog.categories.len(), 2);
        assert_eq!(
            catalog.feeds.iter().map(|feed| feed.id).collect::<Vec<_>>(),
            vec![10, 20]
        );
        assert_eq!(
            core.count_articles(ArticleQuery {
                limit: 1,
                ..Default::default()
            })
            .unwrap(),
            3
        );
        assert_eq!(
            core.count_articles(ArticleQuery {
                scope: ArticleScope::Category(1),
                read_filter: ReadFilter::Unread,
                limit: 0,
                ..Default::default()
            })
            .unwrap(),
            1
        );
        assert_eq!(
            core.count_articles(ArticleQuery {
                scope: ArticleScope::Feed(10),
                starred_filter: StarredFilter::Starred,
                limit: 0,
                ..Default::default()
            })
            .unwrap(),
            1
        );
        core.set_read_state_bulk(&[1, 1], true).unwrap();
        assert_eq!(
            core.count_articles(ArticleQuery {
                read_filter: ReadFilter::Unread,
                limit: 0,
                ..Default::default()
            })
            .unwrap(),
            0
        );
        core.set_read_state_bulk(&[1], false).unwrap();
        assert_eq!(
            core.count_articles(ArticleQuery {
                read_filter: ReadFilter::Unread,
                limit: 0,
                ..Default::default()
            })
            .unwrap(),
            1
        );
    }
    #[test]
    fn comments_sync_metadata_and_runtime_health_are_public_state() {
        let temp = TempDir::new().unwrap();
        let (core, source) = mutation_core(&temp);
        assert_eq!(
            core.runtime_health().unwrap().health,
            RuntimeHealth::Healthy
        );
        assert!(core.runtime_health().unwrap().next_retry_at.is_none());
        let article = core
            .query_articles(ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        assert!(article.comments_url.is_empty());
        assert!(core.last_successful_sync_at().unwrap().is_some());
        let listener = Arc::new(ReentrantListener {
            core: Mutex::new(Some(core.clone())),
            events: Mutex::new(vec![]),
        });
        let id = core.subscribe_events(listener.clone()).unwrap();
        core.sync(SyncReason::Periodic).unwrap();
        core.unsubscribe_events(id).unwrap();
        assert!(listener.events.lock().unwrap().iter().any(|event| matches!(
            event,
            CoreEvent::SyncCompleted(SyncCompleted {
                reason: SyncReason::Periodic,
                new_articles: 0,
                updated_articles: 0,
                data_changed: false,
                navigation_changed: false,
                ..
            })
        )));
        source.snapshot.lock().unwrap().articles[0].title = "updated remotely".into();
        let listener = Arc::new(ReentrantListener {
            core: Mutex::new(Some(core.clone())),
            events: Mutex::new(vec![]),
        });
        let id = core.subscribe_events(listener.clone()).unwrap();
        core.sync(SyncReason::Manual).unwrap();
        core.unsubscribe_events(id).unwrap();
        assert!(listener.events.lock().unwrap().iter().any(|event| matches!(
            event,
            CoreEvent::SyncCompleted(SyncCompleted {
                reason: SyncReason::Manual,
                new_articles: 0,
                updated_articles: 1,
                data_changed: true,
                navigation_changed: false,
                ..
            })
        )));
        *source.failure.lock().unwrap() = Some(CoreError::connectivity("offline"));
        core.set_delivery_mode(DeliveryMode::Live).unwrap();
        core.set_read_state(1, true).unwrap();
        assert!(core.runtime_health().unwrap().next_retry_at.is_some());
    }
}
