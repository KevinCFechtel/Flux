import AppKit
import Combine
import Foundation
import OSLog
import Security

enum BrowserScope: Hashable { case all, starred, category(Int64), feed(Int64) }
enum ArticleListStyle: String { case row, card }

@MainActor
final class BrowserStore: ObservableObject {
    @Published var articles: [ArticleSummary] = []
    @Published var catalog = NavigationCatalog(categories: [], feeds: [])
    @Published var unreadTotal: UInt64 = 0
    @Published var starredTotal: UInt64 = 0
    @Published var selectionTotal: UInt64 = 0
    @Published var categorySidebarCounts: [Int64: UInt64] = [:]
    @Published var feedSidebarCounts: [Int64: UInt64] = [:]
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
    @Published var articleListStyle: ArticleListStyle
    @Published var globalShortcut: GlobalShortcutChoice
    @Published var globalShortcutRegistrationError: String?
    @Published private(set) var listPresentationRevision: UInt64 = 0

    private var core: Flux?
    private var eventSubscription: EventSubscription?
    private var lastAutomaticSyncAttempt: Date?
    private var periodicSyncTimer: Timer?
    private var hasMeaningfullyInteracted = false
    private var sharingPicker: NSSharingServicePicker?
    private var undoExpiry: Task<Void, Never>?

    init() {
        markReadOnScrolloverEnabled = UserDefaults.standard.object(forKey: "FluxNews.markReadOnScrollover") as? Bool ?? true
        articleListStyle = UserDefaults.standard.string(forKey: "FluxNews.articleListStyle").flatMap(ArticleListStyle.init(rawValue:)) ?? .row
        globalShortcut = GlobalShortcutChoice.stored()
    }

