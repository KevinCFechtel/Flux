//! SQLite persistence. Pending rows coalesce by article/field; acknowledgement
//! deletes only the exact sent revision so later local intent always survives.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::domain::{
    Article, ArticleQuery, ArticleScope, ArticleSort, ArticleSummary, Category, CoreError,
    CoreSettings, DeliveryMode, DetailRenderingMode, Enclosure, Feed, FeedPreferences,
    FeedSystemNotificationSetting, MutationField, NavigationCatalog, PlaybackState, PlaybackStatus,
    ReadArticleRetention, ReadFilter, SavedMedia, SavedMediaMarkerState,
    SavedMediaSyncConfiguration, SavedPlayableMediaItem, StarredFilter,
    SystemNotificationCandidate, WidgetArticle, WidgetCounts, WidgetData, WidgetScopedCount,
};
use crate::miniflux::normalize_installation_base;
use rusqlite::{Connection, OptionalExtension, Transaction, params};

const SCHEMA_VERSION: i64 = 12;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingSavedMediaReplication {
    pub enclosure_id: i64,
    pub article_id: i64,
    pub desired: SavedMediaMarkerState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedMediaRemoteState {
    pub enclosure_id: i64,
    pub article_id: i64,
    pub marker_entry_id: i64,
    pub state: SavedMediaMarkerState,
}

#[derive(Clone, Debug)]
pub struct PendingMutation {
    pub article_id: i64,
    pub field: MutationField,
    pub desired: bool,
    pub revision: i64,
    pub progression_seconds: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingMediaProgressMutation {
    pub enclosure_id: i64,
    pub progression_seconds: u64,
    pub revision: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LocalArticleState {
    pub is_read: bool,
    pub is_starred: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredEnclosure {
    pub enclosure: Enclosure,
    pub remote_present: bool,
}

pub(crate) struct ReaderArticle {
    pub feed_id: i64,
    pub url: String,
    pub raw_html_content: String,
    pub image_url: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReconciliationStats {
    pub new_articles: u32,
    pub updated_articles: u32,
    pub navigation_changed: bool,
    pub new_article_ids_by_feed: BTreeMap<i64, Vec<i64>>,
}

pub struct Store {
    connection: Mutex<Connection>,
    database_path: PathBuf,
}

impl Store {
    pub fn open(persistent_data: &Path, _cache: &Path, _media: &Path) -> Result<Self, CoreError> {
        let database_path = persistent_data.join("flux.sqlite3");
        let mut connection = Connection::open(&database_path).map_err(sql_error)?;
        connection
            .busy_timeout(std::time::Duration::from_secs(5))
            .map_err(sql_error)?;
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .map_err(sql_error)?;
        migrate(&mut connection)?;
        initialize_core_settings(&connection)?;
        let schema_version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(sql_error)?;
        tracing::info!(target: "storage", "storage initialized schema_version={schema_version}");
        Ok(Self {
            connection: Mutex::new(connection),
            database_path,
        })
    }
    pub fn database_path(&self) -> PathBuf {
        self.database_path.clone()
    }
    pub fn schema_version(&self) -> Result<i64, CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(sql_error)
    }
    pub fn set_base_url(&self, base_url: &str) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let previous: Option<String> = connection
            .query_row(
                "SELECT value FROM core_settings WHERE key='base_url'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql_error)?;
        let tx = connection.transaction().map_err(sql_error)?;
        let same_installation = previous.as_deref().is_some_and(|previous| {
            normalize_installation_base(previous)
                .map(|previous| previous == base_url)
                .unwrap_or(false)
        });
        if previous.is_some() && !same_installation {
            clear_synchronized_state(&tx, true)?;
        }
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('base_url', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [base_url]).map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }
    /// Discards server-derived state while preserving account association and user configuration.
    pub fn clear_synchronized_state_for_rebuild(&self) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        clear_synchronized_state(&tx, false)?;
        tx.commit().map_err(sql_error)
    }
    /// Restores all Core-owned persistent state to fresh-install defaults.
    pub fn reset_core_state(&self) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        clear_synchronized_state(&tx, true)?;
        tx.execute("DELETE FROM core_settings", [])
            .map_err(sql_error)?;
        for (key, value) in core_setting_defaults() {
            tx.execute(
                "INSERT INTO core_settings (key, value) VALUES (?1, ?2)",
                params![key, value],
            )
            .map_err(sql_error)?;
        }
        tx.commit().map_err(sql_error)
    }
    pub fn base_url(&self) -> Result<Option<String>, CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row(
                "SELECT value FROM core_settings WHERE key='base_url'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(sql_error)
    }
    pub fn core_settings(&self) -> Result<CoreSettings, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let retention = setting_value(&connection, "read_article_retention")?;
        let delivery_mode = setting_value(&connection, "delivery_mode")?;
        let background_sync_enabled = setting_value(&connection, "background_sync_enabled")?;
        let detail_character_limit = setting_value(&connection, "detail_character_limit")?;
        Ok(CoreSettings {
            retention: ReadArticleRetention::from_days(&retention)?,
            delivery_mode: match delivery_mode.as_str() {
                "live" => DeliveryMode::Live,
                "deferred" => DeliveryMode::Deferred,
                _ => return Err(CoreError::persistence("invalid delivery mode setting")),
            },
            background_sync_enabled: match background_sync_enabled.as_str() {
                "0" => false,
                "1" => true,
                _ => return Err(CoreError::persistence("invalid background sync setting")),
            },
            detail_character_limit: detail_character_limit
                .parse()
                .map_err(|_| CoreError::persistence("invalid detail character limit setting"))?,
        })
    }
    pub fn all_feed_preferences(&self) -> Result<Vec<FeedPreferences>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection
            .prepare("SELECT feed_id, system_notifications_enabled, detail_rendering, truncate_detail, open_in_miniflux FROM feed_preferences ORDER BY feed_id")
            .map_err(sql_error)?;
        statement
            .query_map([], |row| {
                Ok(FeedPreferences {
                    feed_id: row.get(0)?,
                    system_notifications_enabled: row.get(1)?,
                    detail_rendering: match row.get::<_, String>(2)?.as_str() {
                        "rendered" => DetailRenderingMode::Rendered,
                        "text_only" => DetailRenderingMode::TextOnly,
                        _ => return Err(rusqlite::Error::InvalidQuery),
                    },
                    truncate_detail: row.get(3)?,
                    open_in_miniflux: row.get(4)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }
    /// Replaces all Core configuration and discards server-derived state in one transaction.
    pub fn replace_configuration(
        &self,
        base_url: &str,
        settings: &CoreSettings,
        preferences: &[FeedPreferences],
    ) -> Result<(), CoreError> {
        if !matches!(settings.detail_character_limit, 5_000 | 10_000 | 20_000) {
            return Err(CoreError::data("unsupported detail character limit"));
        }
        let mut ids = HashSet::with_capacity(preferences.len());
        if preferences
            .iter()
            .any(|preference| preference.feed_id <= 0 || !ids.insert(preference.feed_id))
        {
            return Err(CoreError::data(
                "feed preferences must have unique positive feed IDs",
            ));
        }
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        clear_synchronized_state(&tx, true)?;
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('base_url', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [base_url]).map_err(sql_error)?;
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('read_article_retention', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [settings.retention.days().to_string()]).map_err(sql_error)?;
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('delivery_mode', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [match settings.delivery_mode { DeliveryMode::Live => "live", DeliveryMode::Deferred => "deferred" }]).map_err(sql_error)?;
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('background_sync_enabled', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [if settings.background_sync_enabled { "1" } else { "0" }]).map_err(sql_error)?;
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('detail_character_limit', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [settings.detail_character_limit.to_string()]).map_err(sql_error)?;
        for preference in preferences {
            tx.execute("INSERT INTO feed_preferences(feed_id, system_notifications_enabled, detail_rendering, truncate_detail, open_in_miniflux) VALUES(?1, ?2, ?3, ?4, ?5)", params![preference.feed_id, preference.system_notifications_enabled, match preference.detail_rendering { DetailRenderingMode::Rendered => "rendered", DetailRenderingMode::TextOnly => "text_only" }, preference.truncate_detail, preference.open_in_miniflux]).map_err(sql_error)?;
        }
        tx.commit().map_err(sql_error)
    }
    pub fn set_retention(&self, retention: ReadArticleRetention) -> Result<(), CoreError> {
        self.set_setting("read_article_retention", &retention.days().to_string())
    }
    pub fn set_delivery_mode(&self, mode: DeliveryMode) -> Result<(), CoreError> {
        self.set_setting(
            "delivery_mode",
            match mode {
                DeliveryMode::Live => "live",
                DeliveryMode::Deferred => "deferred",
            },
        )
    }
    pub fn set_background_sync_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        self.set_setting("background_sync_enabled", if enabled { "1" } else { "0" })
    }
    pub fn set_detail_character_limit(&self, limit: u32) -> Result<(), CoreError> {
        if !matches!(limit, 5_000 | 10_000 | 20_000) {
            return Err(CoreError::data("unsupported detail character limit"));
        }
        self.set_setting("detail_character_limit", &limit.to_string())
    }
    fn set_setting(&self, key: &str, value: &str) -> Result<(), CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "INSERT INTO core_settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(sql_error)?;
        Ok(())
    }
    pub fn reconcile(
        &self,
        categories: &[Category],
        feeds: &[Feed],
        articles: &[Article],
    ) -> Result<ReconciliationStats, CoreError> {
        self.reconcile_with_enclosures(categories, feeds, articles, &[])
    }
    pub fn reconcile_with_enclosures(
        &self,
        categories: &[Category],
        feeds: &[Feed],
        articles: &[Article],
        enclosures: &[Enclosure],
    ) -> Result<ReconciliationStats, CoreError> {
        self.reconcile_with_enclosures_and_progress(
            categories,
            feeds,
            articles,
            enclosures,
            &HashMap::new(),
        )
    }
    pub fn reconcile_with_enclosures_and_progress(
        &self,
        categories: &[Category],
        feeds: &[Feed],
        articles: &[Article],
        enclosures: &[Enclosure],
        media_progress_writes: &HashMap<i64, u64>,
    ) -> Result<ReconciliationStats, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let mut stats = ReconciliationStats::default();
        for c in categories {
            let existing = tx
                .query_row("SELECT title FROM categories WHERE id=?1", [c.id], |row| {
                    row.get::<_, String>(0)
                })
                .optional()
                .map_err(sql_error)?;
            stats.navigation_changed |= existing.as_deref() != Some(c.title.as_str());
            tx.execute("INSERT INTO categories (id,title) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET title=excluded.title", params![c.id,c.title]).map_err(sql_error)?;
        }
        for f in feeds {
            let existing = tx
                .query_row(
                    "SELECT category_id,title FROM feeds WHERE id=?1",
                    [f.id],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
                )
                .optional()
                .map_err(sql_error)?;
            stats.navigation_changed |=
                existing.as_ref() != Some(&(f.category_id, f.title.clone()));
            tx.execute("INSERT INTO feeds (id,category_id,title) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET category_id=excluded.category_id,title=excluded.title", params![f.id,f.category_id,f.title]).map_err(sql_error)?;
        }
        let remote_feed_ids: HashSet<i64> = feeds.iter().map(|feed| feed.id).collect();
        let stale_feed_ids = {
            let mut statement = tx.prepare("SELECT id FROM feeds").map_err(sql_error)?;
            statement
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
                .into_iter()
                .filter(|feed_id| !remote_feed_ids.contains(feed_id))
                .collect::<Vec<_>>()
        };
        let removed_preference_ids = {
            let mut statement = tx
                .prepare("SELECT feed_id FROM feed_preferences")
                .map_err(sql_error)?;
            statement
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
                .into_iter()
                .filter(|feed_id| !remote_feed_ids.contains(feed_id))
                .collect::<Vec<_>>()
        };
        for feed_id in &stale_feed_ids {
            // Pending mutations do not cascade from articles; all notification state cascades.
            tx.execute("DELETE FROM pending_mutations WHERE article_id IN (SELECT id FROM articles WHERE feed_id=?1)", [feed_id]).map_err(sql_error)?;
            tx.execute("DELETE FROM articles WHERE feed_id=?1", [feed_id])
                .map_err(sql_error)?;
            tx.execute("DELETE FROM feeds WHERE id=?1", [feed_id])
                .map_err(sql_error)?;
        }
        for feed_id in removed_preference_ids {
            tx.execute("DELETE FROM feed_preferences WHERE feed_id=?1", [feed_id])
                .map_err(sql_error)?;
        }
        stats.navigation_changed |= !stale_feed_ids.is_empty();
        let remote_article_ids: HashSet<i64> = articles.iter().map(|article| article.id).collect();
        let absent_articles = {
            let mut statement = tx
                .prepare("SELECT id,remote_is_read,remote_is_starred FROM articles")
                .map_err(sql_error)?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, bool>(1)?,
                        row.get::<_, bool>(2)?,
                    ))
                })
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
        };
        // The remote snapshot is the union of unread and starred articles. An absent local
        // article is therefore remotely read and unstarred, unless local intent is pending.
        for (id, remote_is_read, remote_is_starred) in absent_articles {
            if remote_article_ids.contains(&id) {
                continue;
            }
            if !remote_is_read || remote_is_starred {
                stats.updated_articles += 1;
            }
            tx.execute("UPDATE articles SET remote_is_read=1,remote_is_starred=0,is_read=CASE WHEN EXISTS(SELECT 1 FROM pending_mutations p WHERE p.article_id=articles.id AND p.field='read') THEN is_read ELSE 1 END,is_starred=CASE WHEN EXISTS(SELECT 1 FROM pending_mutations p WHERE p.article_id=articles.id AND p.field='starred') THEN is_starred ELSE 0 END WHERE id=?1", [id]).map_err(sql_error)?;
        }
        for a in articles {
            let existing = tx
                .query_row("SELECT feed_id,title,url,comments_url,published_at,remote_is_read,remote_is_starred,raw_html_content,preview,image_url FROM articles WHERE id=?1", [a.id], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?, row.get::<_, String>(4)?, row.get::<_, bool>(5)?, row.get::<_, bool>(6)?, row.get::<_, String>(7)?, row.get::<_, String>(8)?, row.get::<_, Option<String>>(9)?)))
                .optional()
                .map_err(sql_error)?;
            match existing {
                None => {
                    stats.new_articles += 1;
                    stats
                        .new_article_ids_by_feed
                        .entry(a.feed_id)
                        .or_default()
                        .push(a.id);
                }
                Some(existing)
                    if existing
                        != (
                            a.feed_id,
                            a.title.clone(),
                            a.url.clone(),
                            a.comments_url.clone(),
                            a.published_at.clone(),
                            a.is_read,
                            a.is_starred,
                            a.raw_html_content.clone(),
                            a.preview.clone(),
                            a.image_url.clone(),
                        ) =>
                {
                    stats.updated_articles += 1
                }
                Some(_) => {}
            }
            tx.execute("INSERT INTO articles (id,feed_id,title,url,comments_url,published_at,is_read,is_starred,remote_is_read,remote_is_starred,raw_html_content,preview,image_url,content_processing_version) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?7,?8,?9,?10,?11,?12) ON CONFLICT(id) DO UPDATE SET feed_id=excluded.feed_id,title=excluded.title,url=excluded.url,comments_url=excluded.comments_url,published_at=excluded.published_at,remote_is_read=excluded.remote_is_read,remote_is_starred=excluded.remote_is_starred,is_read=CASE WHEN EXISTS(SELECT 1 FROM pending_mutations p WHERE p.article_id=excluded.id AND p.field='read') THEN articles.is_read ELSE excluded.is_read END,is_starred=CASE WHEN EXISTS(SELECT 1 FROM pending_mutations p WHERE p.article_id=excluded.id AND p.field='starred') THEN articles.is_starred ELSE excluded.is_starred END,raw_html_content=excluded.raw_html_content,preview=excluded.preview,image_url=excluded.image_url,content_processing_version=excluded.content_processing_version", params![a.id,a.feed_id,a.title,a.url,a.comments_url,a.published_at,a.is_read,a.is_starred,a.raw_html_content,a.preview,a.image_url,crate::article::PROCESSING_VERSION]).map_err(sql_error)?;
        }
        reconcile_remote_enclosures(&tx, articles, enclosures, media_progress_writes)?;
        let remote_category_ids: HashSet<i64> =
            categories.iter().map(|category| category.id).collect();
        let stale_category_ids = {
            let mut statement = tx.prepare("SELECT id FROM categories").map_err(sql_error)?;
            statement
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
                .into_iter()
                .filter(|category_id| !remote_category_ids.contains(category_id))
                .collect::<Vec<_>>()
        };
        for category_id in &stale_category_ids {
            tx.execute("DELETE FROM categories WHERE id=?1", [category_id])
                .map_err(sql_error)?;
        }
        stats.navigation_changed |= !stale_category_ids.is_empty();
        tx.commit().map_err(sql_error)?;
        Ok(stats)
    }

    /// Stores remotely observed enclosures without deciding remote-removal state.
    pub fn upsert_remote_enclosures(&self, enclosures: &[Enclosure]) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        upsert_remote_enclosures(&tx, enclosures)?;
        tx.commit().map_err(sql_error)
    }

    pub fn enclosure(&self, enclosure_id: i64) -> Result<Option<StoredEnclosure>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        connection
            .query_row(
                "SELECT id,article_id,url,mime_type,size_bytes,remote_media_progression_seconds,remote_present FROM enclosures WHERE id=?1",
                [enclosure_id],
                stored_enclosure_from_row,
            )
            .optional()
            .map_err(sql_error)
    }

    pub fn enclosures_for_article(
        &self,
        article_id: i64,
    ) -> Result<Vec<StoredEnclosure>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection
            .prepare("SELECT id,article_id,url,mime_type,size_bytes,remote_media_progression_seconds,remote_present FROM enclosures WHERE article_id=?1 ORDER BY id")
            .map_err(sql_error)?;
        statement
            .query_map([article_id], stored_enclosure_from_row)
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn set_enclosure_remote_present(
        &self,
        enclosure_id: i64,
        remote_present: bool,
    ) -> Result<(), CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        if connection
            .execute(
                "UPDATE enclosures SET remote_present=?2 WHERE id=?1",
                params![enclosure_id, remote_present],
            )
            .map_err(sql_error)?
            == 0
        {
            return Err(CoreError::data(format!(
                "enclosure {enclosure_id} does not exist"
            )));
        }
        Ok(())
    }

    pub fn save_media(&self, enclosure_id: i64, added_at: &str) -> Result<bool, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let inserted = save_media(&tx, enclosure_id, added_at)?;
        if inserted {
            queue_saved_media_replication(&tx, enclosure_id, SavedMediaMarkerState::Saved)?;
        }
        tx.commit().map_err(sql_error)?;
        Ok(inserted)
    }

    /// Atomically materializes a remote-search article/enclosure before saving it locally.
    pub fn materialize_saved_media(
        &self,
        article: &Article,
        enclosure: &Enclosure,
        added_at: &str,
    ) -> Result<(), CoreError> {
        if enclosure.article_id != article.id {
            return Err(CoreError::data(
                "search enclosure does not belong to the materialized article",
            ));
        }
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute("INSERT INTO articles (id,feed_id,title,url,comments_url,published_at,is_read,is_starred,remote_is_read,remote_is_starred,raw_html_content,preview,image_url,content_processing_version) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?7,?8,?9,?10,?11,?12) ON CONFLICT(id) DO NOTHING", params![article.id,article.feed_id,article.title,article.url,article.comments_url,article.published_at,article.is_read,article.is_starred,article.raw_html_content,article.preview,article.image_url,crate::article::PROCESSING_VERSION]).map_err(sql_error)?;
        upsert_remote_enclosures(&tx, std::slice::from_ref(enclosure))?;
        save_media(&tx, enclosure.id, added_at)?;
        tx.commit().map_err(sql_error)
    }

    pub fn unsave_media(&self, enclosure_id: i64) -> Result<bool, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let removed = tx
            .execute(
                "DELETE FROM saved_media WHERE enclosure_id=?1",
                [enclosure_id],
            )
            .map_err(sql_error)?
            > 0;
        if removed {
            queue_saved_media_replication(&tx, enclosure_id, SavedMediaMarkerState::Unsaved)?;
        }
        tx.commit().map_err(sql_error)?;
        Ok(removed)
    }

    pub fn saved_media_sync_configuration(&self) -> Result<SavedMediaSyncConfiguration, CoreError> {
        self.connection.lock().map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row("SELECT enabled,sync_feed_id,requires_repair FROM saved_media_sync_config WHERE id=1", [], |row| Ok(SavedMediaSyncConfiguration { enabled: row.get(0)?, sync_feed_id: row.get(1)?, requires_repair: row.get(2)? })).map_err(sql_error)
    }

    pub fn enable_saved_media_sync(&self, feed_id: i64) -> Result<(), CoreError> {
        if feed_id <= 0 {
            return Err(CoreError::data("SavedMedia sync feed ID must be positive"));
        }
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute("UPDATE saved_media_sync_config SET enabled=1,sync_feed_id=?1,requires_repair=0 WHERE id=1", [feed_id]).map_err(sql_error)?;
        tx.execute("INSERT INTO pending_saved_media_replication(enclosure_id,article_id,desired) SELECT s.enclosure_id,e.article_id,'saved' FROM saved_media s JOIN enclosures e ON e.id=s.enclosure_id ON CONFLICT(enclosure_id) DO UPDATE SET article_id=excluded.article_id,desired=excluded.desired", []).map_err(sql_error)?;
        tx.execute("INSERT INTO pending_saved_media_replication(enclosure_id,article_id,desired) SELECT r.enclosure_id,r.article_id,'unsaved' FROM saved_media_remote_state r WHERE NOT EXISTS(SELECT 1 FROM saved_media s WHERE s.enclosure_id=r.enclosure_id) ON CONFLICT(enclosure_id) DO UPDATE SET article_id=excluded.article_id,desired=excluded.desired", []).map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    pub fn disable_saved_media_sync(&self) -> Result<(), CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "UPDATE saved_media_sync_config SET enabled=0 WHERE id=1",
                [],
            )
            .map_err(sql_error)?;
        Ok(())
    }

    pub fn mark_saved_media_sync_repair_required(&self) -> Result<(), CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "UPDATE saved_media_sync_config SET requires_repair=1 WHERE id=1",
                [],
            )
            .map_err(sql_error)?;
        Ok(())
    }

    pub fn pending_saved_media_replication(
        &self,
    ) -> Result<Vec<PendingSavedMediaReplication>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection.prepare("SELECT enclosure_id,article_id,desired FROM pending_saved_media_replication ORDER BY enclosure_id").map_err(sql_error)?;
        statement
            .query_map([], |row| {
                Ok(PendingSavedMediaReplication {
                    enclosure_id: row.get(0)?,
                    article_id: row.get(1)?,
                    desired: marker_state_from_db(&row.get::<_, String>(2)?)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn acknowledge_saved_media_replication(
        &self,
        enclosure_id: i64,
        desired: SavedMediaMarkerState,
    ) -> Result<(), CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "DELETE FROM pending_saved_media_replication WHERE enclosure_id=?1 AND desired=?2",
                params![enclosure_id, marker_state_db(desired)],
            )
            .map_err(sql_error)?;
        Ok(())
    }

    /// Records the remote write before conditionally clearing the matching local intent.
    pub fn acknowledge_saved_media_replication_with_remote_state(
        &self,
        state: &SavedMediaRemoteState,
        desired: SavedMediaMarkerState,
    ) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute("INSERT INTO saved_media_remote_state(enclosure_id,article_id,marker_entry_id,state) VALUES(?1,?2,?3,?4) ON CONFLICT(enclosure_id) DO UPDATE SET article_id=excluded.article_id,marker_entry_id=excluded.marker_entry_id,state=excluded.state", params![state.enclosure_id,state.article_id,state.marker_entry_id,marker_state_db(state.state)]).map_err(sql_error)?;
        tx.execute(
            "DELETE FROM pending_saved_media_replication WHERE enclosure_id=?1 AND desired=?2",
            params![state.enclosure_id, marker_state_db(desired)],
        )
        .map_err(sql_error)?;
        tx.commit().map_err(sql_error)
    }

    pub fn saved_media_replication_pending(&self, enclosure_id: i64) -> Result<bool, CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM pending_saved_media_replication WHERE enclosure_id=?1)",
                [enclosure_id],
                |row| row.get(0),
            )
            .map_err(sql_error)
    }

    pub fn saved_media_remote_state(
        &self,
        enclosure_id: i64,
    ) -> Result<Option<SavedMediaRemoteState>, CoreError> {
        self.connection.lock().map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row("SELECT enclosure_id,article_id,marker_entry_id,state FROM saved_media_remote_state WHERE enclosure_id=?1", [enclosure_id], |row| Ok(SavedMediaRemoteState { enclosure_id: row.get(0)?, article_id: row.get(1)?, marker_entry_id: row.get(2)?, state: marker_state_from_db(&row.get::<_, String>(3)?)? })).optional().map_err(sql_error)
    }

    pub fn record_saved_media_remote_state(
        &self,
        state: &SavedMediaRemoteState,
    ) -> Result<(), CoreError> {
        self.connection.lock().map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute("INSERT INTO saved_media_remote_state(enclosure_id,article_id,marker_entry_id,state) VALUES(?1,?2,?3,?4) ON CONFLICT(enclosure_id) DO UPDATE SET article_id=excluded.article_id,marker_entry_id=excluded.marker_entry_id,state=excluded.state", params![state.enclosure_id,state.article_id,state.marker_entry_id,marker_state_db(state.state)]).map_err(sql_error)?;
        Ok(())
    }

    pub fn apply_remote_saved_media_state(
        &self,
        enclosure_id: i64,
        state: SavedMediaMarkerState,
        added_at: &str,
    ) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        match state {
            SavedMediaMarkerState::Saved => {
                save_media(&tx, enclosure_id, added_at)?;
            }
            SavedMediaMarkerState::Unsaved => {
                tx.execute(
                    "DELETE FROM saved_media WHERE enclosure_id=?1",
                    [enclosure_id],
                )
                .map_err(sql_error)?;
            }
        }
        tx.commit().map_err(sql_error)
    }

    pub fn saved_media(&self, enclosure_id: i64) -> Result<Option<SavedMedia>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        connection
            .query_row(
                "SELECT enclosure_id,added_at FROM saved_media WHERE enclosure_id=?1",
                [enclosure_id],
                |row| {
                    Ok(SavedMedia {
                        enclosure_id: row.get(0)?,
                        added_at: row.get(1)?,
                    })
                },
            )
            .optional()
            .map_err(sql_error)
    }

    pub fn playback_state(&self, enclosure_id: i64) -> Result<Option<PlaybackState>, CoreError> {
        self.connection.lock().map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row("SELECT enclosure_id,position_ms,duration_ms,status,updated_at FROM playback_states WHERE enclosure_id=?1", [enclosure_id], playback_state_from_row).optional().map_err(sql_error)
    }

    pub fn protected_playback_article_ids(&self) -> Result<Vec<i64>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection.prepare("SELECT DISTINCT e.article_id FROM enclosures e LEFT JOIN playback_states p ON p.enclosure_id=e.id AND p.status='in_progress' LEFT JOIN pending_media_progress_mutations m ON m.enclosure_id=e.id WHERE p.enclosure_id IS NOT NULL OR m.enclosure_id IS NOT NULL ORDER BY e.article_id").map_err(sql_error)?;
        statement
            .query_map([], |row| row.get(0))
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn checkpoint_playback(
        &self,
        enclosure_id: i64,
        position_ms: u64,
        duration_ms: Option<u64>,
        updated_at: &str,
        queue_progress: bool,
    ) -> Result<(), CoreError> {
        if duration_ms.is_some_and(|duration| position_ms > duration) {
            return Err(CoreError::data("playback position exceeds duration"));
        }
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        ensure_enclosure(&tx, enclosure_id)?;
        upsert_playback_state(
            &tx,
            enclosure_id,
            position_ms,
            duration_ms,
            PlaybackStatus::InProgress,
            updated_at,
        )?;
        if queue_progress {
            queue_media_progress(&tx, enclosure_id, milliseconds_to_seconds(position_ms)?)?;
        }
        tx.commit().map_err(sql_error)
    }

    pub fn observe_media_duration(
        &self,
        enclosure_id: i64,
        duration_ms: u64,
        updated_at: &str,
    ) -> Result<(), CoreError> {
        let state = self.playback_state(enclosure_id)?;
        let Some(state) = state else {
            let connection = self
                .connection
                .lock()
                .map_err(|_| CoreError::internal("database lock poisoned"))?;
            let exists: bool = connection
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM enclosures WHERE id=?1)",
                    [enclosure_id],
                    |row| row.get(0),
                )
                .map_err(sql_error)?;
            if !exists {
                return Err(CoreError::data(format!(
                    "enclosure {enclosure_id} does not exist"
                )));
            }
            return Ok(());
        };
        let (position, status) = (state.position_ms.min(duration_ms), state.status);
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        ensure_enclosure(&tx, enclosure_id)?;
        upsert_playback_state(
            &tx,
            enclosure_id,
            position,
            Some(duration_ms),
            status,
            updated_at,
        )?;
        tx.commit().map_err(sql_error)
    }

    pub fn complete_playback(
        &self,
        enclosure_id: i64,
        duration_ms: Option<u64>,
        updated_at: &str,
        queue_progress: bool,
    ) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        ensure_enclosure(&tx, enclosure_id)?;
        let existing: Option<(i64, Option<i64>)> = tx
            .query_row(
                "SELECT position_ms,duration_ms FROM playback_states WHERE enclosure_id=?1",
                [enclosure_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(sql_error)?;
        let duration_ms = duration_ms.or_else(|| {
            existing.and_then(|(_, duration)| duration.and_then(|value| u64::try_from(value).ok()))
        });
        let position_ms = duration_ms
            .or_else(|| existing.and_then(|(position, _)| u64::try_from(position).ok()))
            .ok_or_else(|| {
                CoreError::data(
                    "playback completion requires a duration or prior playback position",
                )
            })?;
        upsert_playback_state(
            &tx,
            enclosure_id,
            position_ms,
            duration_ms,
            PlaybackStatus::Completed,
            updated_at,
        )?;
        if queue_progress && let Some(duration) = duration_ms {
            queue_media_progress(&tx, enclosure_id, milliseconds_to_seconds(duration)?)?;
        }
        tx.commit().map_err(sql_error)
    }

    pub fn restart_playback(
        &self,
        enclosure_id: i64,
        updated_at: &str,
        queue_progress: bool,
    ) -> Result<(), CoreError> {
        self.checkpoint_playback(
            enclosure_id,
            0,
            self.playback_state(enclosure_id)?
                .and_then(|state| state.duration_ms),
            updated_at,
            queue_progress,
        )
    }

    pub fn promote_playback_progress(&self) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let states = {
            let mut statement = tx
                .prepare("SELECT enclosure_id,position_ms,duration_ms,status FROM playback_states")
                .map_err(sql_error)?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<i64>>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                })
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
        };
        for (enclosure_id, position, duration, status) in states {
            let milliseconds = if status == "completed" {
                duration
            } else {
                Some(position)
            };
            if let Some(milliseconds) = milliseconds {
                queue_media_progress(
                    &tx,
                    enclosure_id,
                    milliseconds_to_seconds(
                        u64::try_from(milliseconds)
                            .map_err(|_| CoreError::persistence("invalid playback position"))?,
                    )?,
                )?;
            }
        }
        tx.commit().map_err(sql_error)
    }

    pub fn saved_playable_media(&self) -> Result<Vec<SavedPlayableMediaItem>, CoreError> {
        self.saved_playable_media_query(None)
    }

    pub fn saved_media_by_feed(
        &self,
        feed_id: i64,
    ) -> Result<Vec<SavedPlayableMediaItem>, CoreError> {
        self.saved_playable_media_query(Some(feed_id))
    }

    fn saved_playable_media_query(
        &self,
        feed_id: Option<i64>,
    ) -> Result<Vec<SavedPlayableMediaItem>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let sql = if feed_id.is_some() {
            "SELECT s.enclosure_id,e.article_id,a.feed_id,a.title,f.title,a.published_at,s.added_at,e.url,e.mime_type,e.remote_present FROM saved_media s JOIN enclosures e ON e.id=s.enclosure_id JOIN articles a ON a.id=e.article_id JOIN feeds f ON f.id=a.feed_id WHERE a.feed_id=?1 ORDER BY a.published_at DESC,a.id DESC,e.id DESC"
        } else {
            "SELECT s.enclosure_id,e.article_id,a.feed_id,a.title,f.title,a.published_at,s.added_at,e.url,e.mime_type,e.remote_present FROM saved_media s JOIN enclosures e ON e.id=s.enclosure_id JOIN articles a ON a.id=e.article_id JOIN feeds f ON f.id=a.feed_id ORDER BY s.added_at DESC,s.enclosure_id DESC"
        };
        let mut statement = connection.prepare(sql).map_err(sql_error)?;
        let rows = if let Some(feed_id) = feed_id {
            statement.query_map([feed_id], saved_playable_media_from_row)
        } else {
            statement.query_map([], saved_playable_media_from_row)
        }
        .map_err(sql_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql_error)?;
        Ok(rows
            .into_iter()
            .filter(|item| {
                matches!(
                    item.media_kind,
                    crate::domain::MediaKind::Audio | crate::domain::MediaKind::Video
                )
            })
            .collect())
    }

    pub fn feed_system_notification_settings(
        &self,
    ) -> Result<Vec<FeedSystemNotificationSetting>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection.prepare("SELECT f.id,f.title,COALESCE(p.system_notifications_enabled,0) FROM feeds f LEFT JOIN feed_preferences p ON p.feed_id=f.id ORDER BY f.category_id,f.title COLLATE NOCASE,f.id").map_err(sql_error)?;
        statement
            .query_map([], |row| {
                Ok(FeedSystemNotificationSetting {
                    feed_id: row.get(0)?,
                    feed_title: row.get(1)?,
                    system_notifications_enabled: row.get(2)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn set_feed_system_notifications_enabled(
        &self,
        feed_id: i64,
        enabled: bool,
    ) -> Result<(), CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        if connection
            .query_row("SELECT 1 FROM feeds WHERE id=?1", [feed_id], |_| Ok(()))
            .optional()
            .map_err(sql_error)?
            .is_none()
        {
            return Err(CoreError::data(format!("feed {feed_id} does not exist")));
        }
        connection.execute("INSERT INTO feed_preferences(feed_id,system_notifications_enabled) VALUES(?1,?2) ON CONFLICT(feed_id) DO UPDATE SET system_notifications_enabled=excluded.system_notifications_enabled", params![feed_id, enabled]).map_err(sql_error)?;
        Ok(())
    }

    pub fn feed_preferences(&self, feed_id: i64) -> Result<FeedPreferences, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        connection.query_row("SELECT system_notifications_enabled,detail_rendering,truncate_detail,open_in_miniflux FROM feed_preferences WHERE feed_id=?1", [feed_id], |row| {
            Ok(FeedPreferences {
                feed_id,
                system_notifications_enabled: row.get(0)?,
                detail_rendering: match row.get::<_, String>(1)?.as_str() {
                    "rendered" => DetailRenderingMode::Rendered,
                    "text_only" => DetailRenderingMode::TextOnly,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                },
                truncate_detail: row.get(2)?,
                open_in_miniflux: row.get(3)?,
            })
        }).optional().map_err(sql_error)?.map_or_else(|| {
            let exists = connection.query_row("SELECT 1 FROM feeds WHERE id=?1", [feed_id], |_| Ok(())).optional().map_err(sql_error)?.is_some();
            if exists { Ok(FeedPreferences::defaults(feed_id)) } else { Err(CoreError::data(format!("feed {feed_id} does not exist"))) }
        }, Ok)
    }

    pub fn set_feed_detail_rendering(
        &self,
        feed_id: i64,
        mode: DetailRenderingMode,
    ) -> Result<(), CoreError> {
        self.set_feed_preference(
            feed_id,
            "detail_rendering",
            match mode {
                DetailRenderingMode::Rendered => "rendered",
                DetailRenderingMode::TextOnly => "text_only",
            },
        )
    }
    pub fn set_feed_truncate_detail(&self, feed_id: i64, enabled: bool) -> Result<(), CoreError> {
        self.set_feed_preference(feed_id, "truncate_detail", if enabled { "1" } else { "0" })
    }
    pub fn set_feed_open_in_miniflux(&self, feed_id: i64, enabled: bool) -> Result<(), CoreError> {
        self.set_feed_preference(feed_id, "open_in_miniflux", if enabled { "1" } else { "0" })
    }
    fn set_feed_preference(
        &self,
        feed_id: i64,
        column: &str,
        value: &str,
    ) -> Result<(), CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let exists = connection
            .query_row("SELECT 1 FROM feeds WHERE id=?1", [feed_id], |_| Ok(()))
            .optional()
            .map_err(sql_error)?
            .is_some();
        if !exists {
            return Err(CoreError::data(format!("feed {feed_id} does not exist")));
        }
        let sql = format!(
            "INSERT INTO feed_preferences(feed_id,{column}) VALUES(?1,?2) ON CONFLICT(feed_id) DO UPDATE SET {column}=excluded.{column}"
        );
        connection
            .execute(&sql, params![feed_id, value])
            .map_err(sql_error)?;
        Ok(())
    }

    pub fn prepare_system_notification_candidates(
        &self,
        new_article_ids_by_feed: &BTreeMap<i64, Vec<i64>>,
    ) -> Result<Vec<SystemNotificationCandidate>, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        for article_ids in new_article_ids_by_feed.values() {
            for article_id in article_ids {
                tx.execute("INSERT INTO pending_system_notifications(article_id) SELECT ?1 WHERE EXISTS(SELECT 1 FROM articles WHERE id=?1) ON CONFLICT(article_id) DO NOTHING", [article_id]).map_err(sql_error)?;
            }
        }
        let feeds = {
            let mut statement = tx.prepare("SELECT f.id,f.title FROM feeds f JOIN feed_preferences p ON p.feed_id=f.id WHERE p.system_notifications_enabled=1 ORDER BY f.id").map_err(sql_error)?;
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
        };
        let mut candidates = Vec::new();
        for (feed_id, feed_title) in feeds {
            let article_ids = {
                let mut statement = tx.prepare("SELECT p.article_id FROM pending_system_notifications p JOIN articles a ON a.id=p.article_id WHERE a.feed_id=?1 AND NOT EXISTS(SELECT 1 FROM system_notified_articles n WHERE n.article_id=p.article_id) ORDER BY p.article_id").map_err(sql_error)?;
                statement
                    .query_map([feed_id], |row| row.get::<_, i64>(0))
                    .map_err(sql_error)?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(sql_error)?
            };
            if article_ids.is_empty() {
                continue;
            }
            tx.execute(
                "INSERT INTO system_notification_candidates(feed_id,feed_title) VALUES(?1,?2)",
                params![feed_id, feed_title],
            )
            .map_err(sql_error)?;
            let candidate_id = tx.last_insert_rowid();
            for article_id in &article_ids {
                tx.execute("INSERT INTO notification_candidate_articles(candidate_id,article_id) VALUES(?1,?2)", params![candidate_id, article_id]).map_err(sql_error)?;
            }
            candidates.push(SystemNotificationCandidate {
                candidate_id,
                feed_id,
                feed_title,
                new_count: article_ids.len() as u32,
            });
        }
        tx.commit().map_err(sql_error)?;
        Ok(candidates)
    }

    pub fn acknowledge_system_notification(&self, candidate_id: i64) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let exists = tx
            .query_row(
                "SELECT 1 FROM system_notification_candidates WHERE id=?1",
                [candidate_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(sql_error)?
            .is_some();
        if !exists {
            return Ok(());
        }
        tx.execute("INSERT INTO system_notified_articles(article_id) SELECT article_id FROM notification_candidate_articles WHERE candidate_id=?1 ON CONFLICT(article_id) DO NOTHING", [candidate_id]).map_err(sql_error)?;
        tx.execute("DELETE FROM pending_system_notifications WHERE article_id IN (SELECT article_id FROM notification_candidate_articles WHERE candidate_id=?1)", [candidate_id]).map_err(sql_error)?;
        tx.execute(
            "DELETE FROM system_notification_candidates WHERE id=?1",
            [candidate_id],
        )
        .map_err(sql_error)?;
        tx.execute("DELETE FROM system_notification_candidates WHERE NOT EXISTS(SELECT 1 FROM notification_candidate_articles ca WHERE ca.candidate_id=system_notification_candidates.id AND NOT EXISTS(SELECT 1 FROM system_notified_articles n WHERE n.article_id=ca.article_id))", []).map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    pub fn cleanup_expired_read_articles(&self, cutoff: &str) -> Result<u32, CoreError> {
        let deleted = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "DELETE FROM articles WHERE is_read=1 AND is_starred=0 AND published_at < ?1 AND NOT EXISTS(SELECT 1 FROM saved_media s JOIN enclosures e ON e.id=s.enclosure_id WHERE e.article_id=articles.id) AND NOT EXISTS(SELECT 1 FROM playback_states p JOIN enclosures e ON e.id=p.enclosure_id WHERE e.article_id=articles.id AND p.status='in_progress')",
                [cutoff],
            )
            .map_err(sql_error)?;
        Ok(deleted as u32)
    }

    pub fn local_article_state(
        &self,
        article_id: i64,
    ) -> Result<Option<LocalArticleState>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        connection
            .query_row(
                "SELECT is_read,is_starred FROM articles WHERE id=?1",
                [article_id],
                |row| {
                    Ok(LocalArticleState {
                        is_read: row.get(0)?,
                        is_starred: row.get(1)?,
                    })
                },
            )
            .optional()
            .map_err(sql_error)
    }
    pub(crate) fn reader_article(&self, article_id: i64) -> Result<ReaderArticle, CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row(
                "SELECT feed_id,url,raw_html_content,image_url FROM articles WHERE id=?1",
                [article_id],
                |row| {
                    Ok(ReaderArticle {
                        feed_id: row.get(0)?,
                        url: row.get(1)?,
                        raw_html_content: row.get(2)?,
                        image_url: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(sql_error)?
            .ok_or_else(|| CoreError::data(format!("article {article_id} does not exist")))
    }

    pub fn set_state_bulk(
        &self,
        article_ids: &[i64],
        field: MutationField,
        desired: bool,
    ) -> Result<Vec<PendingMutation>, CoreError> {
        let mut ids = article_ids.to_vec();
        ids.sort_unstable();
        ids.dedup();
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let field_name = field_name(field);
        let mut pending = Vec::with_capacity(ids.len());
        for id in ids {
            let column = match field {
                MutationField::Read => "is_read",
                MutationField::Starred => "is_starred",
                MutationField::MediaProgress => {
                    return Err(CoreError::internal(
                        "media progress is not an article state",
                    ));
                }
            };
            if tx
                .execute(
                    &format!("UPDATE articles SET {column}=?1 WHERE id=?2"),
                    params![desired, id],
                )
                .map_err(sql_error)?
                == 0
            {
                return Err(CoreError::data(format!("article {id} does not exist")));
            }
            tx.execute("INSERT INTO pending_mutations(article_id,field,desired,revision) VALUES(?1,?2,?3,1) ON CONFLICT(article_id,field) DO UPDATE SET desired=excluded.desired,revision=pending_mutations.revision+1",params![id,field_name,desired]).map_err(sql_error)?;
            let revision = tx
                .query_row(
                    "SELECT revision FROM pending_mutations WHERE article_id=?1 AND field=?2",
                    params![id, field_name],
                    |r| r.get(0),
                )
                .map_err(sql_error)?;
            pending.push(PendingMutation {
                article_id: id,
                field,
                desired,
                revision,
                progression_seconds: None,
            });
        }
        tx.commit().map_err(sql_error)?;
        Ok(pending)
    }
    pub fn pending_mutations(&self) -> Result<Vec<PendingMutation>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement=connection.prepare("SELECT article_id,field,desired,NULL,revision FROM pending_mutations ORDER BY article_id,field").map_err(sql_error)?;
        statement
            .query_map([], |r| {
                Ok(PendingMutation {
                    article_id: r.get(0)?,
                    field: parse_field(r.get::<_, String>(1)?.as_str())?,
                    desired: r.get(2)?,
                    progression_seconds: r
                        .get::<_, Option<i64>>(3)?
                        .map(|value| {
                            u64::try_from(value).map_err(|_| rusqlite::Error::InvalidQuery)
                        })
                        .transpose()?,
                    revision: r.get(4)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn pending_media_progress_mutations(
        &self,
    ) -> Result<Vec<PendingMediaProgressMutation>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut statement = connection.prepare("SELECT enclosure_id,progression_seconds,revision FROM pending_media_progress_mutations ORDER BY enclosure_id").map_err(sql_error)?;
        statement
            .query_map([], |row| {
                Ok(PendingMediaProgressMutation {
                    enclosure_id: row.get(0)?,
                    progression_seconds: u64::try_from(row.get::<_, i64>(1)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    revision: row.get(2)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }

    pub fn acknowledge_media_progress(
        &self,
        pending: &PendingMediaProgressMutation,
    ) -> Result<bool, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute(
            "UPDATE enclosures SET remote_media_progression_seconds=?1 WHERE id=?2",
            params![pending.progression_seconds, pending.enclosure_id],
        )
        .map_err(sql_error)?;
        let deleted = tx.execute("DELETE FROM pending_media_progress_mutations WHERE enclosure_id=?1 AND progression_seconds=?2 AND revision=?3", params![pending.enclosure_id, pending.progression_seconds, pending.revision]).map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(deleted == 1)
    }
    pub fn acknowledge(&self, pending: &PendingMutation) -> Result<bool, CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        let remote_column = match pending.field {
            MutationField::Read => "remote_is_read",
            MutationField::Starred => "remote_is_starred",
            MutationField::MediaProgress => "remote_media_progression_seconds",
        };
        if pending.field == MutationField::MediaProgress {
            tx.execute(
                "UPDATE enclosures SET remote_media_progression_seconds=?1 WHERE id=?2",
                params![pending.progression_seconds, pending.article_id],
            )
            .map_err(sql_error)?;
        } else {
            tx.execute(
                &format!("UPDATE articles SET {remote_column}=?1 WHERE id=?2"),
                params![pending.desired, pending.article_id],
            )
            .map_err(sql_error)?;
        }
        let deleted = tx
            .execute(
                "DELETE FROM pending_mutations WHERE article_id=?1 AND field=?2 AND revision=?3",
                params![
                    pending.article_id,
                    field_name(pending.field),
                    pending.revision
                ],
            )
            .map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(deleted == 1)
    }

    pub fn mark_sync_success(&self) -> Result<(), CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .execute(
                "INSERT INTO core_settings (key,value) VALUES ('last_successful_sync_at',datetime('now')) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [],
            )
            .map_err(sql_error)?;
        Ok(())
    }
    pub fn last_successful_sync_at(&self) -> Result<Option<String>, CoreError> {
        self.connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?
            .query_row(
                "SELECT value FROM core_settings WHERE key='last_successful_sync_at'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql_error)
    }
    pub fn navigation_catalog(&self) -> Result<NavigationCatalog, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut categories = connection
            .prepare("SELECT id,title FROM categories ORDER BY title COLLATE NOCASE,id")
            .map_err(sql_error)?;
        let categories = categories
            .query_map([], |row| {
                Ok(Category {
                    id: row.get(0)?,
                    title: row.get(1)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        let mut feeds=connection.prepare("SELECT id,category_id,title FROM feeds ORDER BY category_id,title COLLATE NOCASE,id").map_err(sql_error)?;
        let feeds = feeds
            .query_map([], |row| {
                Ok(Feed {
                    id: row.get(0)?,
                    category_id: row.get(1)?,
                    title: row.get(2)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        Ok(NavigationCatalog { categories, feeds })
    }
    pub fn count_articles(&self, query: &ArticleQuery) -> Result<u64, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let (sql, values) = article_filter_sql(
            "SELECT COUNT(*) FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE 1=1".into(),
            query,
        );
        connection
            .query_row(&sql, rusqlite::params_from_iter(values), |row| {
                row.get::<_, u64>(0)
            })
            .map_err(sql_error)
    }
    pub fn query_articles(&self, query: &ArticleQuery) -> Result<Vec<ArticleSummary>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let (mut sql,mut values)=article_filter_sql("SELECT a.id,a.feed_id,f.category_id,f.title,a.title,a.url,a.comments_url,a.published_at,a.is_read,a.is_starred,a.preview,a.image_url FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE 1=1".into(),query);
        let descending = query.sort == ArticleSort::NewestFirst;
        if let Some(cursor) = &query.cursor {
            let op = if descending { "<" } else { ">" };
            sql.push_str(&format!(
                " AND (a.published_at {op} ? OR (a.published_at = ? AND a.id {op} ?))"
            ));
            values.push(cursor.published_at.clone().into());
            values.push(cursor.published_at.clone().into());
            values.push(cursor.article_id.into());
        }
        let direction = if descending { "DESC" } else { "ASC" };
        sql.push_str(&format!(
            " ORDER BY a.published_at {direction}, a.id {direction}"
        ));
        if query.limit != 0 {
            sql.push_str(" LIMIT ?");
            values.push((query.limit as i64).into());
        }
        let mut statement = connection.prepare(&sql).map_err(sql_error)?;
        statement
            .query_map(rusqlite::params_from_iter(values), |r| {
                Ok(ArticleSummary {
                    id: r.get(0)?,
                    feed_id: r.get(1)?,
                    category_id: r.get(2)?,
                    feed_title: r.get(3)?,
                    title: r.get(4)?,
                    url: r.get(5)?,
                    comments_url: r.get(6)?,
                    published_at: r.get(7)?,
                    is_read: r.get(8)?,
                    is_starred: r.get(9)?,
                    preview: r.get(10)?,
                    image_url: r.get(11)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }
    pub fn widget_data(&self) -> Result<WidgetData, CoreError> {
        const UNREAD_PER_FEED: i64 = 12;
        const BOOKMARKS: i64 = 48;
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let catalog = self.navigation_catalog_locked(&connection)?;
        let mut statement = connection.prepare(
            "WITH unread AS (\
                SELECT a.id,a.feed_id,f.category_id,f.title AS feed_title,a.title AS article_title,a.published_at,a.is_read,a.is_starred,\
                    ROW_NUMBER() OVER (PARTITION BY a.feed_id ORDER BY a.published_at DESC,a.id DESC) AS position \
                FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE a.is_read=0 \
             ), selected_unread AS (SELECT * FROM unread WHERE position <= ?1), \
             selected_bookmarks AS (\
                SELECT a.id,a.feed_id,f.category_id,f.title AS feed_title,a.title AS article_title,a.published_at,a.is_read,a.is_starred \
                FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE a.is_starred=1 \
                ORDER BY a.published_at DESC,a.id DESC LIMIT ?2 \
             ) \
             SELECT id,feed_id,category_id,feed_title,article_title,published_at,is_read,is_starred FROM selected_unread \
             UNION ALL \
             SELECT b.id,b.feed_id,b.category_id,b.feed_title,b.article_title,b.published_at,b.is_read,b.is_starred FROM selected_bookmarks b \
             WHERE NOT EXISTS (SELECT 1 FROM selected_unread u WHERE u.id=b.id) \
             ORDER BY published_at DESC,id DESC",
        ).map_err(sql_error)?;
        let articles = statement
            .query_map(params![UNREAD_PER_FEED, BOOKMARKS], |r| {
                Ok(WidgetArticle {
                    id: r.get(0)?,
                    feed_id: r.get(1)?,
                    category_id: r.get(2)?,
                    feed_title: r.get(3)?,
                    title: r.get(4)?,
                    published_at: r.get(5)?,
                    is_read: r.get(6)?,
                    is_starred: r.get(7)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        let all_unread = connection
            .query_row("SELECT COUNT(*) FROM articles WHERE is_read=0", [], |r| {
                r.get(0)
            })
            .map_err(sql_error)?;
        let bookmarks = connection
            .query_row(
                "SELECT COUNT(*) FROM articles WHERE is_starred=1",
                [],
                |r| r.get(0),
            )
            .map_err(sql_error)?;
        let feed_unread = scoped_counts(
            &connection,
            "SELECT feed_id,COUNT(*) FROM articles WHERE is_read=0 GROUP BY feed_id ORDER BY feed_id",
        )?;
        let category_unread = scoped_counts(
            &connection,
            "SELECT f.category_id,COUNT(*) FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE a.is_read=0 GROUP BY f.category_id ORDER BY f.category_id",
        )?;
        let last_successful_sync_at = connection
            .query_row(
                "SELECT value FROM core_settings WHERE key='last_successful_sync_at'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(sql_error)?;
        Ok(WidgetData {
            categories: catalog.categories,
            feeds: catalog.feeds,
            articles,
            counts: WidgetCounts {
                all_unread,
                bookmarks,
                feed_unread,
                category_unread,
            },
            last_successful_sync_at,
        })
    }
    fn navigation_catalog_locked(
        &self,
        connection: &Connection,
    ) -> Result<NavigationCatalog, CoreError> {
        let mut categories = connection
            .prepare("SELECT id,title FROM categories ORDER BY title COLLATE NOCASE,id")
            .map_err(sql_error)?;
        let categories = categories
            .query_map([], |row| {
                Ok(Category {
                    id: row.get(0)?,
                    title: row.get(1)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        let mut feeds = connection.prepare("SELECT id,category_id,title FROM feeds ORDER BY category_id,title COLLATE NOCASE,id").map_err(sql_error)?;
        let feeds = feeds
            .query_map([], |row| {
                Ok(Feed {
                    id: row.get(0)?,
                    category_id: row.get(1)?,
                    title: row.get(2)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        Ok(NavigationCatalog { categories, feeds })
    }
}
fn scoped_counts(connection: &Connection, sql: &str) -> Result<Vec<WidgetScopedCount>, CoreError> {
    let mut statement = connection.prepare(sql).map_err(sql_error)?;
    statement
        .query_map([], |r| {
            Ok(WidgetScopedCount {
                id: r.get(0)?,
                count: r.get(1)?,
            })
        })
        .map_err(sql_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql_error)
}
fn article_filter_sql(
    mut sql: String,
    query: &ArticleQuery,
) -> (String, Vec<rusqlite::types::Value>) {
    let mut values = Vec::new();
    match query.scope {
        ArticleScope::All => {}
        ArticleScope::Category(id) => {
            sql.push_str(" AND f.category_id=?");
            values.push(id.into())
        }
        ArticleScope::Feed(id) => {
            sql.push_str(" AND a.feed_id=?");
            values.push(id.into())
        }
    }
    match query.read_filter {
        ReadFilter::All => {}
        ReadFilter::Read => sql.push_str(" AND a.is_read=1"),
        ReadFilter::Unread => sql.push_str(" AND a.is_read=0"),
    }
    match query.starred_filter {
        StarredFilter::All => {}
        StarredFilter::Starred => sql.push_str(" AND a.is_starred=1"),
        StarredFilter::Unstarred => sql.push_str(" AND a.is_starred=0"),
    }
    (sql, values)
}
fn migrate(connection: &mut Connection) -> Result<(), CoreError> {
    let current: i64 = connection
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(sql_error)?;
    if current > SCHEMA_VERSION {
        return Err(CoreError::persistence(
            "database schema is newer than this core",
        ));
    }
    if current == 0 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES categories(id), title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id), title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL CHECK(is_read IN(0,1)), is_starred INTEGER NOT NULL CHECK(is_starred IN(0,1)), raw_html_content TEXT NOT NULL); CREATE INDEX articles_published ON articles(published_at,id); CREATE INDEX articles_feed_published ON articles(feed_id,published_at,id); CREATE INDEX feeds_category ON feeds(category_id); PRAGMA user_version=1;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 2 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("ALTER TABLE articles ADD COLUMN remote_is_read INTEGER; ALTER TABLE articles ADD COLUMN remote_is_starred INTEGER; UPDATE articles SET remote_is_read=is_read, remote_is_starred=is_starred WHERE remote_is_read IS NULL; CREATE TABLE pending_mutations (article_id INTEGER NOT NULL REFERENCES articles(id), field TEXT NOT NULL CHECK(field IN ('read','starred')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); PRAGMA user_version=2;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 3 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("ALTER TABLE articles ADD COLUMN preview TEXT NOT NULL DEFAULT ''; ALTER TABLE articles ADD COLUMN image_url TEXT; PRAGMA user_version=3;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 4 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("ALTER TABLE articles ADD COLUMN content_processing_version INTEGER NOT NULL DEFAULT 0;").map_err(sql_error)?;
        let rows = {
            let mut statement = tx.prepare("SELECT id,url,raw_html_content FROM articles WHERE content_processing_version < ?1").map_err(sql_error)?;
            statement
                .query_map([crate::article::PROCESSING_VERSION], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?
        };
        tracing::info!(target: "storage", "article content reprocessing started");
        for (id, url, html) in &rows {
            let processed = crate::article::process(html, url, &[]);
            tx.execute("UPDATE articles SET preview=?1,image_url=?2,content_processing_version=?3 WHERE id=?4", params![processed.preview, processed.image_url, crate::article::PROCESSING_VERSION, id]).map_err(sql_error)?;
        }
        tx.pragma_update(None, "user_version", 4)
            .map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        tracing::info!(target: "storage", "article content reprocessing completed processed={}", rows.len());
    }
    if current < 5 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE feed_system_notification_preferences (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, enabled INTEGER NOT NULL CHECK(enabled IN(0,1))); CREATE TABLE pending_system_notifications (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notified_articles (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notification_candidates (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, feed_title TEXT NOT NULL); CREATE TABLE notification_candidate_articles (candidate_id INTEGER NOT NULL REFERENCES system_notification_candidates(id) ON DELETE CASCADE, article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE, PRIMARY KEY(candidate_id,article_id)); CREATE INDEX pending_system_notifications_article ON pending_system_notifications(article_id); PRAGMA user_version=5;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 6 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE feed_preferences (feed_id INTEGER PRIMARY KEY, system_notifications_enabled INTEGER NOT NULL DEFAULT 0 CHECK(system_notifications_enabled IN(0,1)), detail_rendering TEXT NOT NULL DEFAULT 'rendered' CHECK(detail_rendering IN('rendered','text_only')), truncate_detail INTEGER NOT NULL DEFAULT 0 CHECK(truncate_detail IN(0,1)), open_in_miniflux INTEGER NOT NULL DEFAULT 0 CHECK(open_in_miniflux IN(0,1))); INSERT INTO feed_preferences(feed_id,system_notifications_enabled) SELECT feed_id,enabled FROM feed_system_notification_preferences; DROP TABLE feed_system_notification_preferences; PRAGMA user_version=7;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current == 6 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE feed_preferences_replacement (feed_id INTEGER PRIMARY KEY, system_notifications_enabled INTEGER NOT NULL DEFAULT 0 CHECK(system_notifications_enabled IN(0,1)), detail_rendering TEXT NOT NULL DEFAULT 'rendered' CHECK(detail_rendering IN('rendered','text_only')), truncate_detail INTEGER NOT NULL DEFAULT 0 CHECK(truncate_detail IN(0,1)), open_in_miniflux INTEGER NOT NULL DEFAULT 0 CHECK(open_in_miniflux IN(0,1))); INSERT INTO feed_preferences_replacement (feed_id,system_notifications_enabled,detail_rendering,truncate_detail,open_in_miniflux) SELECT feed_id,system_notifications_enabled,detail_rendering,truncate_detail,open_in_miniflux FROM feed_preferences; DROP TABLE feed_preferences; ALTER TABLE feed_preferences_replacement RENAME TO feed_preferences; PRAGMA user_version=7;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 8 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE enclosures (id INTEGER PRIMARY KEY, article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE, url TEXT NOT NULL, mime_type TEXT NOT NULL, size_bytes INTEGER, remote_media_progression_seconds INTEGER NOT NULL CHECK(remote_media_progression_seconds >= 0), remote_present INTEGER NOT NULL DEFAULT 1 CHECK(remote_present IN(0,1)), CHECK(size_bytes IS NULL OR size_bytes > 0)); CREATE INDEX enclosures_article ON enclosures(article_id,id); PRAGMA user_version=8;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 9 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE saved_media (enclosure_id INTEGER PRIMARY KEY REFERENCES enclosures(id) ON DELETE CASCADE, added_at TEXT NOT NULL); CREATE INDEX saved_media_added_at ON saved_media(added_at DESC,enclosure_id DESC); PRAGMA user_version=9;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 10 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE saved_media_sync_config (id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)), sync_feed_id INTEGER, requires_repair INTEGER NOT NULL DEFAULT 0 CHECK(requires_repair IN(0,1))); INSERT INTO saved_media_sync_config(id) VALUES(1); CREATE TABLE pending_saved_media_replication (enclosure_id INTEGER PRIMARY KEY, article_id INTEGER NOT NULL, desired TEXT NOT NULL CHECK(desired IN ('saved','unsaved'))); CREATE TABLE saved_media_remote_state (enclosure_id INTEGER PRIMARY KEY, article_id INTEGER NOT NULL, marker_entry_id INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('saved','unsaved'))); PRAGMA user_version=10;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 11 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS pending_mutations (article_id INTEGER NOT NULL, field TEXT NOT NULL CHECK(field IN ('read','starred')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); CREATE TABLE pending_mutations_replacement (article_id INTEGER NOT NULL, field TEXT NOT NULL CHECK(field IN ('read','starred','media_progress')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), progression_seconds INTEGER, revision INTEGER NOT NULL, PRIMARY KEY(article_id,field), CHECK((field IN ('read','starred') AND progression_seconds IS NULL) OR (field='media_progress' AND progression_seconds >= 0))); INSERT INTO pending_mutations_replacement(article_id,field,desired,progression_seconds,revision) SELECT article_id,field,desired,NULL,revision FROM pending_mutations; DROP TABLE pending_mutations; ALTER TABLE pending_mutations_replacement RENAME TO pending_mutations; CREATE TABLE playback_states (enclosure_id INTEGER PRIMARY KEY REFERENCES enclosures(id) ON DELETE CASCADE, position_ms INTEGER NOT NULL CHECK(position_ms >= 0), duration_ms INTEGER CHECK(duration_ms >= 0), status TEXT NOT NULL CHECK(status IN ('in_progress','completed')), updated_at TEXT NOT NULL, CHECK(duration_ms IS NULL OR position_ms <= duration_ms)); PRAGMA user_version=11;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    if current < 12 {
        let tx = connection.transaction().map_err(sql_error)?;
        tx.execute_batch("CREATE TABLE pending_media_progress_mutations (enclosure_id INTEGER PRIMARY KEY REFERENCES enclosures(id) ON DELETE CASCADE, progression_seconds INTEGER NOT NULL CHECK(progression_seconds >= 0), revision INTEGER NOT NULL); INSERT INTO pending_media_progress_mutations(enclosure_id,progression_seconds,revision) SELECT article_id,progression_seconds,revision FROM pending_mutations WHERE field='media_progress'; CREATE TABLE pending_mutations_repaired (article_id INTEGER NOT NULL REFERENCES articles(id), field TEXT NOT NULL CHECK(field IN ('read','starred')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); INSERT INTO pending_mutations_repaired(article_id,field,desired,revision) SELECT article_id,field,desired,revision FROM pending_mutations WHERE field IN ('read','starred'); DROP TABLE pending_mutations; ALTER TABLE pending_mutations_repaired RENAME TO pending_mutations; PRAGMA user_version=12;").map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
    }
    Ok(())
}
fn initialize_core_settings(connection: &Connection) -> Result<(), CoreError> {
    for (key, value) in core_setting_defaults() {
        connection
            .execute(
                "INSERT INTO core_settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO NOTHING",
                params![key, value],
            )
            .map_err(sql_error)?;
    }
    Ok(())
}
fn core_setting_defaults() -> Vec<(&'static str, String)> {
    let defaults = CoreSettings::default();
    vec![
        (
            "read_article_retention",
            defaults.retention.days().to_string(),
        ),
        ("delivery_mode", "deferred".to_string()),
        (
            "background_sync_enabled",
            if defaults.background_sync_enabled {
                "1".to_string()
            } else {
                "0".to_string()
            },
        ),
        (
            "detail_character_limit",
            defaults.detail_character_limit.to_string(),
        ),
    ]
}
fn clear_synchronized_state(
    tx: &Transaction<'_>,
    remove_feed_preferences: bool,
) -> Result<(), CoreError> {
    tx.execute_batch("DELETE FROM notification_candidate_articles; DELETE FROM system_notification_candidates; DELETE FROM pending_system_notifications; DELETE FROM system_notified_articles; DELETE FROM pending_mutations; DELETE FROM articles;").map_err(sql_error)?;
    if remove_feed_preferences {
        tx.execute("DELETE FROM feed_preferences", [])
            .map_err(sql_error)?;
        // Technical feed IDs and remote baselines are scoped to the previous account.
        tx.execute_batch("DELETE FROM pending_saved_media_replication; DELETE FROM saved_media_remote_state; UPDATE saved_media_sync_config SET enabled=0,sync_feed_id=NULL,requires_repair=0 WHERE id=1;").map_err(sql_error)?;
    }
    tx.execute_batch("DELETE FROM feeds; DELETE FROM categories; DELETE FROM core_settings WHERE key='last_successful_sync_at';").map_err(sql_error)
}
fn upsert_remote_enclosures(
    tx: &Transaction<'_>,
    enclosures: &[Enclosure],
) -> Result<(), CoreError> {
    for enclosure in enclosures {
        let size_bytes = enclosure
            .size_bytes
            .map(i64::try_from)
            .transpose()
            .map_err(|_| CoreError::data("enclosure size exceeds SQLite integer range"))?;
        let remote_media_progression_seconds =
            i64::try_from(enclosure.remote_media_progression_seconds)
                .map_err(|_| CoreError::data("media progression exceeds SQLite integer range"))?;
        tx.execute(
            "INSERT INTO enclosures (id,article_id,url,mime_type,size_bytes,remote_media_progression_seconds,remote_present) VALUES (?1,?2,?3,?4,?5,?6,1) ON CONFLICT(id) DO UPDATE SET article_id=excluded.article_id,url=excluded.url,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes,remote_media_progression_seconds=excluded.remote_media_progression_seconds,remote_present=1",
            params![enclosure.id, enclosure.article_id, enclosure.url, enclosure.mime_type, size_bytes, remote_media_progression_seconds],
        )
        .map_err(sql_error)?;
    }
    Ok(())
}
fn save_media(tx: &Transaction<'_>, enclosure_id: i64, added_at: &str) -> Result<bool, CoreError> {
    let enclosure = tx
        .query_row(
            "SELECT id,article_id,url,mime_type,size_bytes,remote_media_progression_seconds,remote_present FROM enclosures WHERE id=?1",
            [enclosure_id],
            stored_enclosure_from_row,
        )
        .optional()
        .map_err(sql_error)?
        .ok_or_else(|| CoreError::data(format!("enclosure {enclosure_id} does not exist")))?;
    if !matches!(
        enclosure.enclosure.media_kind(),
        crate::domain::MediaKind::Audio | crate::domain::MediaKind::Video
    ) {
        return Err(CoreError::data(
            "only audio or video enclosures can be saved",
        ));
    }
    Ok(tx
        .execute(
            "INSERT INTO saved_media(enclosure_id,added_at) VALUES(?1,?2) ON CONFLICT(enclosure_id) DO NOTHING",
            params![enclosure_id, added_at],
        )
        .map_err(sql_error)?
        > 0)
}
fn playback_state_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PlaybackState> {
    Ok(PlaybackState {
        enclosure_id: row.get(0)?,
        position_ms: u64::try_from(row.get::<_, i64>(1)?)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        duration_ms: row
            .get::<_, Option<i64>>(2)?
            .map(|value| u64::try_from(value).map_err(|_| rusqlite::Error::InvalidQuery))
            .transpose()?,
        status: match row.get::<_, String>(3)?.as_str() {
            "in_progress" => PlaybackStatus::InProgress,
            "completed" => PlaybackStatus::Completed,
            _ => return Err(rusqlite::Error::InvalidQuery),
        },
        updated_at: row.get(4)?,
    })
}
fn ensure_enclosure(tx: &Transaction<'_>, enclosure_id: i64) -> Result<(), CoreError> {
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM enclosures WHERE id=?1)",
            [enclosure_id],
            |row| row.get(0),
        )
        .map_err(sql_error)?;
    exists
        .then_some(())
        .ok_or_else(|| CoreError::data(format!("enclosure {enclosure_id} does not exist")))
}
fn upsert_playback_state(
    tx: &Transaction<'_>,
    enclosure_id: i64,
    position_ms: u64,
    duration_ms: Option<u64>,
    status: PlaybackStatus,
    updated_at: &str,
) -> Result<(), CoreError> {
    let position = i64::try_from(position_ms)
        .map_err(|_| CoreError::data("playback position exceeds SQLite range"))?;
    let duration = duration_ms
        .map(i64::try_from)
        .transpose()
        .map_err(|_| CoreError::data("playback duration exceeds SQLite range"))?;
    tx.execute("INSERT INTO playback_states(enclosure_id,position_ms,duration_ms,status,updated_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(enclosure_id) DO UPDATE SET position_ms=excluded.position_ms,duration_ms=COALESCE(excluded.duration_ms,playback_states.duration_ms),status=excluded.status,updated_at=excluded.updated_at", params![enclosure_id,position,duration,match status { PlaybackStatus::InProgress => "in_progress", PlaybackStatus::Completed => "completed" },updated_at]).map_err(sql_error)?;
    Ok(())
}
fn milliseconds_to_seconds(milliseconds: u64) -> Result<u64, CoreError> {
    Ok(milliseconds / 1_000)
}
fn queue_media_progress(
    tx: &Transaction<'_>,
    enclosure_id: i64,
    seconds: u64,
) -> Result<(), CoreError> {
    let seconds = i64::try_from(seconds)
        .map_err(|_| CoreError::data("media progression exceeds SQLite range"))?;
    tx.execute("INSERT INTO pending_media_progress_mutations(enclosure_id,progression_seconds,revision) VALUES(?1,?2,1) ON CONFLICT(enclosure_id) DO UPDATE SET progression_seconds=excluded.progression_seconds,revision=pending_media_progress_mutations.revision+1 WHERE pending_media_progress_mutations.progression_seconds != excluded.progression_seconds", params![enclosure_id,seconds]).map_err(sql_error)?;
    Ok(())
}
fn queue_saved_media_replication(
    tx: &Transaction<'_>,
    enclosure_id: i64,
    desired: SavedMediaMarkerState,
) -> Result<(), CoreError> {
    let enabled: bool = tx
        .query_row(
            "SELECT enabled FROM saved_media_sync_config WHERE id=1",
            [],
            |row| row.get(0),
        )
        .map_err(sql_error)?;
    if !enabled {
        return Ok(());
    }
    let article_id: i64 = tx
        .query_row(
            "SELECT article_id FROM enclosures WHERE id=?1",
            [enclosure_id],
            |row| row.get(0),
        )
        .map_err(sql_error)?;
    tx.execute(
        "INSERT INTO pending_saved_media_replication(enclosure_id,article_id,desired) VALUES(?1,?2,?3) ON CONFLICT(enclosure_id) DO UPDATE SET article_id=excluded.article_id,desired=excluded.desired",
        params![enclosure_id, article_id, marker_state_db(desired)],
    ).map_err(sql_error)?;
    Ok(())
}
fn marker_state_db(state: SavedMediaMarkerState) -> &'static str {
    match state {
        SavedMediaMarkerState::Saved => "saved",
        SavedMediaMarkerState::Unsaved => "unsaved",
    }
}
fn marker_state_from_db(value: &str) -> rusqlite::Result<SavedMediaMarkerState> {
    match value {
        "saved" => Ok(SavedMediaMarkerState::Saved),
        "unsaved" => Ok(SavedMediaMarkerState::Unsaved),
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}
fn reconcile_remote_enclosures(
    tx: &Transaction<'_>,
    articles: &[Article],
    enclosures: &[Enclosure],
    media_progress_writes: &HashMap<i64, u64>,
) -> Result<(), CoreError> {
    let fetched_article_ids: HashSet<i64> = articles.iter().map(|article| article.id).collect();
    let mut enclosure_ids = HashSet::with_capacity(enclosures.len());
    for enclosure in enclosures {
        if !fetched_article_ids.contains(&enclosure.article_id) {
            return Err(CoreError::data(format!(
                "enclosure {} references article {} absent from the remote snapshot",
                enclosure.id, enclosure.article_id
            )));
        }
        if !enclosure_ids.insert(enclosure.id) {
            return Err(CoreError::data(format!(
                "remote snapshot contains duplicate enclosure {}",
                enclosure.id
            )));
        }
    }
    for article_id in fetched_article_ids {
        tx.execute(
            "UPDATE enclosures SET remote_present=0 WHERE article_id=?1",
            [article_id],
        )
        .map_err(sql_error)?;
    }
    let old_progressions = enclosures
        .iter()
        .map(|enclosure| {
            let old = tx
                .query_row(
                    "SELECT remote_media_progression_seconds FROM enclosures WHERE id=?1",
                    [enclosure.id],
                    |row| row.get::<_, i64>(0),
                )
                .optional()
                .map_err(sql_error)?
                .map(|value| {
                    u64::try_from(value)
                        .map_err(|_| CoreError::persistence("invalid stored media progression"))
                })
                .transpose()?;
            Ok::<_, CoreError>((enclosure.id, old))
        })
        .collect::<Result<HashMap<_, _>, _>>()?;
    upsert_remote_enclosures(tx, enclosures)?;
    for enclosure in enclosures {
        let old = old_progressions.get(&enclosure.id).copied().flatten();
        let pending: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pending_media_progress_mutations WHERE enclosure_id=?1)", [enclosure.id], |row| row.get(0)).map_err(sql_error)?;
        let written = media_progress_writes.get(&enclosure.id).copied();
        let stale_write =
            written.is_some_and(|value| value != enclosure.remote_media_progression_seconds);
        let should_adopt =
            !pending && !stale_write && old != Some(enclosure.remote_media_progression_seconds);
        if should_adopt {
            reconcile_playback_progress(tx, enclosure, old)?;
        }
        if stale_write && let Some(old) = old {
            tx.execute(
                "UPDATE enclosures SET remote_media_progression_seconds=?1 WHERE id=?2",
                params![old, enclosure.id],
            )
            .map_err(sql_error)?;
        }
    }
    Ok(())
}

const COMPLETION_TOLERANCE_SECONDS: u64 = 3;

fn reconcile_playback_progress(
    tx: &Transaction<'_>,
    enclosure: &Enclosure,
    old: Option<u64>,
) -> Result<(), CoreError> {
    let local = tx.query_row("SELECT position_ms,duration_ms,status,updated_at FROM playback_states WHERE enclosure_id=?1", [enclosure.id], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<i64>>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?))).optional().map_err(sql_error)?;
    let progression = enclosure.remote_media_progression_seconds;
    if local.is_none() && progression == 0 {
        return Ok(());
    }
    let duration = local
        .as_ref()
        .and_then(|(_, duration, _, _)| duration.and_then(|value| u64::try_from(value).ok()));
    let status = if progression == 0 {
        "in_progress"
    } else if duration.is_some_and(|duration| {
        duration.abs_diff(progression.saturating_mul(1000)) <= COMPLETION_TOLERANCE_SECONDS * 1000
    }) {
        "completed"
    } else {
        "in_progress"
    };
    let position_ms =
        if status == "completed" {
            duration.unwrap_or(progression.checked_mul(1000).ok_or_else(|| {
                CoreError::data("remote media progression exceeds playback range")
            })?)
        } else {
            progression
                .checked_mul(1000)
                .ok_or_else(|| CoreError::data("remote media progression exceeds playback range"))?
        };
    let position = i64::try_from(position_ms)
        .map_err(|_| CoreError::data("remote media progression exceeds playback range"))?;
    if local.is_some() && old == Some(progression) {
        return Ok(());
    }
    tx.execute("INSERT INTO playback_states(enclosure_id,position_ms,duration_ms,status,updated_at) VALUES(?1,?2,?3,?4,datetime('now')) ON CONFLICT(enclosure_id) DO UPDATE SET position_ms=excluded.position_ms,duration_ms=COALESCE(excluded.duration_ms,playback_states.duration_ms),status=excluded.status,updated_at=excluded.updated_at", params![enclosure.id,position,duration, status]).map_err(sql_error)?;
    Ok(())
}
fn stored_enclosure_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredEnclosure> {
    let size_bytes = row
        .get::<_, Option<i64>>(4)?
        .map(|size| u64::try_from(size).map_err(|_| rusqlite::Error::InvalidQuery))
        .transpose()?;
    let remote_media_progression_seconds =
        u64::try_from(row.get::<_, i64>(5)?).map_err(|_| rusqlite::Error::InvalidQuery)?;
    Ok(StoredEnclosure {
        enclosure: Enclosure {
            id: row.get(0)?,
            article_id: row.get(1)?,
            url: row.get(2)?,
            mime_type: row.get(3)?,
            size_bytes,
            remote_media_progression_seconds,
        },
        remote_present: row.get(6)?,
    })
}
fn saved_playable_media_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<SavedPlayableMediaItem> {
    let mime_type: String = row.get(8)?;
    Ok(SavedPlayableMediaItem {
        enclosure_id: row.get(0)?,
        article_id: row.get(1)?,
        feed_id: row.get(2)?,
        title: row.get(3)?,
        feed_title: row.get(4)?,
        published_at: row.get(5)?,
        added_at: row.get(6)?,
        url: row.get(7)?,
        media_kind: crate::domain::MediaKind::from_mime_type(&mime_type),
        mime_type,
        remote_present: row.get(9)?,
    })
}
fn setting_value(connection: &Connection, key: &str) -> Result<String, CoreError> {
    connection
        .query_row(
            "SELECT value FROM core_settings WHERE key=?1",
            [key],
            |row| row.get(0),
        )
        .map_err(sql_error)
}
fn field_name(field: MutationField) -> &'static str {
    match field {
        MutationField::Read => "read",
        MutationField::Starred => "starred",
        MutationField::MediaProgress => "media_progress",
    }
}
fn parse_field(field: &str) -> Result<MutationField, rusqlite::Error> {
    match field {
        "read" => Ok(MutationField::Read),
        "starred" => Ok(MutationField::Starred),
        "media_progress" => Ok(MutationField::MediaProgress),
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}
fn sql_error(error: rusqlite::Error) -> CoreError {
    CoreError::persistence(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn roots(temp: &TempDir) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let data = temp.path().join("data");
        let cache = temp.path().join("cache");
        let media = temp.path().join("media");
        std::fs::create_dir_all(&data).unwrap();
        (data, cache, media)
    }

    #[test]
    fn legacy_api_url_keeps_the_existing_server_context_when_canonicalized() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        store
            .set_base_url("https://miniflux.example/news/v1")
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO categories (id, title) VALUES (1, 'Existing')",
                [],
            )
            .unwrap();

        store.set_base_url("https://miniflux.example/news").unwrap();

        assert_eq!(
            store.base_url().unwrap().as_deref(),
            Some("https://miniflux.example/news")
        );
        let category_count: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM categories", [], |row| row.get(0))
            .unwrap();
        assert_eq!(category_count, 1);
    }

    #[test]
    fn configuration_replacement_discards_server_state_and_replaces_orphan_preferences() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        store.set_base_url("https://old.example").unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute_batch("INSERT INTO categories VALUES(1, 'Old'); INSERT INTO feeds VALUES(2, 1, 'Old Feed'); INSERT INTO articles(id,feed_id,title,url,published_at,is_read,is_starred,raw_html_content,preview) VALUES(3,2,'Old','https://old.example/post','2024-01-01T00:00:00Z',0,0,'',''); INSERT INTO pending_mutations VALUES(3,'read',1,1);")
            .unwrap();
        store.set_feed_open_in_miniflux(2, true).unwrap();

        let settings = CoreSettings {
            retention: ReadArticleRetention::Days30,
            delivery_mode: DeliveryMode::Live,
            background_sync_enabled: true,
            detail_character_limit: 5_000,
        };
        let preferences = vec![FeedPreferences {
            feed_id: 999,
            system_notifications_enabled: true,
            detail_rendering: DetailRenderingMode::TextOnly,
            truncate_detail: true,
            open_in_miniflux: true,
        }];
        store
            .replace_configuration("https://new.example", &settings, &preferences)
            .unwrap();

        assert_eq!(
            store.base_url().unwrap().as_deref(),
            Some("https://new.example")
        );
        assert_eq!(store.core_settings().unwrap(), settings);
        assert_eq!(store.all_feed_preferences().unwrap(), preferences);
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM articles", [], |row| row.get(0))
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM pending_mutations", [], |row| row
                    .get(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn v3_migration_reprocesses_and_preserves_article_state() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let path = data.join("flux.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL, title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL, is_starred INTEGER NOT NULL, raw_html_content TEXT NOT NULL, remote_is_read INTEGER, remote_is_starred INTEGER, preview TEXT NOT NULL DEFAULT '', image_url TEXT); CREATE TABLE pending_mutations (article_id INTEGER NOT NULL, field TEXT NOT NULL, desired INTEGER NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); INSERT INTO core_settings VALUES ('base_url','https://miniflux.example'); INSERT INTO categories VALUES (1,'Category'); INSERT INTO feeds VALUES (2,1,'Feed'); INSERT INTO articles VALUES (3,2,'Title','https://example.test/post','', '2024-01-01T00:00:00Z',1,1,'<p>Hello <b>world</b></p><img src=\"/cover.jpg\">',1,1,'',''); INSERT INTO pending_mutations VALUES (3,'read',0,7); PRAGMA user_version=3;").unwrap();
        drop(connection);
        let store = Store::open(&data, &cache, &media).unwrap();
        let connection = store.connection.lock().unwrap();
        let row: (i64, String, Option<String>, String, bool, bool, i64, i64) = connection.query_row("SELECT content_processing_version,preview,image_url,raw_html_content,is_read,is_starred,feed_id,(SELECT COUNT(*) FROM pending_mutations) FROM articles WHERE id=3", [], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?,row.get(6)?,row.get(7)?))).unwrap();
        drop(connection);
        assert_eq!(store.schema_version().unwrap(), 12);
        assert_eq!(row.0, crate::article::PROCESSING_VERSION);
        assert_eq!(row.1, "Hello world");
        assert_eq!(row.2.as_deref(), Some("https://example.test/cover.jpg"));
        assert!(row.3.contains("<b>world</b>"));
        assert!(row.4 && row.5);
        assert_eq!((row.6, row.7), (2, 1));
        assert_eq!(store.core_settings().unwrap(), CoreSettings::default());
        assert_eq!(
            store.base_url().unwrap().as_deref(),
            Some("https://miniflux.example")
        );
    }

    #[test]
    fn v5_migration_preserves_notification_preferences_and_adds_reader_defaults() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let path = data.join("flux.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES categories(id), title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id), title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL CHECK(is_read IN(0,1)), is_starred INTEGER NOT NULL CHECK(is_starred IN(0,1)), raw_html_content TEXT NOT NULL, remote_is_read INTEGER, remote_is_starred INTEGER, preview TEXT NOT NULL DEFAULT '', image_url TEXT, content_processing_version INTEGER NOT NULL DEFAULT 0); CREATE TABLE pending_mutations (article_id INTEGER NOT NULL REFERENCES articles(id), field TEXT NOT NULL CHECK(field IN ('read','starred')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); CREATE TABLE feed_system_notification_preferences (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, enabled INTEGER NOT NULL CHECK(enabled IN(0,1))); CREATE TABLE pending_system_notifications (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notified_articles (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notification_candidates (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, feed_title TEXT NOT NULL); CREATE TABLE notification_candidate_articles (candidate_id INTEGER NOT NULL REFERENCES system_notification_candidates(id) ON DELETE CASCADE, article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE, PRIMARY KEY(candidate_id,article_id)); CREATE INDEX pending_system_notifications_article ON pending_system_notifications(article_id); INSERT INTO categories VALUES (1,'Category'); INSERT INTO feeds VALUES (2,1,'Enabled'),(3,1,'Disabled'); INSERT INTO feed_system_notification_preferences VALUES (2,1),(3,0); PRAGMA user_version=5;").unwrap();
        drop(connection);

        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(store.schema_version().unwrap(), 12);
        assert_eq!(
            store.feed_preferences(2).unwrap(),
            FeedPreferences {
                feed_id: 2,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::Rendered,
                truncate_detail: false,
                open_in_miniflux: false
            }
        );
        assert_eq!(
            store.feed_preferences(3).unwrap(),
            FeedPreferences::defaults(3)
        );
        assert_eq!(
            store.core_settings().unwrap().detail_character_limit,
            10_000
        );
    }

    #[test]
    fn feed_preferences_are_independent_persistent_and_reset_after_feed_reappears() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        store.reconcile(&categories, &feeds, &[]).unwrap();
        assert_eq!(
            store.feed_preferences(2).unwrap(),
            FeedPreferences::defaults(2)
        );
        store
            .set_feed_system_notifications_enabled(2, true)
            .unwrap();
        store
            .set_feed_detail_rendering(2, DetailRenderingMode::TextOnly)
            .unwrap();
        store.set_feed_truncate_detail(2, true).unwrap();
        store.set_feed_open_in_miniflux(2, true).unwrap();
        assert_eq!(
            store.feed_preferences(2).unwrap(),
            FeedPreferences {
                feed_id: 2,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::TextOnly,
                truncate_detail: true,
                open_in_miniflux: true
            }
        );
        drop(store);
        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(
            store.feed_preferences(2).unwrap(),
            FeedPreferences {
                feed_id: 2,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::TextOnly,
                truncate_detail: true,
                open_in_miniflux: true
            }
        );
        store.reconcile(&categories, &[], &[]).unwrap();
        assert!(store.feed_preferences(2).is_err());
        store.reconcile(&categories, &feeds, &[]).unwrap();
        assert_eq!(
            store.feed_preferences(2).unwrap(),
            FeedPreferences::defaults(2)
        );
    }

    #[test]
    fn v7_migration_preserves_preferences_and_removes_feed_foreign_key() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let path = data.join("flux.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES categories(id), title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id), title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL CHECK(is_read IN(0,1)), is_starred INTEGER NOT NULL CHECK(is_starred IN(0,1)), raw_html_content TEXT NOT NULL, remote_is_read INTEGER, remote_is_starred INTEGER, preview TEXT NOT NULL DEFAULT '', image_url TEXT, content_processing_version INTEGER NOT NULL DEFAULT 0); CREATE TABLE pending_mutations (article_id INTEGER NOT NULL REFERENCES articles(id), field TEXT NOT NULL CHECK(field IN ('read','starred')), desired INTEGER NOT NULL CHECK(desired IN(0,1)), revision INTEGER NOT NULL, PRIMARY KEY(article_id,field)); CREATE TABLE pending_system_notifications (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notified_articles (article_id INTEGER PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE); CREATE TABLE system_notification_candidates (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, feed_title TEXT NOT NULL); CREATE TABLE notification_candidate_articles (candidate_id INTEGER NOT NULL REFERENCES system_notification_candidates(id) ON DELETE CASCADE, article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE, PRIMARY KEY(candidate_id,article_id)); CREATE TABLE feed_preferences (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, system_notifications_enabled INTEGER NOT NULL DEFAULT 0 CHECK(system_notifications_enabled IN(0,1)), detail_rendering TEXT NOT NULL DEFAULT 'rendered' CHECK(detail_rendering IN('rendered','text_only')), truncate_detail INTEGER NOT NULL DEFAULT 0 CHECK(truncate_detail IN(0,1)), open_in_miniflux INTEGER NOT NULL DEFAULT 0 CHECK(open_in_miniflux IN(0,1))); INSERT INTO categories VALUES (1,'Category'); INSERT INTO feeds VALUES (123,1,'One'); INSERT INTO feeds VALUES (456,1,'Two'); INSERT INTO articles VALUES (9,123,'Article','https://example.test','', '2026-01-01T00:00:00Z',0,0,0,0,'content','',NULL,0); INSERT INTO feed_preferences VALUES (123,1,'text_only',1,1); INSERT INTO feed_preferences VALUES (456,0,'rendered',0,1); PRAGMA user_version=6;").unwrap();
        drop(connection);

        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(store.schema_version().unwrap(), 12);
        assert_eq!(
            store.feed_preferences(123).unwrap(),
            FeedPreferences {
                feed_id: 123,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::TextOnly,
                truncate_detail: true,
                open_in_miniflux: true
            }
        );
        assert_eq!(
            store.feed_preferences(456).unwrap(),
            FeedPreferences {
                feed_id: 456,
                system_notifications_enabled: false,
                detail_rendering: DetailRenderingMode::Rendered,
                truncate_detail: false,
                open_in_miniflux: true
            }
        );
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row("SELECT feed_id FROM articles WHERE id=9", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            123
        );
        let foreign_key_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_foreign_key_list('feed_preferences')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(foreign_key_count, 0);
    }

    #[test]
    fn v8_migration_preserves_phase_a_data_and_creates_enclosures() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let path = data.join("flux.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES categories(id), title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id), title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL, is_starred INTEGER NOT NULL, raw_html_content TEXT NOT NULL, remote_is_read INTEGER, remote_is_starred INTEGER, preview TEXT NOT NULL DEFAULT '', image_url TEXT, content_processing_version INTEGER NOT NULL DEFAULT 0); INSERT INTO core_settings VALUES ('base_url','https://miniflux.example'); INSERT INTO categories VALUES (1,'Category'); INSERT INTO feeds VALUES (2,1,'Feed'); INSERT INTO articles VALUES (3,2,'Title','https://example.test/post','', '2024-01-01T00:00:00Z',1,0,'<p>Saved</p>',1,0,'Saved',NULL,1); PRAGMA user_version=7;").unwrap();
        drop(connection);

        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(store.schema_version().unwrap(), 12);
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row("SELECT title FROM articles WHERE id=3", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "Title"
        );
        let columns = connection
            .prepare("SELECT name FROM pragma_table_info('enclosures') ORDER BY cid")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            columns,
            vec![
                "id",
                "article_id",
                "url",
                "mime_type",
                "size_bytes",
                "remote_media_progression_seconds",
                "remote_present",
            ]
        );
    }

    #[test]
    fn enclosure_storage_round_trips_updates_and_cascades_from_articles() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let articles = [Article {
            id: 3,
            feed_id: 2,
            title: "Article".into(),
            url: "https://example.test/article".into(),
            comments_url: String::new(),
            published_at: "2024-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        }];
        let enclosures = [
            Enclosure {
                id: 11,
                article_id: 3,
                url: "https://cdn.test/episode.mp3?token=raw".into(),
                mime_type: "audio/mpeg; codecs=mp3".into(),
                size_bytes: Some(123_456),
                remote_media_progression_seconds: 42,
            },
            Enclosure {
                id: 12,
                article_id: 3,
                url: "https://cdn.test/cover.custom".into(),
                mime_type: "application/x-cover".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
        ];

        store
            .reconcile_with_enclosures(&categories, &feeds, &articles, &enclosures)
            .unwrap();
        assert_eq!(
            store.enclosures_for_article(3).unwrap(),
            enclosures
                .iter()
                .cloned()
                .map(|enclosure| StoredEnclosure {
                    enclosure,
                    remote_present: true,
                })
                .collect::<Vec<_>>()
        );

        store
            .reconcile_with_enclosures(&categories, &feeds, &articles, &[])
            .unwrap();
        assert_eq!(
            store
                .enclosures_for_article(3)
                .unwrap()
                .iter()
                .map(|enclosure| enclosure.remote_present)
                .collect::<Vec<_>>(),
            vec![false, false]
        );

        store.set_enclosure_remote_present(11, false).unwrap();
        assert!(!store.enclosure(11).unwrap().unwrap().remote_present);
        let updated = Enclosure {
            id: 11,
            article_id: 3,
            url: "https://cdn.test/episode-updated.mp3".into(),
            mime_type: "audio/ogg".into(),
            size_bytes: None,
            remote_media_progression_seconds: 99,
        };
        store
            .upsert_remote_enclosures(std::slice::from_ref(&updated))
            .unwrap();
        assert_eq!(
            store.enclosure(11).unwrap(),
            Some(StoredEnclosure {
                enclosure: updated,
                remote_present: true,
            })
        );
        assert_eq!(store.enclosures_for_article(3).unwrap().len(), 2);

        store
            .connection
            .lock()
            .unwrap()
            .execute("DELETE FROM articles WHERE id=3", [])
            .unwrap();
        assert!(store.enclosure(11).unwrap().is_none());
        assert!(store.enclosures_for_article(3).unwrap().is_empty());
    }

    #[test]
    fn reconciliation_marks_missing_enclosures_only_for_fetched_articles() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let article = |id| Article {
            id,
            feed_id: 2,
            title: format!("Article {id}"),
            url: format!("https://example.test/{id}"),
            comments_url: String::new(),
            published_at: "2024-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        };
        let articles = [article(1), article(2)];
        store
            .reconcile_with_enclosures(
                &categories,
                &feeds,
                &articles,
                &[
                    Enclosure {
                        id: 10,
                        article_id: 1,
                        url: "https://cdn.test/10.mp3".into(),
                        mime_type: "audio/mpeg".into(),
                        size_bytes: Some(10),
                        remote_media_progression_seconds: 1,
                    },
                    Enclosure {
                        id: 11,
                        article_id: 1,
                        url: "https://cdn.test/11.mp3".into(),
                        mime_type: "audio/mpeg".into(),
                        size_bytes: Some(11),
                        remote_media_progression_seconds: 2,
                    },
                    Enclosure {
                        id: 20,
                        article_id: 2,
                        url: "https://cdn.test/20.mp3".into(),
                        mime_type: "audio/mpeg".into(),
                        size_bytes: Some(20),
                        remote_media_progression_seconds: 3,
                    },
                ],
            )
            .unwrap();

        let reappearing = Enclosure {
            id: 10,
            article_id: 1,
            url: "https://cdn.test/10-new.mp3".into(),
            mime_type: "audio/ogg".into(),
            size_bytes: None,
            remote_media_progression_seconds: 99,
        };
        let inserted = Enclosure {
            id: 12,
            article_id: 1,
            url: "https://cdn.test/12.mp3".into(),
            mime_type: "video/mp4".into(),
            size_bytes: Some(12),
            remote_media_progression_seconds: 4,
        };
        store
            .reconcile_with_enclosures(
                &categories,
                &feeds,
                &[article(1)],
                &[reappearing.clone(), inserted],
            )
            .unwrap();
        assert_eq!(
            store.enclosure(10).unwrap(),
            Some(StoredEnclosure {
                enclosure: reappearing.clone(),
                remote_present: true,
            })
        );
        assert!(!store.enclosure(11).unwrap().unwrap().remote_present);
        assert!(store.enclosure(12).unwrap().unwrap().remote_present);
        assert!(store.enclosure(20).unwrap().unwrap().remote_present);

        store
            .reconcile_with_enclosures(&categories, &feeds, &[article(1)], &[])
            .unwrap();
        assert!(!store.enclosure(10).unwrap().unwrap().remote_present);
        assert!(!store.enclosure(12).unwrap().unwrap().remote_present);
        assert!(store.enclosure(20).unwrap().unwrap().remote_present);

        store
            .reconcile_with_enclosures(
                &categories,
                &feeds,
                &[article(1)],
                std::slice::from_ref(&reappearing),
            )
            .unwrap();
        assert_eq!(
            store.enclosure(10).unwrap(),
            Some(StoredEnclosure {
                enclosure: reappearing,
                remote_present: true,
            })
        );
    }

    #[test]
    fn v9_migration_preserves_enclosures() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let connection = Connection::open(data.join("flux.sqlite3")).unwrap();
        connection.execute_batch("CREATE TABLE core_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE categories (id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE feeds (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES categories(id), title TEXT NOT NULL); CREATE TABLE articles (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id), title TEXT NOT NULL, url TEXT NOT NULL, comments_url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL, is_read INTEGER NOT NULL, is_starred INTEGER NOT NULL, raw_html_content TEXT NOT NULL, remote_is_read INTEGER, remote_is_starred INTEGER, preview TEXT NOT NULL DEFAULT '', image_url TEXT, content_processing_version INTEGER NOT NULL DEFAULT 0); CREATE TABLE enclosures (id INTEGER PRIMARY KEY, article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE, url TEXT NOT NULL, mime_type TEXT NOT NULL, size_bytes INTEGER, remote_media_progression_seconds INTEGER NOT NULL, remote_present INTEGER NOT NULL DEFAULT 1); INSERT INTO categories VALUES(1,'Category'); INSERT INTO feeds VALUES(2,1,'Feed'); INSERT INTO articles VALUES(3,2,'Article','https://example.test/article','','2024-01-01T00:00:00Z',1,0,'',1,0,'',NULL,1); INSERT INTO enclosures VALUES(10,3,'https://cdn.test/episode.mp3','audio/mpeg',123,4,0); PRAGMA user_version=8;").unwrap();
        drop(connection);

        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(store.schema_version().unwrap(), 12);
        assert!(!store.enclosure(10).unwrap().unwrap().remote_present);
        assert_eq!(
            store
                .connection
                .lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM saved_media", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn saved_media_is_local_idempotent_and_protects_its_article() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [
            Feed {
                id: 2,
                category_id: 1,
                title: "Alpha".into(),
            },
            Feed {
                id: 3,
                category_id: 1,
                title: "Beta".into(),
            },
        ];
        let articles = [
            Article {
                id: 10,
                feed_id: 2,
                title: "Older".into(),
                url: "https://example.test/10".into(),
                comments_url: String::new(),
                published_at: "2020-01-01T00:00:00Z".into(),
                is_read: true,
                is_starred: false,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
            Article {
                id: 11,
                feed_id: 2,
                title: "Newer".into(),
                url: "https://example.test/11".into(),
                comments_url: String::new(),
                published_at: "2021-01-01T00:00:00Z".into(),
                is_read: true,
                is_starred: false,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
            Article {
                id: 12,
                feed_id: 3,
                title: "Other Feed".into(),
                url: "https://example.test/12".into(),
                comments_url: String::new(),
                published_at: "2022-01-01T00:00:00Z".into(),
                is_read: false,
                is_starred: false,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
        ];
        store
            .reconcile_with_enclosures(
                &categories,
                &feeds,
                &articles,
                &[
                    Enclosure {
                        id: 100,
                        article_id: 10,
                        url: "https://cdn.test/100.mp3".into(),
                        mime_type: "audio/mpeg".into(),
                        size_bytes: Some(100),
                        remote_media_progression_seconds: 0,
                    },
                    Enclosure {
                        id: 101,
                        article_id: 10,
                        url: "https://cdn.test/101.mp3".into(),
                        mime_type: "audio/mpeg".into(),
                        size_bytes: None,
                        remote_media_progression_seconds: 0,
                    },
                    Enclosure {
                        id: 110,
                        article_id: 11,
                        url: "https://cdn.test/110.mp4".into(),
                        mime_type: "video/mp4".into(),
                        size_bytes: None,
                        remote_media_progression_seconds: 0,
                    },
                    Enclosure {
                        id: 120,
                        article_id: 12,
                        url: "https://cdn.test/120.jpg".into(),
                        mime_type: "image/jpeg".into(),
                        size_bytes: None,
                        remote_media_progression_seconds: 0,
                    },
                ],
            )
            .unwrap();
        store.set_enclosure_remote_present(100, false).unwrap();

        assert!(store.save_media(100, "2024-01-01T00:00:00Z").unwrap());
        assert!(!store.save_media(100, "2025-01-01T00:00:00Z").unwrap());
        assert_eq!(
            store.saved_media(100).unwrap(),
            Some(SavedMedia {
                enclosure_id: 100,
                added_at: "2024-01-01T00:00:00Z".into()
            })
        );
        assert!(!store.enclosure(100).unwrap().unwrap().remote_present);
        assert!(!store.local_article_state(10).unwrap().unwrap().is_starred);
        store
            .reconcile_with_enclosures(
                &categories,
                &feeds,
                &[articles[0].clone()],
                &[Enclosure {
                    id: 100,
                    article_id: 10,
                    url: "https://cdn.test/100-reappeared.mp3".into(),
                    mime_type: "audio/mpeg".into(),
                    size_bytes: Some(101),
                    remote_media_progression_seconds: 0,
                }],
            )
            .unwrap();
        assert!(store.saved_media(100).unwrap().is_some());
        assert!(store.enclosure(100).unwrap().unwrap().remote_present);
        assert!(store.save_media(110, "2024-02-01T00:00:00Z").unwrap());
        assert!(store.save_media(120, "2024-03-01T00:00:00Z").is_err());
        assert!(store.saved_media(101).unwrap().is_none());

        let library = store.saved_playable_media().unwrap();
        assert_eq!(
            library
                .iter()
                .map(|item| item.enclosure_id)
                .collect::<Vec<_>>(),
            vec![110, 100]
        );
        assert_eq!(library[1].title, "Older");
        assert_eq!(library[1].feed_title, "Alpha");
        assert!(library[1].remote_present);
        assert_eq!(
            store
                .saved_media_by_feed(2)
                .unwrap()
                .iter()
                .map(|item| item.enclosure_id)
                .collect::<Vec<_>>(),
            vec![110, 100]
        );

        assert_eq!(
            store
                .cleanup_expired_read_articles("2021-01-01T00:00:00Z")
                .unwrap(),
            0
        );
        assert!(store.enclosure(100).unwrap().is_some());
        assert!(store.unsave_media(100).unwrap());
        assert!(!store.unsave_media(100).unwrap());
        assert_eq!(
            store
                .cleanup_expired_read_articles("2021-01-01T00:00:00Z")
                .unwrap(),
            1
        );
        assert!(store.enclosure(100).unwrap().is_none());
        assert!(store.enclosure(101).unwrap().is_none());
        assert!(store.enclosure(110).unwrap().is_some());
    }

    #[test]
    fn materializes_search_article_enclosure_and_saved_media_atomically() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        store
            .reconcile(
                &[Category {
                    id: 1,
                    title: "Category".into(),
                }],
                &[Feed {
                    id: 2,
                    category_id: 1,
                    title: "Feed".into(),
                }],
                &[],
            )
            .unwrap();
        let article = Article {
            id: 10,
            feed_id: 2,
            title: "Search result".into(),
            url: "https://example.test/10".into(),
            comments_url: String::new(),
            published_at: "2024-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: false,
            raw_html_content: "<p>Search result</p>".into(),
            preview: "Search result".into(),
            image_url: None,
        };
        let enclosure = Enclosure {
            id: 100,
            article_id: 10,
            url: "https://cdn.test/100.mp3".into(),
            mime_type: "audio/mpeg".into(),
            size_bytes: None,
            remote_media_progression_seconds: 0,
        };
        store
            .materialize_saved_media(&article, &enclosure, "2024-02-01T00:00:00Z")
            .unwrap();
        assert_eq!(
            store.saved_media(100).unwrap().unwrap().added_at,
            "2024-02-01T00:00:00Z"
        );
        assert_eq!(store.saved_playable_media().unwrap()[0].article_id, 10);

        let invalid = Enclosure {
            id: 101,
            article_id: 11,
            ..enclosure
        };
        assert!(
            store
                .materialize_saved_media(&article, &invalid, "2024-02-01T00:00:00Z")
                .is_err()
        );
        assert!(store.enclosure(101).unwrap().is_none());
    }

    #[test]
    fn fresh_schema_permits_orphan_preferences_without_cascade() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        assert_eq!(store.schema_version().unwrap(), 12);
        let connection = store.connection.lock().unwrap();
        let foreign_key_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_foreign_key_list('feed_preferences')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(foreign_key_count, 0);
        connection.execute("INSERT INTO feed_preferences(feed_id,system_notifications_enabled,detail_rendering,truncate_detail,open_in_miniflux) VALUES(999,1,'text_only',1,1)", []).unwrap();
        drop(connection);
        assert_eq!(
            store.feed_preferences(999).unwrap(),
            FeedPreferences {
                feed_id: 999,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::TextOnly,
                truncate_detail: true,
                open_in_miniflux: true
            }
        );
    }

    #[test]
    fn local_feed_removal_does_not_delete_orphan_preferences() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 123,
            category_id: 1,
            title: "Feed".into(),
        }];
        store.reconcile(&categories, &feeds, &[]).unwrap();
        store
            .set_feed_system_notifications_enabled(123, true)
            .unwrap();
        store
            .set_feed_detail_rendering(123, DetailRenderingMode::TextOnly)
            .unwrap();
        store.set_feed_truncate_detail(123, true).unwrap();
        store.set_feed_open_in_miniflux(123, true).unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute("DELETE FROM feeds WHERE id=123", [])
            .unwrap();
        assert_eq!(
            store.feed_preferences(123).unwrap(),
            FeedPreferences {
                feed_id: 123,
                system_notifications_enabled: true,
                detail_rendering: DetailRenderingMode::TextOnly,
                truncate_detail: true,
                open_in_miniflux: true
            }
        );
    }

    #[test]
    fn changing_installations_explicitly_removes_all_preferences() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        store.set_base_url("https://server-a.example").unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 123,
            category_id: 1,
            title: "Feed".into(),
        }];
        store.reconcile(&categories, &feeds, &[]).unwrap();
        store
            .set_feed_system_notifications_enabled(123, true)
            .unwrap();

        store.set_base_url("https://server-b.example").unwrap();

        assert!(store.navigation_catalog().unwrap().feeds.is_empty());
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM feed_preferences", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0
        );
    }

    #[test]
    fn reconciliation_removes_only_preferences_for_remotely_removed_feeds() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [
            Feed {
                id: 123,
                category_id: 1,
                title: "Removed".into(),
            },
            Feed {
                id: 456,
                category_id: 1,
                title: "Remaining".into(),
            },
        ];
        store.reconcile(&categories, &feeds, &[]).unwrap();
        store
            .set_feed_system_notifications_enabled(123, true)
            .unwrap();
        store
            .set_feed_detail_rendering(123, DetailRenderingMode::TextOnly)
            .unwrap();
        store.set_feed_open_in_miniflux(456, true).unwrap();

        store.reconcile(&categories, &feeds[1..], &[]).unwrap();

        assert!(store.feed_preferences(123).is_err());
        assert_eq!(
            store.feed_preferences(456).unwrap(),
            FeedPreferences {
                feed_id: 456,
                system_notifications_enabled: false,
                detail_rendering: DetailRenderingMode::Rendered,
                truncate_detail: false,
                open_in_miniflux: true
            }
        );
    }

    #[test]
    fn reconciliation_removes_orphan_preferences_absent_from_authoritative_catalog() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute("INSERT INTO feed_preferences(feed_id) VALUES(999)", [])
            .unwrap();

        store
            .reconcile(
                &[Category {
                    id: 1,
                    title: "Category".into(),
                }],
                &[],
                &[],
            )
            .unwrap();

        assert!(store.feed_preferences(999).is_err());
    }

    #[test]
    fn reconcile_round_trip_returns_processed_summary_and_version() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let processed = crate::article::process(
            "<p>Hello &amp; goodbye</p><img data-original=\"/image.jpg\">",
            "https://example.test/post",
            &[],
        );
        store
            .reconcile(
                &[Category {
                    id: 1,
                    title: "Category".into(),
                }],
                &[Feed {
                    id: 2,
                    category_id: 1,
                    title: "Feed".into(),
                }],
                &[Article {
                    id: 3,
                    feed_id: 2,
                    title: "Title".into(),
                    url: "https://example.test/post".into(),
                    comments_url: String::new(),
                    published_at: "2024-01-01T00:00:00Z".into(),
                    is_read: false,
                    is_starred: false,
                    raw_html_content:
                        "<p>Hello &amp; goodbye</p><img data-original=\"/image.jpg\">".into(),
                    preview: processed.preview.clone(),
                    image_url: processed.image_url.clone(),
                }],
            )
            .unwrap();
        let article = store
            .query_articles(&ArticleQuery {
                limit: 0,
                ..Default::default()
            })
            .unwrap()
            .pop()
            .unwrap();
        assert_eq!(article.preview, processed.preview);
        assert_eq!(article.image_url, processed.image_url);
        assert_eq!(
            store
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT content_processing_version FROM articles WHERE id=3",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            crate::article::PROCESSING_VERSION
        );
    }

    #[test]
    fn reconcile_absent_unread_starred_articles_as_remote_read_unstarred_without_overwriting_pending_intent()
     {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let articles = [1, 2].map(|id| Article {
            id,
            feed_id: 2,
            title: format!("Title {id}"),
            url: format!("https://example.test/{id}"),
            comments_url: String::new(),
            published_at: "2024-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: true,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        });
        store.reconcile(&categories, &feeds, &articles).unwrap();

        store
            .set_state_bulk(&[2], MutationField::Read, false)
            .unwrap();
        store
            .set_state_bulk(&[2], MutationField::Starred, true)
            .unwrap();
        let stats = store.reconcile(&categories, &feeds, &[]).unwrap();

        let rows = store
            .connection
            .lock()
            .unwrap()
            .prepare("SELECT id,is_read,is_starred,remote_is_read,remote_is_starred FROM articles ORDER BY id")
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, bool>(1)?,
                    row.get::<_, bool>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, bool>(4)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(stats.updated_articles, 2);
        assert_eq!(
            rows,
            vec![(1, true, false, true, false), (2, false, true, true, false)]
        );
    }

    #[test]
    fn reconcile_removes_absent_feed_data_and_notification_candidates() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [
            Category {
                id: 1,
                title: "A".into(),
            },
            Category {
                id: 2,
                title: "B".into(),
            },
        ];
        let feeds = [
            Feed {
                id: 10,
                category_id: 1,
                title: "Keep".into(),
            },
            Feed {
                id: 20,
                category_id: 2,
                title: "Remove".into(),
            },
        ];
        let articles = [
            Article {
                id: 1,
                feed_id: 10,
                title: "Keep".into(),
                url: "https://example.test/1".into(),
                comments_url: String::new(),
                published_at: "2024-01-01T00:00:00Z".into(),
                is_read: false,
                is_starred: false,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
            Article {
                id: 2,
                feed_id: 20,
                title: "Unread".into(),
                url: "https://example.test/2".into(),
                comments_url: String::new(),
                published_at: "2024-01-01T00:00:00Z".into(),
                is_read: false,
                is_starred: false,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
            Article {
                id: 3,
                feed_id: 20,
                title: "Starred".into(),
                url: "https://example.test/3".into(),
                comments_url: String::new(),
                published_at: "2024-01-01T00:00:00Z".into(),
                is_read: true,
                is_starred: true,
                raw_html_content: String::new(),
                preview: String::new(),
                image_url: None,
            },
        ];
        let initial = store.reconcile(&categories, &feeds, &articles).unwrap();
        store
            .set_feed_system_notifications_enabled(20, true)
            .unwrap();
        assert_eq!(
            store
                .prepare_system_notification_candidates(&initial.new_article_ids_by_feed)
                .unwrap()
                .len(),
            1
        );
        store
            .set_feed_system_notifications_enabled(10, true)
            .unwrap();
        store
            .set_state_bulk(&[2], MutationField::Read, true)
            .unwrap();

        let stats = store.reconcile(&categories[..1], &feeds[..1], &[]).unwrap();
        assert!(stats.navigation_changed);
        assert_eq!(
            store
                .navigation_catalog()
                .unwrap()
                .feeds
                .iter()
                .map(|feed| feed.id)
                .collect::<Vec<_>>(),
            vec![10]
        );
        assert_eq!(
            store
                .query_articles(&ArticleQuery {
                    limit: 0,
                    ..Default::default()
                })
                .unwrap()
                .iter()
                .map(|article| article.id)
                .collect::<Vec<_>>(),
            vec![1]
        );
        assert!(store.pending_mutations().unwrap().is_empty());
        assert_eq!(
            store
                .feed_system_notification_settings()
                .unwrap()
                .iter()
                .map(|setting| setting.feed_id)
                .collect::<Vec<_>>(),
            vec![10]
        );
        assert!(store.feed_system_notification_settings().unwrap()[0].system_notifications_enabled);
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM feed_preferences WHERE feed_id=20",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        assert_eq!(connection.query_row("SELECT COUNT(*) FROM pending_system_notifications p LEFT JOIN articles a ON a.id=p.article_id WHERE a.id IS NULL", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
        assert_eq!(connection.query_row("SELECT COUNT(*) FROM system_notified_articles n LEFT JOIN articles a ON a.id=n.article_id WHERE a.id IS NULL", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM system_notification_candidates WHERE feed_id=20",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM notification_candidate_articles",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        drop(connection);
        store.reconcile(&categories, &feeds, &[]).unwrap();
        assert!(
            !store
                .feed_system_notification_settings()
                .unwrap()
                .iter()
                .find(|setting| setting.feed_id == 20)
                .unwrap()
                .system_notifications_enabled
        );
    }

    #[test]
    fn reconcile_removes_only_categories_absent_from_the_remote_catalog() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [
            Category {
                id: 1,
                title: "A".into(),
            },
            Category {
                id: 2,
                title: "Removed".into(),
            },
            Category {
                id: 3,
                title: "Empty".into(),
            },
        ];
        let feeds = [Feed {
            id: 10,
            category_id: 1,
            title: "Feed".into(),
        }];
        store.reconcile(&categories, &feeds, &[]).unwrap();

        let stats = store
            .reconcile(&[categories[0].clone(), categories[2].clone()], &feeds, &[])
            .unwrap();
        assert!(stats.navigation_changed);
        let catalog = store.navigation_catalog().unwrap();
        assert_eq!(
            catalog
                .categories
                .iter()
                .map(|category| category.id)
                .collect::<Vec<_>>(),
            vec![1, 3]
        );
        assert_eq!(
            catalog.feeds.iter().map(|feed| feed.id).collect::<Vec<_>>(),
            vec![10]
        );
        assert!(
            !store
                .reconcile(&[categories[0].clone(), categories[2].clone()], &feeds, &[])
                .unwrap()
                .navigation_changed
        );
    }

    #[test]
    fn playback_state_is_enclosure_scoped_and_progress_coalesces() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
        let categories = [Category {
            id: 1,
            title: "Category".into(),
        }];
        let feeds = [Feed {
            id: 2,
            category_id: 1,
            title: "Feed".into(),
        }];
        let articles = [Article {
            id: 1,
            feed_id: 2,
            title: "Article".into(),
            url: "https://example.test/1".into(),
            comments_url: String::new(),
            published_at: "2026-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        }];
        let enclosures = [
            Enclosure {
                id: 10,
                article_id: 1,
                url: "https://cdn.test/a.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
            Enclosure {
                id: 11,
                article_id: 1,
                url: "https://cdn.test/b.mp3".into(),
                mime_type: "audio/mpeg".into(),
                size_bytes: None,
                remote_media_progression_seconds: 0,
            },
        ];
        store
            .reconcile_with_enclosures(&categories, &feeds, &articles, &enclosures)
            .unwrap();
        store
            .checkpoint_playback(10, 120_000, None, "2026-01-01T00:00:00Z", true)
            .unwrap();
        store
            .checkpoint_playback(10, 60_000, None, "2026-01-01T00:01:00Z", true)
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().position_ms,
            60_000
        );
        assert!(store.playback_state(11).unwrap().is_none());
        let pending = store.pending_media_progress_mutations().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].progression_seconds, 60);
        store
            .complete_playback(10, None, "2026-01-01T00:02:00Z", true)
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().status,
            PlaybackStatus::Completed
        );
        assert_eq!(
            store.pending_media_progress_mutations().unwrap()[0].progression_seconds,
            60
        );
        store
            .complete_playback(10, Some(180_000), "2026-01-01T00:03:00Z", true)
            .unwrap();
        let completed = store.playback_state(10).unwrap().unwrap();
        assert_eq!(completed.position_ms, 180_000);
        assert_eq!(completed.duration_ms, Some(180_000));
        assert_eq!(
            store.pending_media_progress_mutations().unwrap()[0].progression_seconds,
            180
        );
        store
            .restart_playback(10, "2026-01-01T00:04:00Z", true)
            .unwrap();
        let restarted = store.playback_state(10).unwrap().unwrap();
        assert_eq!(restarted.status, PlaybackStatus::InProgress);
        assert_eq!(restarted.position_ms, 0);
        assert_eq!(
            store.pending_media_progress_mutations().unwrap()[0].progression_seconds,
            0
        );
    }

    #[test]
    fn playback_reconciliation_preserves_local_and_handles_remote_changes() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
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
        let article = [Article {
            id: 1,
            feed_id: 2,
            title: "Article".into(),
            url: "https://example.test/1".into(),
            comments_url: String::new(),
            published_at: "2026-01-01T00:00:00Z".into(),
            is_read: false,
            is_starred: false,
            raw_html_content: String::new(),
            preview: String::new(),
            image_url: None,
        }];
        let enclosure = |progression| Enclosure {
            id: 10,
            article_id: 1,
            url: "https://cdn.test/a.mp3".into(),
            mime_type: "audio/mpeg".into(),
            size_bytes: None,
            remote_media_progression_seconds: progression,
        };
        store
            .reconcile_with_enclosures(&category, &feeds, &article, &[enclosure(100)])
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().position_ms,
            100_000
        );
        store
            .checkpoint_playback(10, 150_000, None, "2026-01-01T00:01:00Z", false)
            .unwrap();
        store
            .reconcile_with_enclosures(&category, &feeds, &article, &[enclosure(100)])
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().position_ms,
            150_000
        );
        store
            .reconcile_with_enclosures(&category, &feeds, &article, &[enclosure(50)])
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().position_ms,
            50_000
        );
        store
            .checkpoint_playback(10, 120_000, None, "2026-01-01T00:02:00Z", false)
            .unwrap();
        store.upsert_remote_enclosures(&[enclosure(120)]).unwrap();
        store
            .reconcile_with_enclosures_and_progress(
                &category,
                &feeds,
                &article,
                &[enclosure(50)],
                &[(10, 120)].into_iter().collect(),
            )
            .unwrap();
        assert_eq!(
            store.playback_state(10).unwrap().unwrap().position_ms,
            120_000
        );
        assert_eq!(
            store
                .enclosure(10)
                .unwrap()
                .unwrap()
                .enclosure
                .remote_media_progression_seconds,
            120
        );
    }
}
