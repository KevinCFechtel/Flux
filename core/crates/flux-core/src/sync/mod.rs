use crate::domain::{CoreError, SyncReason};
use crate::miniflux::RemoteSource;
use crate::storage::Store;
use chrono::{Duration, Utc};

pub const DEFAULT_RETENTION_DAYS: i64 = 90;

/// Normal-sync orchestration. Pending delivery and cleanup join these explicit stages when implemented.
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
    let mut snapshot = remote.fetch_initial_articles()?;
    let cutoff = Utc::now() - Duration::days(DEFAULT_RETENTION_DAYS);
    snapshot.articles.retain(|article| {
        article.is_starred
            || !article.is_read
            || chrono::DateTime::parse_from_rfc3339(&article.published_at)
                .is_ok_and(|published| published >= cutoff)
    });
    let stats = store.reconcile(&snapshot.categories, &snapshot.feeds, &snapshot.articles)?;
    // Future stage: retention cleanup.
    store.mark_sync_success()?;
    // Future stage: event publication.
    Ok(SyncData {
        new_articles: stats.new_articles,
        updated_articles: stats.updated_articles,
        data_changed: stats.new_articles > 0
            || stats.updated_articles > 0
            || stats.navigation_changed,
        navigation_changed: stats.navigation_changed,
    })
}
