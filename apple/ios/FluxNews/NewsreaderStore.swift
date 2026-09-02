import Combine
import Foundation

@MainActor
final class NewsreaderStore: ObservableObject {
    private enum Key {
        static let startupScope = "FluxNews.iOS.startupScope"
        static let startupCategoryID = "FluxNews.iOS.startupCategoryID"
        static let startupFeedID = "FluxNews.iOS.startupFeedID"
        static let hideEmpty = "FluxNews.iOS.hideEmptyNavigationEntries"
        static let removeWhenRead = "FluxNews.iOS.removeArticlesWhenMarkedRead"
        static let scrollover = "FluxNews.iOS.markReadOnScrollover"
        static let presentationMode = "FluxNews.iOS.articlePresentationMode"
        static let previewLines = "FluxNews.iOS.articlePreviewLines"
    }

    @Published private(set) var articles: [ArticleSummary] = []
    @Published private(set) var catalog = NavigationCatalog(categories: [], feeds: [])
    @Published private(set) var unreadTotal: UInt64 = 0
    @Published private(set) var starredTotal: UInt64 = 0
    @Published private(set) var selectionTotal: UInt64 = 0
    @Published private(set) var categoryCounts: [Int64: UInt64] = [:]
    @Published private(set) var feedCounts: [Int64: UInt64] = [:]
    @Published private(set) var feedIcons: [Int64: Data] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingNewByFeed: [Int64: Int] = [:]
    @Published private(set) var hasPendingNewData = false
    @Published private(set) var snapshotRevision: UInt64 = 0
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
    @Published private(set) var scrolloverUndoIDs: [Int64] = []
    @Published private(set) var scrolloverUndoVisible = false

    private(set) var core: Flux?
    private var pending = PendingNewData()
    private var requestedFeedIcons = Set<Int64>()
    private var unavailableFeedIcons = Set<Int64>()
    private var scrolloverUndoTask: Task<Void, Never>?
    private var scrolloverRemovedArticles: [Int64: ArticleSummary] = [:]
    private var scrolloverOriginalOrder: [Int64: Int] = [:]
    private var scrolloverCountsPending = false
    private var scrolloverBatchActive = false

    init(defaults: UserDefaults = .standard) {
        startupScope = defaults.string(forKey: Key.startupScope).flatMap(StartupScopePreference.init(rawValue:)) ?? .allNews
        startupCategoryID = defaults.object(forKey: Key.startupCategoryID) as? Int64
        startupFeedID = defaults.object(forKey: Key.startupFeedID) as? Int64
        hideEmptyNavigationEntries = defaults.object(forKey: Key.hideEmpty) as? Bool ?? false
        removeArticlesWhenMarkedRead = defaults.object(forKey: Key.removeWhenRead) as? Bool ?? false
        markReadOnScrolloverEnabled = defaults.object(forKey: Key.scrollover) as? Bool ?? true
        articlePresentationMode = defaults.string(forKey: Key.presentationMode).flatMap(ArticlePresentationMode.init(rawValue:)) ?? .visual
        articlePreviewLines = ArticlePreviewLines(rawValue: defaults.object(forKey: Key.previewLines) as? Int ?? 3) ?? .standard
    }

