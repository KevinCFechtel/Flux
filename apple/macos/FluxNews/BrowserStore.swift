import AppKit
import Combine
import Foundation
import OSLog
import Security
import UserNotifications

struct FeedSettingsTarget: Identifiable { let id: Int64; let title: String }

struct ArticleAudioActionState: Equatable {
    let articleID: Int64
    let enclosures: [Enclosure]
    let isInListeningList: Bool
    let downloads: [Int64: MediaDownload]
}

struct ListeningListProgress: Equatable {
    let positionMs: UInt64
    let durationMs: UInt64?
    let status: PlaybackStatus
}

enum ListeningListPresentation {
    static func textOrFallback(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    static func validatedFeedID(_ feedID: Int64?, feeds: [ListeningListFeed]) -> Int64? {
        guard let feedID else { return nil }
        return feeds.contains(where: { $0.feedId == feedID }) ? feedID : nil
    }

    static func preferredEnclosure(_ item: ListeningListItem) -> Enclosure? {
        if let activeID = item.activeEnclosureId,
           let active = item.audioEnclosures.first(where: { $0.enclosure.id == activeID }) {
            return active.enclosure
        }
        return item.audioEnclosures.count == 1 ? item.audioEnclosures[0].enclosure : nil
    }

    @MainActor static func progress(_ item: ListeningListItem, runtime: MediaPlaybackPresentationState? = nil) -> ListeningListProgress? {
        let selected = item.activeEnclosureId.flatMap { id in item.audioEnclosures.first(where: { $0.enclosure.id == id }) }
            ?? (item.audioEnclosures.count == 1 ? item.audioEnclosures[0] : nil)
        guard let selected else { return nil }
        let isRuntimeItem = runtime?.loadedEnclosure?.id == selected.enclosure.id
        let playback = selected.playbackState
        let status: PlaybackStatus
        if isRuntimeItem {
            switch runtime?.status {
            case .playing: status = .inProgress
            case .paused, .stopped, nil: status = playback?.status ?? .notStarted
            }
        } else {
            status = playback?.status ?? .notStarted
        }
        let rawPosition = isRuntimeItem ? runtime?.positionMs ?? playback?.positionMs ?? 0 : playback?.positionMs ?? 0
        let rawDuration = isRuntimeItem ? runtime?.durationMs ?? selected.durationMs ?? playback?.durationMs : selected.durationMs ?? playback?.durationMs
        let duration = rawDuration.flatMap { $0 > 0 ? $0 : nil }
        let position = duration.map { min(rawPosition, $0) } ?? rawPosition
        guard status != .notStarted || position > 0 else { return nil }
        return ListeningListProgress(positionMs: position, durationMs: duration, status: status)
    }

    static func downloadedCount(_ item: ListeningListItem) -> (downloaded: Int, total: Int, pending: Int) {
        let states = item.audioEnclosures.compactMap(\.download?.state)
        let downloaded = states.filter { $0 == .downloaded }.count
        let pending = states.filter { $0 == .requested || $0 == .deleteRequested }.count
        return (downloaded, item.audioEnclosures.count, pending)
    }
}

enum ArticleAudioActions {
    enum DownloadAction: Equatable { case download, pending, delete, downloading, pendingDeletion, retry }

    static func audioEnclosures(_ enclosures: [Enclosure]) -> [Enclosure] {
        enclosures.filter { $0.mediaKind == .audio }
    }

    static func shouldRender(_ state: ArticleAudioActionState?, transferStateAvailable: Bool) -> Bool {
        state != nil && transferStateAvailable && !(state?.enclosures.isEmpty ?? true)
    }

    static func requiresReplacement(currentID: Int64?, currentStatus: MediaPlaybackPresentationStatus, selectedID: Int64) -> Bool {
        currentID != selectedID && currentStatus == .playing
    }

    static func canRequestDownload(_ download: MediaDownload?) -> Bool {
        switch downloadAction(download) {
        case .download, .retry: return true
        case .pending, .delete, .downloading, .pendingDeletion: return false
        }
    }

    static func canDeleteDownload(_ download: MediaDownload?) -> Bool {
        downloadAction(download) == .delete
    }

    static func hasLocalDownload(_ item: ListeningListItem) -> Bool {
        item.audioEnclosures.contains { $0.download?.state == .downloaded }
    }

    static func downloadAction(_ download: MediaDownload?, runtime: MediaTransferRuntime? = nil) -> DownloadAction {
        switch download?.state {
        case .downloaded: return .delete
        case .requested: return runtime?.phase == .transferring ? .downloading : .pending
        case .deleteRequested: return .pendingDeletion
        case .failed: return .retry
        case .notDownloaded, nil: return .download
        }
    }

    static func enclosureLabel(_ enclosure: Enclosure, index: Int) -> String {
        let filename: String?
        if let url = URL(string: enclosure.url), let decoded = url.lastPathComponent.removingPercentEncoding {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            filename = trimmed.isEmpty || trimmed == "/" ? nil : trimmed
        } else {
            filename = nil
        }
        let name = filename ?? String(localized: "Audio \(index + 1)")
        let format = enclosure.mimeType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let size = enclosure.sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64(min($0, UInt64(Int64.max))), countStyle: .file) }
        let details = [format, size].compactMap { $0 }.filter { !$0.isEmpty }
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }
}

private struct MacOSBackupSettingsV1: Codable {
    static let version: UInt32 = 1
    let version: UInt32
    let markReadOnScrollover: Bool
    let syncOnStart: Bool
    let articleListStyle: String
    let previewLines: Int
    let clickOnNews: String
    let globalShortcut: String
    let launchAtLogin: Bool
    let startupScope: String?
    let startupCategoryID: Int64?
    let startupFeedID: Int64?
    let hideEmptyNavigationEntries: Bool?
    let removeArticlesWhenMarkedRead: Bool?
    let customHeaders: [CustomHTTPHeader]?
}

private enum ConfigurationBackupPresentationError: LocalizedError {
    case noConfiguredAccount
    case unsupportedPlatformSettings
    case coreInitialization

    var errorDescription: String? {
        switch self {
        case .noConfiguredAccount: "Configure a Miniflux account before exporting a backup."
        case .unsupportedPlatformSettings: "This backup contains unsupported macOS settings."
        case .coreInitialization: "The restored account could not be activated locally."
        }
    }
}

@MainActor
final class BrowserStore: ObservableObject {
    nonisolated static var mediaRootURL: URL { MediaPlaybackPaths.mediaRootURL }
    var onCoreConfigured: ((Flux) -> Void)?
    @Published var articles: [ArticleSummary] = []
    @Published var catalog = NavigationCatalog(categories: [], feeds: [])
    @Published var unreadTotal: UInt64 = 0
    @Published var starredTotal: UInt64 = 0
    @Published var selectionTotal: UInt64 = 0
    @Published var categorySidebarCounts: [Int64: UInt64] = [:]
    @Published var feedSidebarCounts: [Int64: UInt64] = [:]
    @Published private(set) var feedIcons: [String: Data] = [:]
    @Published private(set) var articleThumbnails: [String: NSImage] = [:]
    @Published private(set) var unavailableArticleThumbnails = Set<String>()
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var actionConfirmation: String?
    @Published var scope: BrowserScope = .all
    @Published private(set) var listeningListItems: [ListeningListItem] = []
    @Published private(set) var listeningListFeeds: [ListeningListFeed] = []
    @Published var listeningListSort: ListeningListSort = .recentlyAdded
    @Published var listeningListFeedID: Int64?
    @Published var searchQuery = ""
    @Published private(set) var searchTotal: Int64 = 0
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published var unreadOnly = true
    @Published var newestFirst = false
    @Published var popoverVisible = false
    @Published var settingsVisible = false
    @Published var addFeedVisible = false
    @Published var addCategoryVisible = false
    @Published var newDataAvailable = false
    @Published var lastScrolloverBatch: [Int64] = []
    @Published var scrolloverUndoVisible = false
    @Published var markReadOnScrolloverEnabled = true
    @Published var startupScope: StartupScopePreference
    @Published var startupCategoryID: Int64?
    @Published var startupFeedID: Int64?
    @Published var hideEmptyNavigationEntries: Bool
    @Published var removeArticlesWhenMarkedRead: Bool
    @Published private(set) var syncOnStartEnabled: Bool
    @Published var articleListStyle: ArticleListStyle
    @Published var articlePreviewLines: ArticlePreviewLines
    @Published var clickOnNews: ClickOnNews
    @Published var globalShortcut: GlobalShortcutChoice
    @Published var globalShortcutRegistrationError: String?
    @Published private(set) var coreSettings: CoreSettings?
    @Published private(set) var pendingNewByFeed: [Int64: Int] = [:]
    @Published private(set) var hasPendingNewData = false
    @Published private(set) var systemNotificationSettings: [FeedSystemNotificationSetting] = []
    @Published private(set) var systemNotificationSettingsError: String?
    @Published private(set) var updatingSystemNotificationFeedIDs = Set<Int64>()
    @Published private(set) var listPresentationRevision: UInt64 = 0
    @Published private(set) var snapshotResetRevision: UInt64 = 0
    @Published private(set) var configuredServer: String?
    @Published private(set) var minifluxVersion: String?
    @Published private(set) var accountValidationError: String?
    @Published private(set) var isSavingAccount = false
    @Published var feedSettingsTarget: FeedSettingsTarget?
    @Published private(set) var articleAudioActionState: ArticleAudioActionState?
    @Published private(set) var articleAudioActionStates: [Int64: ArticleAudioActionState] = [:]

