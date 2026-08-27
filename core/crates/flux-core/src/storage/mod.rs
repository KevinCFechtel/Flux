//! SQLite persistence. Pending rows coalesce by article/field; acknowledgement
//! deletes only the exact sent revision so later local intent always survives.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::domain::{
    Article, ArticleQuery, ArticleScope, ArticleSort, ArticleSummary, Category, CoreError,
    CoreSettings, DeliveryMode, DetailRenderingMode, Feed, FeedPreferences,
    FeedSystemNotificationSetting, MutationField, NavigationCatalog, ReadArticleRetention,
    ReadFilter, StarredFilter, SystemNotificationCandidate, WidgetArticle, WidgetCounts,
    WidgetData, WidgetScopedCount,
};
use crate::miniflux::normalize_installation_base;
use rusqlite::{Connection, OptionalExtension, Transaction, params};

const SCHEMA_VERSION: i64 = 7;

#[derive(Clone, Debug)]
pub struct PendingMutation {
    pub article_id: i64,
    pub field: MutationField,
    pub desired: bool,
    pub revision: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LocalArticleState {
    pub is_read: bool,
    pub is_starred: bool,
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
                "DELETE FROM articles WHERE is_read=1 AND is_starred=0 AND published_at < ?1",
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
        let mut statement=connection.prepare("SELECT article_id,field,desired,revision FROM pending_mutations ORDER BY article_id,field").map_err(sql_error)?;
        statement
            .query_map([], |r| {
                Ok(PendingMutation {
                    article_id: r.get(0)?,
                    field: parse_field(r.get::<_, String>(1)?.as_str())?,
                    desired: r.get(2)?,
                    revision: r.get(3)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
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
        };
        tx.execute(
            &format!("UPDATE articles SET {remote_column}=?1 WHERE id=?2"),
            params![pending.desired, pending.article_id],
        )
        .map_err(sql_error)?;
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
        tx.pragma_update(None, "user_version", SCHEMA_VERSION)
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
    }
    tx.execute_batch("DELETE FROM feeds; DELETE FROM categories; DELETE FROM core_settings WHERE key='last_successful_sync_at';").map_err(sql_error)
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
    }
}
fn parse_field(field: &str) -> Result<MutationField, rusqlite::Error> {
    match field {
        "read" => Ok(MutationField::Read),
        "starred" => Ok(MutationField::Starred),
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
        assert_eq!(store.schema_version().unwrap(), 7);
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
        assert_eq!(store.schema_version().unwrap(), 7);
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
        assert_eq!(store.schema_version().unwrap(), 7);
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
    fn fresh_schema_permits_orphan_preferences_without_cascade() {
        let temp = TempDir::new().unwrap();
        let (data, cache, media) = roots(&temp);
        let store = Store::open(&data, &cache, &media).unwrap();
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
}
