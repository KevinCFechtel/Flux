//! Thin UniFFI adapter around the real shared core API.

use flux_core::domain;
use flux_core::{CoreConfig, FluxCore};
use std::sync::Arc;

uniffi::setup_scaffolding!();

#[derive(uniffi::Record)]
pub struct InitializationConfig {
    pub persistent_data: String,
    pub cache: String,
    pub media: String,
    pub base_url: String,
    pub api_key: String,
}
#[derive(uniffi::Record)]
pub struct ArticleCursor {
    pub published_at: String,
    pub article_id: i64,
}
#[derive(uniffi::Record)]
pub struct ArticleQuery {
    pub scope: ArticleScope,
    pub read_filter: ReadFilter,
    pub starred_filter: StarredFilter,
    pub sort: ArticleSort,
    pub limit: u32,
    pub cursor: Option<ArticleCursor>,
}
#[derive(uniffi::Record)]
pub struct ArticleSummary {
    pub id: i64,
    pub feed_id: i64,
    pub category_id: i64,
    pub feed_title: String,
    pub title: String,
    pub url: String,
    pub published_at: String,
    pub is_read: bool,
    pub is_starred: bool,
}

#[derive(uniffi::Enum)]
pub enum ArticleScope {
    All,
    Category { id: i64 },
    Feed { id: i64 },
}
#[derive(uniffi::Enum)]
pub enum ReadFilter {
    All,
    Read,
    Unread,
}
#[derive(uniffi::Enum)]
pub enum StarredFilter {
    All,
    Starred,
    Unstarred,
}
#[derive(uniffi::Enum)]
pub enum ArticleSort {
    NewestFirst,
    OldestFirst,
}
#[derive(uniffi::Enum)]
pub enum SyncReason {
    Manual,
    AppStart,
    Resume,
    Background,
    Widget,
}

#[derive(Debug, uniffi::Error)]
pub enum FluxError {
    Connectivity { message: String },
    Authentication { message: String },
    InvalidConfiguration { message: String },
    ServerTransient { message: String },
    Persistence { message: String },
    Data { message: String },
    Internal { message: String },
}

impl std::fmt::Display for FluxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

#[derive(uniffi::Object)]
pub struct Flux {
    core: FluxCore,
}

#[uniffi::export]
impl Flux {
    #[uniffi::constructor]
    pub fn initialize(config: InitializationConfig) -> Result<Arc<Self>, FluxError> {
        let core = FluxCore::initialize(CoreConfig {
            persistent_data: config.persistent_data.into(),
            cache: config.cache.into(),
            media: config.media.into(),
            base_url: config.base_url,
            api_key: config.api_key,
        })
        .map_err(map_error)?;
        Ok(Arc::new(Self { core }))
    }
    pub fn sync(&self, reason: SyncReason) -> Result<(), FluxError> {
        self.core.sync(reason.into()).map_err(map_error)
    }
    pub fn query_articles(&self, query: ArticleQuery) -> Result<Vec<ArticleSummary>, FluxError> {
        self.core
            .query_articles(query.into())
            .map(|rows| rows.into_iter().map(Into::into).collect())
            .map_err(map_error)
    }
}

impl From<ArticleScope> for domain::ArticleScope {
    fn from(value: ArticleScope) -> Self {
        match value {
            ArticleScope::All => Self::All,
            ArticleScope::Category { id } => Self::Category(id),
            ArticleScope::Feed { id } => Self::Feed(id),
        }
    }
}
impl From<ReadFilter> for domain::ReadFilter {
    fn from(value: ReadFilter) -> Self {
        match value {
            ReadFilter::All => Self::All,
            ReadFilter::Read => Self::Read,
            ReadFilter::Unread => Self::Unread,
        }
    }
}
impl From<StarredFilter> for domain::StarredFilter {
    fn from(value: StarredFilter) -> Self {
        match value {
            StarredFilter::All => Self::All,
            StarredFilter::Starred => Self::Starred,
            StarredFilter::Unstarred => Self::Unstarred,
        }
    }
}
impl From<ArticleSort> for domain::ArticleSort {
    fn from(value: ArticleSort) -> Self {
        match value {
            ArticleSort::NewestFirst => Self::NewestFirst,
            ArticleSort::OldestFirst => Self::OldestFirst,
        }
    }
}
impl From<SyncReason> for domain::SyncReason {
    fn from(value: SyncReason) -> Self {
        match value {
            SyncReason::Manual => Self::Manual,
            SyncReason::AppStart => Self::AppStart,
            SyncReason::Resume => Self::Resume,
            SyncReason::Background => Self::Background,
            SyncReason::Widget => Self::Widget,
        }
    }
}
impl From<ArticleQuery> for domain::ArticleQuery {
    fn from(value: ArticleQuery) -> Self {
        Self {
            scope: value.scope.into(),
            read_filter: value.read_filter.into(),
            starred_filter: value.starred_filter.into(),
            sort: value.sort.into(),
            limit: value.limit,
            cursor: value.cursor.map(|c| domain::ArticleCursor {
                published_at: c.published_at,
                article_id: c.article_id,
            }),
        }
    }
}
impl From<domain::ArticleSummary> for ArticleSummary {
    fn from(value: domain::ArticleSummary) -> Self {
        Self {
            id: value.id,
            feed_id: value.feed_id,
            category_id: value.category_id,
            feed_title: value.feed_title,
            title: value.title,
            url: value.url,
            published_at: value.published_at,
            is_read: value.is_read,
            is_starred: value.is_starred,
        }
    }
}
fn map_error(error: domain::CoreError) -> FluxError {
    let message = error.message;
    match error.kind {
        domain::CoreErrorKind::Connectivity => FluxError::Connectivity { message },
        domain::CoreErrorKind::Authentication => FluxError::Authentication { message },
        domain::CoreErrorKind::InvalidConfiguration => FluxError::InvalidConfiguration { message },
        domain::CoreErrorKind::ServerTransient => FluxError::ServerTransient { message },
        domain::CoreErrorKind::Persistence => FluxError::Persistence { message },
        domain::CoreErrorKind::Data => FluxError::Data { message },
        domain::CoreErrorKind::Internal => FluxError::Internal { message },
    }
}
