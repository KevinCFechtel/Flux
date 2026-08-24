use crate::domain::{CoreError, SyncReason};
use crate::miniflux::RemoteSource;
use crate::storage::Store;
use chrono::{Duration, Utc};

pub const DEFAULT_RETENTION_DAYS: i64 = 90;

/// Normal-sync orchestration. Pending delivery and cleanup join these explicit stages when implemented.
pub fn run(remote: &dyn RemoteSource, store: &Store, _reason: SyncReason) -> Result<(), CoreError> {
    let mut snapshot = remote.fetch_initial_articles()?;
    let cutoff = Utc::now() - Duration::days(DEFAULT_RETENTION_DAYS);
    snapshot.articles.retain(|article| {
        article.is_starred
            || !article.is_read
            || chrono::DateTime::parse_from_rfc3339(&article.published_at)
                .is_ok_and(|published| published >= cutoff)
    });
    store.reconcile(&snapshot.categories, &snapshot.feeds, &snapshot.articles)?;
    // Future stage: retention cleanup.
    store.mark_sync_success()?;
    // Future stage: event publication.
    Ok(())
}
