use crate::domain::{CoreError, SyncReason};
use crate::miniflux::RemoteSource;
use crate::storage::Store;
use chrono::{Duration, Utc};
use std::time::Instant;

pub const DEFAULT_RETENTION_DAYS: i64 = 90;

/// Normal-sync orchestration after pending mutation delivery.
#[derive(Clone, Copy, Debug, Default)]
pub struct SyncData {
    pub new_articles: u32,
    pub updated_articles: u32,
    pub data_changed: bool,
    pub navigation_changed: bool,
}

pub fn run(
    remote: &dyn RemoteSource,
    store: &Store,
    _reason: SyncReason,
) -> Result<SyncData, CoreError> {
    let fetch_started = Instant::now();
    tracing::info!(target: "sync", "remote fetch started");
    let snapshot = remote.fetch_initial_articles()?;
    tracing::info!(target: "sync", "remote fetch completed articles={} elapsed_ms={}", snapshot.articles.len(), fetch_started.elapsed().as_millis());
    let reconcile_started = Instant::now();
    let stats = store.reconcile(&snapshot.categories, &snapshot.feeds, &snapshot.articles)?;
    tracing::info!(target: "storage", "reconciliation completed new={} updated={} elapsed_ms={}", stats.new_articles, stats.updated_articles, reconcile_started.elapsed().as_millis());
    let cutoff = Utc::now() - Duration::days(DEFAULT_RETENTION_DAYS);
    let cleanup_started = Instant::now();
    let removed_articles = store.cleanup_expired_read_articles(&cutoff.to_rfc3339())?;
    tracing::info!(target: "retention", "retention cleanup completed removed={} elapsed_ms={}", removed_articles, cleanup_started.elapsed().as_millis());
    store.mark_sync_success()?;
    Ok(SyncData {
        new_articles: stats.new_articles,
        updated_articles: stats.updated_articles,
        data_changed: stats.new_articles > 0
            || stats.updated_articles > 0
            || removed_articles > 0
            || stats.navigation_changed,
        navigation_changed: stats.navigation_changed,
    })
}