    func start() {
        do {
            guard let credentials = try CredentialStore.load() else { settingsVisible = true; return }
            NativeLog.keychain.notice("stored Miniflux credentials loaded")
            configure(server: credentials.server, apiKey: credentials.apiKey)
        } catch {
            NativeLog.keychain.error("credential lookup failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            settingsVisible = true
        }
    }

    @discardableResult
    func configure(server: String, apiKey: String, launchAtLogin: Bool? = nil) -> Bool {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        let media = fm.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("Flux", isDirectory: true)
        do {
            core = try Flux.initializeWithDiagnostics(config: InitializationConfig(persistentData: support.path, cache: cache.path, media: media.path, baseUrl: server, apiKey: apiKey), listener: CoreDiagnosticLogger())
            eventSubscription = try core?.subscribeEvents(listener: BrowserEventListener(store: self))
            if let launchAtLogin { try CredentialStore.setLaunchAtLogin(launchAtLogin) }
            try CredentialStore.save(MinifluxCredentials(server: server, apiKey: apiKey))
            NativeLog.app.notice("core configured")
            resetPresentation()
            reloadNavigationAndCounts(); reloadVisibleArticles()
            sync(reason: .appStart)
            if NSApp.isActive { activatePeriodicSyncScheduling() }
            return true
        } catch {
            NativeLog.app.error("core configuration failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func query(scope: BrowserScope? = nil) -> ArticleQuery {
        let scope = scope ?? self.scope
        let coreScope: ArticleScope = switch scope { case .all, .starred: .all; case let .category(id): .category(id: id); case let .feed(id): .feed(id: id) }
        return ArticleQuery(scope: coreScope, readFilter: scope == .starred ? .all : (unreadOnly ? .unread : .all), starredFilter: scope == .starred ? .starred : .all, sort: newestFirst ? .newestFirst : .oldestFirst, limit: 0, cursor: nil)
    }
    func reloadVisibleArticles() { guard let core else { return }; do { articles = try core.queryArticles(query: query()); selectionTotal = try core.countArticles(query: query()); errorMessage = nil } catch { errorMessage = String(describing: error) } }
    func reloadNavigation() {
        guard let core else { return }
        do {
            catalog = try core.navigationCatalog()
        } catch { errorMessage = String(describing: error) }
    }
    func reloadCounts() {
        guard let core else { return }
        do {
            unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
            starredTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
            var categoryCounts: [Int64: UInt64] = [:]
            var feedCounts: [Int64: UInt64] = [:]
            for category in catalog.categories { categoryCounts[category.id] = try core.countArticles(query: query(scope: .category(category.id))) }
            for feed in catalog.feeds { feedCounts[feed.id] = try core.countArticles(query: query(scope: .feed(feed.id))) }
            categorySidebarCounts = categoryCounts
            feedSidebarCounts = feedCounts
        } catch { errorMessage = String(describing: error) }
    }
    func reloadNavigationAndCounts() { reloadNavigation(); reloadCounts() }
    func select(_ scope: BrowserScope) { self.scope = scope; resetPresentation(); reloadVisibleArticles() }
    func route(to route: NavigationRoute) {
        switch route {
        case .all: select(.all)
        case .starred: select(.starred)
        case .category(let id): select(.category(id))
        case .feed(let id): select(.feed(id))
        }
    }
    func setUnreadOnly(_ enabled: Bool) { unreadOnly = enabled; resetPresentation(); reloadCounts(); reloadVisibleArticles() }
    func setNewestFirst(_ enabled: Bool) { newestFirst = enabled; resetPresentation(); reloadVisibleArticles() }
    func noteMeaningfulInteraction() { hasMeaningfullyInteracted = true }
    func resetPresentation() { hasMeaningfullyInteracted = false; newDataAvailable = false; listPresentationRevision &+= 1 }
    func setArticleListStyle(_ style: ArticleListStyle) { guard style != articleListStyle else { return }; articleListStyle = style; UserDefaults.standard.set(style.rawValue, forKey: "FluxNews.articleListStyle"); resetPresentation() }
    func applyNewData() { resetPresentation(); reloadVisibleArticles() }
    func sync(reason: SyncReason = .manual) {
        guard let core else { return }
        guard !isLoading else {
            if reason == .periodic { NativeLog.sync.debug("periodic sync skipped because sync is already in flight") }
            return
        }
        isLoading = true
        if reason != .manual { lastAutomaticSyncAttempt = .now }
        if reason == .periodic { NativeLog.sync.notice("periodic sync triggered") }
        let store = WeakBrowserStore(self)
        Task.detached { [core, store] in
            do { try core.sync(reason: reason) }
            catch { await MainActor.run { store.value?.isLoading = false; store.value?.errorMessage = String(describing: error) } }
        }
    }
    func syncIfStale(reason: SyncReason = .periodic) {
        if lastAutomaticSyncAttempt.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true { sync(reason: reason) }
    }
    func activatePeriodicSyncScheduling() {
        guard core != nil, periodicSyncTimer == nil else { return }
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runPeriodicSync() }
        }
        NativeLog.sync.notice("periodic sync scheduled cadence_seconds=900")
    }
    func deactivatePeriodicSyncScheduling() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }
    func resume() {
        activatePeriodicSyncScheduling()
        syncIfStale(reason: .resume)
    }
    private func runPeriodicSync() { sync(reason: .periodic) }
    func handle(event: CoreEvent) {
        guard case let .syncCompleted(metadata) = event else { return }
        isLoading = false
        if metadata.navigationChanged { reloadNavigationAndCounts() }
        else if metadata.dataChanged { reloadCounts() }
        if metadata.reason == .periodic { NativeLog.sync.notice("periodic sync completed") }
        guard metadata.dataChanged else { return }
        if metadata.reason == .manual || !popoverVisible || !hasMeaningfullyInteracted { reloadVisibleArticles(); newDataAvailable = false }
        else { newDataAvailable = true }
    }
    func setRead(_ article: ArticleSummary, _ read: Bool) { guard let core else { return }; do { _ = try core.setReadState(articleId: article.id, read: read); updateVisible([article.id]) { $0.isRead = read }; reloadCounts() } catch { errorMessage = String(describing: error) } }
    func setStarred(_ article: ArticleSummary, _ starred: Bool) { guard let core else { return }; do { _ = try core.setStarredState(articleId: article.id, starred: starred); updateVisible([article.id]) { $0.isStarred = starred }; reloadCounts() } catch { errorMessage = String(describing: error) } }
    func flushScrollover(_ ids: [Int64]) { guard let core, !ids.isEmpty else { return }; do { _ = try core.setReadStateBulk(articleIds: ids, read: true); lastScrolloverBatch = ids; updateVisible(ids) { $0.isRead = true }; reloadCounts(); showScrolloverUndo() } catch { errorMessage = String(describing: error) } }
    func undoScrollover() { guard let core, !lastScrolloverBatch.isEmpty else { return }; do { _ = try core.setReadStateBulk(articleIds: lastScrolloverBatch, read: false); updateVisible(lastScrolloverBatch) { $0.isRead = false }; lastScrolloverBatch = []; scrolloverUndoVisible = false; undoExpiry?.cancel(); reloadCounts() } catch { errorMessage = String(describing: error) } }
    func setScrolloverEnabled(_ enabled: Bool) { markReadOnScrolloverEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "FluxNews.markReadOnScrollover") }
    func setGlobalShortcut(_ shortcut: GlobalShortcutChoice) { guard shortcut != globalShortcut else { return }; globalShortcut = shortcut; shortcut.store() }
    func open(_ article: ArticleSummary) { setRead(article, true); if let url = URL(string: article.url) { NSWorkspace.shared.open(url) } }
    func openComments(_ article: ArticleSummary) { if let url = URL(string: article.commentsUrl), !article.commentsUrl.isEmpty { NSWorkspace.shared.open(url) } }
    func copyLink(_ article: ArticleSummary) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(article.url, forType: .string) }
    func share(_ article: ArticleSummary) { guard let url = URL(string: article.url) else { return }; DispatchQueue.main.async { [weak self] in guard let self, let view = NSApplication.shared.keyWindow?.contentView else { return }; let picker = NSSharingServicePicker(items: [article.title, url]); self.sharingPicker = picker; let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil); picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY) } }
    private func updateVisible(_ ids: [Int64], _ change: (inout ArticleSummary) -> Void) { let ids = Set(ids); for index in articles.indices where ids.contains(articles[index].id) { change(&articles[index]) } }
    private func showScrolloverUndo() { scrolloverUndoVisible = true; undoExpiry?.cancel(); undoExpiry = Task { [weak self] in try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; self?.scrolloverUndoVisible = false } }
}

private final class WeakBrowserStore: @unchecked Sendable { weak var value: BrowserStore?; init(_ value: BrowserStore) { self.value = value } }
private final class BrowserEventListener: EventListener, @unchecked Sendable { weak var store: BrowserStore?; init(store: BrowserStore) { self.store = store }; func onEvent(event: CoreEvent) { Task { @MainActor [weak store] in store?.handle(event: event) } } }

private final class CoreDiagnosticLogger: DiagnosticListener, @unchecked Sendable {
    func onDiagnostic(record: DiagnosticRecord) {
        let logger = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "core.\(record.target)")
        switch record.level {
        case .trace, .debug:
            logger.debug("\(record.message, privacy: .public)")
        case .info:
            logger.notice("\(record.message, privacy: .public)")
        case .warn:
            logger.warning("\(record.message, privacy: .public)")
        case .error:
            logger.error("\(record.message, privacy: .public)")
        }
    }
}

enum NativeLog {
    static let app = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "app")
    static let sync = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "sync")
    static let keychain = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "keychain")
    static let launchAtLogin = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "launch_at_login")
    static let shortcut = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "shortcut")
}
