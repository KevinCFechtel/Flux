//! SQLite persistence. Pending rows coalesce by article/field; acknowledgement
//! deletes only the exact sent revision so later local intent always survives.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::domain::{
    Article, ArticleQuery, ArticleScope, ArticleSort, ArticleSummary, Category, CoreError,
    CoreSettings, DeliveryMode, Feed, FeedSystemNotificationSetting, MutationField,
    NavigationCatalog, ReadArticleRetention, ReadFilter, StarredFilter,
    SystemNotificationCandidate,
};
use rusqlite::{Connection, OptionalExtension, params};

const SCHEMA_VERSION: i64 = 5;

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
        if previous
            .as_deref()
            .is_some_and(|previous| previous != base_url)
        {
            tx.execute_batch("DELETE FROM notification_candidate_articles; DELETE FROM system_notification_candidates; DELETE FROM pending_system_notifications; DELETE FROM feed_system_notification_preferences; DELETE FROM pending_mutations; DELETE FROM articles; DELETE FROM feeds; DELETE FROM categories;").map_err(sql_error)?;
        }
        tx.execute("INSERT INTO core_settings (key, value) VALUES ('base_url', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [base_url]).map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
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
        })
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
        let mut statement = connection.prepare("SELECT f.id,f.title,COALESCE(p.enabled,0) FROM feeds f LEFT JOIN feed_system_notification_preferences p ON p.feed_id=f.id ORDER BY f.category_id,f.title COLLATE NOCASE,f.id").map_err(sql_error)?;
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
        connection.execute("INSERT INTO feed_system_notification_preferences(feed_id,enabled) VALUES(?1,?2) ON CONFLICT(feed_id) DO UPDATE SET enabled=excluded.enabled", params![feed_id, enabled]).map_err(sql_error)?;
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
            let mut statement = tx.prepare("SELECT f.id,f.title FROM feeds f JOIN feed_system_notification_preferences p ON p.feed_id=f.id WHERE p.enabled=1 ORDER BY f.id").map_err(sql_error)?;
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
    Ok(())
}
fn initialize_core_settings(connection: &Connection) -> Result<(), CoreError> {
    let defaults = CoreSettings::default();
    for (key, value) in [
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
    ] {
        connection
            .execute(
                "INSERT INTO core_settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO NOTHING",
                params![key, value],
            )
            .map_err(sql_error)?;
    }
    Ok(())
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
        assert_eq!(store.schema_version().unwrap(), 5);
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
}
