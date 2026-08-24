//! Shared durable Flux domain core. Platform clients provide paths and secrets.

pub mod domain;
pub mod miniflux;
pub mod mutations;
pub mod queries;
pub mod storage;
pub mod sync;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use domain::{ArticleQuery, ArticleSummary, CoreError, SyncReason};
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
    sync_gate: Mutex<()>,
}

impl FluxCore {
    pub fn initialize(config: CoreConfig) -> Result<Self, CoreError> {
        validate_config(&config)?;
        let store = Arc::new(Store::open(
            &config.persistent_data,
            &config.cache,
            &config.media,
        )?);
        store.set_base_url(&config.base_url)?;
        let remote = Arc::new(MinifluxClient::new(&config.base_url, &config.api_key)?);
        Ok(Self {
            store,
            remote,
            sync_gate: Mutex::new(()),
        })
    }

    /// Constructor for controlled sources in integration tests and embedders.
    pub fn with_remote(
        config: CoreConfig,
        remote: Arc<dyn RemoteSource>,
    ) -> Result<Self, CoreError> {
        validate_config(&config)?;
        let store = Arc::new(Store::open(
            &config.persistent_data,
            &config.cache,
            &config.media,
        )?);
        store.set_base_url(&config.base_url)?;
        Ok(Self {
            store,
            remote,
            sync_gate: Mutex::new(()),
        })
    }

    pub fn sync(&self, reason: SyncReason) -> Result<(), CoreError> {
        let _sync = self
            .sync_gate
            .lock()
            .map_err(|_| CoreError::internal("sync gate poisoned"))?;
        sync::run(self.remote.as_ref(), self.store.as_ref(), reason)
    }

    pub fn query_articles(&self, query: ArticleQuery) -> Result<Vec<ArticleSummary>, CoreError> {
        self.store.query_articles(&query)
    }

    pub fn database_path(&self) -> PathBuf {
        self.store.database_path()
    }
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
    impl RemoteSource for Source {
        fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            thread::sleep(self.delay);
            Ok(self.snapshot.clone())
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
            1
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
    fn initial_sync_retains_unread_recent_read_and_all_starred() {
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
}
