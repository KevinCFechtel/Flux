use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Category {
    pub id: i64,
    pub title: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Feed {
    pub id: i64,
    pub category_id: i64,
    pub title: String,
}

/// Flexible local representation aligned with Miniflux's source article data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Article {
    pub id: i64,
    pub feed_id: i64,
    pub title: String,
    pub url: String,
    pub comments_url: String,
    pub published_at: String,
    pub is_read: bool,
    pub is_starred: bool,
    pub raw_html_content: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArticleScope {
    All,
    Category(i64),
    Feed(i64),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadFilter {
    All,
    Read,
    Unread,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StarredFilter {
    All,
    Starred,
    Unstarred,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArticleSort {
    NewestFirst,
    OldestFirst,
}

/// Opaque keyset position. It includes the invisible ID tie-breaker only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArticleCursor {
    pub published_at: String,
    pub article_id: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArticleQuery {
    pub scope: ArticleScope,
    pub read_filter: ReadFilter,
    pub starred_filter: StarredFilter,
    pub sort: ArticleSort,
    pub limit: u32,
    pub cursor: Option<ArticleCursor>,
}

impl Default for ArticleQuery {
    fn default() -> Self {
        Self {
            scope: ArticleScope::All,
            read_filter: ReadFilter::All,
            starred_filter: StarredFilter::All,
            sort: ArticleSort::NewestFirst,
            limit: 50,
            cursor: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncReason {
    Manual,
    AppStart,
    Resume,
    Background,
    Widget,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryMode {
    Live,
    Deferred,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeHealth {
    Healthy,
    ConnectivityDegraded,
    ServerDegraded,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MutationField {
    Read,
    Starred,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryDisposition {
    Queued,
    Delivered,
    DeferredByBackoff,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MutationResult {
    pub disposition: DeliveryDisposition,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreEvent {
    ArticleReadStateChanged {
        article_id: i64,
        read: bool,
    },
    ArticleStarredStateChanged {
        article_id: i64,
        starred: bool,
    },
    MutationQueued {
        article_id: i64,
        field: MutationField,
    },
    MutationDeliverySucceeded {
        article_id: i64,
        field: MutationField,
    },
    MutationDeliveryFailed {
        article_id: i64,
        field: MutationField,
        error_kind: CoreErrorKind,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreErrorKind {
    Connectivity,
    Authentication,
    InvalidConfiguration,
    ServerTransient,
    Persistence,
    Data,
    Internal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoreError {
    pub kind: CoreErrorKind,
    pub message: String,
}

impl CoreError {
    pub fn connectivity(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::Connectivity,
            message: message.into(),
        }
    }
    pub fn authentication(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::Authentication,
            message: message.into(),
        }
    }
    pub fn invalid_configuration(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::InvalidConfiguration,
            message: message.into(),
        }
    }
    pub fn server_transient(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::ServerTransient,
            message: message.into(),
        }
    }
    pub fn persistence(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::Persistence,
            message: message.into(),
        }
    }
    pub fn data(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::Data,
            message: message.into(),
        }
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            kind: CoreErrorKind::Internal,
            message: message.into(),
        }
    }
}
impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for CoreError {}
