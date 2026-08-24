import AppKit
import Combine
import Foundation
import Security

enum BrowserScope: Hashable { case all, starred, category(Int64), feed(Int64) }

@MainActor
final class BrowserStore: ObservableObject {
    @Published var articles: [ArticleSummary] = []
    @Published var catalog = NavigationCatalog(categories: [], feeds: [])
    @Published var unreadTotal: UInt64 = 0
    @Published var starredTotal: UInt64 = 0
    @Published var selectionTotal: UInt64 = 0
    @Published var sidebarCounts: [Int64: UInt64] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var scope: BrowserScope = .all
    @Published var unreadOnly = true
    @Published var newestFirst = false
    @Published var popoverVisible = false
    @Published var settingsVisible = false
    @Published var newDataAvailable = false
    @Published var lastScrolloverBatch: [Int64] = []
    @Published var scrolloverUndoVisible = false
    @Published var markReadOnScrolloverEnabled = true

    private var core: Flux?
    private var eventSubscription: EventSubscription?
    private var lastSync: Date?
    private var hasMeaningfullyInteracted = false
    private var sharingPicker: NSSharingServicePicker?
    private var undoExpiry: Task<Void, Never>?

    init() { markReadOnScrolloverEnabled = UserDefaults.standard.object(forKey: "FluxBar.markReadOnScrollover") as? Bool ?? true }

    func start() {
        if let server = UserDefaults.standard.string(forKey: "Flux.server"), let key = KeychainCredentials.load(), !server.isEmpty { configure(server: server, apiKey: key) }
        else { settingsVisible = true }
    }

