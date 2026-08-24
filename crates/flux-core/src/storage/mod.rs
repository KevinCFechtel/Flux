use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::domain::{
    Article, ArticleQuery, ArticleScope, ArticleSort, ArticleSummary, Category, CoreError, Feed,
    ReadFilter, StarredFilter,
};
use rusqlite::{Connection, OptionalExtension, params};

const SCHEMA_VERSION: i64 = 1;

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
        self.connection.lock().map_err(|_| CoreError::internal("database lock poisoned"))?.execute("INSERT INTO core_settings (key, value) VALUES ('base_url', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [base_url]).map_err(sql_error)?;
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
    pub fn reconcile(
        &self,
        categories: &[Category],
        feeds: &[Feed],
        articles: &[Article],
    ) -> Result<(), CoreError> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let tx = connection.transaction().map_err(sql_error)?;
        for c in categories {
            tx.execute("INSERT INTO categories (id,title) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET title=excluded.title", params![c.id,c.title]).map_err(sql_error)?;
        }
        for f in feeds {
            tx.execute("INSERT INTO feeds (id,category_id,title) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET category_id=excluded.category_id,title=excluded.title", params![f.id,f.category_id,f.title]).map_err(sql_error)?;
        }
        for a in articles {
            tx.execute("INSERT INTO articles (id,feed_id,title,url,comments_url,published_at,is_read,is_starred,raw_html_content) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(id) DO UPDATE SET feed_id=excluded.feed_id,title=excluded.title,url=excluded.url,comments_url=excluded.comments_url,published_at=excluded.published_at,is_read=excluded.is_read,is_starred=excluded.is_starred,raw_html_content=excluded.raw_html_content", params![a.id,a.feed_id,a.title,a.url,a.comments_url,a.published_at,a.is_read,a.is_starred,a.raw_html_content]).map_err(sql_error)?;
        }
        tx.commit().map_err(sql_error)
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
    pub fn query_articles(&self, query: &ArticleQuery) -> Result<Vec<ArticleSummary>, CoreError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| CoreError::internal("database lock poisoned"))?;
        let mut sql = String::from(
            "SELECT a.id,a.feed_id,f.category_id,f.title,a.title,a.url,a.published_at,a.is_read,a.is_starred FROM articles a JOIN feeds f ON f.id=a.feed_id WHERE 1=1",
        );
        let mut values: Vec<rusqlite::types::Value> = Vec::new();
        match query.scope {
            ArticleScope::All => {}
            ArticleScope::Category(id) => {
                sql.push_str(" AND f.category_id=?");
                values.push(id.into());
            }
            ArticleScope::Feed(id) => {
                sql.push_str(" AND a.feed_id=?");
                values.push(id.into());
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
                    published_at: r.get(6)?,
                    is_read: r.get(7)?,
                    is_starred: r.get(8)?,
                })
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)
    }
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
    Ok(())
}
fn sql_error(error: rusqlite::Error) -> CoreError {
    CoreError::persistence(error.to_string())
}
