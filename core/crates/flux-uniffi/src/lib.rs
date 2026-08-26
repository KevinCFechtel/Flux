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
    pub comments_url: String,
    pub published_at: String,
    pub is_read: bool,
    pub is_starred: bool,
    pub preview: String,
    pub image_url: Option<String>,
}
#[derive(uniffi::Record)]
pub struct SearchArticlesRequest {
    pub query: String,
    pub offset: i64,
    pub limit: u32,
}
#[derive(uniffi::Record)]
pub struct SearchArticlesResult {
    pub total: i64,
    pub articles: Vec<ArticleSummary>,
}

#[derive(uniffi::Enum)]
pub enum SearchMutationDisposition {
    LocalFirst,
    RemoteOnly,
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
    Periodic,
    Widget,
}
#[derive(uniffi::Record)]
pub struct Category {
    pub id: i64,
    pub title: String,
}
#[derive(uniffi::Record)]
pub struct Feed {
    pub id: i64,
    pub category_id: i64,
    pub title: String,
}
#[derive(uniffi::Enum)]
pub enum FeedIconVariant {
    Normal,
    Dark,
}
#[derive(uniffi::Record)]
pub struct FeedIcon {
    pub feed_id: i64,
    pub variant: FeedIconVariant,
    pub png_data: Vec<u8>,
}
#[derive(uniffi::Enum)]
pub enum ArticleThumbnailResult {
    Available { png_data: Vec<u8> },
    Unavailable,
}
#[derive(uniffi::Record)]
pub struct NavigationCatalog {
    pub categories: Vec<Category>,
    pub feeds: Vec<Feed>,
}
#[derive(uniffi::Enum)]
pub enum RuntimeHealth {
    Healthy,
    ConnectivityDegraded,
    ServerDegraded,
}
#[derive(uniffi::Record)]
pub struct RuntimeHealthStatus {
    pub health: RuntimeHealth,
    pub next_retry_at: Option<String>,
}
#[derive(uniffi::Record)]
pub struct SyncCompleted {
    pub reason: SyncReason,
    pub new_articles: u32,
    pub updated_articles: u32,
    pub mutations_delivered: u32,
    pub data_changed: bool,
    pub navigation_changed: bool,
}
#[derive(uniffi::Record)]
pub struct SyncFailed {
    pub reason: SyncReason,
    pub error_kind: ErrorKind,
    pub mutation_delivery_completed: bool,
    pub remote_fetch_started: bool,
    pub remote_fetch_completed: bool,
    pub mutations_delivered: u32,
}
#[derive(uniffi::Enum)]
pub enum DeliveryMode {
    Live,
    Deferred,
}
#[derive(uniffi::Enum)]
pub enum ReadArticleRetention {
    Days30,
    Days60,
    Days90,
    Days180,
    Days365,
}
#[derive(uniffi::Record)]
pub struct CoreSettings {
    pub retention: ReadArticleRetention,
    pub delivery_mode: DeliveryMode,
    pub background_sync_enabled: bool,
}
#[derive(uniffi::Enum)]
pub enum DeliveryDisposition {
    Queued,
    Delivered,
    DeferredByBackoff,
}
#[derive(uniffi::Record)]
pub struct MutationResult {
    pub disposition: DeliveryDisposition,
}
#[derive(uniffi::Record)]
pub struct DiscoverSubscriptionsRequest {
    pub url: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub user_agent: Option<String>,
    pub fetch_via_proxy: Option<bool>,
}
#[derive(uniffi::Record)]
pub struct DiscoveredSubscription {
    pub url: String,
    pub title: String,
    pub feed_type: String,
}
#[derive(uniffi::Record)]
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
#[derive(uniffi::Record)]
pub struct CreateFeedResult {
    pub feed_id: i64,
}
#[derive(uniffi::Record)]
pub struct CreateCategoryResult {
    pub category_id: i64,
}
#[derive(uniffi::Enum)]
pub enum SaveToServiceResult {
    Saved,
    NoIntegrationConfigured,
}
#[derive(uniffi::Enum)]
pub enum MutationField {
    Read,
    Starred,
}
#[derive(uniffi::Enum)]
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
        error_kind: ErrorKind,
    },
    SyncCompleted {
        metadata: SyncCompleted,
    },
    SyncFailed {
        metadata: SyncFailed,
    },
}
#[derive(uniffi::Enum)]
pub enum ErrorKind {
    Connectivity,
    Authentication,
    InvalidConfiguration,
    ServerTransient,
    Persistence,
    Data,
    Internal,
}
#[uniffi::export(with_foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}
#[derive(uniffi::Enum)]
pub enum DiagnosticLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}
#[derive(uniffi::Record)]
pub struct DiagnosticRecord {
    pub level: DiagnosticLevel,
    pub target: String,
    pub message: String,
}
#[uniffi::export(with_foreign)]
pub trait DiagnosticListener: Send + Sync {
    fn on_diagnostic(&self, record: DiagnosticRecord);
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
    core: Arc<FluxCore>,
}
#[derive(uniffi::Object)]
pub struct EventSubscription {
    core: Arc<FluxCore>,
    id: u64,
}
#[derive(uniffi::Object)]
pub struct DiagnosticSubscription {
    core: Arc<FluxCore>,
    id: u64,
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
        Ok(Arc::new(Self {
            core: Arc::new(core),
        }))
    }
    #[uniffi::constructor]
    pub fn initialize_with_diagnostics(
        config: InitializationConfig,
        listener: Arc<dyn DiagnosticListener>,
    ) -> Result<Arc<Self>, FluxError> {
        let core = FluxCore::initialize_with_diagnostics(
            CoreConfig {
                persistent_data: config.persistent_data.into(),
                cache: config.cache.into(),
                media: config.media.into(),
                base_url: config.base_url,
                api_key: config.api_key,
            },
            Some(Arc::new(DiagnosticListenerBridge { listener })),
        )
        .map_err(map_error)?;
        Ok(Arc::new(Self {
            core: Arc::new(core),
        }))
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
    pub fn count_articles(&self, query: ArticleQuery) -> Result<u64, FluxError> {
        self.core.count_articles(query.into()).map_err(map_error)
    }
    pub fn search_articles(
        &self,
        request: SearchArticlesRequest,
    ) -> Result<SearchArticlesResult, FluxError> {
        self.core
            .search_articles(request.into())
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn search_set_starred_state(
        &self,
        article_id: i64,
        starred: bool,
    ) -> Result<SearchMutationDisposition, FluxError> {
        self.core
            .search_set_starred_state(article_id, starred)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn search_set_read_state(
        &self,
        article_id: i64,
        read: bool,
    ) -> Result<SearchMutationDisposition, FluxError> {
        self.core
            .search_set_read_state(article_id, read)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn navigation_catalog(&self) -> Result<NavigationCatalog, FluxError> {
        self.core
            .navigation_catalog()
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn feed_icon(
        &self,
        feed_id: i64,
        variant: FeedIconVariant,
    ) -> Result<Option<FeedIcon>, FluxError> {
        self.core
            .feed_icon(feed_id, variant.into())
            .map(|icon| icon.map(Into::into))
            .map_err(map_error)
    }
    pub fn article_thumbnail(
        &self,
        article_id: i64,
        image_url: String,
    ) -> Result<ArticleThumbnailResult, FluxError> {
        self.core
            .article_thumbnail(article_id, image_url)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn last_successful_sync_at(&self) -> Result<Option<String>, FluxError> {
        self.core.last_successful_sync_at().map_err(map_error)
    }
    pub fn runtime_health(&self) -> Result<RuntimeHealthStatus, FluxError> {
        self.core
            .runtime_health()
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn set_delivery_mode(&self, mode: DeliveryMode) -> Result<(), FluxError> {
        self.core.set_delivery_mode(mode.into()).map_err(map_error)
    }
    pub fn core_settings(&self) -> Result<CoreSettings, FluxError> {
        self.core.core_settings().map(Into::into).map_err(map_error)
    }
    pub fn set_retention(&self, retention: ReadArticleRetention) -> Result<(), FluxError> {
        self.core.set_retention(retention.into()).map_err(map_error)
    }
    pub fn set_background_sync_enabled(&self, enabled: bool) -> Result<(), FluxError> {
        self.core
            .set_background_sync_enabled(enabled)
            .map_err(map_error)
    }
    pub fn set_read_state(&self, article_id: i64, read: bool) -> Result<MutationResult, FluxError> {
        self.core
            .set_read_state(article_id, read)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn set_read_state_bulk(
        &self,
        article_ids: Vec<i64>,
        read: bool,
    ) -> Result<MutationResult, FluxError> {
        self.core
            .set_read_state_bulk(&article_ids, read)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn set_starred_state(
        &self,
        article_id: i64,
        starred: bool,
    ) -> Result<MutationResult, FluxError> {
        self.core
            .set_starred_state(article_id, starred)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn set_starred_state_bulk(
        &self,
        article_ids: Vec<i64>,
        starred: bool,
    ) -> Result<MutationResult, FluxError> {
        self.core
            .set_starred_state_bulk(&article_ids, starred)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn save_to_service(&self, article_id: i64) -> Result<SaveToServiceResult, FluxError> {
        self.core
            .save_to_service(article_id)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn discover_subscriptions(
        &self,
        request: DiscoverSubscriptionsRequest,
    ) -> Result<Vec<DiscoveredSubscription>, FluxError> {
        self.core
            .discover_subscriptions(request.into())
            .map(|subscriptions| subscriptions.into_iter().map(Into::into).collect())
            .map_err(map_error)
    }
    pub fn create_feed(&self, request: CreateFeedRequest) -> Result<CreateFeedResult, FluxError> {
        self.core
            .create_feed(request.into())
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn create_category(&self, title: String) -> Result<CreateCategoryResult, FluxError> {
        self.core
            .create_category(title)
            .map(Into::into)
            .map_err(map_error)
    }
    pub fn subscribe_events(
        &self,
        listener: Arc<dyn EventListener>,
    ) -> Result<Arc<EventSubscription>, FluxError> {
        let id = self
            .core
            .subscribe_events(Arc::new(ListenerBridge { listener }))
            .map_err(map_error)?;
        Ok(Arc::new(EventSubscription {
            core: self.core.clone(),
            id,
        }))
    }
    pub fn subscribe_diagnostics(
        &self,
        listener: Arc<dyn DiagnosticListener>,
    ) -> Arc<DiagnosticSubscription> {
        let id = self
            .core
            .subscribe_diagnostics(Arc::new(DiagnosticListenerBridge { listener }));
        Arc::new(DiagnosticSubscription {
            core: self.core.clone(),
            id,
        })
    }
}
#[uniffi::export]
impl EventSubscription {
    pub fn unsubscribe(&self) -> Result<(), FluxError> {
        self.core.unsubscribe_events(self.id).map_err(map_error)
    }
}
#[uniffi::export]
impl DiagnosticSubscription {
    pub fn unsubscribe(&self) {
        self.core.unsubscribe_diagnostics(self.id);
    }
}
struct ListenerBridge {
    listener: Arc<dyn EventListener>,
}
impl flux_core::CoreEventListener for ListenerBridge {
    fn on_event(&self, event: domain::CoreEvent) {
        self.listener.on_event(event.into())
    }
}
struct DiagnosticListenerBridge {
    listener: Arc<dyn DiagnosticListener>,
}
impl flux_core::diagnostics::CoreDiagnosticListener for DiagnosticListenerBridge {
    fn on_diagnostic(&self, record: flux_core::diagnostics::DiagnosticRecord) {
        self.listener.on_diagnostic(record.into())
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
            SyncReason::Periodic => Self::Periodic,
            SyncReason::Widget => Self::Widget,
        }
    }
}
impl From<DeliveryMode> for domain::DeliveryMode {
    fn from(value: DeliveryMode) -> Self {
        match value {
            DeliveryMode::Live => Self::Live,
            DeliveryMode::Deferred => Self::Deferred,
        }
    }
}
impl From<ReadArticleRetention> for domain::ReadArticleRetention {
    fn from(value: ReadArticleRetention) -> Self {
        match value {
            ReadArticleRetention::Days30 => Self::Days30,
            ReadArticleRetention::Days60 => Self::Days60,
            ReadArticleRetention::Days90 => Self::Days90,
            ReadArticleRetention::Days180 => Self::Days180,
            ReadArticleRetention::Days365 => Self::Days365,
        }
    }
}
impl From<domain::CoreSettings> for CoreSettings {
    fn from(value: domain::CoreSettings) -> Self {
        Self {
            retention: match value.retention {
                domain::ReadArticleRetention::Days30 => ReadArticleRetention::Days30,
                domain::ReadArticleRetention::Days60 => ReadArticleRetention::Days60,
                domain::ReadArticleRetention::Days90 => ReadArticleRetention::Days90,
                domain::ReadArticleRetention::Days180 => ReadArticleRetention::Days180,
                domain::ReadArticleRetention::Days365 => ReadArticleRetention::Days365,
            },
            delivery_mode: match value.delivery_mode {
                domain::DeliveryMode::Live => DeliveryMode::Live,
                domain::DeliveryMode::Deferred => DeliveryMode::Deferred,
            },
            background_sync_enabled: value.background_sync_enabled,
        }
    }
}
impl From<domain::MutationResult> for MutationResult {
    fn from(value: domain::MutationResult) -> Self {
        Self {
            disposition: match value.disposition {
                domain::DeliveryDisposition::Queued => DeliveryDisposition::Queued,
                domain::DeliveryDisposition::Delivered => DeliveryDisposition::Delivered,
                domain::DeliveryDisposition::DeferredByBackoff => {
                    DeliveryDisposition::DeferredByBackoff
                }
            },
        }
    }
}
impl From<domain::SaveToServiceResult> for SaveToServiceResult {
    fn from(value: domain::SaveToServiceResult) -> Self {
        match value {
            domain::SaveToServiceResult::Saved => Self::Saved,
            domain::SaveToServiceResult::NoIntegrationConfigured => Self::NoIntegrationConfigured,
        }
    }
}
impl From<DiscoverSubscriptionsRequest> for domain::DiscoverSubscriptionsRequest {
    fn from(value: DiscoverSubscriptionsRequest) -> Self {
        Self {
            url: value.url,
            username: value.username,
            password: value.password,
            user_agent: value.user_agent,
            fetch_via_proxy: value.fetch_via_proxy,
        }
    }
}
impl From<domain::DiscoveredSubscription> for DiscoveredSubscription {
    fn from(value: domain::DiscoveredSubscription) -> Self {
        Self {
            url: value.url,
            title: value.title,
            feed_type: value.feed_type,
        }
    }
}
impl From<CreateFeedRequest> for domain::CreateFeedRequest {
    fn from(value: CreateFeedRequest) -> Self {
        Self {
            feed_url: value.feed_url,
            category_id: value.category_id,
            username: value.username,
            password: value.password,
            crawler: value.crawler,
            user_agent: value.user_agent,
            scraper_rules: value.scraper_rules,
            rewrite_rules: value.rewrite_rules,
            blocklist_rules: value.blocklist_rules,
            keeplist_rules: value.keeplist_rules,
            disabled: value.disabled,
            ignore_http_cache: value.ignore_http_cache,
            fetch_via_proxy: value.fetch_via_proxy,
        }
    }
}
impl From<domain::CreateFeedResult> for CreateFeedResult {
    fn from(value: domain::CreateFeedResult) -> Self {
        Self {
            feed_id: value.feed_id,
        }
    }
}
impl From<domain::CreateCategoryResult> for CreateCategoryResult {
    fn from(value: domain::CreateCategoryResult) -> Self {
        Self {
            category_id: value.category_id,
        }
    }
}
impl From<domain::MutationField> for MutationField {
    fn from(value: domain::MutationField) -> Self {
        match value {
            domain::MutationField::Read => Self::Read,
            domain::MutationField::Starred => Self::Starred,
        }
    }
}
impl From<flux_core::diagnostics::DiagnosticLevel> for DiagnosticLevel {
    fn from(value: flux_core::diagnostics::DiagnosticLevel) -> Self {
        match value {
            flux_core::diagnostics::DiagnosticLevel::Trace => Self::Trace,
            flux_core::diagnostics::DiagnosticLevel::Debug => Self::Debug,
            flux_core::diagnostics::DiagnosticLevel::Info => Self::Info,
            flux_core::diagnostics::DiagnosticLevel::Warn => Self::Warn,
            flux_core::diagnostics::DiagnosticLevel::Error => Self::Error,
        }
    }
}
impl From<flux_core::diagnostics::DiagnosticRecord> for DiagnosticRecord {
    fn from(value: flux_core::diagnostics::DiagnosticRecord) -> Self {
        Self {
            level: value.level.into(),
            target: value.target,
            message: value.message,
        }
    }
}
impl From<domain::CoreErrorKind> for ErrorKind {
    fn from(value: domain::CoreErrorKind) -> Self {
        match value {
            domain::CoreErrorKind::Connectivity => Self::Connectivity,
            domain::CoreErrorKind::Authentication => Self::Authentication,
            domain::CoreErrorKind::InvalidConfiguration => Self::InvalidConfiguration,
            domain::CoreErrorKind::ServerTransient => Self::ServerTransient,
            domain::CoreErrorKind::Persistence => Self::Persistence,
            domain::CoreErrorKind::Data => Self::Data,
            domain::CoreErrorKind::Internal => Self::Internal,
        }
    }
}
impl From<domain::CoreEvent> for CoreEvent {
    fn from(value: domain::CoreEvent) -> Self {
        match value {
            domain::CoreEvent::ArticleReadStateChanged { article_id, read } => {
                Self::ArticleReadStateChanged { article_id, read }
            }
            domain::CoreEvent::ArticleStarredStateChanged {
                article_id,
                starred,
            } => Self::ArticleStarredStateChanged {
                article_id,
                starred,
            },
            domain::CoreEvent::MutationQueued { article_id, field } => Self::MutationQueued {
                article_id,
                field: field.into(),
            },
            domain::CoreEvent::MutationDeliverySucceeded { article_id, field } => {
                Self::MutationDeliverySucceeded {
                    article_id,
                    field: field.into(),
                }
            }
            domain::CoreEvent::MutationDeliveryFailed {
                article_id,
                field,
                error_kind,
            } => Self::MutationDeliveryFailed {
                article_id,
                field: field.into(),
                error_kind: error_kind.into(),
            },
            domain::CoreEvent::SyncCompleted(metadata) => Self::SyncCompleted {
                metadata: metadata.into(),
            },
            domain::CoreEvent::SyncFailed(metadata) => Self::SyncFailed {
                metadata: metadata.into(),
            },
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
impl From<SearchArticlesRequest> for domain::SearchArticlesRequest {
    fn from(value: SearchArticlesRequest) -> Self {
        Self {
            query: value.query,
            offset: value.offset,
            limit: value.limit,
        }
    }
}
impl From<domain::SearchArticlesResult> for SearchArticlesResult {
    fn from(value: domain::SearchArticlesResult) -> Self {
        Self {
            total: value.total,
            articles: value.articles.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<domain::SearchMutationDisposition> for SearchMutationDisposition {
    fn from(value: domain::SearchMutationDisposition) -> Self {
        match value {
            domain::SearchMutationDisposition::LocalFirst => Self::LocalFirst,
            domain::SearchMutationDisposition::RemoteOnly => Self::RemoteOnly,
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
            comments_url: value.comments_url,
            published_at: value.published_at,
            is_read: value.is_read,
            is_starred: value.is_starred,
            preview: value.preview,
            image_url: value.image_url,
        }
    }
}
impl From<domain::Category> for Category {
    fn from(value: domain::Category) -> Self {
        Self {
            id: value.id,
            title: value.title,
        }
    }
}
impl From<domain::Feed> for Feed {
    fn from(value: domain::Feed) -> Self {
        Self {
            id: value.id,
            category_id: value.category_id,
            title: value.title,
        }
    }
}
impl From<FeedIconVariant> for domain::FeedIconVariant {
    fn from(value: FeedIconVariant) -> Self {
        match value {
            FeedIconVariant::Normal => Self::Normal,
            FeedIconVariant::Dark => Self::Dark,
        }
    }
}
impl From<domain::FeedIconVariant> for FeedIconVariant {
    fn from(value: domain::FeedIconVariant) -> Self {
        match value {
            domain::FeedIconVariant::Normal => Self::Normal,
            domain::FeedIconVariant::Dark => Self::Dark,
        }
    }
}
impl From<domain::FeedIcon> for FeedIcon {
    fn from(value: domain::FeedIcon) -> Self {
        Self {
            feed_id: value.feed_id,
            variant: value.variant.into(),
            png_data: value.png_data,
        }
    }
}
impl From<domain::ArticleThumbnailResult> for ArticleThumbnailResult {
    fn from(value: domain::ArticleThumbnailResult) -> Self {
        match value {
            domain::ArticleThumbnailResult::Available { png_data } => Self::Available { png_data },
            domain::ArticleThumbnailResult::Unavailable => Self::Unavailable,
        }
    }
}
impl From<domain::NavigationCatalog> for NavigationCatalog {
    fn from(value: domain::NavigationCatalog) -> Self {
        Self {
            categories: value.categories.into_iter().map(Into::into).collect(),
            feeds: value.feeds.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<domain::RuntimeHealth> for RuntimeHealth {
    fn from(value: domain::RuntimeHealth) -> Self {
        match value {
            domain::RuntimeHealth::Healthy => Self::Healthy,
            domain::RuntimeHealth::ConnectivityDegraded => Self::ConnectivityDegraded,
            domain::RuntimeHealth::ServerDegraded => Self::ServerDegraded,
        }
    }
}
impl From<domain::RuntimeHealthStatus> for RuntimeHealthStatus {
    fn from(value: domain::RuntimeHealthStatus) -> Self {
        Self {
            health: value.health.into(),
            next_retry_at: value.next_retry_at,
        }
    }
}
impl From<domain::SyncCompleted> for SyncCompleted {
    fn from(value: domain::SyncCompleted) -> Self {
        Self {
            reason: match value.reason {
                domain::SyncReason::Manual => SyncReason::Manual,
                domain::SyncReason::AppStart => SyncReason::AppStart,
                domain::SyncReason::Resume => SyncReason::Resume,
                domain::SyncReason::Background => SyncReason::Background,
                domain::SyncReason::Periodic => SyncReason::Periodic,
                domain::SyncReason::Widget => SyncReason::Widget,
            },
            new_articles: value.new_articles,
            updated_articles: value.updated_articles,
            mutations_delivered: value.mutations_delivered,
            data_changed: value.data_changed,
            navigation_changed: value.navigation_changed,
        }
    }
}
impl From<domain::SyncFailure> for SyncFailed {
    fn from(value: domain::SyncFailure) -> Self {
        Self {
            reason: match value.reason {
                domain::SyncReason::Manual => SyncReason::Manual,
                domain::SyncReason::AppStart => SyncReason::AppStart,
                domain::SyncReason::Resume => SyncReason::Resume,
                domain::SyncReason::Background => SyncReason::Background,
                domain::SyncReason::Periodic => SyncReason::Periodic,
                domain::SyncReason::Widget => SyncReason::Widget,
            },
            error_kind: value.error_kind.into(),
            mutation_delivery_completed: value.mutation_delivery_completed,
            remote_fetch_started: value.remote_fetch_started,
            remote_fetch_completed: value.remote_fetch_completed,
            mutations_delivered: value.mutations_delivered,
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
