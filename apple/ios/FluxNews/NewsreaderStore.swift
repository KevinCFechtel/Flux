import Foundation
import Observation
import UIKit
#if DEBUG
import OSLog
#endif

struct IOSFeedIconKey: Hashable {
    let feedID: Int64
    let variant: FeedIconVariant
}

@Observable final class IOSFeedIconPresentationState {
    var image: UIImage?
    var isUnavailable = false
}

enum IOSFeedIconPresentation {
    static func variant(isDark: Bool) -> FeedIconVariant { isDark ? .dark : .normal }
}

struct IOSNewsreaderReadRequest: Equatable {
    let session: UInt64
    let generation: UInt64
    let selectionCountGeneration: UInt64
    let errorGeneration: UInt64
}

struct IOSNewsreaderReadLifecycle {
    private(set) var session: UInt64 = 0
    private(set) var articleGeneration: UInt64 = 0
    private(set) var navigationGeneration: UInt64 = 0
    private(set) var selectionCountGeneration: UInt64 = 0
    private(set) var errorGeneration: UInt64 = 0

    mutating func invalidateSession() {
        session &+= 1
        articleGeneration &+= 1
        navigationGeneration &+= 1
        selectionCountGeneration &+= 1
        errorGeneration &+= 1
    }

    mutating func beginArticle() -> IOSNewsreaderReadRequest {
        articleGeneration &+= 1
        selectionCountGeneration &+= 1
        errorGeneration &+= 1
        return .init(session: session, generation: articleGeneration, selectionCountGeneration: selectionCountGeneration, errorGeneration: errorGeneration)
    }

    mutating func invalidateArticle() {
        articleGeneration &+= 1
        selectionCountGeneration &+= 1
        errorGeneration &+= 1
    }

    mutating func invalidateNavigation() {
        navigationGeneration &+= 1
        errorGeneration &+= 1
    }

    mutating func beginNavigation() -> IOSNewsreaderReadRequest {
        navigationGeneration &+= 1
        errorGeneration &+= 1
        return .init(session: session, generation: navigationGeneration, selectionCountGeneration: selectionCountGeneration, errorGeneration: errorGeneration)
    }

    mutating func beginSelectionCount() -> IOSNewsreaderReadRequest {
        selectionCountGeneration &+= 1
        errorGeneration &+= 1
        return .init(session: session, generation: selectionCountGeneration, selectionCountGeneration: selectionCountGeneration, errorGeneration: errorGeneration)
    }

    func isCurrentArticle(_ request: IOSNewsreaderReadRequest) -> Bool { request.session == session && request.generation == articleGeneration }
    func isCurrentNavigation(_ request: IOSNewsreaderReadRequest) -> Bool { request.session == session && request.generation == navigationGeneration }
    func isCurrentSelectionCount(_ request: IOSNewsreaderReadRequest) -> Bool { request.session == session && request.selectionCountGeneration == selectionCountGeneration }
    func ownsError(_ request: IOSNewsreaderReadRequest) -> Bool { request.errorGeneration == errorGeneration }
}

private struct NavigationReadResult {
    let catalog: NavigationCatalog
    let unreadTotal: UInt64
    let starredTotal: UInt64
    let categoryCounts: [Int64: UInt64]
    let feedCounts: [Int64: UInt64]
}

private struct ArticleReadResult {
    let articles: [ArticleSummary]
    let selectionTotal: UInt64
}

enum IOSSyncCountRefreshPolicy: Equatable {
    case none
    case allCounts
    case navigationAndAllCounts

    static func resolve(dataChanged: Bool, navigationChanged: Bool) -> Self {
        if navigationChanged { return .navigationAndAllCounts }
        return dataChanged ? .allCounts : .none
    }
}

enum IOSScrolloverPresentationPhase: Equatable {
    case interacting
    case decelerating
    case idle

    var isScrolling: Bool { self != .idle }
}

private struct IOSPendingScrolloverPresentation {
    let ids: [Int64]
    let generation: UInt64
    let completedAt: TimeInterval
}

struct ArticleRowContent: Equatable {
    let article: ArticleSummary
    let publishedDate: String
    let imageURL: URL?
    let hasComments: Bool

    init(article: ArticleSummary) {
        self.article = article
        publishedDate = ISO8601DateFormatter().date(from: article.publishedAt)
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? article.publishedAt
        imageURL = article.imageUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        hasComments = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) != nil
    }
}

@Observable final class ArticleRowPresentationState {
    private(set) var content: ArticleRowContent
    var isRead: Bool
    var isStarred: Bool
    private(set) var mutationRevision: UInt64 = 0

    init(article: ArticleSummary) {
        content = ArticleRowContent(article: article)
        isRead = article.isRead
        isStarred = article.isStarred
    }

    func setRead(_ value: Bool) {
        guard isRead != value else { return }
        isRead = value
        mutationRevision &+= 1
    }

    func setStarred(_ value: Bool) {
        guard isStarred != value else { return }
        isStarred = value
        mutationRevision &+= 1
    }

    func reconcile(with article: ArticleSummary) {
        if content.article != article { content = ArticleRowContent(article: article) }
        setRead(article.isRead)
        setStarred(article.isStarred)
    }
}

@MainActor
@Observable final class NewsreaderStore {
#if DEBUG
    private static let scrolloverDiagnosticLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews", category: "scrollover-diagnostic")
#endif
    private enum Key {
        static let startupScope = "FluxNews.iOS.startupScope"
        static let startupCategoryID = "FluxNews.iOS.startupCategoryID"
        static let startupFeedID = "FluxNews.iOS.startupFeedID"
        static let hideEmpty = "FluxNews.iOS.hideEmptyNavigationEntries"
        static let removeWhenRead = "FluxNews.iOS.removeArticlesWhenMarkedRead"
        static let scrollover = "FluxNews.iOS.markReadOnScrollover"
        static let presentationMode = "FluxNews.iOS.articlePresentationMode"
        static let previewLines = "FluxNews.iOS.articlePreviewLines"
        static let showArticleCount = "FluxNews.iOS.showArticleCount"
        static let clickOnNews = "FluxNews.clickOnNews"
    }

