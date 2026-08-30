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
    let mut snapshot = remote.fetch_initial_articles()?;
    tracing::info!(target: "sync", "remote fetch completed articles={} elapsed_ms={}", snapshot.articles.len(), fetch_started.elapsed().as_millis());
    // Marker entries are transport metadata, never user-visible articles or feeds.
    let saved_media_sync = store.saved_media_sync_configuration()?;
    if saved_media_sync.enabled {
        let Some(feed_id) = saved_media_sync.sync_feed_id else {
            return Err(CoreError::data("SavedMedia Sync setup requires repair"));
        };
        let technical_article_ids = snapshot
            .articles
            .iter()
            .filter(|article| article.feed_id == feed_id)
            .map(|article| article.id)
            .collect::<std::collections::HashSet<_>>();
        snapshot.feeds.retain(|feed| feed.id != feed_id);
        snapshot
            .articles
            .retain(|article| article.feed_id != feed_id);
        snapshot
            .enclosures
            .retain(|enclosure| !technical_article_ids.contains(&enclosure.article_id));
    }
    let reconcile_started = Instant::now();
    let stats = store.reconcile_with_enclosures(
        &snapshot.categories,
        &snapshot.feeds,
        &snapshot.articles,
        &snapshot.enclosures,
    )?;
    let saved_media_changed = crate::saved_media_sync::run(remote, store)?;
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
            || stats.navigation_changed
            || saved_media_changed,
        navigation_changed: stats.navigation_changed,
        new_articles_by_feed,
        system_notification_candidates,
    })
}