    func attach(to configuredCore: Flux) {
        core = configuredCore
        loadNavigationAndCounts()
        scope = StartupScopeResolver.resolve(startupScope, categoryID: startupCategoryID, feedID: startupFeedID, categoryIDs: Set(catalog.categories.map(\.id)), feedIDs: Set(catalog.feeds.map(\.id)) )
        loadVisibleArticles()
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

    func requestFeedIcon(_ feedID: Int64) {
        guard feedIcons[feedID] == nil, !unavailableFeedIcons.contains(feedID), let core else { return }
        guard requestedFeedIcons.insert(feedID).inserted else { return }
        Task { [weak self, core] in
            let data = await Task.detached {
                try? core.feedIcon(feedId: feedID, variant: .normal)?.pngData
            }.value
            guard let self else { return }
            requestedFeedIcons.remove(feedID)
            if let data { feedIcons[feedID] = Data(data) }
            else { unavailableFeedIcons.insert(feedID) }
        }
    }

    func syncManually() async {
        guard let core, !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let result = await Task.detached { Result { try core.sync(reason: .manual) } }.value
        switch result {
        case .success:
            loadNavigationAndCounts()
            loadVisibleArticles()
        case let .failure(error):
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func select(_ newScope: BrowserScope) { scope = newScope; loadVisibleArticles(acknowledgePending: true, resetSnapshot: true) }

    func setUnreadOnly(_ value: Bool) { unreadOnly = value; loadVisibleArticles(resetSnapshot: true) }
    func setNewestFirst(_ value: Bool) { newestFirst = value; loadVisibleArticles(resetSnapshot: true) }
    func setStartupScope(_ value: StartupScopePreference) { startupScope = value; UserDefaults.standard.set(value.rawValue, forKey: Key.startupScope) }
    func setStartupCategoryID(_ value: Int64?) { startupCategoryID = value; UserDefaults.standard.set(value, forKey: Key.startupCategoryID) }
    func setStartupFeedID(_ value: Int64?) { startupFeedID = value; UserDefaults.standard.set(value, forKey: Key.startupFeedID) }
    func setHideEmptyNavigationEntries(_ value: Bool) { hideEmptyNavigationEntries = value; UserDefaults.standard.set(value, forKey: Key.hideEmpty) }
    func setRemoveArticlesWhenMarkedRead(_ value: Bool) { removeArticlesWhenMarkedRead = value; UserDefaults.standard.set(value, forKey: Key.removeWhenRead) }
    func setMarkReadOnScrolloverEnabled(_ value: Bool) { markReadOnScrolloverEnabled = value; UserDefaults.standard.set(value, forKey: Key.scrollover) }
    func setArticlePresentationMode(_ value: ArticlePresentationMode) { articlePresentationMode = value; UserDefaults.standard.set(value.rawValue, forKey: Key.presentationMode) }
    func setArticlePreviewLines(_ value: ArticlePreviewLines) { articlePreviewLines = value; UserDefaults.standard.set(value.rawValue, forKey: Key.previewLines) }

    func setRead(_ article: ArticleSummary, read: Bool) { setRead(articleIDs: [article.id], read: read) }
    func setStarred(_ article: ArticleSummary, starred: Bool) { setStarred(articleIDs: [article.id], starred: starred) }

    func setRead(articleIDs: [Int64], read: Bool) {
        guard let core, !articleIDs.isEmpty else { return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: articleIDs, read: read) } }.value
            guard let self else { return }
            switch result {
            case .success: updateVisibleRead(articleIDs, read: read); reloadCounts()
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
            case .success: updateVisible(articleIDs) { $0.isStarred = starred }; reloadCounts()
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    func beginScrolloverUndoBatch() {
        scrolloverBatchActive = true
        scrolloverUndoIDs = []
        scrolloverRemovedArticles = [:]
        scrolloverOriginalOrder = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
    }

    func flushScrollover(_ ids: [Int64]) {
        guard let core, !ids.isEmpty else { return }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: true) } }.value
            guard let self else { return }
            switch result {
            case .success:
                let unique = ids.filter { !self.scrolloverUndoIDs.contains($0) }
                scrolloverUndoIDs.append(contentsOf: unique)
                updateVisibleRead(unique, read: true, retainingForScrolloverUndo: true)
                scrolloverCountsPending = true
                if !scrolloverBatchActive { scrolloverCountsPending = false; reloadCounts() }
                scrolloverUndoVisible = scrolloverUndoIDs.count >= 2
                scrolloverUndoTask?.cancel()
                scrolloverUndoTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    self?.scrolloverUndoVisible = false
                }
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    func finishScrolloverUndoBatch() {
        scrolloverBatchActive = false
        if scrolloverCountsPending { scrolloverCountsPending = false; reloadCounts() }
    }

    func undoScrollover() {
        guard let core, !scrolloverUndoIDs.isEmpty else { return }
        let ids = scrolloverUndoIDs
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.setReadStateBulk(articleIds: ids, read: false) } }.value
            guard let self else { return }
            switch result {
            case .success:
                updateVisibleRead(ids, read: false); restoreScrolloverRemovedArticles()
                scrolloverUndoIDs = []; scrolloverUndoVisible = false; scrolloverUndoTask?.cancel(); reloadCounts()
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    func accumulateNewData(_ additions: [(feedID: Int64, count: UInt32)]) { pending.accumulate(additions); publishPending() }
    func adoptVisibleSnapshot() { acknowledgePendingForCurrentScope(); loadVisibleArticles(resetSnapshot: true) }
    func resetVisibleSnapshot() { articles = []; selectionTotal = 0; snapshotRevision &+= 1 }

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

    private func updateVisibleRead(_ ids: [Int64], read: Bool, retainingForScrolloverUndo: Bool = false) {
        let ids = Set(ids)
        if read && ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope) {
            if retainingForScrolloverUndo { for article in articles where ids.contains(article.id) { scrolloverRemovedArticles[article.id] = article } }
            articles.removeAll { ids.contains($0.id) }
        } else { updateVisible(Array(ids)) { $0.isRead = read } }
    }

    private func restoreScrolloverRemovedArticles() {
        let visibleIDs = Set(articles.map(\.id))
        articles.append(contentsOf: scrolloverRemovedArticles.values.filter { !visibleIDs.contains($0.id) })
        articles.sort { scrolloverOriginalOrder[$0.id, default: .max] < scrolloverOriginalOrder[$1.id, default: .max] }
        scrolloverRemovedArticles = [:]; scrolloverOriginalOrder = [:]
    }

    private func updateVisible(_ ids: [Int64], _ change: (inout ArticleSummary) -> Void) {
        let ids = Set(ids)
        for index in articles.indices where ids.contains(articles[index].id) { change(&articles[index]) }
    }

    private func reloadCounts() {
        guard let core else { return }
        let selectionQuery = query()
        Task { [weak self, core] in
            let result = await Task.detached {
                Result {
                    (try core.countArticles(query: selectionQuery),
                     try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil)),
                     try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil)))
                }
            }.value
            guard let self else { return }
            switch result { case let .success(counts): selectionTotal = counts.0; unreadTotal = counts.1; starredTotal = counts.2; case let .failure(error): errorMessage = error.localizedDescription }
        }
    }
}