    func configure(server: String, apiKey: String) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        let media = fm.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        do {
            core = try Flux.initialize(config: InitializationConfig(persistentData: support.path, cache: cache.path, media: media.path, baseUrl: server, apiKey: apiKey))
            eventSubscription = try core?.subscribeEvents(listener: BrowserEventListener(store: self))
            UserDefaults.standard.set(server, forKey: "Flux.server")
            try KeychainCredentials.save(apiKey)
            resetPresentation()
            reloadNavigationAndCounts(); reloadVisibleArticles()
            sync(reason: .appStart)
        } catch { errorMessage = String(describing: error) }
    }

    func query(scope: BrowserScope? = nil) -> ArticleQuery {
        let scope = scope ?? self.scope
        let coreScope: ArticleScope = switch scope { case .all, .starred: .all; case let .category(id): .category(id: id); case let .feed(id): .feed(id: id) }
        return ArticleQuery(scope: coreScope, readFilter: scope == .starred ? .all : (unreadOnly ? .unread : .all), starredFilter: scope == .starred ? .starred : .all, sort: newestFirst ? .newestFirst : .oldestFirst, limit: 0, cursor: nil)
    }
    func reloadVisibleArticles() { guard let core else { return }; do { articles = try core.queryArticles(query: query()); selectionTotal = try core.countArticles(query: query()); errorMessage = nil } catch { errorMessage = String(describing: error) } }
    func reloadNavigationAndCounts() {
        guard let core else { return }
        do {
            catalog = try core.navigationCatalog()
            unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
            starredTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
            var counts: [Int64: UInt64] = [:]
            for category in catalog.categories { counts[category.id] = try core.countArticles(query: query(scope: .category(category.id))) }
            for feed in catalog.feeds { counts[feed.id] = try core.countArticles(query: query(scope: .feed(feed.id))) }
            sidebarCounts = counts
        } catch { errorMessage = String(describing: error) }
    }
    func select(_ scope: BrowserScope) { self.scope = scope; resetPresentation(); reloadVisibleArticles() }
    func setUnreadOnly(_ enabled: Bool) { unreadOnly = enabled; resetPresentation(); reloadNavigationAndCounts(); reloadVisibleArticles() }
    func setNewestFirst(_ enabled: Bool) { newestFirst = enabled; resetPresentation(); reloadNavigationAndCounts(); reloadVisibleArticles() }
    func noteMeaningfulInteraction() { hasMeaningfullyInteracted = true }
    func resetPresentation() { hasMeaningfullyInteracted = false; newDataAvailable = false }
    func applyNewData() { resetPresentation(); reloadVisibleArticles() }
    func sync(reason: SyncReason = .manual) {
        guard let core, !isLoading else { return }
        isLoading = true
        let store = WeakBrowserStore(self)
        Task.detached { [core, store] in
            do { try core.sync(reason: reason) }
            catch { await MainActor.run { store.value?.isLoading = false; store.value?.errorMessage = String(describing: error) } }
        }
    }
    func syncIfStale() { if lastSync.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true { sync(reason: .periodic) } }
    func handle(event: CoreEvent) {
        guard case let .syncCompleted(metadata) = event else { return }
        lastSync = .now; isLoading = false; reloadNavigationAndCounts()
        guard metadata.dataChanged else { return }
        if metadata.reason == .manual || !popoverVisible || !hasMeaningfullyInteracted { reloadVisibleArticles(); newDataAvailable = false }
        else { newDataAvailable = true }
    }
    func setRead(_ article: ArticleSummary, _ read: Bool) { guard let core else { return }; do { _ = try core.setReadState(articleId: article.id, read: read); updateVisible([article.id]) { $0.isRead = read }; reloadNavigationAndCounts() } catch { errorMessage = String(describing: error) } }
    func setStarred(_ article: ArticleSummary, _ starred: Bool) { guard let core else { return }; do { _ = try core.setStarredState(articleId: article.id, starred: starred); updateVisible([article.id]) { $0.isStarred = starred }; reloadNavigationAndCounts() } catch { errorMessage = String(describing: error) } }
    func flushScrollover(_ ids: [Int64]) { guard let core, !ids.isEmpty else { return }; do { _ = try core.setReadStateBulk(articleIds: ids, read: true); lastScrolloverBatch = ids; updateVisible(ids) { $0.isRead = true }; reloadNavigationAndCounts(); showScrolloverUndo() } catch { errorMessage = String(describing: error) } }
    func undoScrollover() { guard let core, !lastScrolloverBatch.isEmpty else { return }; do { _ = try core.setReadStateBulk(articleIds: lastScrolloverBatch, read: false); updateVisible(lastScrolloverBatch) { $0.isRead = false }; lastScrolloverBatch = []; scrolloverUndoVisible = false; undoExpiry?.cancel(); reloadNavigationAndCounts() } catch { errorMessage = String(describing: error) } }
    func setScrolloverEnabled(_ enabled: Bool) { markReadOnScrolloverEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "FluxBar.markReadOnScrollover") }
    func open(_ article: ArticleSummary) { setRead(article, true); if let url = URL(string: article.url) { NSWorkspace.shared.open(url) } }
    func openComments(_ article: ArticleSummary) { if let url = URL(string: article.commentsUrl), !article.commentsUrl.isEmpty { NSWorkspace.shared.open(url) } }
    func copyLink(_ article: ArticleSummary) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(article.url, forType: .string) }
    func share(_ article: ArticleSummary) { guard let url = URL(string: article.url) else { return }; DispatchQueue.main.async { [weak self] in guard let self, let view = NSApplication.shared.keyWindow?.contentView else { return }; let picker = NSSharingServicePicker(items: [article.title, url]); self.sharingPicker = picker; let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil); picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY) } }
    private func updateVisible(_ ids: [Int64], _ change: (inout ArticleSummary) -> Void) { let ids = Set(ids); for index in articles.indices where ids.contains(articles[index].id) { change(&articles[index]) } }
    private func showScrolloverUndo() { scrolloverUndoVisible = true; undoExpiry?.cancel(); undoExpiry = Task { [weak self] in try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; self?.scrolloverUndoVisible = false } }
}

private final class WeakBrowserStore: @unchecked Sendable { weak var value: BrowserStore?; init(_ value: BrowserStore) { self.value = value } }
private final class BrowserEventListener: EventListener, @unchecked Sendable { weak var store: BrowserStore?; init(store: BrowserStore) { self.store = store }; func onEvent(event: CoreEvent) { Task { @MainActor [weak store] in store?.handle(event: event) } } }

enum KeychainCredentials {
    static let service = "dev.kevincfechtel.Flux.api-key"
    static func load() -> String? { let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnData as String:true]; var result:CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data=result as? Data else{return nil}; return String(data:data,encoding:.utf8) }
    static func save(_ key:String) throws { let data=Data(key.utf8); let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service]; if SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary) == errSecItemNotFound { guard SecItemAdd((query.merging([kSecValueData as String:data]){$1}) as CFDictionary,nil) == errSecSuccess else { throw NSError(domain:"Flux",code:1) } } }
}