    private var core: Flux?
    private var eventSubscription: EventSubscription?
    private var lastAutomaticSyncAttempt: Date?
    private var periodicSyncTimer: Timer?
    private var hasMeaningfullyInteracted = false
    private var sharingPicker: NSSharingServicePicker?
    private var undoExpiry: Task<Void, Never>?
    private var actionConfirmationExpiry: Task<Void, Never>?
    private var feedIconRequests = FeedIconRequestState()
    private var scrolloverUndoBatch = ScrolloverUndoBatch()
    private var articleThumbnailRequests = ArticleThumbnailRequestState()
    private var scrolloverCountsPending = false
    private var searchGeneration: UInt64 = 0
    private var pendingNewData = PendingNewData()
    private var readerDocumentRequest: UInt64 = 0
    private let searchPageSize: UInt32 = 50
    private var pendingWidgetActions: [WidgetAction] = []
    private var startupRouteState = StartupRouteState()
    private var hasAppliedStartupScope = false
    private var scrolloverRemovedArticles: [Int64: ArticleSummary] = [:]
    private var scrolloverOriginalOrder: [Int64: Int] = [:]
    private var articleAudioRequestGeneration: UInt64 = 0
    var onMediaTransferRequested: (() -> Void)?

    init() {
        markReadOnScrolloverEnabled = UserDefaults.standard.object(forKey: "FluxNews.markReadOnScrollover") as? Bool ?? true
        startupScope = UserDefaults.standard.string(forKey: "FluxNews.startupScope").flatMap(StartupScopePreference.init(rawValue:)) ?? .allNews
        startupCategoryID = UserDefaults.standard.object(forKey: "FluxNews.startupCategoryID") as? Int64
        startupFeedID = UserDefaults.standard.object(forKey: "FluxNews.startupFeedID") as? Int64
        hideEmptyNavigationEntries = UserDefaults.standard.object(forKey: "FluxNews.hideEmptyNavigationEntries") as? Bool ?? false
        removeArticlesWhenMarkedRead = UserDefaults.standard.object(forKey: "FluxNews.removeArticlesWhenMarkedRead") as? Bool ?? false
        syncOnStartEnabled = UserDefaults.standard.object(forKey: "FluxNews.syncOnStart") as? Bool ?? true
        articleListStyle = UserDefaults.standard.string(forKey: "FluxNews.articleListStyle").flatMap(ArticleListStyle.init(rawValue:)) ?? .row
        articlePreviewLines = ArticlePreviewLines(rawValue: UserDefaults.standard.integer(forKey: "FluxNews.articlePreviewLines")) ?? .standard
        clickOnNews = UserDefaults.standard.string(forKey: "FluxNews.clickOnNews").flatMap(ClickOnNews.init(rawValue:)) ?? .openLink
        globalShortcut = GlobalShortcutChoice.stored()
    }

    func start() {
        do {
            guard let credentials = try CredentialStore.load() else { settingsVisible = true; return }
            NativeLog.keychain.notice("stored Miniflux credentials loaded")
            configure(server: credentials.server, apiKey: credentials.apiKey, customHeaders: credentials.resolvedCustomHeaders)
        } catch {
            NativeLog.keychain.error("credential lookup failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = NativeErrorPresentation.message(for: error)
            settingsVisible = true
        }
    }

    @discardableResult
    func configure(server: String, apiKey: String, customHeaders: [CustomHTTPHeader] = [], refreshVersion: Bool = true, startSync: Bool = true) -> Bool {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FluxNews", isDirectory: true)
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("FluxNews", isDirectory: true)
        let media = Self.mediaRootURL
        do {
            let configuredCore = try Flux.initializeWithDiagnostics(config: InitializationConfig(persistentData: support.path, cache: cache.path, media: media.path, baseUrl: server, apiKey: apiKey, customHeaders: customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }), listener: CoreDiagnosticLogger())
            let settings = try configuredCore.coreSettings()
            let subscription = try configuredCore.subscribeEvents(listener: BrowserEventListener(store: self))
            core = configuredCore
            onCoreConfigured?(configuredCore)
            configuredServer = server
            coreSettings = settings
            eventSubscription = subscription
            NativeLog.app.notice("core configured")
            resetPresentation()
            reloadNavigationAndCounts()
            refreshWidgetSnapshot()
            consumePendingWidgetActions()
            applyStartupScopeIfNeeded()
            reloadVisibleArticles()
            if startSync && syncOnStartEnabled { sync(reason: .appStart) }
            if settings.backgroundSyncEnabled { activatePeriodicSyncScheduling() }
            else { deactivatePeriodicSyncScheduling() }
            if refreshVersion { refreshMinifluxVersion(server: server, apiKey: apiKey, customHeaders: customHeaders, for: configuredCore) }
            return true
        } catch {
            NativeLog.app.error("core configuration failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = NativeErrorPresentation.message(for: error)
            return false
        }
    }

    func saveAccount(server: String, apiKey: String, customHeaders: [CustomHTTPHeader], launchAtLogin: Bool, scrollover: Bool, syncOnStart: Bool, globalShortcut: GlobalShortcutChoice) {
        guard !isSavingAccount else { return }
        isSavingAccount = true
        accountValidationError = nil
        Task { [weak self] in
            let validation = await Task.detached(priority: .userInitiated) {
                Result { try validateMinifluxAccount(serverUrl: server, apiKey: apiKey, customHeaders: customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }) }
            }.value
            guard let self else { return }
            self.isSavingAccount = false
            switch validation {
            case let .success(result):
                self.commitValidatedAccount(result, apiKey: apiKey, customHeaders: customHeaders, launchAtLogin: launchAtLogin, scrollover: scrollover, syncOnStart: syncOnStart, globalShortcut: globalShortcut)
            case let .failure(error):
                self.accountValidationError = AccountValidationPresentation.message(for: accountValidationFailure(for: error))
            }
        }
    }

    private func commitValidatedAccount(_ validation: AccountValidationResult, apiKey: String, customHeaders: [CustomHTTPHeader], launchAtLogin: Bool, scrollover: Bool, syncOnStart: Bool, globalShortcut: GlobalShortcutChoice) {
        do {
            let previousCredentials = try CredentialStore.load()
            invalidateWidgetSnapshot()
            try CredentialStore.save(MinifluxCredentials(server: validation.installationBase, apiKey: apiKey, customHeaders: customHeaders))
            guard configure(server: validation.installationBase, apiKey: apiKey, customHeaders: customHeaders, refreshVersion: false) else {
                do { try restoreCredentials(previousCredentials) }
                catch { accountValidationError = String(localized: "The account could not be saved."); return }
                accountValidationError = String(localized: "The validated account could not be configured. Your previous account is still active.")
                return
            }
            try CredentialStore.setLaunchAtLogin(launchAtLogin)
            setScrolloverEnabled(scrollover)
            setSyncOnStartEnabled(syncOnStart)
            setGlobalShortcut(globalShortcut)
            configuredServer = validation.installationBase
            minifluxVersion = validation.version
            accountValidationError = nil
        } catch {
            accountValidationError = String(localized: "The account could not be saved.")
        }
    }

    private func restoreCredentials(_ credentials: MinifluxCredentials?) throws {
        if let credentials { try CredentialStore.save(credentials) }
        else { try CredentialStore.remove() }
    }

