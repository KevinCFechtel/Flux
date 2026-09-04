import Combine
import Foundation
#if DEBUG
import OSLog
#endif

struct IOSFeedIconKey: Hashable {
    let feedID: Int64
    let variant: FeedIconVariant
}

enum IOSFeedIconPresentation {
    static func variant(isDark: Bool) -> FeedIconVariant { isDark ? .dark : .normal }
}

@MainActor
final class NewsreaderStore: ObservableObject {
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
        static let clickOnNews = "FluxNews.clickOnNews"
    }

    @Published private(set) var articles: [ArticleSummary] = []
    @Published private(set) var catalog = NavigationCatalog(categories: [], feeds: [])
    @Published private(set) var unreadTotal: UInt64 = 0
    @Published private(set) var starredTotal: UInt64 = 0
    @Published private(set) var selectionTotal: UInt64 = 0
    @Published private(set) var categoryCounts: [Int64: UInt64] = [:]
    @Published private(set) var feedCounts: [Int64: UInt64] = [:]
    @Published private(set) var feedIcons: [IOSFeedIconKey: Data] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingNewByFeed: [Int64: Int] = [:]
    @Published private(set) var hasPendingNewData = false
    @Published private(set) var hasUnscopedNewDataSignal = false
    @Published private(set) var snapshotRevision: UInt64 = 0
    @Published private(set) var scrollResetRevision: UInt64 = 0
    @Published var scope: BrowserScope = .all
    @Published var unreadOnly = true
    @Published var newestFirst = false
    @Published var startupScope: StartupScopePreference
    @Published var startupCategoryID: Int64?
    @Published var startupFeedID: Int64?
    @Published var hideEmptyNavigationEntries: Bool
    @Published var removeArticlesWhenMarkedRead: Bool
    @Published var markReadOnScrolloverEnabled: Bool
    @Published var articlePresentationMode: ArticlePresentationMode
    @Published var articlePreviewLines: ArticlePreviewLines
    @Published var clickOnNews: ClickOnNews
    @Published private(set) var scrolloverUndoIDs: [Int64] = []
    @Published private(set) var scrolloverUndoVisible = false

    private(set) var core: Flux?
    private var eventSubscription: EventSubscription?
    private let defaults: UserDefaults
    private var pending = PendingNewData()
    private var requestedFeedIcons = Set<IOSFeedIconKey>()
    private var unavailableFeedIcons = Set<IOSFeedIconKey>()
    private var scrolloverUndoTask: Task<Void, Never>?
    private var scrolloverRemovedArticles: [Int64: ArticleSummary] = [:]
    private var scrolloverOriginalOrder: [Int64: Int] = [:]
    private var scrolloverCountsPending = false
    private var scrolloverBatchActive = false
    private var scrolloverBatchGeneration: UInt64 = 0
    private var scrolloverUndoBatchGeneration: UInt64?
    private var scrolloverMutationsInFlight = 0
    private var scrolloverPendingRemovals = Set<Int64>()
    private var scrolloverPresentationScrollActive = false
    private var hasMeaningfullyInteracted = false
    private var readerRequests = ReaderRequestState()

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
        clickOnNews = defaults.string(forKey: Key.clickOnNews).flatMap(ClickOnNews.init(rawValue:)) ?? .openLink
    }

    func attach(to configuredCore: Flux) {
        detach()
        core = configuredCore
        do {
            eventSubscription = try configuredCore.subscribeEvents(listener: IOSNewsreaderEventListener(store: self))
        } catch {
            errorMessage = error.localizedDescription
        }
        loadNavigationAndCounts()
        let categoryIDs = Set(catalog.categories.map(\.id))
        let feedIDs = Set(catalog.feeds.map(\.id))
        scope = StartupScopeResolver.resolve(startupScope, categoryID: startupCategoryID, feedID: startupFeedID, categoryIDs: categoryIDs, feedIDs: feedIDs)
        normalizeStartupScope(categoryIDs: categoryIDs, feedIDs: feedIDs)
        loadVisibleArticles()
    }

    func detach() {
        eventSubscription = nil
        core = nil
        articles = []
        catalog = NavigationCatalog(categories: [], feeds: [])
        unreadTotal = 0
        starredTotal = 0
        selectionTotal = 0
        categoryCounts = [:]
        feedCounts = [:]
        feedIcons = [:]
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

    func loadNavigationAndCounts() {
        guard let core else { return }
        do {
            catalog = try core.navigationCatalog()
            unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
            starredTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
            categoryCounts = try catalog.categories.reduce(into: [:]) { $0[$1.id] = try core.countArticles(query: query(scope: .category($1.id))) }
            feedCounts = try catalog.feeds.reduce(into: [:]) { $0[$1.id] = try core.countArticles(query: query(scope: .feed($1.id))) }
            pending.removeAbsentFeeds(Set(catalog.feeds.map(\.id)))
            publishPending()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadVisibleArticles(acknowledgePending: Bool = false, resetSnapshot: Bool = false) {
        guard let core else { return }
        isLoading = true
        do {
            articles = try core.queryArticles(query: query())
            selectionTotal = try core.countArticles(query: query())
            if acknowledgePending { acknowledgePendingForCurrentScope() }
            if resetSnapshot { snapshotRevision &+= 1 }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    func requestFeedIcon(_ feedID: Int64, variant: FeedIconVariant) {
        let key = IOSFeedIconKey(feedID: feedID, variant: variant)
        guard feedIcons[key] == nil, !unavailableFeedIcons.contains(key), let core else { return }
        guard requestedFeedIcons.insert(key).inserted else { return }
        Task { [weak self, core] in
            let data = await Task.detached {
                try? core.feedIcon(feedId: feedID, variant: variant)?.pngData
            }.value
            guard let self else { return }
            requestedFeedIcons.remove(key)
            if let data { feedIcons[key] = Data(data) }
            else { unavailableFeedIcons.insert(key) }
        }
    }

    func syncManually() async {
        guard let core, !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let result = await Task.detached { Result { try core.sync(reason: .manual) } }.value
        switch result {
        case let .success(metadata):
            handleSyncCompleted(metadata)
        case let .failure(error):
            errorMessage = error.localizedDescription
            isLoading = false
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
    func setClickOnNews(_ value: ClickOnNews) { clickOnNews = value; defaults.set(value.rawValue, forKey: Key.clickOnNews) }

    func setRead(_ article: ArticleSummary, read: Bool) { setRead(articleIDs: [article.id], read: read) }
    func setStarred(_ article: ArticleSummary, starred: Bool) { setStarred(articleIDs: [article.id], starred: starred) }

    func markCurrentScopeAsRead() {
        guard case .all = scope else {
            guard case .category = scope else {
                guard case .feed = scope else { return }
                markCurrentScopeArticlesRead()
                return
            }
            markCurrentScopeArticlesRead()
            return
        }
        markCurrentScopeArticlesRead()
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
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
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
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        completion(.success(core.minifluxEntryUrl(articleId: article.id)))
    }

    func saveToService(_ article: ArticleSummary, completion: @escaping (Result<SaveToServiceResult, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
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

    func feedPreferences(feedID: Int64) throws -> FeedPreferences { guard let core else { throw unconfiguredError }; return try core.feedPreferences(feedId: feedID) }
    func setFeedDetailRendering(feedID: Int64, mode: DetailRenderingMode) throws { try core?.setFeedDetailRendering(feedId: feedID, mode: mode) }
    func setFeedTruncateDetail(feedID: Int64, enabled: Bool) throws { try core?.setFeedTruncateDetail(feedId: feedID, enabled: enabled) }
    func setFeedOpenInMiniflux(feedID: Int64, enabled: Bool) throws { try core?.setFeedOpenInMiniflux(feedId: feedID, enabled: enabled) }

    func setRead(articleIDs: [Int64], read: Bool) {
        guard let core, !articleIDs.isEmpty else { return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: articleIDs, read: read) } }.value
            guard let self else { return }
            switch result {
            case .success: markMeaningfulInteraction(); updateVisibleRead(articleIDs, read: read); reloadCounts(includeNavigationCounts: true)
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    func setStarred(articleIDs: [Int64], starred: Bool) {
        guard let core, !articleIDs.isEmpty else { return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setStarredStateBulk(articleIds: articleIDs, starred: starred) } }.value
            guard let self else { return }
            switch result {
            case .success:
                markMeaningfulInteraction()
                if !starred && scope == .starred { articles.removeAll { articleIDs.contains($0.id) } }
                else { updateVisible(articleIDs) { $0.isStarred = starred } }
                reloadCounts(includeNavigationCounts: true)
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func beginScrolloverUndoBatch() -> UInt64 {
        scrolloverBatchActive = true
        scrolloverBatchGeneration &+= 1
        return scrolloverBatchGeneration
    }

    func flushScrollover(_ ids: [Int64]) {
        guard let core, !ids.isEmpty else { return }
        let batchGeneration = scrolloverBatchGeneration
        scrolloverDiagnostic("flush ids=\(ids) batch=\(batchGeneration)")
        scrolloverMutationsInFlight += 1
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: true) } }.value
            guard let self else { return }
            switch result {
            case .success:
                recordSuccessfulScrolloverRead(ids, batchGeneration: batchGeneration)
                scrolloverDiagnostic("mutation success ids=\(ids) batch=\(batchGeneration)")
            case let .failure(error):
                errorMessage = error.localizedDescription
                scrolloverDiagnostic("mutation failure ids=\(ids) batch=\(batchGeneration) error=\(error.localizedDescription)")
            }
            scrolloverMutationsInFlight -= 1
            if !scrolloverBatchActive && scrolloverMutationsInFlight == 0 && scrolloverCountsPending {
                scrolloverCountsPending = false
                reloadCounts(includeNavigationCounts: true)
            }
        }
    }

    func finishScrolloverUndoBatch() {
        scrolloverBatchActive = false
        if scrolloverMutationsInFlight == 0 && scrolloverCountsPending { scrolloverCountsPending = false; reloadCounts(includeNavigationCounts: true) }
    }

    func beginScrolloverPresentationScroll() {
        scrolloverPresentationScrollActive = true
    }

    func finishScrolloverPresentationScroll() {
        scrolloverPresentationScrollActive = false
        applyPendingScrolloverPresentation()
    }

    private func recordSuccessfulScrolloverRead(_ ids: [Int64], batchGeneration: UInt64) {
        let undoEligible: Bool
        if let undoGeneration = scrolloverUndoBatchGeneration {
            undoEligible = batchGeneration >= undoGeneration
            if batchGeneration > undoGeneration {
                scrolloverUndoIDs = []
                scrolloverRemovedArticles = [:]
                scrolloverOriginalOrder = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
                scrolloverUndoBatchGeneration = batchGeneration
            }
        } else {
            scrolloverUndoIDs = []
            scrolloverRemovedArticles = [:]
            scrolloverOriginalOrder = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
            scrolloverUndoBatchGeneration = batchGeneration
            undoEligible = true
        }

        // A completed Core mutation always updates the visible snapshot. Generation
        // ordering controls only whether it belongs to the current Undo transaction.
        guard undoEligible else {
            markMeaningfulInteraction()
            updateVisibleRead(ids, read: true, deferStructuralRemoval: true)
            scrolloverCountsPending = true
            return
        }
        var seen = Set(scrolloverUndoIDs)
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        markMeaningfulInteraction()
        scrolloverUndoIDs.append(contentsOf: unique)
        updateVisibleRead(unique, read: true, retainingForScrolloverUndo: true, deferStructuralRemoval: true)
        scrolloverCountsPending = true
        scrolloverUndoVisible = scrolloverUndoIDs.count >= 2
        scrolloverUndoTask?.cancel()
        scrolloverUndoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.scrolloverUndoVisible = false
        }
    }

    func undoScrollover() {
        guard let core, !scrolloverUndoIDs.isEmpty else { return }
        let ids = scrolloverUndoIDs
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: false) } }.value
            guard let self else { return }
            switch result {
            case .success:
                scrolloverPendingRemovals.subtract(ids)
                updateVisibleRead(ids, read: false); restoreScrolloverRemovedArticles()
                scrolloverUndoIDs = []; scrolloverUndoBatchGeneration = nil; scrolloverUndoVisible = false; scrolloverUndoTask?.cancel(); reloadCounts(includeNavigationCounts: true)
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    func accumulateNewData(_ additions: [(feedID: Int64, count: UInt32)]) { pending.accumulate(additions); publishPending() }
    func adoptVisibleSnapshot() { acknowledgePendingForCurrentScope(); hasUnscopedNewDataSignal = false; resetPresentationState(); replaceSnapshot(shouldResetScroll: true) }
    func resetVisibleSnapshot() { articles = []; selectionTotal = 0; resetPresentationState() }

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

    private func resetPresentationState() {
        hasMeaningfullyInteracted = false
        snapshotRevision &+= 1
        scrolloverUndoTask?.cancel()
        scrolloverUndoTask = nil
        scrolloverUndoIDs = []
        scrolloverUndoVisible = false
        scrolloverRemovedArticles = [:]
        scrolloverOriginalOrder = [:]
        scrolloverBatchActive = false
        scrolloverBatchGeneration = 0
        scrolloverUndoBatchGeneration = nil
        scrolloverCountsPending = false
        scrolloverPendingRemovals = []
        scrolloverPresentationScrollActive = false
    }

    fileprivate func handleSyncCompleted(_ metadata: SyncCompleted) {
        isLoading = false
        if metadata.reason == .background || metadata.reason == .periodic {
            pending.accumulate(metadata.newArticlesByFeed.map { (feedID: $0.feedId, count: $0.count) })
            publishPending()
            if metadata.dataChanged && metadata.newArticlesByFeed.isEmpty { hasUnscopedNewDataSignal = true }
        }
        if metadata.navigationChanged { loadNavigationAndCounts() }
        else if metadata.dataChanged { reloadCounts(includeNavigationCounts: false) }
        let action = SnapshotRefreshPolicy.action(manual: metadata.reason == .manual, dataChanged: metadata.dataChanged, hasMeaningfullyInteracted: hasMeaningfullyInteracted)
        switch action {
        case .replace:
            hasUnscopedNewDataSignal = false
            if metadata.reason == .manual { acknowledgePendingForCurrentScope() }
            replaceSnapshot(shouldResetScroll: metadata.reason == .manual)
        case .signalNewData:
            if metadata.newArticlesByFeed.isEmpty { hasUnscopedNewDataSignal = true }
        case .preserve:
            break
        }
    }

    private func replaceSnapshot(shouldResetScroll: Bool = false) {
        scrolloverUndoTask?.cancel()
        scrolloverUndoTask = nil
        scrolloverUndoIDs = []
        scrolloverUndoVisible = false
        scrolloverRemovedArticles = [:]
        scrolloverOriginalOrder = [:]
        scrolloverBatchActive = false
        scrolloverBatchGeneration = 0
        scrolloverUndoBatchGeneration = nil
        scrolloverCountsPending = false
        resetPresentationState()
        loadVisibleArticles(resetSnapshot: true)
        if shouldResetScroll { requestScrollReset() }
    }

    private func updateVisibleRead(_ ids: [Int64], read: Bool, retainingForScrolloverUndo: Bool = false, deferStructuralRemoval: Bool = false) {
        let ids = Set(ids)
        let removesReadArticles = ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope)
        if read && deferStructuralRemoval && scrolloverPresentationScrollActive {
            if retainingForScrolloverUndo { for article in articles where ids.contains(article.id) { scrolloverRemovedArticles[article.id] = article } }
            updateVisible(Array(ids)) { $0.isRead = true }
            if removesReadArticles { scrolloverPendingRemovals.formUnion(ids) }
            return
        }
        if read && removesReadArticles {
            if retainingForScrolloverUndo { for article in articles where ids.contains(article.id) { scrolloverRemovedArticles[article.id] = article } }
            updateVisible(Array(ids)) { $0.isRead = true }
            articles.removeAll { ids.contains($0.id) }
        } else { updateVisible(Array(ids)) { $0.isRead = read } }
    }

    private func applyPendingScrolloverPresentation() {
        guard !scrolloverPendingRemovals.isEmpty else { return }
        let removalIDs = scrolloverPendingRemovals
        scrolloverPendingRemovals.removeAll()
        let removesReadArticles = ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope)
        if removesReadArticles {
            articles.removeAll { removalIDs.contains($0.id) }
            requestScrollReset()
        }
    }

    private func restoreScrolloverRemovedArticles() {
        scrolloverPendingRemovals.subtract(scrolloverRemovedArticles.keys)
        let visibleIDs = Set(articles.map(\.id))
        articles.append(contentsOf: scrolloverRemovedArticles.values.filter { !visibleIDs.contains($0.id) })
        articles.sort { scrolloverOriginalOrder[$0.id, default: .max] < scrolloverOriginalOrder[$1.id, default: .max] }
        scrolloverRemovedArticles = [:]; scrolloverOriginalOrder = [:]
    }

    private func updateVisible(_ ids: [Int64], _ change: (inout ArticleSummary) -> Void) {
        let ids = Set(ids)
        for index in articles.indices where ids.contains(articles[index].id) { change(&articles[index]) }
    }

    private var unconfiguredError: NSError { NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"]) }

    private func markCurrentScopeArticlesRead() {
        guard let core else { return }
        let scope = scope
        let query = ArticleQuery(scope: query(scope: scope).scope, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil)
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.queryArticles(query: query).map(\.id) } }.value
            guard let self else { return }
            switch result {
            case let .success(ids):
                guard !ids.isEmpty else { return }
                let mutation = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: true) } }.value
                switch mutation {
                case .success:
                    self.markMeaningfulInteraction()
                    self.loadNavigationAndCounts()
                    self.loadVisibleArticles(resetSnapshot: true)
                    self.requestScrollReset()
                case let .failure(error): self.errorMessage = error.localizedDescription
                }
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

    private func scrolloverDiagnostic(_ message: String) {
#if DEBUG
        Self.scrolloverDiagnosticLog.debug("\(message, privacy: .public)")
#endif
    }

    // Narrow seam for deterministic iOS mutation-state tests without a live Core.
    @MainActor
    func setArticlesForTesting(_ value: [ArticleSummary]) { articles = value }
    @MainActor
    func applyReadMutationForTesting(_ ids: [Int64], read: Bool, retainingForScrolloverUndo: Bool = false) { markMeaningfulInteraction(); updateVisibleRead(ids, read: read, retainingForScrolloverUndo: retainingForScrolloverUndo) }
    @MainActor
    func applyScrolloverMutationForTesting(_ ids: [Int64], batchGeneration: UInt64) { recordSuccessfulScrolloverRead(ids, batchGeneration: batchGeneration) }
    @MainActor
    func applyScrolloverUndoForTesting() { let ids = scrolloverUndoIDs; scrolloverPendingRemovals.subtract(ids); updateVisibleRead(ids, read: false); restoreScrolloverRemovedArticles(); scrolloverUndoIDs = []; scrolloverUndoBatchGeneration = nil; scrolloverUndoVisible = false }
    @MainActor
    func beginScrolloverPresentationScrollForTesting() { beginScrolloverPresentationScroll() }
    @MainActor
    func finishScrolloverPresentationScrollForTesting() { finishScrolloverPresentationScroll() }
    @MainActor
    var scrolloverPendingRemovalsForTesting: Set<Int64> { scrolloverPendingRemovals }
    @MainActor
    var scrolloverUndoIDsForTesting: [Int64] { scrolloverUndoIDs }
    @MainActor
    func applyStarredMutationForTesting(_ ids: [Int64], starred: Bool) {
        markMeaningfulInteraction()
        if !starred && scope == .starred { articles.removeAll { ids.contains($0.id) } }
        else { updateVisible(ids) { $0.isStarred = starred } }
    }
    @MainActor
    func restoreScrolloverRemovedArticlesForTesting() { restoreScrolloverRemovedArticles() }
    @MainActor
    func completeSyncForTesting(_ metadata: SyncCompleted) { handleSyncCompleted(metadata) }
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

    private func reloadCounts(includeNavigationCounts: Bool = false) {
        guard let core else { return }
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
            guard let self else { return }
            switch result {
            case let .success(counts):
                selectionTotal = counts.0; unreadTotal = counts.1; starredTotal = counts.2
                if includeNavigationCounts { categoryCounts = counts.3; feedCounts = counts.4 }
            case let .failure(error): errorMessage = error.localizedDescription
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