    private(set) var articles: [ArticleSummary] = []
    @ObservationIgnored private var rowPresentationStates: [Int64: ArticleRowPresentationState] = [:]
    private(set) var catalog = NavigationCatalog(categories: [], feeds: [])
    private(set) var unreadTotal: UInt64 = 0
    private(set) var starredTotal: UInt64 = 0
    private(set) var selectionTotal: UInt64 = 0
    private(set) var categoryCounts: [Int64: UInt64] = [:]
    private(set) var feedCounts: [Int64: UInt64] = [:]
    @ObservationIgnored private var feedIconPresentationStates: [IOSFeedIconKey: IOSFeedIconPresentationState] = [:]
    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var errorMessage: String?
    private(set) var pendingNewByFeed: [Int64: Int] = [:]
    private(set) var hasPendingNewData = false
    private(set) var hasUnscopedNewDataSignal = false
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var scrollResetRevision: UInt64 = 0
    var scope: BrowserScope = .all
    var unreadOnly = true
    var newestFirst = false
    var startupScope: StartupScopePreference
    var startupCategoryID: Int64?
    var startupFeedID: Int64?
    var hideEmptyNavigationEntries: Bool
    var removeArticlesWhenMarkedRead: Bool
    var markReadOnScrolloverEnabled: Bool
    var articlePresentationMode: ArticlePresentationMode
    var articlePreviewLines: ArticlePreviewLines
    var showArticleCount: Bool
    var clickOnNews: ClickOnNews
    private(set) var scrolloverUndoIDs: [Int64] = []
    // The tracker only needs to re-arm when an existing Undo group is cleared.
    private(set) var scrolloverRearmRevision: UInt64 = 0
    var scrolloverUndoVisible: Bool { scrolloverUndoIDs.count >= 2 }