    private func accountValidationFailure(for error: Error) -> AccountValidationFailure {
        switch error {
        case AccountValidationError.InvalidUrl, AccountValidationError.UnsupportedUrlScheme:
            .invalidURL
        case AccountValidationError.Network, AccountValidationError.ServerUnavailable:
            .network
        case AccountValidationError.Unauthorized:
            .unauthorized
        case AccountValidationError.IncompatibleServer:
            .incompatibleServer
        case AccountValidationError.InvalidResponse:
            .invalidResponse
        case AccountValidationError.InvalidCustomHeader:
            .invalidCustomHeader
        default:
            .invalidResponse
        }
    }

    private func refreshMinifluxVersion(server: String, apiKey: String, customHeaders: [CustomHTTPHeader], for configuredCore: Flux) {
        Task { [weak self] in
            let validation = await Task.detached(priority: .utility) {
                try? validateMinifluxAccount(serverUrl: server, apiKey: apiKey, customHeaders: customHeaders.map { HttpHeader(name: $0.name, value: $0.value) })
            }.value
            guard let self, self.core === configuredCore, let validation else { return }
            self.minifluxVersion = validation.version
        }
    }

    var isListeningList: Bool { scope == .listeningList }
    func feedID(forArticleID articleID: Int64) -> Int64? {
        articles.first(where: { $0.id == articleID })?.feedId
            ?? listeningListItems.first(where: { $0.articleId == articleID })?.feedId
    }
    func query(scope: BrowserScope? = nil) -> ArticleQuery {
        let requestedScope = scope ?? self.scope
        let coreScope: ArticleScope = switch requestedScope { case .all, .starred: .all; case .search, .listeningList: fatalError("Scope has no article query"); case let .category(id): .category(id: id); case let .feed(id): .feed(id: id) }
        return ArticleQuery(scope: coreScope, readFilter: self.scope == .starred ? .all : (unreadOnly ? .unread : .all), starredFilter: self.scope == .starred ? .starred : .all, sort: newestFirst ? .newestFirst : .oldestFirst, limit: 0, cursor: nil)
    }
    func reloadVisibleArticles(resetPosition: Bool = false, acknowledgingPendingNewData: Bool = false) {
        if isListeningList { reloadListeningList(); return }
        guard scope != .search else { return }
        guard let core else { return }
        do {
            articles = try core.queryArticles(query: query())
            loadArticleAudioActions(for: articles.map(\.id))
            selectionTotal = try core.countArticles(query: query())
            errorMessage = nil
            if acknowledgingPendingNewData { acknowledgePendingNewDataForCurrentScope() }
            if resetPosition {
                resetPresentation()
                snapshotResetRevision &+= 1
            }
        } catch { errorMessage = NativeErrorPresentation.message(for: error) }
    }
    func reloadSelectionTotal() { guard let core else { return }; do { selectionTotal = try core.countArticles(query: query()); errorMessage = nil } catch { errorMessage = NativeErrorPresentation.message(for: error) } }
    func reloadNavigation() {
        guard let core else { return }
        do {
            catalog = try core.navigationCatalog()
            pendingNewData.removeAbsentFeeds(Set(catalog.feeds.map(\.id)))
            publishPendingNewData()
        } catch { errorMessage = NativeErrorPresentation.message(for: error) }
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
        } catch { errorMessage = NativeErrorPresentation.message(for: error) }
    }
    func reloadNavigationAndCounts() { reloadNavigation(); reloadCounts() }
    func requestFeedIcon(_ feedID: Int64, darkAppearance: Bool) {
        let key = "\(feedID)-\(darkAppearance ? "dark" : "normal")"
        guard feedIconRequests.begin(key, cached: feedIcons[key] != nil), let core else { return }
        let store = WeakBrowserStore(self)
        Task.detached {
            do {
                let variant: FeedIconVariant = darkAppearance ? .dark : .normal
                let icon = try core.feedIcon(feedId: feedID, variant: variant)
                await MainActor.run {
                    guard let store = store.value else { return }
                    if let icon {
                        store.feedIcons[key] = Data(icon.pngData)
                        store.feedIconRequests.complete(key)
                        NativeLog.feedIcon.debug("feed icon available feed_id=\(feedID, privacy: .public) variant=\(darkAppearance ? "dark" : "normal", privacy: .public)")
                    } else {
                        store.feedIconRequests.complete(key)
                        NativeLog.feedIcon.debug("feed icon unavailable feed_id=\(feedID, privacy: .public) variant=\(darkAppearance ? "dark" : "normal", privacy: .public)")
                    }
                }
            } catch {
                await MainActor.run {
                    store.value?.feedIconRequests.complete(key)
                    NativeLog.feedIcon.debug("feed icon request failed feed_id=\(feedID, privacy: .public) variant=\(darkAppearance ? "dark" : "normal", privacy: .public)")
                }
            }
        }
    }
    func articleThumbnailKey(_ article: ArticleSummary) -> String { "\(article.id)-\(article.imageUrl ?? "")" }
    func requestArticleThumbnail(_ article: ArticleSummary) {
        guard let imageURL = article.imageUrl else { return }
        let key = articleThumbnailKey(article)
        guard !unavailableArticleThumbnails.contains(key), articleThumbnailRequests.begin(key, cached: articleThumbnails[key] != nil), let core else { return }
        let store = WeakBrowserStore(self)
        Task.detached {
            do {
                let result = try core.articleThumbnail(articleId: article.id, imageUrl: imageURL)
                let image: NSImage? = if case let .available(pngData) = result { NSImage(data: Data(pngData)) } else { nil }
                await MainActor.run {
                    switch result {
                    case .available:
                        if let image { store.value?.articleThumbnails[key] = image }
                        store.value?.articleThumbnailRequests.complete(key)
                    case .unavailable:
                        store.value?.unavailableArticleThumbnails.insert(key)
                        store.value?.articleThumbnailRequests.complete(key)
                    }
                }
            } catch {
                // Optional thumbnails fail silently and remain retryable on a later presentation.
                _ = await MainActor.run {
                    store.value?.unavailableArticleThumbnails.insert(key)
                    store.value?.articleThumbnailRequests.complete(key)
                }
            }
        }
    }
    func retryUnavailableArticleThumbnail(_ article: ArticleSummary) {
        let key = articleThumbnailKey(article)
        guard unavailableArticleThumbnails.contains(key) else { return }
        unavailableArticleThumbnails.remove(key)
    }
    var isSearchActive: Bool { scope == .search }
    var canLoadMoreSearchResults: Bool { Int64(articles.count) < searchTotal }
    func select(_ scope: BrowserScope) {
        if scope == .search { selectSearch(); return }
        self.scope = scope
        resetPresentation()
        if scope == .listeningList { reloadListeningList() }
        else { reloadVisibleArticles(acknowledgingPendingNewData: true) }
    }
    func setListeningListSort(_ sort: ListeningListSort) {
        guard listeningListSort != sort else { return }
        listeningListSort = sort
        reloadListeningList()
    }
    func setListeningListFeed(_ feedID: Int64?) {
        listeningListFeedID = feedID
        reloadListeningList()
    }
    func reloadListeningList() {
        guard let core else { return }
        do {
            listeningListFeeds = try core.listeningListFeeds()
            listeningListFeedID = ListeningListPresentation.validatedFeedID(listeningListFeedID, feeds: listeningListFeeds)
            listeningListItems = try core.listeningList(feedId: listeningListFeedID, sort: listeningListSort)
            selectionTotal = UInt64(listeningListItems.count)
            errorMessage = nil
        } catch { errorMessage = NativeErrorPresentation.message(for: error) }
    }
    func refreshListeningListIfVisible() {
        guard isListeningList else { return }
        reloadListeningList()
    }
    func selectSearch() {
        guard scope != .search else { return }
        scope = .search
        articles = []
        selectionTotal = 0
        searchQuery = ""
        searchTotal = 0
        hasSearched = false
        isSearching = false
        errorMessage = nil
        searchGeneration &+= 1
        resetPresentation()
    }
    func submitSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration &+= 1
        let generation = searchGeneration
        guard !query.isEmpty else { clearSearch(); return }
        guard let core else { return }
        articles = []
        selectionTotal = 0
        searchTotal = 0
        hasSearched = true
        isSearching = true
        errorMessage = nil
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.searchArticles(request: SearchArticlesRequest(query: query, offset: 0, limit: store.value?.searchPageSize ?? 50)) }
            await MainActor.run {
                guard let store = store.value, store.scope == .search, store.searchGeneration == generation else { return }
                store.isSearching = false
                switch result {
                case let .success(page):
                    store.articles = page.articles
                    store.searchTotal = page.total
                    store.loadArticleAudioActions(for: page.articles.map(\.id))
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func clearSearch() {
        searchGeneration &+= 1
        searchQuery = ""
        articles = []
        selectionTotal = 0
        searchTotal = 0
        hasSearched = false
        isSearching = false
        errorMessage = nil
    }
    func loadMoreSearchResults() {
        guard scope == .search, hasSearched, !isSearching, canLoadMoreSearchResults, let core else { return }
        let generation = searchGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = Int64(articles.count)
        isSearching = true
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.searchArticles(request: SearchArticlesRequest(query: query, offset: offset, limit: store.value?.searchPageSize ?? 50)) }
            await MainActor.run {
                guard let store = store.value, store.scope == .search, store.searchGeneration == generation else { return }
                store.isSearching = false
                switch result {
                case let .success(page):
                    let existing = Set(store.articles.map(\.id))
                    store.articles.append(contentsOf: page.articles.filter { !existing.contains($0.id) })
                    store.searchTotal = page.total
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func route(to route: NavigationRoute) {
        startupRouteState.markExplicitRoute()
        switch route {
        case .all: select(.all)
        case .starred: select(.starred)
        case .category(let id): select(.category(id))
        case .feed(let id): select(.feed(id))
        }
    }
    func handleWidgetAction(_ action: WidgetAction) {
        guard core != nil else { pendingWidgetActions.append(action); return }
        startupRouteState.markExplicitRoute()
        switch action {
        case let .article(id):
            openArticle(id)
        case let .open(selection):
            openWidgetScope(selection)
        case .sync:
            sync(reason: .widget)
        }
    }
    func setUnreadOnly(_ enabled: Bool) { unreadOnly = enabled; resetPresentation(); reloadCounts(); reloadVisibleArticles(acknowledgingPendingNewData: true) }
    func setNewestFirst(_ enabled: Bool) { newestFirst = enabled; resetPresentation(); reloadVisibleArticles(acknowledgingPendingNewData: true) }
    func noteMeaningfulInteraction() { hasMeaningfullyInteracted = true }
    func resetPresentation() { hasMeaningfullyInteracted = false; newDataAvailable = false; listPresentationRevision &+= 1 }
    func setArticleListStyle(_ style: ArticleListStyle) { guard style != articleListStyle else { return }; articleListStyle = style; UserDefaults.standard.set(style.rawValue, forKey: "FluxNews.articleListStyle"); resetPresentation() }
    func applyNewData() { reloadVisibleArticles(resetPosition: true, acknowledgingPendingNewData: true) }
    func requestMediaTransferReconciliation() { onMediaTransferRequested?() }
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
            do {
                let result = try core.sync(reason: reason)
                await MainActor.run {
                    guard let store = store.value else { return }
                    NativeLog.sync.debug("sync completed; reconciling native media work")
                    store.requestMediaTransferReconciliation()
                }
                await SystemNotificationManager.shared.deliver(result.systemNotificationCandidates, core: core)
            }
            catch { await MainActor.run { store.value?.isLoading = false; store.value?.errorMessage = NativeErrorPresentation.message(for: error) } }
        }
    }
    func syncIfStale(reason: SyncReason = .periodic) {
        if lastAutomaticSyncAttempt.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true { sync(reason: reason) }
    }
    func activatePeriodicSyncScheduling() {
        guard core != nil, coreSettings?.backgroundSyncEnabled == true, periodicSyncTimer == nil else { return }
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
        if coreSettings?.backgroundSyncEnabled == true { activatePeriodicSyncScheduling() }
        syncIfStale(reason: .resume)
    }
    private func runPeriodicSync() { sync(reason: .periodic) }
    func setRetention(_ retention: ReadArticleRetention) { updateCoreSettings { try $0.setRetention(retention: retention) } }
    func setDeliveryMode(_ mode: DeliveryMode) { updateCoreSettings { try $0.setDeliveryMode(mode: mode) } }
    func setBackgroundSyncEnabled(_ enabled: Bool) {
        updateCoreSettings(
            { try $0.setBackgroundSyncEnabled(enabled: enabled) },
            afterSuccess: { [weak self] in
                if enabled { self?.activatePeriodicSyncScheduling() }
                else { self?.deactivatePeriodicSyncScheduling() }
            }
        )
    }
    func setDetailCharacterLimit(_ limit: UInt32) { updateCoreSettings { try $0.setDetailCharacterLimit(limit: limit) } }
    func setDeleteAfterPlayback(_ enabled: Bool) { updateCoreSettings { try $0.setDeleteAfterPlayback(enabled: enabled) } }
    func setAutoDownloadListeningList(_ enabled: Bool) { updateCoreSettings { try $0.setAutoDownloadListeningList(enabled: enabled) } }
    func setRemoveCompletedListeningList(_ enabled: Bool) { updateCoreSettings { try $0.setRemoveCompletedListeningList(enabled: enabled) } }
    func reloadSystemNotificationSettings() {
        guard let core else { return }
        do {
            systemNotificationSettings = try core.feedSystemNotificationSettings()
            systemNotificationSettingsError = nil
        } catch {
            systemNotificationSettingsError = NativeErrorPresentation.message(for: error)
        }
    }
    func setSystemNotificationsEnabled(feedID: Int64, enabled: Bool) {
        guard let core, !updatingSystemNotificationFeedIDs.contains(feedID) else { return }
        updatingSystemNotificationFeedIDs.insert(feedID)
        systemNotificationSettingsError = nil
        let store = WeakBrowserStore(self)
        Task.detached {
            do {
                if enabled { try await SystemNotificationManager.shared.ensureAuthorization() }
                try core.setFeedSystemNotificationsEnabled(feedId: feedID, enabled: enabled)
                let settings = try core.feedSystemNotificationSettings()
                await MainActor.run {
                    guard let store = store.value else { return }
                    store.updatingSystemNotificationFeedIDs.remove(feedID)
                    store.systemNotificationSettings = settings
                }
            } catch {
                await MainActor.run {
                    guard let store = store.value else { return }
                    store.updatingSystemNotificationFeedIDs.remove(feedID)
                    store.systemNotificationSettingsError = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func selectNotificationFeed(_ feedID: Int64) {
        startupRouteState.markExplicitRoute()
        select(.feed(feedID))
    }
    private func updateCoreSettings(_ update: @escaping (Flux) throws -> Void, afterSuccess: @escaping () -> Void = {}) {
        guard let core else { return }
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result {
                try update(core)
                return try core.coreSettings()
            }
            await MainActor.run {
                switch result {
                case let .success(settings):
                    store.value?.coreSettings = settings
                    afterSuccess()
                case let .failure(error): store.value?.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func handle(event: CoreEvent) {
        switch event {
        case .articleReadStateChanged, .articleStarredStateChanged:
            refreshWidgetSnapshot()
            return
        case let .syncCompleted(metadata):
            refreshWidgetSnapshot()
            handleSyncCompleted(metadata)
        default:
            return
        }
    }
    private func handleSyncCompleted(_ metadata: SyncCompleted) {
        isLoading = false
        refreshListeningListIfVisible()
        reloadLiveUnreadTotal()
        if metadata.reason == .background || metadata.reason == .periodic {
            pendingNewData.accumulate(metadata.newArticlesByFeed.map { (feedID: $0.feedId, count: $0.count) })
            publishPendingNewData()
        }
        if metadata.navigationChanged { reloadNavigationAndCounts() }
        else if metadata.reason == .manual { reloadCounts() }
        else if metadata.dataChanged { reloadCounts() }
        if metadata.reason == .periodic { NativeLog.sync.notice("periodic sync completed") }
        let action: SnapshotRefreshPolicy.Action = if metadata.reason == .background || metadata.reason == .periodic {
            metadata.dataChanged ? .signalNewData : .preserve
        } else {
            SnapshotRefreshPolicy.action(manual: metadata.reason == .manual, dataChanged: metadata.dataChanged, hasMeaningfullyInteracted: hasMeaningfullyInteracted)
        }
        switch action {
        case .replace:
            reloadVisibleArticles(resetPosition: true, acknowledgingPendingNewData: metadata.reason == .manual)
        case .signalNewData:
            newDataAvailable = true
        case .preserve:
            break
        }
    }
    private func reloadLiveUnreadTotal() {
        guard let core else { return }
        do {
            unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
        } catch {
            NativeLog.sync.error("live unread count refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func acknowledgePendingNewDataForCurrentScope() {
        switch scope {
        case .all:
            pendingNewData.adoptAll()
        case let .category(categoryID):
            pendingNewData.adoptFeeds(in: Set(catalog.feeds.filter { $0.categoryId == categoryID }.map(\.id)))
        case let .feed(feedID):
            pendingNewData.adoptFeed(feedID)
        case .starred, .search, .listeningList:
            return
        }
        publishPendingNewData()
    }
    private func publishPendingNewData() {
        pendingNewByFeed = pendingNewData.byFeed
        hasPendingNewData = pendingNewData.hasPending
    }
    func setRead(_ article: ArticleSummary, _ read: Bool) {
        guard let core else { return }
        if scope == .search {
            let store = WeakBrowserStore(self)
            Task.detached {
                let result = Result { try core.searchSetReadState(articleId: article.id, read: read) }
                await MainActor.run {
                    switch result {
                    case let .success(disposition):
                        store.value?.updateVisibleRead([article.id], read: read)
                        if case .localFirst = disposition { store.value?.reloadCounts() }
                    case let .failure(error): store.value?.errorMessage = NativeErrorPresentation.message(for: error)
                    }
                }
            }
            return
        }
        do { _ = try core.setReadState(articleId: article.id, read: read); updateVisibleRead([article.id], read: read); reloadSelectionTotal(); reloadCounts() } catch { errorMessage = NativeErrorPresentation.message(for: error) }
    }
    func setStarred(_ article: ArticleSummary, _ starred: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let core else { completion?(false); return }
        if scope == .search {
            let store = WeakBrowserStore(self)
            Task.detached {
                let result = Result { try core.searchSetStarredState(articleId: article.id, starred: starred) }
                await MainActor.run {
                    switch result {
                    case let .success(disposition):
                        store.value?.updateVisible([article.id]) { $0.isStarred = starred }
                        if case .localFirst = disposition { store.value?.reloadCounts() }
                        completion?(true)
                    case let .failure(error): store.value?.errorMessage = NativeErrorPresentation.message(for: error); completion?(false)
                    }
                }
            }
            return
        }
        do { _ = try core.setStarredState(articleId: article.id, starred: starred); updateVisible([article.id]) { $0.isStarred = starred }; reloadSelectionTotal(); reloadCounts(); completion?(true) } catch { errorMessage = NativeErrorPresentation.message(for: error); completion?(false) }
    }
    func loadReaderDocument(_ article: ArticleSummary, completion: @escaping (Result<ReaderDocument, Error>) -> Void) {
        loadReaderDocument(articleID: article.id, completion: completion)
    }
    func loadReaderDocument(articleID: Int64, completion: @escaping (Result<ReaderDocument, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        readerDocumentRequest &+= 1
        let request = readerDocumentRequest
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.readerDocument(articleId: articleID) }
            await MainActor.run {
                guard let store = store.value, store.readerDocumentRequest == request else { return }
                completion(result)
            }
        }
    }
    func loadArticleAudioActions(for articleID: Int64) {
        loadArticleAudioActions(for: [articleID], selectedArticleID: articleID)
    }
    func loadArticleAudioActions(for articleIDs: [Int64], selectedArticleID: Int64? = nil) {
        articleAudioRequestGeneration &+= 1
        let generation = articleAudioRequestGeneration
        articleAudioActionState = nil
        guard let core else { return }
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result {
                try core.articleAudioActionStates(articleIds: articleIDs).reduce(into: [Int64: ArticleAudioActionState]()) { result, state in
                    result[state.articleId] = ArticleAudioActionState(articleID: state.articleId, enclosures: ArticleAudioActions.audioEnclosures(state.enclosures), isInListeningList: state.isInListeningList, downloads: Dictionary(uniqueKeysWithValues: state.downloads.map { ($0.enclosureId, $0) }))
                }
            }
            await MainActor.run {
                guard let store = store.value, store.articleAudioRequestGeneration == generation else { return }
                switch result {
                case let .success(states):
                    store.articleAudioActionStates.merge(states) { _, new in new }
                    if let selectedArticleID { store.articleAudioActionState = states[selectedArticleID] }
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func refreshArticleAudioActions() {
        guard let articleID = articleAudioActionState?.articleID else { return }
        loadArticleAudioActions(for: articleID)
    }
    func selectArticleAudioActions(for articleID: Int64?) {
        articleAudioActionState = articleID.flatMap { articleAudioActionStates[$0] }
    }
    func addToListeningList(articleID: Int64) {
        guard let core else { return }
        let generation = articleAudioRequestGeneration
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.addToListeningList(articleId: articleID) }
            await MainActor.run {
                guard let store = store.value else { return }
                switch result {
                case .success:
                    store.showActionConfirmation(String(localized: "Added to Listening List"))
                    store.onMediaTransferRequested?()
                    store.refreshListeningListIfVisible()
                    guard store.articleAudioRequestGeneration == generation else { return }
                    store.loadArticleAudioActions(for: articleID)
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func requestManualDownload(articleID: Int64, enclosureID: Int64) {
        guard let core else { return }
        let refreshArticleActions = articleAudioActionState?.articleID == articleID
        let generation = articleAudioRequestGeneration
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.requestDownload(enclosureId: enclosureID, origin: .manual) }
            await MainActor.run {
                guard let store = store.value else { return }
                switch result {
                case .success:
                    store.showActionConfirmation(String(localized: "Download requested"))
                    store.onMediaTransferRequested?()
                    store.refreshListeningListIfVisible()
                    if refreshArticleActions, store.articleAudioRequestGeneration == generation {
                        store.loadArticleAudioActions(for: articleID)
                    }
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func removeFromListeningList(articleID: Int64) {
        guard let core else { return }
        let refreshArticleActions = articleAudioActionState?.articleID == articleID
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.removeFromListeningList(articleId: articleID) }
            await MainActor.run {
                guard let store = store.value else { return }
                switch result {
                case .success:
                    store.showActionConfirmation(String(localized: "Removed from Listening List"))
                    store.onMediaTransferRequested?()
                    store.refreshListeningListIfVisible()
                    if refreshArticleActions { store.refreshArticleAudioActions() }
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func deleteDownload(articleID: Int64, enclosureID: Int64) {
        guard let core else { return }
        let refreshArticleActions = articleAudioActionState?.articleID == articleID
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.requestDownloadDeletion(enclosureId: enclosureID) }
            await MainActor.run {
                guard let store = store.value else { return }
                switch result {
                case .success:
                    store.showActionConfirmation(String(localized: "Download deletion requested"))
                    store.onMediaTransferRequested?()
                    store.refreshListeningListIfVisible()
                    if refreshArticleActions { store.refreshArticleAudioActions() }
                case let .failure(error): store.errorMessage = NativeErrorPresentation.message(for: error)
                }
            }
        }
    }
    func saveToService(_ article: ArticleSummary) {
        guard let core else { return }
        let store = WeakBrowserStore(self)
        Task.detached {
            do {
                let result = try core.saveToService(articleId: article.id)
                await MainActor.run {
                    switch result {
                    case .saved:
                        store.value?.showActionConfirmation(String(localized: "Saved to third-party service"))
                    case .noIntegrationConfigured:
                        store.value?.showActionConfirmation(String(localized: "No third-party integration is configured in Miniflux"))
                    }
                }
            } catch {
                await MainActor.run { store.value?.errorMessage = NativeErrorPresentation.message(for: error) }
            }
        }
    }
    func discoverSubscriptions(_ request: DiscoverSubscriptionsRequest, completion: @escaping (Result<[DiscoveredSubscription], Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        Task.detached {
            let result = Result { try core.discoverSubscriptions(request: request) }
            await MainActor.run { completion(result) }
        }
    }
    func createFeed(_ request: CreateFeedRequest, completion: @escaping (Result<CreateFeedResult, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        Task.detached {
            let result = Result { try core.createFeed(request: request) }
            await MainActor.run { completion(result) }
        }
    }
    func createCategory(_ title: String, completion: @escaping (Result<CreateCategoryResult, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        Task.detached {
            let result = Result { try core.createCategory(title: title) }
            await MainActor.run { completion(result) }
        }
    }
    func beginScrolloverUndoBatch() {
        scrolloverUndoBatch.beginScroll()
        scrolloverRemovedArticles = [:]
        scrolloverOriginalOrder = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
    }
    func finishScrolloverUndoBatch() {
        guard scrolloverCountsPending else { return }
        scrolloverCountsPending = false
        reloadScrolloverCounts()
    }
    func flushScrollover(_ ids: [Int64]) {
        guard let core, !ids.isEmpty else { return }
        let started = ContinuousClock.now
        do {
            _ = try core.setReadStateBulk(articleIds: ids, read: true)
            let elapsed = started.duration(to: .now)
            if elapsed >= .milliseconds(8) {
                let components = elapsed.components
                let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
                NativeLog.scrollover.debug("scrollover mutation elapsed_ms=\(milliseconds, privacy: .public) ids=\(ids.count, privacy: .public)")
            }
            lastScrolloverBatch = scrolloverUndoBatch.append(ids)
            updateVisibleRead(ids, read: true, retainingForScrolloverUndo: true)
            scrolloverCountsPending = true
            showScrolloverUndo()
        } catch { errorMessage = NativeErrorPresentation.message(for: error) }
    }
    func undoScrollover() { guard let core, !lastScrolloverBatch.isEmpty else { return }; do { _ = try core.setReadStateBulk(articleIds: lastScrolloverBatch, read: false); updateVisibleRead(lastScrolloverBatch, read: false); restoreScrolloverRemovedArticles(); scrolloverUndoBatch.clear(); lastScrolloverBatch = []; scrolloverUndoVisible = false; undoExpiry?.cancel(); reloadSelectionTotal(); reloadCounts() } catch { errorMessage = NativeErrorPresentation.message(for: error) } }
    func setScrolloverEnabled(_ enabled: Bool) { markReadOnScrolloverEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "FluxNews.markReadOnScrollover") }
    func setStartupScope(_ preference: StartupScopePreference) {
        startupScope = preference
        if preference == .category, startupCategoryID == nil { startupCategoryID = catalog.categories.first?.id }
        if preference == .feed, startupFeedID == nil { startupFeedID = catalog.feeds.first?.id }
        UserDefaults.standard.set(preference.rawValue, forKey: "FluxNews.startupScope")
        persistStartupTargets()
    }
    func setStartupCategoryID(_ id: Int64?) { startupCategoryID = id; persistStartupTargets() }
    func setStartupFeedID(_ id: Int64?) { startupFeedID = id; persistStartupTargets() }
    func setHideEmptyNavigationEntries(_ enabled: Bool) { hideEmptyNavigationEntries = enabled; UserDefaults.standard.set(enabled, forKey: "FluxNews.hideEmptyNavigationEntries") }
    func setRemoveArticlesWhenMarkedRead(_ enabled: Bool) { removeArticlesWhenMarkedRead = enabled; UserDefaults.standard.set(enabled, forKey: "FluxNews.removeArticlesWhenMarkedRead") }
    func setSyncOnStartEnabled(_ enabled: Bool) { syncOnStartEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "FluxNews.syncOnStart") }
    func setArticlePreviewLines(_ lines: ArticlePreviewLines) { articlePreviewLines = lines; UserDefaults.standard.set(lines.rawValue, forKey: "FluxNews.articlePreviewLines") }
    func setClickOnNews(_ preference: ClickOnNews) { clickOnNews = preference; UserDefaults.standard.set(preference.rawValue, forKey: "FluxNews.clickOnNews") }
    func setGlobalShortcut(_ shortcut: GlobalShortcutChoice) { guard shortcut != globalShortcut else { return }; globalShortcut = shortcut; shortcut.store() }
    func exportConfigurationBackup(password: String) throws -> Data {
        guard let core else { throw ConfigurationBackupPresentationError.noConfiguredAccount }
        guard let credentials = try CredentialStore.load() else { throw ConfigurationBackupPresentationError.noConfiguredAccount }
        let snapshot = try core.configurationSnapshot()
        let payload = try JSONEncoder().encode(nativeBackupSettings(customHeaders: credentials.resolvedCustomHeaders))
        let input = ConfigBackupInput(
            platform: .macos,
            account: BackupAccount(installationBase: snapshot.installationBase, apiKey: credentials.apiKey),
            coreSettings: snapshot.coreSettings,
            feedPreferences: snapshot.feedPreferences,
            platformSettings: PlatformSettingsPayload(schemaVersion: MacOSBackupSettingsV1.version, dataJson: String(decoding: payload, as: UTF8.self))
        )
        return Data(try exportConfigBackup(input: input, password: password))
    }
    func importConfigurationBackup(bytes: Data, password: String) async throws -> BackupImportOutcome {
        let restored = try await Task.detached(priority: .userInitiated) {
            try parseConfigBackup(bytes: bytes, password: password, expectedPlatform: .macos)
        }.value
        guard restored.platformSettings.schemaVersion == MacOSBackupSettingsV1.version else {
            throw ConfigurationBackupPresentationError.unsupportedPlatformSettings
        }
        let native = try JSONDecoder().decode(MacOSBackupSettingsV1.self, from: Data(restored.platformSettings.dataJson.utf8))
        guard native.version == MacOSBackupSettingsV1.version else {
            throw ConfigurationBackupPresentationError.unsupportedPlatformSettings
        }
        guard let core else { throw ConfigurationBackupPresentationError.noConfiguredAccount }
        let previousSnapshot = try core.configurationSnapshot()
        let previousCredentials = try CredentialStore.load()
        let previousNative = nativeBackupSettings(customHeaders: previousCredentials?.resolvedCustomHeaders ?? [])
        do {
            invalidateWidgetSnapshot()
            try core.replaceConfiguration(installationBase: restored.account.installationBase, coreSettings: restored.coreSettings, feedPreferences: restored.feedPreferences)
            let customHeaders = native.customHeaders ?? []
            try CredentialStore.save(MinifluxCredentials(server: restored.account.installationBase, apiKey: restored.account.apiKey, customHeaders: customHeaders))
            guard configure(server: restored.account.installationBase, apiKey: restored.account.apiKey, customHeaders: customHeaders, refreshVersion: false, startSync: false) else {
                throw ConfigurationBackupPresentationError.coreInitialization
            }
            try applyNativeBackupSettings(native)
        } catch {
            try? core.replaceConfiguration(installationBase: previousSnapshot.installationBase, coreSettings: previousSnapshot.coreSettings, feedPreferences: previousSnapshot.feedPreferences)
            try? restoreCredentials(previousCredentials)
            _ = configure(server: previousSnapshot.installationBase, apiKey: previousCredentials?.apiKey ?? "", customHeaders: previousCredentials?.resolvedCustomHeaders ?? [], refreshVersion: false, startSync: false)
            try? applyNativeBackupSettings(previousNative)
            throw error
        }
        invalidateLocalPresentation()
        return await syncAfterImport()
    }
    func rebuildLocalState() {
        guard let core, !isLoading else { return }
        invalidateWidgetSnapshot()
        isLoading = true
        let store = WeakBrowserStore(self)
        Task.detached {
            let result = Result { try core.rebuildLocalState() }
            await MainActor.run {
                guard let store = store.value else { return }
                store.invalidateLocalPresentation()
                store.isLoading = false
                switch result {
                case .success: store.showActionConfirmation(String(localized: "Local state rebuilt"))
                case .failure: store.errorMessage = String(localized: "Local state was cleared, but synchronization could not be completed.")
                }
            }
        }
    }
    func resetFluxNews() {
        guard let core else { return }
        do {
            try core.resetCoreState()
            try CredentialStore.remove()
            try CredentialStore.setLaunchAtLogin(false)
            resetNativeSettings()
            eventSubscription = nil
            self.core = nil
            configuredServer = nil
            minifluxVersion = nil
            coreSettings = nil
            deactivatePeriodicSyncScheduling()
            invalidateWidgetSnapshot()
            invalidateLocalPresentation()
            showActionConfirmation(String(localized: "FluxNews was reset"))
            settingsVisible = true
        } catch {
            errorMessage = String(localized: "FluxNews could not be fully reset.")
        }
    }
    var onInvalidateContent: (() -> Void)?
    private func syncAfterImport() async -> BackupImportOutcome {
        guard let core else { return .synchronizationFailed }
        isLoading = true
        let result = await Task.detached {
            Result { try core.sync(reason: .manual) }
        }.value
        isLoading = false
        switch result {
        case .success:
            return .synchronized
        case .failure:
            return .synchronizationFailed
        }
    }
    private func invalidateLocalPresentation() {
        articles = []
        catalog = NavigationCatalog(categories: [], feeds: [])
        unreadTotal = 0
        starredTotal = 0
        selectionTotal = 0
        categorySidebarCounts = [:]
        feedSidebarCounts = [:]
        feedIcons = [:]
        articleThumbnails = [:]
        unavailableArticleThumbnails = []
        pendingNewData = PendingNewData()
        publishPendingNewData()
        clearSearch()
        onInvalidateContent?()
        resetPresentation()
        snapshotResetRevision &+= 1
    }
    private func refreshWidgetSnapshot() {
        guard let core else {
            WidgetSnapshotDiagnostics.logger.error("Widget snapshot refresh skipped because Flux core is unavailable")
            return
        }
        Task.detached {
            let store: WidgetSnapshotStore
            do {
                store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            } catch {
                WidgetSnapshotDiagnostics.logger.error("Widget snapshot refresh could not resolve App Group container error=\(error.localizedDescription, privacy: .public)")
                return
            }
            do {
                try WidgetSnapshotWriter.refresh(core: core, store: store)
                WidgetSnapshotDiagnostics.logger.notice("Widget snapshot refresh succeeded path=\(store.snapshotPath, privacy: .public)")
                WidgetTimelineReloader.reloadAll()
            } catch {
                WidgetSnapshotDiagnostics.logger.error("Widget snapshot refresh failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
    private func invalidateWidgetSnapshot() {
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            try store.invalidate()
            WidgetSnapshotDiagnostics.logger.notice("Widget snapshot invalidated path=\(store.snapshotPath, privacy: .public)")
            WidgetTimelineReloader.reloadAll()
        } catch {
            WidgetSnapshotDiagnostics.logger.error("Widget snapshot invalidation failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
    private func nativeBackupSettings(customHeaders: [CustomHTTPHeader] = []) -> MacOSBackupSettingsV1 {
        MacOSBackupSettingsV1(
            version: MacOSBackupSettingsV1.version,
            markReadOnScrollover: markReadOnScrolloverEnabled,
            syncOnStart: syncOnStartEnabled,
            articleListStyle: articleListStyle.rawValue,
            previewLines: articlePreviewLines.rawValue,
            clickOnNews: clickOnNews.rawValue,
            globalShortcut: globalShortcut.rawValue,
            launchAtLogin: CredentialStore.launchAtLoginEnabled,
            startupScope: startupScope.rawValue,
            startupCategoryID: startupCategoryID,
            startupFeedID: startupFeedID,
            hideEmptyNavigationEntries: hideEmptyNavigationEntries,
            removeArticlesWhenMarkedRead: removeArticlesWhenMarkedRead,
            customHeaders: customHeaders
        )
    }
    private func applyNativeBackupSettings(_ settings: MacOSBackupSettingsV1) throws {
        try CredentialStore.setLaunchAtLogin(settings.launchAtLogin)
        setScrolloverEnabled(settings.markReadOnScrollover)
        setSyncOnStartEnabled(settings.syncOnStart)
        setArticleListStyle(ArticleListStyle(rawValue: settings.articleListStyle) ?? .row)
        setArticlePreviewLines(ArticlePreviewLines(rawValue: settings.previewLines) ?? .standard)
        setClickOnNews(ClickOnNews(rawValue: settings.clickOnNews) ?? .openLink)
        setGlobalShortcut(GlobalShortcutChoice(rawValue: settings.globalShortcut) ?? .optionCommandF)
        setStartupScope(StartupScopePreference(rawValue: settings.startupScope ?? "") ?? .allNews)
        setStartupCategoryID(settings.startupCategoryID)
        setStartupFeedID(settings.startupFeedID)
        setHideEmptyNavigationEntries(settings.hideEmptyNavigationEntries ?? false)
        setRemoveArticlesWhenMarkedRead(settings.removeArticlesWhenMarkedRead ?? false)
    }
    private func resetNativeSettings() {
        try? CredentialStore.setLaunchAtLogin(false)
        setScrolloverEnabled(true)
        setSyncOnStartEnabled(true)
        setArticleListStyle(.row)
        setArticlePreviewLines(.standard)
        setClickOnNews(.openLink)
        setGlobalShortcut(.optionCommandF)
        setStartupScope(.allNews)
        setStartupCategoryID(nil)
        setStartupFeedID(nil)
        setHideEmptyNavigationEntries(false)
        setRemoveArticlesWhenMarkedRead(false)
    }
    func open(_ article: ArticleSummary) {
        setRead(article, true)
        let prefersMiniflux = (try? core?.feedPreferences(feedId: article.feedId).openInMiniflux) ?? false
        switch ArticleOpenRouting.action(clickOnNews: clickOnNews, openInMiniflux: prefersMiniflux) {
        case .detail: openDetail(article)
        case .original: openOriginal(article)
        case .miniflux: openInMiniflux(article)
        }
    }
    private func openArticle(_ articleID: Int64) {
        guard let core else { return }
        do {
            let query = ArticleQuery(scope: .all, readFilter: .all, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil)
            guard let article = try core.queryArticles(query: query).first(where: { $0.id == articleID }) else { return }
            open(article)
        } catch {
            errorMessage = NativeErrorPresentation.message(for: error)
        }
    }
    private func openWidgetScope(_ selection: WidgetContentSelection) {
        switch selection.scope {
        case .allNews:
            unreadOnly = true
            select(.all)
        case .bookmarks:
            select(.starred)
        case .category:
            guard let id = selection.categoryID, catalog.categories.contains(where: { $0.id == id }) else { return }
            unreadOnly = true
            select(.category(id))
        case .feed:
            guard let id = selection.feedID, catalog.feeds.contains(where: { $0.id == id }) else { return }
            unreadOnly = true
            select(.feed(id))
        }
    }
    private func consumePendingWidgetActions() {
        let actions = pendingWidgetActions
        pendingWidgetActions.removeAll()
        actions.forEach(handleWidgetAction)
    }
    var onOpenDetail: ((ArticleSummary, Bool) -> Void)?
    func openDetail(_ article: ArticleSummary, togglesPreview: Bool = false) { onOpenDetail?(article, togglesPreview) }
    func openOriginal(_ article: ArticleSummary) { if let url = URL(string: article.url) { NSWorkspace.shared.open(url) } }
    func openComments(_ article: ArticleSummary) { if let url = URL(string: article.commentsUrl), !article.commentsUrl.isEmpty { NSWorkspace.shared.open(url) } }
    func openInMiniflux(_ article: ArticleSummary) {
        guard let core, let url = MinifluxEntryURL.resolve(articleID: article.id, using: core.minifluxEntryUrl) else {
            errorMessage = String(localized: "Flux could not resolve the Miniflux entry URL.")
            return
        }
        NSWorkspace.shared.open(url)
    }
    func copyLink(_ article: ArticleSummary) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(article.url, forType: .string) }
    func feedPreferences(feedID: Int64) throws -> FeedPreferences { guard let core else { throw NSError(domain: "FluxNews", code: 1) }; return try core.feedPreferences(feedId: feedID) }
    func setFeedDetailRendering(feedID: Int64, mode: DetailRenderingMode) throws { try core?.setFeedDetailRendering(feedId: feedID, mode: mode) }
    func setFeedTruncateDetail(feedID: Int64, enabled: Bool) throws { try core?.setFeedTruncateDetail(feedId: feedID, enabled: enabled) }
    func setFeedOpenInMiniflux(feedID: Int64, enabled: Bool) throws { try core?.setFeedOpenInMiniflux(feedId: feedID, enabled: enabled) }
    func setFeedAutoDownloadAudio(feedID: Int64, enabled: Bool) throws { try core?.setFeedAutoDownloadAudio(feedId: feedID, enabled: enabled) }
    func share(_ article: ArticleSummary) { guard let url = URL(string: article.url) else { return }; DispatchQueue.main.async { [weak self] in guard let self, let view = NSApplication.shared.keyWindow?.contentView else { return }; let picker = NSSharingServicePicker(items: [article.title, url]); self.sharingPicker = picker; let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil); picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY) } }
    func showActionConfirmation(_ message: String) {
        actionConfirmation = message
        actionConfirmationExpiry?.cancel()
        actionConfirmationExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.actionConfirmation == message else { return }
            self?.actionConfirmation = nil
        }
    }
    private func applyStartupScopeIfNeeded() {
        guard !hasAppliedStartupScope else { return }
        hasAppliedStartupScope = true
        guard startupRouteState.shouldApplyStartupScope else { return }
        let resolved = StartupScopeResolver.resolve(startupScope, categoryID: startupCategoryID, feedID: startupFeedID, categoryIDs: Set(catalog.categories.map(\.id)), feedIDs: Set(catalog.feeds.map(\.id)))
        if resolved == .all && (startupScope == .category || startupScope == .feed) {
            if startupScope == .category { startupCategoryID = nil }
            if startupScope == .feed { startupFeedID = nil }
            startupScope = .allNews
            UserDefaults.standard.set(StartupScopePreference.allNews.rawValue, forKey: "FluxNews.startupScope")
            persistStartupTargets()
        }
        scope = resolved
    }
    private func persistStartupTargets() {
        if let startupCategoryID { UserDefaults.standard.set(startupCategoryID, forKey: "FluxNews.startupCategoryID") }
        else { UserDefaults.standard.removeObject(forKey: "FluxNews.startupCategoryID") }
        if let startupFeedID { UserDefaults.standard.set(startupFeedID, forKey: "FluxNews.startupFeedID") }
        else { UserDefaults.standard.removeObject(forKey: "FluxNews.startupFeedID") }
    }
    private func updateVisibleRead(_ ids: [Int64], read: Bool, retainingForScrolloverUndo: Bool = false) {
        let ids = Set(ids)
        if read && ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: removeArticlesWhenMarkedRead, unreadOnly: unreadOnly, scope: scope) {
            if retainingForScrolloverUndo {
                for article in articles where ids.contains(article.id) { scrolloverRemovedArticles[article.id] = article }
            }
            articles.removeAll { ids.contains($0.id) }
        } else {
            updateVisible(Array(ids)) { $0.isRead = read }
        }
    }
    private func restoreScrolloverRemovedArticles() {
        guard !scrolloverRemovedArticles.isEmpty else { return }
        let visibleIDs = Set(articles.map(\.id))
        articles.append(contentsOf: scrolloverRemovedArticles.values.filter { !visibleIDs.contains($0.id) })
        articles.sort { scrolloverOriginalOrder[$0.id, default: .max] < scrolloverOriginalOrder[$1.id, default: .max] }
        scrolloverRemovedArticles = [:]
        scrolloverOriginalOrder = [:]
    }
    private func updateVisible(_ ids: [Int64], _ change: (inout ArticleSummary) -> Void) { let ids = Set(ids); for index in articles.indices where ids.contains(articles[index].id) { change(&articles[index]) } }
    private func reloadScrolloverCounts() {
        guard let core else { return }
        let selectionQuery = query()
        let categoryIDs = catalog.categories.map(\.id)
        let feedIDs = catalog.feeds.map(\.id)
        let categoryQueries = categoryIDs.map { (id: $0, query: query(scope: .category($0))) }
        let feedQueries = feedIDs.map { (id: $0, query: query(scope: .feed($0))) }
        let store = WeakBrowserStore(self)
        Task.detached {
            do {
                let started = ContinuousClock.now
                let selectionTotal = try core.countArticles(query: selectionQuery)
                let unreadTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .unread, starredFilter: .all, sort: .newestFirst, limit: 0, cursor: nil))
                let starredTotal = try core.countArticles(query: ArticleQuery(scope: .all, readFilter: .all, starredFilter: .starred, sort: .newestFirst, limit: 0, cursor: nil))
                var categoryCounts: [Int64: UInt64] = [:]
                var feedCounts: [Int64: UInt64] = [:]
                for item in categoryQueries { categoryCounts[item.id] = try core.countArticles(query: item.query) }
                for item in feedQueries { feedCounts[item.id] = try core.countArticles(query: item.query) }
                let elapsed = started.duration(to: .now)
                if elapsed >= .milliseconds(8) {
                    let components = elapsed.components
                    let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
                    NativeLog.scrollover.debug("scrollover count refresh elapsed_ms=\(milliseconds, privacy: .public) queries=\(categoryIDs.count + feedIDs.count + 3, privacy: .public)")
                }
                let categoryCountsSnapshot = categoryCounts
                let feedCountsSnapshot = feedCounts
                await MainActor.run {
                    guard let store = store.value else { return }
                    store.selectionTotal = selectionTotal
                    store.unreadTotal = unreadTotal
                    store.starredTotal = starredTotal
                    store.categorySidebarCounts = categoryCountsSnapshot
                    store.feedSidebarCounts = feedCountsSnapshot
                }
            } catch {
                await MainActor.run { store.value?.errorMessage = NativeErrorPresentation.message(for: error) }
            }
        }
    }
    private func showScrolloverUndo() {
        guard scrolloverUndoBatch.showsUndo else {
            scrolloverUndoVisible = false
            undoExpiry?.cancel()
            return
        }
        scrolloverUndoVisible = true
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; self?.scrolloverUndoVisible = false }
    }
}

enum AddFeedOptionalBoolean: String, CaseIterable, Identifiable {
    case serverDefault, enabled, disabled

    var id: Self { self }
    var value: Bool? {
        switch self {
        case .serverDefault: nil
        case .enabled: true
        case .disabled: false
        }
    }
    var title: String {
        switch self {
        case .serverDefault: String(localized: "Use Miniflux default")
        case .enabled: String(localized: "Enabled")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct AddFeedForm {
    var url = ""
    var categoryID: Int64?
    var username = ""
    var password = ""
    var userAgent = ""
    var scraperRules = ""
    var rewriteRules = ""
    var blocklistRules = ""
    var keeplistRules = ""
    var crawler: AddFeedOptionalBoolean = .serverDefault
    var disabled: AddFeedOptionalBoolean = .serverDefault
    var ignoreHttpCache: AddFeedOptionalBoolean = .serverDefault
    var fetchViaProxy: AddFeedOptionalBoolean = .serverDefault

    func discoveryRequest() -> DiscoverSubscriptionsRequest {
        DiscoverSubscriptionsRequest(
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: optional(username),
            password: optional(password),
            userAgent: optional(userAgent),
            fetchViaProxy: fetchViaProxy.value
        )
    }
    func createRequest(feedURL: String) -> CreateFeedRequest {
        CreateFeedRequest(
            feedUrl: feedURL,
            categoryId: categoryID,
            username: optional(username),
            password: optional(password),
            crawler: crawler.value,
            userAgent: optional(userAgent),
            scraperRules: optional(scraperRules),
            rewriteRules: optional(rewriteRules),
            blocklistRules: optional(blocklistRules),
            keeplistRules: optional(keeplistRules),
            disabled: disabled.value,
            ignoreHttpCache: ignoreHttpCache.value,
            fetchViaProxy: fetchViaProxy.value
        )
    }
    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AddFeedDiscoveryOutcome: Equatable {
    case none
    case automatic(DiscoveredSubscription)
    case choose

    static func from(_ candidates: [DiscoveredSubscription]) -> Self {
        switch candidates.count {
        case 0: .none
        case 1: .automatic(candidates[0])
        default: .choose
        }
    }
}

private final class WeakBrowserStore: @unchecked Sendable { weak var value: BrowserStore?; init(_ value: BrowserStore) { self.value = value } }
private final class BrowserEventListener: EventListener, @unchecked Sendable { weak var store: BrowserStore?; init(store: BrowserStore) { self.store = store }; func onEvent(event: CoreEvent) { Task { @MainActor [weak store] in store?.handle(event: event) } } }

final class SystemNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationManager()

    private enum PayloadKey {
        static let candidateID = "flux.systemNotificationCandidateID"
        static let feedID = "flux.systemNotificationFeedID"
    }

    var onFeedSelected: ((Int64) -> Void)?

    func configure() { UNUserNotificationCenter.current().delegate = self }

    func ensureAuthorization() async throws {
        let center = UNUserNotificationCenter.current()
        switch (await center.notificationSettings()).authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            throw SystemNotificationError.authorizationDenied
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert]) else {
                throw SystemNotificationError.authorizationDenied
            }
        @unknown default:
            throw SystemNotificationError.authorizationDenied
        }
    }

    func deliver(_ candidates: [SystemNotificationCandidate], core: Flux) async {
        for candidate in candidates {
            do {
                try await add(candidate)
                try core.acknowledgeSystemNotification(candidateId: candidate.candidateId)
            } catch {
                NativeLog.notification.error("system notification delivery failed candidate_id=\(candidate.candidateId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func add(_ candidate: SystemNotificationCandidate) async throws {
        let content = UNMutableNotificationContent()
        content.title = candidate.feedTitle
        content.body = SystemNotificationPresentation.body(newCount: candidate.newCount, submittedAt: Date())
        content.userInfo = [PayloadKey.candidateID: candidate.candidateId, PayloadKey.feedID: candidate.feedId]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "flux.system-notification.\(candidate.candidateId)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let feedID = response.notification.request.content.userInfo[PayloadKey.feedID] as? Int64 {
            DispatchQueue.main.async { [weak self] in self?.onFeedSelected?(feedID) }
        } else if let number = response.notification.request.content.userInfo[PayloadKey.feedID] as? NSNumber {
            DispatchQueue.main.async { [weak self] in self?.onFeedSelected?(number.int64Value) }
        }
        completionHandler()
    }
}

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
    static let feedIcon = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "feed_icon")
    static let scrollover = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "scrollover")
    static let snapshot = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "snapshot")
    static let notification = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "notification")
}
