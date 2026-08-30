use crate::domain::{
    CoreError, NewArticlesByFeed, ReadArticleRetention, SyncReason, SystemNotificationCandidate,
};
use crate::miniflux::RemoteSource;
use crate::storage::Store;
use chrono::{Duration, Utc};
use std::collections::HashMap;
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
    media_progress_writes: HashMap<i64, u64>,
) -> Result<SyncData, CoreError> {
    let fetch_started = Instant::now();
    tracing::info!(target: "sync", "remote fetch started");
    let mut snapshot = remote.fetch_initial_articles()?;
    tracing::info!(target: "sync", "remote fetch completed articles={} elapsed_ms={}", snapshot.articles.len(), fetch_started.elapsed().as_millis());
    // Marker entries are transport metadata, never user-visible articles or feeds.
    let saved_media_sync = store.saved_media_sync_configuration()?;
    let known_articles = snapshot
        .articles
        .iter()
        .map(|article| article.id)
        .collect::<std::collections::HashSet<_>>();
    let protected_requirements = store.protected_playback_requirements()?;
    for article_id in store.protected_playback_article_ids()? {
        let article_needs_enclosures = protected_requirements
            .iter()
            .filter(|(required_article_id, _)| *required_article_id == article_id)
            .any(|(_, enclosure_id)| {
                !snapshot
                    .enclosures
                    .iter()
                    .any(|enclosure| enclosure.id == *enclosure_id)
            });
        if !known_articles.contains(&article_id) || article_needs_enclosures {
            let protected = remote.fetch_article_by_id(article_id)?;
            snapshot.articles.push(protected.article);
            snapshot.enclosures.extend(protected.enclosures);
        }
    }
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
    let stats = store.reconcile_with_enclosures_and_progress(
        &snapshot.categories,
        &snapshot.feeds,
        &snapshot.articles,
        &snapshot.enclosures,
        &media_progress_writes,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Article, Category, Enclosure, Feed};
    use crate::miniflux::{RemoteSnapshot, RemoteSource};
    use tempfile::TempDir;

    struct ProtectedFetchFailure;

    impl RemoteSource for ProtectedFetchFailure {
        fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError> {
            Ok(RemoteSnapshot {
                categories: vec![Category {
                    id: 1,
                    title: "Category".into(),
                }],
                feeds: vec![Feed {
                    id: 2,
                    category_id: 1,
                    title: "Feed".into(),
                }],
                articles: Vec::new(),
                enclosures: Vec::new(),
            })
        }
        fn set_read_state(&self, _: &[i64], _: bool) -> Result<(), CoreError> {
            Ok(())
        }
        fn set_starred_state(&self, _: i64, _: bool) -> Result<(), CoreError> {
            Ok(())
        }
        fn fetch_article_by_id(
            &self,
            _: i64,
        ) -> Result<crate::miniflux::RemoteSavedMediaArticle, CoreError> {
            Err(CoreError::server_transient("protected fetch failed"))
        }
    }

    #[test]
    fn required_protected_fetch_failure_aborts_sync() {
        let temp = TempDir::new().unwrap();
        let data = temp.path().join("data");
        let cache = temp.path().join("cache");
        let media = temp.path().join("media");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        std::fs::create_dir_all(&media).unwrap();
        let store = Store::open(&data, &cache, &media).unwrap();
        let article = Article {
            id: 9,
            feed_id: 2,
            title: "Protected".into(),
            url: "https://example.test/9".into(),
            comments_url: String::new(),
            published_at: "2020-01-01T00:00:00Z".into(),
            is_read: true,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        };
        store
            .reconcile_with_enclosures(
                &[Category {
                    id: 1,
                    title: "Category".into(),
                }],
                &[Feed {
                    id: 2,
                    category_id: 1,
                    title: "Feed".into(),
                }],
                std::slice::from_ref(&article),
                &[Enclosure {
                    id: 90,
                    article_id: 9,
                    url: "https://example.test/90.mp3".into(),
                    mime_type: "audio/mpeg".into(),
                    size_bytes: None,
                    remote_media_progression_seconds: 0,
                }],
            )
            .unwrap();
        store
            .checkpoint_playback(90, 1_000, None, "2026-01-01T00:00:00Z", false)
            .unwrap();

        let result = run(
            &ProtectedFetchFailure,
            &store,
            ReadArticleRetention::Days30,
            SyncReason::Manual,
            HashMap::new(),
        );

        assert_eq!(
            result.unwrap_err().kind,
            crate::domain::CoreErrorKind::ServerTransient
        );
        assert!(store.last_successful_sync_at().unwrap().is_none());
    }
}
