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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FeedIconVariant {
    Normal,
    Dark,
}

/// A normalized 32x32 PNG owned by the core cache.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeedIcon {
    pub feed_id: i64,
    pub variant: FeedIconVariant,
    pub png_data: Vec<u8>,
}

/// A lazily acquired, normalized article thumbnail owned by the core cache.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArticleThumbnailResult {
    Available { png_data: Vec<u8> },
    Unavailable,
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
    pub preview: String,
    pub image_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArticleSummary {
    pub id: i64,
    pub feed_id: i64,
    pub category_id: i64,
    pub feed_title: String,
    pub title: String,
    pub url: String,
    pub comments_url: String,
    pub published_at: String,
    pub is_read: bool,
    pub is_starred: bool,
    pub preview: String,
    pub image_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReaderDocument {
    pub blocks: Vec<ReaderBlock>,
    pub has_simplified_content: bool,
    pub was_truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReaderBlock {
    Paragraph {
        inlines: Vec<ReaderInline>,
    },
    Heading {
        level: u8,
        inlines: Vec<ReaderInline>,
    },
    Image {
        url: String,
        alt: Option<String>,
        link: Option<String>,
    },
    List {
        ordered: bool,
        items: Vec<ReaderListItem>,
    },
    Quote {
        blocks: Vec<ReaderBlock>,
    },
    CodeBlock {
        text: String,
    },
    HorizontalRule,
    ExternalContent {
        url: String,
        label: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReaderListItem {
    pub blocks: Vec<ReaderBlock>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReaderInline {
    Text {
        text: String,
    },
    Bold {
        inlines: Vec<ReaderInline>,
    },
    Italic {
        inlines: Vec<ReaderInline>,
    },
    Code {
        text: String,
    },
    Link {
        url: String,
        inlines: Vec<ReaderInline>,
    },
}

/// A page of temporary, remote Miniflux search results.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchArticlesRequest {
    pub query: String,
    pub offset: i64,
    pub limit: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchArticlesResult {
    pub total: i64,
    pub articles: Vec<ArticleSummary>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchMutationDisposition {
    LocalFirst,
    RemoteOnly,
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
    Periodic,
    Widget,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryMode {
    Live,
    Deferred,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadArticleRetention {
    Days30,
    Days60,
    Days90,
    Days180,
    Days365,
}

impl ReadArticleRetention {
    pub const fn days(self) -> i64 {
        match self {
            Self::Days30 => 30,
            Self::Days60 => 60,
            Self::Days90 => 90,
            Self::Days180 => 180,
            Self::Days365 => 365,
        }
    }

    pub(crate) fn from_days(days: &str) -> Result<Self, CoreError> {
        match days {
            "30" => Ok(Self::Days30),
            "60" => Ok(Self::Days60),
            "90" => Ok(Self::Days90),
            "180" => Ok(Self::Days180),
            "365" => Ok(Self::Days365),
            _ => Err(CoreError::persistence(
                "invalid read article retention setting",
            )),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CoreSettings {
    pub retention: ReadArticleRetention,
    pub delivery_mode: DeliveryMode,
    pub background_sync_enabled: bool,
    pub detail_character_limit: u32,
}

impl Default for CoreSettings {
    fn default() -> Self {
        Self {
            retention: ReadArticleRetention::Days90,
            delivery_mode: DeliveryMode::Deferred,
            background_sync_enabled: true,
            detail_character_limit: 10_000,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeHealth {
    Healthy,
    ConnectivityDegraded,
    ServerDegraded,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeHealthStatus {
    pub health: RuntimeHealth,
    /// RFC 3339 timestamp. Absent while healthy.
    pub next_retry_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NavigationCatalog {
    pub categories: Vec<Category>,
    pub feeds: Vec<Feed>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewArticlesByFeed {
    pub feed_id: i64,
    pub count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeedSystemNotificationSetting {
    pub feed_id: i64,
    pub feed_title: String,
    pub system_notifications_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DetailRenderingMode {
    Rendered,
    TextOnly,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeedPreferences {
    pub feed_id: i64,
    pub system_notifications_enabled: bool,
    pub detail_rendering: DetailRenderingMode,
    pub truncate_detail: bool,
    pub open_in_miniflux: bool,
}

impl FeedPreferences {
    pub fn defaults(feed_id: i64) -> Self {
        Self {
            feed_id,
            system_notifications_enabled: false,
            detail_rendering: DetailRenderingMode::Rendered,
            truncate_detail: false,
            open_in_miniflux: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SystemNotificationCandidate {
    pub candidate_id: i64,
    pub feed_id: i64,
    pub feed_title: String,
    pub new_count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncCompleted {
    pub reason: SyncReason,
    pub new_articles: u32,
    pub updated_articles: u32,
    pub mutations_delivered: u32,
    pub data_changed: bool,
    pub navigation_changed: bool,
    pub new_articles_by_feed: Vec<NewArticlesByFeed>,
    pub system_notification_candidates: Vec<SystemNotificationCandidate>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncFailure {
    pub reason: SyncReason,
    pub error_kind: CoreErrorKind,
    pub mutation_delivery_completed: bool,
    pub remote_fetch_started: bool,
    pub remote_fetch_completed: bool,
    pub mutations_delivered: u32,
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
pub enum SaveToServiceResult {
    Saved,
    NoIntegrationConfigured,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoverSubscriptionsRequest {
    pub url: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub user_agent: Option<String>,
    pub fetch_via_proxy: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoveredSubscription {
    pub url: String,
    pub title: String,
    pub feed_type: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateFeedRequest {
    pub feed_url: String,
    pub category_id: Option<i64>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub crawler: Option<bool>,
    pub user_agent: Option<String>,
    pub scraper_rules: Option<String>,
    pub rewrite_rules: Option<String>,
    pub blocklist_rules: Option<String>,
    pub keeplist_rules: Option<String>,
    pub disabled: Option<bool>,
    pub ignore_http_cache: Option<bool>,
    pub fetch_via_proxy: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateFeedResult {
    pub feed_id: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateCategoryResult {
    pub category_id: i64,
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
    SyncCompleted(SyncCompleted),
    SyncFailed(SyncFailure),
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
