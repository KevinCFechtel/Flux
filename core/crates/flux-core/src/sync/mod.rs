use crate::domain::{
    CoreError, NewArticlesByFeed, ReadArticleRetention, SyncReason, SystemNotificationCandidate,
};
use crate::miniflux::RemoteSource;
use crate::storage::Store;
use chrono::{Duration, Utc};
use std::time::Instant;

/// Normal-sync orchestration after pending mutation delivery.
#[derive(Clone, Debug, Default)]
pub struct SyncData {
    pub new_articles: u32,
    pub updated_articles: u32,
    pub data_changed: bool,
    pub navigation_changed: bool,
    pub new_articles_by_feed: Vec<NewArticlesByFeed>,
    pub system_notification_candidates: Vec<SystemNotificationCandidate>,
}

pub fn run(
    remote: &dyn RemoteSource,
    store: &Store,
    retention: ReadArticleRetention,
    reason: SyncReason,
) -> Result<SyncData, CoreError> {
    let fetch_started = Instant::now();
    tracing::info!(target: "sync", "remote fetch started");
    let snapshot = remote.fetch_initial_articles()?;
    tracing::info!(target: "sync", "remote fetch completed articles={} elapsed_ms={}", snapshot.articles.len(), fetch_started.elapsed().as_millis());
    let reconcile_started = Instant::now();
    let stats = store.reconcile(&snapshot.categories, &snapshot.feeds, &snapshot.articles)?;
    tracing::info!(target: "storage", "reconciliation completed new={} updated={} elapsed_ms={}", stats.new_articles, stats.updated_articles, reconcile_started.elapsed().as_millis());
    let cutoff = Utc::now() - Duration::days(retention.days());
    let cleanup_started = Instant::now();
    let removed_articles = store.cleanup_expired_read_articles(&cutoff.to_rfc3339())?;
    tracing::info!(target: "retention", "retention cleanup completed removed={} elapsed_ms={}", removed_articles, cleanup_started.elapsed().as_millis());
    let new_articles_by_feed = stats
        .new_article_ids_by_feed
        .iter()
        .map(|(&feed_id, article_ids)| NewArticlesByFeed {
            feed_id,
            count: article_ids.len() as u32,
        })
        .collect();
    let system_notification_candidates =
        if matches!(reason, SyncReason::Background | SyncReason::Periodic) {
            store.prepare_system_notification_candidates(&stats.new_article_ids_by_feed)?
        } else {
            Vec::new()
        };
    store.mark_sync_success()?;
    Ok(SyncData {
        new_articles: stats.new_articles,
        updated_articles: stats.updated_articles,
        data_changed: stats.new_articles > 0
            || stats.updated_articles > 0
            || removed_articles > 0
            || stats.navigation_changed,
        navigation_changed: stats.navigation_changed,
        new_articles_by_feed,
        system_notification_candidates,
    })
}
