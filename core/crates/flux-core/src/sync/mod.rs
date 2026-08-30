use crate::domain::{
    CoreError, DiscoveryMode, NewArticlesByFeed, ReadArticleRetention, SyncReason,
    SystemNotificationCandidate,
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
    let download_requirements = store.protected_download_requirements()?;
    if !download_requirements.is_empty() {
        let known_enclosures = snapshot
            .enclosures
            .iter()
            .map(|enclosure| enclosure.id)
            .collect::<std::collections::HashSet<_>>();
        let mut articles_to_fetch = Vec::new();
        let mut seen_articles = std::collections::HashSet::new();
        for (article_id, enclosure_id) in &download_requirements {
            let article_missing = !known_articles.contains(article_id);
            let enclosure_missing = !known_enclosures.contains(enclosure_id);
            if (article_missing || enclosure_missing) && seen_articles.insert(*article_id) {
                articles_to_fetch.push(*article_id);
            }
        }
        for article_id in articles_to_fetch {
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
    let discovery_mode = if store.last_successful_sync_at()?.is_some() {
        DiscoveryMode::LiveDiscovery
    } else {
        DiscoveryMode::Restore
    };
    let stats = store.reconcile_with_enclosures_and_progress_mode(
        &snapshot.categories,
        &snapshot.feeds,
        &snapshot.articles,
        &snapshot.enclosures,
        &media_progress_writes,
        discovery_mode,
    )?;
    let saved_media_changed = crate::saved_media_sync::run(remote, store)?;
    tracing::info!(target: "storage", "reconciliation completed new={} updated={} elapsed_ms={}", stats.new_articles, stats.updated_articles, reconcile_started.elapsed().as_millis());
    let cutoff = Utc::now() - Duration::days(retention.days());
    let cleanup_started = Instant::now();
    let removed_articles = store.cleanup_expired_read_articles(&cutoff.to_rfc3339())?;
    let removed_media = store.evaluate_media_cleanup(Utc::now())?;
    tracing::info!(target: "retention", "retention cleanup completed removed={} elapsed_ms={}", removed_articles, cleanup_started.elapsed().as_millis());
    tracing::info!(target: "retention", "media cleanup evaluated delete_requested={}", removed_media.len());
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

    #[test]
    fn protected_download_requirements_track_enclosure_scoped_protection() {
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
            title: "Download-protected".into(),
            url: "https://example.test/9".into(),
            comments_url: String::new(),
            published_at: "2020-01-01T00:00:00Z".into(),
            is_read: true,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        };
        let enclosure = Enclosure {
            id: 90,
            article_id: 9,
            url: "https://example.test/90.mp3".into(),
            mime_type: "audio/mpeg".into(),
            size_bytes: None,
            remote_media_progression_seconds: 0,
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
                std::slice::from_ref(&enclosure),
            )
            .unwrap();
        // Requested + Downloaded must appear in the protected set;
        // Failed + DeleteRequested must not.
        store
            .request_download(90, crate::domain::DownloadOrigin::Manual)
            .unwrap();
        assert_eq!(
            store.protected_download_requirements().unwrap(),
            vec![(9, 90)]
        );
        store
            .download_finished(90, "enclosure/90.mp3", 1024)
            .unwrap();
        assert_eq!(
            store.protected_download_requirements().unwrap(),
            vec![(9, 90)]
        );
        store.request_download_deletion(90).unwrap();
        assert_eq!(
            store.protected_download_requirements().unwrap(),
            Vec::<(i64, i64)>::new()
        );
        store.download_deleted(90).unwrap();
        store
            .request_download(90, crate::domain::DownloadOrigin::Manual)
            .unwrap();
        store
            .download_failed(90, crate::domain::DownloadFailureKind::Network)
            .unwrap();
        assert_eq!(
            store.protected_download_requirements().unwrap(),
            Vec::<(i64, i64)>::new()
        );
    }

    #[test]
    fn protected_download_fetch_protects_article_even_when_already_in_snapshot() {
        use crate::domain::CoreErrorKind;
        use std::sync::Mutex;
        use std::sync::atomic::{AtomicUsize, Ordering};

        struct TrackingRemote {
            snapshot: RemoteSnapshot,
            fetch_calls: AtomicUsize,
            fetched_articles: Mutex<Vec<i64>>,
        }
        impl crate::miniflux::RemoteSource for TrackingRemote {
            fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, crate::domain::CoreError> {
                Ok(self.snapshot.clone())
            }
            fn set_read_state(&self, _: &[i64], _: bool) -> Result<(), crate::domain::CoreError> {
                Ok(())
            }
            fn set_starred_state(&self, _: i64, _: bool) -> Result<(), crate::domain::CoreError> {
                Ok(())
            }
            fn fetch_article_by_id(
                &self,
                article_id: i64,
            ) -> Result<crate::miniflux::RemoteSavedMediaArticle, crate::domain::CoreError>
            {
                self.fetch_calls.fetch_add(1, Ordering::SeqCst);
                self.fetched_articles.lock().unwrap().push(article_id);
                Err(crate::domain::CoreError::data("test fetch failure"))
            }
        }
        let temp = TempDir::new().unwrap();
        let data = temp.path().join("data");
        let cache = temp.path().join("cache");
        let media = temp.path().join("media");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        std::fs::create_dir_all(&media).unwrap();
        let store = Store::open(&data, &cache, &media).unwrap();
        // Set up: Article present locally with two enclosures; only Enclosure 10 has a Required download.
        let category = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let article = Article {
            id: 9,
            feed_id: 2,
            title: "Article".into(),
            url: "https://example.test/9".into(),
            comments_url: String::new(),
            published_at: "2020-01-01T00:00:00Z".into(),
            is_read: true,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        };
        let enclosures = [
            Enclosure {
                id: 10,
                article_id: 9,
                url: "https://example.test/10.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
            Enclosure {
                id: 11,
                article_id: 9,
                url: "https://example.test/11.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
        ];
        store
            .reconcile_with_enclosures(
                &category,
                &feeds,
                std::slice::from_ref(&article),
                &enclosures,
            )
            .unwrap();
        store
            .request_download(10, crate::domain::DownloadOrigin::Manual)
            .unwrap();

        // The remote snapshot contains Article 9 and Enclosure 11, but not Enclosure 10.
        let snapshot = RemoteSnapshot {
            categories: category.to_vec(),
            feeds: feeds.to_vec(),
            articles: vec![article.clone()],
            enclosures: vec![enclosures[1].clone()],
        };
        let remote = TrackingRemote {
            snapshot,
            fetch_calls: AtomicUsize::new(0),
            fetched_articles: Mutex::new(Vec::new()),
        };
        let result = run(
            &remote,
            &store,
            ReadArticleRetention::Days30,
            SyncReason::Manual,
            HashMap::new(),
        );
        // The protected fetch must be attempted exactly once because the protected Enclosure is absent
        // from the normal snapshot, even though the parent Article is present.
        assert_eq!(remote.fetch_calls.load(Ordering::SeqCst), 1);
        assert_eq!(*remote.fetched_articles.lock().unwrap(), vec![9]);
        // Fetch errors propagate as the normal sync error.
        assert_eq!(result.unwrap_err().kind, CoreErrorKind::Data);
        assert!(store.last_successful_sync_at().unwrap().is_none());
    }

    #[test]
    fn protected_download_fetch_coalesces_multiple_enclosures_on_same_article() {
        use std::sync::Mutex;
        use std::sync::atomic::{AtomicUsize, Ordering};

        struct CountingRemote {
            snapshot: RemoteSnapshot,
            fetch_calls: AtomicUsize,
            fetched_articles: Mutex<Vec<i64>>,
        }
        impl crate::miniflux::RemoteSource for CountingRemote {
            fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, crate::domain::CoreError> {
                Ok(self.snapshot.clone())
            }
            fn set_read_state(&self, _: &[i64], _: bool) -> Result<(), crate::domain::CoreError> {
                Ok(())
            }
            fn set_starred_state(&self, _: i64, _: bool) -> Result<(), crate::domain::CoreError> {
                Ok(())
            }
            fn fetch_article_by_id(
                &self,
                article_id: i64,
            ) -> Result<crate::miniflux::RemoteSavedMediaArticle, crate::domain::CoreError>
            {
                self.fetch_calls.fetch_add(1, Ordering::SeqCst);
                self.fetched_articles.lock().unwrap().push(article_id);
                Ok(crate::miniflux::RemoteSavedMediaArticle {
                    article: crate::domain::Article {
                        id: article_id,
                        feed_id: 2,
                        title: format!("Fetched {article_id}"),
                        url: format!("https://example.test/{article_id}"),
                        comments_url: String::new(),
                        published_at: "2020-01-01T00:00:00Z".into(),
                        is_read: true,
                        is_starred: false,
                        raw_html_content: String::new(),
                        preview: String::new(),
                        image_url: None,
                    },
                    enclosures: vec![],
                })
            }
        }
        let temp = TempDir::new().unwrap();
        let data = temp.path().join("data");
        let cache = temp.path().join("cache");
        let media = temp.path().join("media");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        std::fs::create_dir_all(&media).unwrap();
        let store = Store::open(&data, &cache, &media).unwrap();
        let category = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let article = Article {
            id: 9,
            feed_id: 2,
            title: "Article".into(),
            url: "https://example.test/9".into(),
            comments_url: String::new(),
            published_at: "2020-01-01T00:00:00Z".into(),
            is_read: true,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        };
        let enclosures = [
            Enclosure {
                id: 10,
                article_id: 9,
                url: "https://example.test/10.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
            Enclosure {
                id: 11,
                article_id: 9,
                url: "https://example.test/11.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
        ];
        store
            .reconcile_with_enclosures(
                &category,
                &feeds,
                std::slice::from_ref(&article),
                &enclosures,
            )
            .unwrap();
        store
            .request_download(10, crate::domain::DownloadOrigin::Manual)
            .unwrap();
        store
            .request_download(11, crate::domain::DownloadOrigin::Manual)
            .unwrap();

        // The remote snapshot does not contain either Article 9 nor its protected Enclosures.
        let snapshot = RemoteSnapshot {
            categories: category.to_vec(),
            feeds: feeds.to_vec(),
            articles: Vec::new(),
            enclosures: Vec::new(),
        };
        let remote = CountingRemote {
            snapshot,
            fetch_calls: AtomicUsize::new(0),
            fetched_articles: Mutex::new(Vec::new()),
        };
        let result = run(
            &remote,
            &store,
            ReadArticleRetention::Days30,
            SyncReason::Manual,
            HashMap::new(),
        );
        assert!(result.is_ok());
        // Two protected enclosures on the same article must produce at most one fetch.
        assert_eq!(remote.fetch_calls.load(Ordering::SeqCst), 1);
        assert_eq!(*remote.fetched_articles.lock().unwrap(), vec![9]);
    }
}