    private(set) var core: Flux?
    private var eventSubscription: EventSubscription?
    private let defaults: UserDefaults
    private var pending = PendingNewData()
    private var requestedFeedIcons = Set<IOSFeedIconKey>()
    private var scrolloverUndoTask: Task<Void, Never>?
    private var scrolloverUndoOpenedAt: TimeInterval?
    private var scrolloverUndoLastSuccessAt: TimeInterval?
    private var recentSuccessfulScrolloverReads: [(id: Int64, time: TimeInterval)] = []
    private var scrolloverCountsPending = false
    private var pendingScrolloverIDs: [Int64] = []
    private var pendingScrolloverIDSet = Set<Int64>()
    @ObservationIgnored private var pendingScrolloverPresentationRevisions: [Int64: UInt64] = [:]
    private var scrolloverMutationRunning = false
    private var runningScrolloverIDs = Set<Int64>()
    private var scrolloverMutationTask: Task<Void, Never>?
    private var scrolloverQueueGeneration: UInt64 = 0
    private var scrolloverPresentationPhase: IOSScrolloverPresentationPhase = .idle
    private var pendingScrolloverPresentation: [IOSPendingScrolloverPresentation] = []
    private var hasMeaningfullyInteracted = false
    private var readerRequests = ReaderRequestState()
    private var readLifecycle = IOSNewsreaderReadLifecycle()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startupScope = defaults.string(forKey: Key.startupScope).flatMap(StartupScopePreference.init(rawValue:)) ?? .allNews
        startupCategoryID = defaults.object(forKey: Key.startupCategoryID) as? Int64
        startupFeedID = defaults.object(forKey: Key.startupFeedID) as? Int64
        hideEmptyNavigationEntries = defaults.object(forKey: Key.hideEmpty) as? Bool ?? false
        removeArticlesWhenMarkedRead = defaults.object(forKey: Key.removeWhenRead) as? Bool ?? false
        markReadOnScrolloverEnabled = defaults.object(forKey: Key.scrollover) as? Bool ?? true
        articlePresentationMode = defaults.string(forKey: Key.presentationMode).flatMap(ArticlePresentationMode.init(rawValue:)) ?? .visual
        articlePreviewLines = ArticlePreviewLines(rawValue: defaults.object(forKey: Key.previewLines) as? Int ?? 3) ?? .standard
        showArticleCount = defaults.object(forKey: Key.showArticleCount) as? Bool ?? true
        clickOnNews = defaults.string(forKey: Key.clickOnNews).flatMap(ClickOnNews.init(rawValue:)) ?? .openLink
    }

    func attach(to configuredCore: Flux) {
        detach()
        core = configuredCore
        do {
            eventSubscription = try configuredCore.subscribeEvents(listener: IOSNewsreaderEventListener(store: self))
        } catch {
            errorMessage = IOSErrorPresentation.message(for: error, context: .contentLoad)
        }
        let session = readLifecycle.session
        loadNavigationAndCounts { [weak self] in
            guard let self, self.readLifecycle.session == session else { return }
            let categoryIDs = Set(self.catalog.categories.map(\.id))
            let feedIDs = Set(self.catalog.feeds.map(\.id))
            self.scope = StartupScopeResolver.resolve(self.startupScope, categoryID: self.startupCategoryID, feedID: self.startupFeedID, categoryIDs: categoryIDs, feedIDs: feedIDs)
            self.normalizeStartupScope(categoryIDs: categoryIDs, feedIDs: feedIDs)
            self.loadVisibleArticles()
        }
    }

    func detach() {
        flushScrolloverPersistenceForLifecycle()
        readLifecycle.invalidateSession()
        eventSubscription = nil
        core = nil
        replaceArticles([])
        catalog = NavigationCatalog(categories: [], feeds: [])
        unreadTotal = 0
        starredTotal = 0
        selectionTotal = 0
        categoryCounts = [:]
        feedCounts = [:]
        feedIconPresentationStates = [:]
        isLoading = false
        isSyncing = false
        resetPresentationState()
    }

    func query(scope requestedScope: BrowserScope? = nil) -> ArticleQuery {
        let selected = requestedScope ?? scope
        let coreScope: ArticleScope = switch selected {
        case .all, .starred: .all
        case let .category(id): .category(id: id)
        case let .feed(id): .feed(id: id)
        case .search, .listeningList: .all
        }
        return ArticleQuery(scope: coreScope, readFilter: selected == .starred ? .all : (unreadOnly ? .unread : .all), starredFilter: selected == .starred ? .starred : .all, sort: newestFirst ? .newestFirst : .oldestFirst, limit: 0, cursor: nil)
    }

    nonisolated private static func navigationQuery(scope: ArticleScope, unreadOnly: Bool, newestFirst: Bool) -> ArticleQuery {
        ArticleQuery(scope: scope, readFilter: unreadOnly ? .unread : .all, starredFilter: .all, sort: newestFirst ? .newestFirst : .oldestFirst, limit: 0, cursor: nil)
    }

    func loadNavigationAndCounts(afterCompletion: (() -> Void)? = nil) {
        guard let core else { return }
        let request = readLifecycle.beginNavigation()
        let categoryQueryInputs = (unreadOnly, newestFirst)
        Task { [weak self, core] in
            let result = await Task.detached {
                Result {
                    let catalog = try core.navigationCatalog()
                    let unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
                    let starredTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
                    let categoryCounts = try catalog.categories.reduce(into: [:]) { counts, category in
                        counts[category.id] = try core.countArticles(query: Self.navigationQuery(scope: .category(id: category.id), unreadOnly: categoryQueryInputs.0, newestFirst: categoryQueryInputs.1))
                    }
                    let feedCounts = try catalog.feeds.reduce(into: [:]) { counts, feed in
                        counts[feed.id] = try core.countArticles(query: Self.navigationQuery(scope: .feed(id: feed.id), unreadOnly: categoryQueryInputs.0, newestFirst: categoryQueryInputs.1))
                    }
                    return NavigationReadResult(catalog: catalog, unreadTotal: unreadTotal, starredTotal: starredTotal, categoryCounts: categoryCounts, feedCounts: feedCounts)
                }
            }.value
            guard let self, self.readLifecycle.isCurrentNavigation(request) else { return }
            switch result {
            case let .success(value):
                catalog = value.catalog
                unreadTotal = value.unreadTotal
                starredTotal = value.starredTotal
                categoryCounts = value.categoryCounts
                feedCounts = value.feedCounts
                pending.removeAbsentFeeds(Set(value.catalog.feeds.map(\.id)))
                publishPending()
                if readLifecycle.ownsError(request) { errorMessage = nil }
            case let .failure(error):
                if readLifecycle.ownsError(request) { errorMessage = IOSErrorPresentation.message(for: error, context: .contentLoad) }
            }
            afterCompletion?()
        }
    }

    func loadVisibleArticles(acknowledgePending: Bool = false, resetSnapshot: Bool = false, completion: (() -> Void)? = nil) {
        guard let core else { return }
        let request = readLifecycle.beginArticle()
        let articleQuery = query()
        isLoading = true
        errorMessage = nil
        Task { [weak self, core] in
            let result = await Task.detached {
                Result {
                    ArticleReadResult(articles: try core.queryArticles(query: articleQuery), selectionTotal: try core.countArticles(query: articleQuery))
                }
            }.value
            guard let self, self.readLifecycle.isCurrentArticle(request), self.readLifecycle.isCurrentSelectionCount(request) else { return }
            switch result {
            case let .success(value):
                replaceArticles(value.articles)
                selectionTotal = value.selectionTotal
                if acknowledgePending { acknowledgePendingForCurrentScope() }
                if resetSnapshot { snapshotRevision &+= 1 }
                if readLifecycle.ownsError(request) { errorMessage = nil }
            case let .failure(error):
                if readLifecycle.ownsError(request) { errorMessage = IOSErrorPresentation.message(for: error, context: .contentLoad) }
            }
            isLoading = false
            if case .success = result { completion?() }
        }
    }

    func feedIconPresentationState(for feedID: Int64, variant: FeedIconVariant) -> IOSFeedIconPresentationState {
        let key = IOSFeedIconKey(feedID: feedID, variant: variant)
        if let state = feedIconPresentationStates[key] { return state }
        let state = IOSFeedIconPresentationState()
        feedIconPresentationStates[key] = state
        return state
    }

    func requestFeedIcon(_ feedID: Int64, variant: FeedIconVariant) {
        let key = IOSFeedIconKey(feedID: feedID, variant: variant)
        let state = feedIconPresentationState(for: feedID, variant: variant)
        guard state.image == nil, !state.isUnavailable, let core else { return }
        guard requestedFeedIcons.insert(key).inserted else { return }
        Task { [weak self, core] in
            let image: UIImage? = await Task.detached { () -> UIImage? in
                guard let data = try? core.feedIcon(feedId: feedID, variant: variant)?.pngData else { return nil }
                return UIImage(data: Data(data))
            }.value
            guard let self else { return }
            requestedFeedIcons.remove(key)
            guard let state = feedIconPresentationStates[key] else { return }
            if let image { state.image = image }
            else { state.isUnavailable = true }
        }
    }

    func syncManually() async {
        guard let core, !isSyncing else { return }
        isSyncing = true
        errorMessage = nil

        let result = await Task.detached { Result { try core.sync(reason: .manual) } }.value
        switch result {
        case let .success(metadata):
            handleSyncCompleted(metadata)
        case let .failure(error):
            errorMessage = IOSErrorPresentation.message(for: error, context: .sync)
            isSyncing = false
        }
    }

    func select(_ newScope: BrowserScope) {
        markMeaningfulInteraction()
        scope = newScope
        loadVisibleArticles(acknowledgePending: true, resetSnapshot: true)
        requestScrollReset()
    }

    func setUnreadOnly(_ value: Bool) {
        guard unreadOnly != value else { return }
        unreadOnly = value
        readLifecycle.invalidateNavigation()
        resetPresentationState()
        loadVisibleArticles(resetSnapshot: true)
        requestScrollReset()
    }
    func setNewestFirst(_ value: Bool) {
        guard newestFirst != value else { return }
        newestFirst = value
        resetPresentationState()
        loadVisibleArticles(resetSnapshot: true)
        requestScrollReset()
    }
    func setStartupScope(_ value: StartupScopePreference) { startupScope = value; defaults.set(value.rawValue, forKey: Key.startupScope) }
    func setStartupCategoryID(_ value: Int64?) { startupCategoryID = value; defaults.set(value, forKey: Key.startupCategoryID) }
    func setStartupFeedID(_ value: Int64?) { startupFeedID = value; defaults.set(value, forKey: Key.startupFeedID) }
    func setHideEmptyNavigationEntries(_ value: Bool) { hideEmptyNavigationEntries = value; defaults.set(value, forKey: Key.hideEmpty) }
    func setRemoveArticlesWhenMarkedRead(_ value: Bool) { removeArticlesWhenMarkedRead = value; defaults.set(value, forKey: Key.removeWhenRead) }
    func setMarkReadOnScrolloverEnabled(_ value: Bool) { markReadOnScrolloverEnabled = value; defaults.set(value, forKey: Key.scrollover) }
    func setArticlePresentationMode(_ value: ArticlePresentationMode) { articlePresentationMode = value; defaults.set(value.rawValue, forKey: Key.presentationMode); resetPresentationState() }
    func setArticlePreviewLines(_ value: ArticlePreviewLines) { articlePreviewLines = value; defaults.set(value.rawValue, forKey: Key.previewLines); resetPresentationState() }
    func setShowArticleCount(_ value: Bool) { showArticleCount = value; defaults.set(value, forKey: Key.showArticleCount) }
    func setClickOnNews(_ value: ClickOnNews) { clickOnNews = value; defaults.set(value.rawValue, forKey: Key.clickOnNews) }

    func setRead(_ article: ArticleSummary, read: Bool) { setRead(articleIDs: [article.id], read: read) }
    func setStarred(_ article: ArticleSummary, starred: Bool) { setStarred(articleIDs: [article.id], starred: starred) }

    func markCurrentScopeAsRead(completion: @escaping (Bool) -> Void = { _ in }) {
        guard case .all = scope else {
            guard case .category = scope else {
                guard case .feed = scope else { return }
                markCurrentScopeArticlesRead(completion: completion)
                return
            }
            markCurrentScopeArticlesRead(completion: completion)
            return
        }
        markCurrentScopeArticlesRead(completion: completion)
    }

    // Read-on-open stays on the existing Core mutation path; only the original URL is returned.
    func open(_ article: ArticleSummary, completion: @escaping (String) -> Void) {
        setRead(article, read: true)
        completion(article.url)
    }

    func openReader(_ article: ArticleSummary, completion: @escaping (Result<ReaderDocument, Error>) -> Void) {
        setRead(article, read: true)
        loadReaderDocument(articleID: article.id, completion: completion)
    }

    func loadReaderDocument(articleID: Int64, completion: @escaping (Result<ReaderDocument, Error>) -> Void) {
        let request = readerRequests.begin()
        guard let core else {
            completion(.failure(IOSCoreError.notConfigured))
            return
        }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.readerDocument(articleId: articleID) } }.value
            guard let self, self.readerRequests.isCurrent(request) else { return }
            completion(result)
        }
    }

    func minifluxEntryURL(for article: ArticleSummary, completion: @escaping (Result<String, Error>) -> Void) {
        guard let core else {
            completion(.failure(IOSCoreError.notConfigured))
            return
        }
        completion(.success(core.minifluxEntryUrl(articleId: article.id)))
    }

    func saveToService(_ article: ArticleSummary, completion: @escaping (Result<SaveToServiceResult, Error>) -> Void) {
        guard let core else {
            completion(.failure(IOSCoreError.notConfigured))
            return
        }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.saveToService(articleId: article.id) } }.value
            guard self != nil else { return }
            completion(result)
        }
    }

    func discoverSubscriptions(_ request: DiscoverSubscriptionsRequest, completion: @escaping (Result<[DiscoveredSubscription], Error>) -> Void) {
        guard let core else { completion(.failure(unconfiguredError)); return }
        Task { let result = await Task.detached { Result { try core.discoverSubscriptions(request: request) } }.value; completion(result) }
    }

    func createFeed(_ request: CreateFeedRequest, completion: @escaping (Result<CreateFeedResult, Error>) -> Void) {
        guard let core else { completion(.failure(unconfiguredError)); return }
        Task { [weak self] in
            let result = await Task.detached { Result { try core.createFeed(request: request) } }.value
            if case .success = result { self?.loadNavigationAndCounts() }
            completion(result)
        }
    }

    func createCategory(_ title: String, completion: @escaping (Result<CreateCategoryResult, Error>) -> Void) {
        guard let core else { completion(.failure(unconfiguredError)); return }
        Task { [weak self] in
            let result = await Task.detached { Result { try core.createCategory(title: title) } }.value
            if case .success = result { self?.loadNavigationAndCounts() }
            completion(result)
        }
    }

    func loadFeedPreferences(feedID: Int64, completion: @escaping (Result<FeedPreferences, Error>) -> Void) {
        guard let core else { completion(.failure(unconfiguredError)); return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.feedPreferences(feedId: feedID) } }.value
            guard self?.core === core else { return }
            completion(result)
        }
    }

    func setFeedDetailRendering(feedID: Int64, mode: DetailRenderingMode, completion: @escaping (Result<Void, Error>) -> Void) {
        updateFeedPreferences(feedID: feedID, change: { try $0.setFeedDetailRendering(feedId: feedID, mode: mode) }, completion: completion)
    }

    func setFeedTruncateDetail(feedID: Int64, enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        updateFeedPreferences(feedID: feedID, change: { try $0.setFeedTruncateDetail(feedId: feedID, enabled: enabled) }, completion: completion)
    }

    func setFeedOpenInMiniflux(feedID: Int64, enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        updateFeedPreferences(feedID: feedID, change: { try $0.setFeedOpenInMiniflux(feedId: feedID, enabled: enabled) }, completion: completion)
    }

    private func updateFeedPreferences(feedID: Int64, change: @escaping @Sendable (Flux) throws -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let core else { completion(.failure(unconfiguredError)); return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try change(core) } }.value
            guard self?.core === core else { return }
            completion(result)
        }
    }

    func setRead(articleIDs: [Int64], read: Bool) {
        guard let core, !articleIDs.isEmpty else { return }
        let conflictingScrolloverMutation = !runningScrolloverIDs.isDisjoint(with: articleIDs) ? scrolloverMutationTask : nil
        flushConflictingScrolloverIDs(articleIDs)
        let revisions = optimisticallySetRead(articleIDs, read: read)
        let snapshotRevision = snapshotRevision
        Task { [weak self, core] in
            if let conflictingScrolloverMutation {
                await conflictingScrolloverMutation.value
            }
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: articleIDs, read: read) } }.value
            guard let self else { return }
            switch result {
            case .success:
                markMeaningfulInteraction()
                if snapshotRevision == self.snapshotRevision && read && ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope) {
                    removeVisibleArticles(articleIDs)
                }
                reloadCounts(includeNavigationCounts: true)
            case let .failure(error):
                restoreReadPresentation(articleIDs, revisions: revisions, snapshotRevision: snapshotRevision)
                errorMessage = IOSErrorPresentation.message(for: error, context: .articleAction)
            }
        }
    }

    func setStarred(articleIDs: [Int64], starred: Bool) {
        guard let core, !articleIDs.isEmpty else { return }
        let revisions = optimisticallySetStarred(articleIDs, starred: starred)
        let snapshotRevision = snapshotRevision
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setStarredStateBulk(articleIds: articleIDs, starred: starred) } }.value
            guard let self else { return }
            switch result {
            case .success:
                markMeaningfulInteraction()
                if snapshotRevision == self.snapshotRevision && !starred && scope == .starred { removeVisibleArticles(articleIDs) }
                reloadCounts(includeNavigationCounts: true)
            case let .failure(error):
                restoreStarredPresentation(articleIDs, revisions: revisions, snapshotRevision: snapshotRevision)
                errorMessage = IOSErrorPresentation.message(for: error, context: .articleAction)
            }
        }
    }

    func flushScrollover(_ batch: IOSScrolloverBatch) {
        guard core != nil else { return }
        let ids = eligibleScrolloverIDs(batch.articleIDs)
        guard !ids.isEmpty else { return }
        scrolloverDiagnostic("detected count=\(ids.count)")
        for id in ids {
            if let state = rowPresentationStates[id] {
                state.setRead(true)
                pendingScrolloverPresentationRevisions[id] = state.mutationRevision
            }
            pendingScrolloverIDSet.insert(id)
            pendingScrolloverIDs.append(id)
        }
        scrolloverDiagnostic("optimistic presentation count=\(ids.count)")
        if pendingScrolloverIDs.count >= Self.maximumScrolloverMutationBatchSize {
            drainScrolloverMutations()
        }
    }

    func setScrolloverPresentationPhase(_ phase: IOSScrolloverPresentationPhase) {
        scrolloverPresentationPhase = phase
        if phase == .idle {
            drainScrolloverMutations()
            flushPendingScrolloverPresentation()
            reloadScrolloverCountsIfReady()
        }
    }

    func flushScrolloverPersistenceForLifecycle() {
        drainScrolloverMutations()
    }

    private func drainScrolloverMutations() {
        guard !scrolloverMutationRunning, let core, !pendingScrolloverIDs.isEmpty else { return }
        let ids = pendingScrolloverIDs
        pendingScrolloverIDs = []
        scrolloverMutationRunning = true
        runningScrolloverIDs = Set(ids)
        let generation = scrolloverQueueGeneration
        scrolloverDiagnostic("persistence flush count=\(ids.count)")
        let task = Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: true) } }.value
            guard let self else { return }
            switch result {
            case .success:
                completeSuccessfulScrolloverMutation(ids, generation: generation)
                scrolloverDiagnostic("persistence success count=\(ids.count)")
            case let .failure(error):
                restoreScrolloverPresentation(ids, generation: generation)
                if generation == scrolloverQueueGeneration {
                    errorMessage = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
                scrolloverDiagnosticError(ids: ids, error: error)
            }
            pendingScrolloverIDSet.subtract(ids)
            for id in ids { pendingScrolloverPresentationRevisions[id] = nil }
            scrolloverMutationRunning = false
            runningScrolloverIDs = []
            scrolloverMutationTask = nil
            reloadScrolloverCountsIfReady()
            drainScrolloverMutations()
        }
        scrolloverMutationTask = task
    }

    private func completeSuccessfulScrolloverMutation(
        _ ids: [Int64],
        generation: UInt64,
        completedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        // A new structural snapshot owns its presentation state; stale Core
        // completions remain persisted but cannot publish into that snapshot.
        guard generation == scrolloverQueueGeneration else { return }
        scrolloverCountsPending = true
        let result = IOSPendingScrolloverPresentation(ids: ids, generation: generation, completedAt: completedAt)
        if scrolloverPresentationPhase.isScrolling {
            pendingScrolloverPresentation.append(result)
        } else {
            publishSuccessfulScrolloverMutation(result)
        }
    }

    private func flushPendingScrolloverPresentation() {
        let pending = pendingScrolloverPresentation
        pendingScrolloverPresentation = []
        for result in pending where result.generation == scrolloverQueueGeneration {
            publishSuccessfulScrolloverMutation(result)
        }
    }

    private func publishSuccessfulScrolloverMutation(_ result: IOSPendingScrolloverPresentation) {
        recordSuccessfulScrolloverUndo(result.ids, now: result.completedAt)
    }

    private func reloadScrolloverCountsIfReady() {
        guard scrolloverPresentationPhase == .idle,
              !scrolloverMutationRunning,
              pendingScrolloverIDs.isEmpty,
              scrolloverCountsPending else { return }
        scrolloverCountsPending = false
        reloadCounts(includeNavigationCounts: true)
    }

    private func recordSuccessfulScrolloverUndo(_ ids: [Int64], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !ids.isEmpty else { return }
        if scrolloverUndoOpenedAt != nil {
            appendSuccessfulScrolloverUndo(ids, now: now)
            return
        }
        recentSuccessfulScrolloverReads.append(contentsOf: ids.map { (id: $0, time: now) })
        recentSuccessfulScrolloverReads.removeAll { now - $0.time > Self.scrolloverUndoQualificationWindow }
        guard recentSuccessfulScrolloverReads.count >= Self.minimumSuccessfulScrolloverReadsForUndo else { return }
        let burstIDs = recentSuccessfulScrolloverReads.map(\.id)
        recentSuccessfulScrolloverReads.removeAll()
        scrolloverUndoOpenedAt = now
        appendSuccessfulScrolloverUndo(burstIDs, now: now)
    }

    private func appendSuccessfulScrolloverUndo(_ ids: [Int64], now: TimeInterval) {
        let groupExpired: Bool
        if let openedAt = scrolloverUndoOpenedAt, let lastSuccessAt = scrolloverUndoLastSuccessAt {
            groupExpired = now - lastSuccessAt >= Self.scrolloverUndoInactivityTimeout || now - openedAt >= Self.scrolloverUndoMaximumLifetime
        } else {
            groupExpired = scrolloverUndoOpenedAt != nil || scrolloverUndoLastSuccessAt != nil
        }
        if scrolloverUndoOpenedAt == nil || groupExpired {
            // A replacement group never presented an empty array to the tracker.
            clearScrolloverUndoGroup(rearmTracker: false, clearQualification: false)
            scrolloverUndoOpenedAt = now
        }
        var seen = Set(scrolloverUndoIDs)
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        markMeaningfulInteraction()
        scrolloverUndoIDs.append(contentsOf: unique)
        scrolloverCountsPending = true
        scrolloverUndoLastSuccessAt = now
        scheduleScrolloverUndoExpiry()
    }

    private static let scrolloverUndoInactivityTimeout: TimeInterval = 4
    private static let scrolloverUndoMaximumLifetime: TimeInterval = 15
    private static let scrolloverUndoQualificationWindow: TimeInterval = 1
    private static let minimumSuccessfulScrolloverReadsForUndo = 3

    private func scheduleScrolloverUndoExpiry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let openedAt = scrolloverUndoOpenedAt, let lastSuccessAt = scrolloverUndoLastSuccessAt else { return }
        scrolloverUndoTask?.cancel()
        scrolloverUndoTask = Task { [weak self] in
            let delay = min(
                Self.scrolloverUndoInactivityTimeout - (now - lastSuccessAt),
                Self.scrolloverUndoMaximumLifetime - (now - openedAt)
            )
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            self?.expireScrolloverUndoGroup()
        }
    }

    private func expireScrolloverUndoGroup(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let openedAt = scrolloverUndoOpenedAt, let lastSuccessAt = scrolloverUndoLastSuccessAt else { return }
        if now - openedAt >= Self.scrolloverUndoMaximumLifetime || now - lastSuccessAt >= Self.scrolloverUndoInactivityTimeout {
            clearScrolloverUndoGroup()
        } else {
            scheduleScrolloverUndoExpiry(now: now)
        }
    }

    private func clearScrolloverUndoGroup(rearmTracker: Bool = true, clearQualification: Bool = true) {
        if rearmTracker && !scrolloverUndoIDs.isEmpty { scrolloverRearmRevision &+= 1 }
        scrolloverUndoTask?.cancel()
        scrolloverUndoTask = nil
        scrolloverUndoIDs = []
        scrolloverUndoOpenedAt = nil
        scrolloverUndoLastSuccessAt = nil
        if clearQualification { recentSuccessfulScrolloverReads.removeAll() }
    }

    func undoScrollover() {
        guard let core, !scrolloverUndoIDs.isEmpty else { return }
        let ids = scrolloverUndoIDs
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: false) } }.value
            guard let self else { return }
            switch result {
            case .success:
                updateVisibleRead(ids, read: false)
                clearScrolloverUndoGroup(); reloadCounts(includeNavigationCounts: true)
            case let .failure(error): errorMessage = IOSErrorPresentation.message(for: error, context: .articleAction)
            }
        }
    }

    func accumulateNewData(_ additions: [(feedID: Int64, count: UInt32)]) { pending.accumulate(additions); publishPending() }
    func adoptVisibleSnapshot() { acknowledgePendingForCurrentScope(); hasUnscopedNewDataSignal = false; resetPresentationState(); replaceSnapshot(shouldResetScroll: true) }
    func resetVisibleSnapshot() { replaceArticles([]); selectionTotal = 0; resetPresentationState() }

    private func acknowledgePendingForCurrentScope() {
        switch scope {
        case .all, .starred: pending.adoptAll()
        case let .category(id): pending.adoptFeeds(in: Set(catalog.feeds.filter { $0.categoryId == id }.map(\.id)))
        case let .feed(id): pending.adoptFeed(id)
        case .search, .listeningList: break
        }
        publishPending()
    }
    private func publishPending() { pendingNewByFeed = pending.byFeed; hasPendingNewData = pending.hasPending }

    private func normalizeStartupScope(categoryIDs: Set<Int64>, feedIDs: Set<Int64>) {
        if startupScope == .category && (startupCategoryID == nil || !categoryIDs.contains(startupCategoryID!)) {
            setStartupCategoryID(nil)
            setStartupScope(.allNews)
        } else if startupScope == .feed && (startupFeedID == nil || !feedIDs.contains(startupFeedID!)) {
            setStartupFeedID(nil)
            setStartupScope(.allNews)
        }
    }

    func markMeaningfulInteraction() { hasMeaningfullyInteracted = true }

    private func resetPresentationState(preserveLoading: Bool = false) {
        // Do not discard local-first reads accepted during a moving snapshot.
        drainScrolloverMutations()
        readLifecycle.invalidateArticle()
        if !preserveLoading { isLoading = false }
        hasMeaningfullyInteracted = false
        snapshotRevision &+= 1
        // The structural snapshot change independently clears tracker emissions.
        clearScrolloverUndoGroup(rearmTracker: false)
        scrolloverCountsPending = false
        pendingScrolloverIDs = []
        pendingScrolloverIDSet = []
        pendingScrolloverPresentationRevisions = [:]
        pendingScrolloverPresentation = []
        for article in articles { rowPresentationStates[article.id]?.reconcile(with: article) }
        scrolloverPresentationPhase = .idle
        scrolloverQueueGeneration &+= 1
    }

    fileprivate func handleSyncCompleted(_ metadata: SyncCompleted) {
        if metadata.reason == .background || metadata.reason == .periodic {
            pending.accumulate(metadata.newArticlesByFeed.map { (feedID: $0.feedId, count: $0.count) })
            publishPending()
            if metadata.dataChanged && metadata.newArticlesByFeed.isEmpty { hasUnscopedNewDataSignal = true }
        }
        let action = SnapshotRefreshPolicy.action(manual: metadata.reason == .manual, dataChanged: metadata.dataChanged, hasMeaningfullyInteracted: hasMeaningfullyInteracted)
        if action == .replace { isLoading = true }
        isSyncing = false
        switch IOSSyncCountRefreshPolicy.resolve(dataChanged: metadata.dataChanged, navigationChanged: metadata.navigationChanged) {
        case .navigationAndAllCounts:
            loadNavigationAndCounts { [weak self] in self?.applySyncSnapshotRefresh(metadata, action: action) }
            return
        case .allCounts where action == .replace:
            applySyncSnapshotRefresh(metadata, action: action) { [weak self] in self?.reloadCounts(includeNavigationCounts: true) }
        case .allCounts:
            reloadCounts(includeNavigationCounts: true)
            applySyncSnapshotRefresh(metadata, action: action)
        case .none:
            applySyncSnapshotRefresh(metadata, action: action)
        }
    }

    private func applySyncSnapshotRefresh(_ metadata: SyncCompleted, action: SnapshotRefreshPolicy.Action, afterSnapshot: (() -> Void)? = nil) {
        switch action {
        case .replace:
            hasUnscopedNewDataSignal = false
            if metadata.reason == .manual { acknowledgePendingForCurrentScope() }
            replaceSnapshot(shouldResetScroll: metadata.reason == .manual, afterLoad: afterSnapshot)
        case .signalNewData:
            if metadata.newArticlesByFeed.isEmpty { hasUnscopedNewDataSignal = true }
            afterSnapshot?()
        case .preserve:
            afterSnapshot?()
        }
    }

    private func replaceSnapshot(shouldResetScroll: Bool = false, afterLoad: (() -> Void)? = nil) {
        resetPresentationState(preserveLoading: true)
        loadVisibleArticles(resetSnapshot: true, completion: afterLoad)
        if shouldResetScroll { requestScrollReset() }
    }

    private func updateVisibleRead(_ ids: [Int64], read: Bool, removeFromVisibleList: Bool = true) {
        let removesReadArticles = ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope)
        if read && removeFromVisibleList && removesReadArticles {
            _ = optimisticallySetRead(ids, read: true)
            removeVisibleArticles(ids)
        } else { _ = optimisticallySetRead(ids, read: read) }
    }

    private func eligibleScrolloverIDs(_ ids: [Int64]) -> [Int64] {
        ids.filter { id in
            !pendingScrolloverIDSet.contains(id) && rowPresentationStates[id]?.isRead == false
        }
    }

    private static let maximumScrolloverMutationBatchSize = 64

    private func flushConflictingScrolloverIDs(_ ids: [Int64]) {
        let conflicts = Set(ids)
        pendingScrolloverIDs.removeAll { conflicts.contains($0) }
        pendingScrolloverIDSet.subtract(conflicts)
        for id in conflicts where !runningScrolloverIDs.contains(id) {
            pendingScrolloverPresentationRevisions[id] = nil
        }
    }

    private func replaceArticles(_ value: [ArticleSummary]) {
        articles = value
        let currentIDs = Set(value.map(\.id))
        rowPresentationStates = rowPresentationStates.filter { currentIDs.contains($0.key) }
        for article in value {
            if let state = rowPresentationStates[article.id] {
                state.reconcile(with: article)
            } else {
                rowPresentationStates[article.id] = ArticleRowPresentationState(article: article)
            }
        }
    }

    func rowPresentationState(for article: ArticleSummary) -> ArticleRowPresentationState {
        if let state = rowPresentationStates[article.id] { return state }
        let state = ArticleRowPresentationState(article: article)
        rowPresentationStates[article.id] = state
        return state
    }

    private func optimisticallySetRead(_ ids: [Int64], read: Bool) -> [Int64: UInt64] {
        var revisions: [Int64: UInt64] = [:]
        for id in ids where rowPresentationStates[id] != nil {
            rowPresentationStates[id]?.setRead(read)
            revisions[id] = rowPresentationStates[id]?.mutationRevision
        }
        return revisions
    }

    private func optimisticallySetStarred(_ ids: [Int64], starred: Bool) -> [Int64: UInt64] {
        var revisions: [Int64: UInt64] = [:]
        for id in ids where rowPresentationStates[id] != nil {
            rowPresentationStates[id]?.setStarred(starred)
            revisions[id] = rowPresentationStates[id]?.mutationRevision
        }
        return revisions
    }

    private func restoreReadPresentation(_ ids: [Int64], revisions: [Int64: UInt64], snapshotRevision: UInt64) {
        guard self.snapshotRevision == snapshotRevision else { return }
        for id in ids where rowPresentationStates[id]?.mutationRevision == revisions[id] {
            if let article = articles.first(where: { $0.id == id }) { rowPresentationStates[id]?.setRead(article.isRead) }
        }
    }

    private func restoreStarredPresentation(_ ids: [Int64], revisions: [Int64: UInt64], snapshotRevision: UInt64) {
        guard self.snapshotRevision == snapshotRevision else { return }
        for id in ids where rowPresentationStates[id]?.mutationRevision == revisions[id] {
            if let article = articles.first(where: { $0.id == id }) { rowPresentationStates[id]?.setStarred(article.isStarred) }
        }
    }

    private func restoreScrolloverPresentation(_ ids: [Int64], generation: UInt64) {
        guard generation == scrolloverQueueGeneration else { return }
        for id in ids where rowPresentationStates[id]?.mutationRevision == pendingScrolloverPresentationRevisions[id] {
            if let article = articles.first(where: { $0.id == id }) { rowPresentationStates[id]?.setRead(article.isRead) }
        }
    }

    private func removeVisibleArticles(_ ids: [Int64]) {
        let ids = Set(ids)
        guard articles.contains(where: { ids.contains($0.id) }) else { return }
        replaceArticles(articles.filter { !ids.contains($0.id) })
        snapshotRevision &+= 1
    }

    private var unconfiguredError: IOSCoreError { .notConfigured }

    private func markCurrentScopeArticlesRead(completion: @escaping (Bool) -> Void) {
        guard let core else { completion(false); return }
        let scope = scope
        let query = ArticleQuery(scope: query(scope: scope).scope, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil)
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.queryArticles(query: query).map(\.id) } }.value
            guard let self else { return }
            switch result {
            case let .success(ids):
                guard !ids.isEmpty else { completion(true); return }
                let mutation = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: true) } }.value
                switch mutation {
                case .success:
                    self.markMeaningfulInteraction()
                    self.loadNavigationAndCounts { [weak self] in
                        self?.loadVisibleArticles(resetSnapshot: true)
                        self?.requestScrollReset()
                    }
                    completion(true)
                case let .failure(error): self.errorMessage = IOSErrorPresentation.message(for: error, context: .articleAction)
                    completion(false)
                }
            case let .failure(error):
                self.errorMessage = IOSErrorPresentation.message(for: error, context: .contentLoad)
                completion(false)
            }
        }
    }

    private func scrolloverDiagnostic(_ message: String) {
#if DEBUG
        Self.scrolloverDiagnosticLog.debug("\(message, privacy: .public)")
#endif
    }

    private func scrolloverDiagnosticError(ids: [Int64], error: Error) {
#if DEBUG
        Self.scrolloverDiagnosticLog.debug("mutation failure ids=\(ids) error=\(String(reflecting: error), privacy: .private)")
#endif
    }

    // Narrow seam for deterministic iOS mutation-state tests without a live Core.
    @MainActor
    func setArticlesForTesting(_ value: [ArticleSummary]) { replaceArticles(value) }
    @MainActor
    func applyReadMutationForTesting(_ ids: [Int64], read: Bool) { markMeaningfulInteraction(); updateVisibleRead(ids, read: read) }
    @MainActor
    func applyScrolloverMutationForTesting(_ ids: [Int64], now: TimeInterval = 0) {
        let eligible = eligibleScrolloverIDs(ids)
        _ = optimisticallySetRead(eligible, read: true)
        completeSuccessfulScrolloverMutation(eligible, generation: scrolloverQueueGeneration, completedAt: now)
    }
    @MainActor
    func setScrolloverPresentationPhaseForTesting(_ phase: IOSScrolloverPresentationPhase) { setScrolloverPresentationPhase(phase) }
    @MainActor
    func completeSuccessfulScrolloverMutationForTesting(_ ids: [Int64], now: TimeInterval = 0) {
        completeSuccessfulScrolloverMutation(ids, generation: scrolloverQueueGeneration, completedAt: now)
    }
    @MainActor
    var pendingScrolloverPresentationIDsForTesting: [Int64] { pendingScrolloverPresentation.flatMap(\.ids) }
    @MainActor
    func rebaselineScrolloverPresentationForTesting() { resetPresentationState() }
    @MainActor
    func applyScrolloverUndoForTesting() { updateVisibleRead(scrolloverUndoIDs, read: false); clearScrolloverUndoGroup() }
    @MainActor
    var scrolloverUndoIDsForTesting: [Int64] { scrolloverUndoIDs }
    @MainActor
    func eligibleScrolloverIDsForTesting(_ ids: [Int64]) -> [Int64] { eligibleScrolloverIDs(ids) }
    @MainActor
    func enqueueScrolloverForTesting(_ ids: [Int64]) -> [Int64] {
        let eligible = eligibleScrolloverIDs(ids)
        for id in eligible {
            rowPresentationStates[id]?.setRead(true)
            pendingScrolloverPresentationRevisions[id] = rowPresentationStates[id]?.mutationRevision
        }
        pendingScrolloverIDSet.formUnion(eligible)
        pendingScrolloverIDs.append(contentsOf: eligible)
        return eligible
    }
    @MainActor
    func beginScrolloverMutationForTesting() -> [Int64] {
        let ids = pendingScrolloverIDs
        pendingScrolloverIDs = []
        return ids
    }
    @MainActor
    func flushScrolloverPersistenceForTesting() -> [Int64] {
        let ids = pendingScrolloverIDs
        pendingScrolloverIDs = []
        return ids
    }
    @MainActor
    func discardPendingScrolloverForTesting(_ ids: [Int64]) { flushConflictingScrolloverIDs(ids) }
    @MainActor
    func failScrolloverMutationForTesting(_ ids: [Int64], generation: UInt64? = nil) {
        restoreScrolloverPresentation(ids, generation: generation ?? scrolloverQueueGeneration)
        for id in ids {
            pendingScrolloverIDSet.remove(id)
            pendingScrolloverPresentationRevisions[id] = nil
        }
    }
    @MainActor
    func expireScrolloverUndoGroupForTesting(now: TimeInterval) { expireScrolloverUndoGroup(now: now) }
    @MainActor
    func applyStarredMutationForTesting(_ ids: [Int64], starred: Bool) {
        markMeaningfulInteraction()
        _ = optimisticallySetStarred(ids, starred: starred)
        if !starred && scope == .starred { removeVisibleArticles(ids) }
    }
    @MainActor
    func completeSyncForTesting(_ metadata: SyncCompleted) { handleSyncCompleted(metadata) }
    @MainActor
    func setSyncingForTesting(_ value: Bool) { isSyncing = value }
    @MainActor
    var meaningfullyInteractedForTesting: Bool { hasMeaningfullyInteracted }
    @MainActor
    var pendingByFeedForTesting: [Int64: Int] { pendingNewByFeed }
    @MainActor
    func normalizeStartupScopeForTesting(categoryIDs: Set<Int64>, feedIDs: Set<Int64>) { normalizeStartupScope(categoryIDs: categoryIDs, feedIDs: feedIDs) }
    @MainActor
    func setCatalogForTesting(_ value: NavigationCatalog) { catalog = value }
    @MainActor
    func setSelectionTotalForTesting(_ value: UInt64) { selectionTotal = value }
    @MainActor
    func rowPresentationStateForTesting(_ id: Int64) -> ArticleRowPresentationState? { rowPresentationStates[id] }
    @MainActor
    func isArticleReadForTesting(_ id: Int64) -> Bool? { rowPresentationStates[id]?.isRead }
    @MainActor
    func isArticleStarredForTesting(_ id: Int64) -> Bool? { rowPresentationStates[id]?.isStarred }

    private func reloadCounts(includeNavigationCounts: Bool = false) {
        guard let core else { return }
        let request = readLifecycle.beginSelectionCount()
        let selectionQuery = query()
        let categoryQueries = includeNavigationCounts ? catalog.categories.map { (id: $0.id, query: query(scope: .category($0.id))) } : []
        let feedQueries = includeNavigationCounts ? catalog.feeds.map { (id: $0.id, query: query(scope: .feed($0.id))) } : []
        Task { [weak self, core] in
            let result = await Task.detached {
                Result {
                    let selection = try core.countArticles(query: selectionQuery)
                    let unread = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
                    let starred = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
                    var categories: [Int64: UInt64] = [:]
                    var feeds: [Int64: UInt64] = [:]
                    for item in categoryQueries { categories[item.id] = try core.countArticles(query: item.query) }
                    for item in feedQueries { feeds[item.id] = try core.countArticles(query: item.query) }
                    return (selection, unread, starred, categories, feeds)
                }
            }.value
            guard let self, self.readLifecycle.isCurrentSelectionCount(request) else { return }
            switch result {
            case let .success(counts):
                selectionTotal = counts.0; unreadTotal = counts.1; starredTotal = counts.2
                if includeNavigationCounts { categoryCounts = counts.3; feedCounts = counts.4 }
            case let .failure(error):
                if readLifecycle.ownsError(request) { errorMessage = IOSErrorPresentation.message(for: error, context: .contentLoad) }
            }
        }
    }

    private func requestScrollReset() { scrollResetRevision &+= 1 }
}

private final class IOSNewsreaderEventListener: EventListener, @unchecked Sendable {
    weak var store: NewsreaderStore?

    init(store: NewsreaderStore) { self.store = store }

    func onEvent(event: CoreEvent) {
        Task { @MainActor [weak store] in
            guard let store else { return }
            if case let .syncCompleted(metadata) = event, metadata.reason != .manual { store.handleSyncCompleted(metadata) }
        }
    }
}
