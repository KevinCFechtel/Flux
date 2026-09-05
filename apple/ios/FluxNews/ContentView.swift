import SwiftUI
import UIKit
import SafariServices

private struct IOSBrowserURL: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct IOSReaderArticle: Identifiable {
    let article: ArticleSummary
    var id: Int64 { article.id }
}

private struct IOSSharePayload: Identifiable {
    let items: [Any]
    let id = UUID()
}

enum IOSBottomAction: Equatable {
    case sync
    case filterAndSort
    case search
    case listeningList
    case markAllRead
    case markAllReadAndNext
    case settings
    case more

    static let defaultActions: [Self] = [.sync, .filterAndSort, .more]
}

enum IOSMoreAction: Equatable {
    case markAllRead
    case markAllReadAndNext
    case settings

    static func actions(for scope: BrowserScope, hasNextScope: Bool) -> [Self] {
        let supportsMarkRead: Bool = switch scope {
        case .all, .category, .feed: true
        case .starred, .search, .listeningList: false
        }
        guard supportsMarkRead else { return [.settings] }
        let canAdvance = hasNextScope && {
            switch scope {
            case .category, .feed: true
            case .all, .starred, .search, .listeningList: false
            }
        }()
        return canAdvance ? [.markAllRead, .markAllReadAndNext, .settings] : [.markAllRead, .settings]
    }
}

enum IOSScopeNavigation {
    static func nextScope(
        after scope: BrowserScope,
        catalog: NavigationCatalog,
        hidingEmpty: Bool,
        counts: [Int64: UInt64]
    ) -> BrowserScope? {
        let groups = NavigationVisibility.groups(
            categories: catalog.categories.map { .init(id: $0.id, title: $0.title) },
            feeds: catalog.feeds.map { .init(id: $0.id, categoryID: $0.categoryId) },
            hidingEmpty: hidingEmpty,
            counts: counts
        )
        switch scope {
        case let .feed(feedID):
            let feeds = groups.flatMap(\.feeds)
            guard let index = feeds.firstIndex(where: { $0.id == feedID }), feeds.indices.contains(feeds.index(after: index)) else { return nil }
            return .feed(feeds[feeds.index(after: index)].id)
        case let .category(categoryID):
            let categories = groups.compactMap(\.categoryID)
            guard let index = categories.firstIndex(of: categoryID), categories.indices.contains(categories.index(after: index)) else { return nil }
            return .category(categories[categories.index(after: index)])
        case .all, .starred, .search, .listeningList:
            return nil
        }
    }
}

private enum IOSMarkReadWorkflow: Equatable {
    case read
    case readAndNext
}

enum NewsNavigationLayout {
    static func usesSplitView(for idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .pad
    }
}

enum IOSNavigationButtonPresentation {
    static let imageName = "FluxNewsTemplate"
    static let accessibilityLabel = "Choose news scope"
    static let glyphSize: CGFloat = 22
}

enum IOSReaderDismissalPresentation {
    static let title = "Done"
}

enum IOSArticleNavigationPresentation {
    // The navigation controller, rather than the Article ScrollView, owns the
    // native large-title collapse state. Keep both lifecycles on this signal.
    static func identity(for resetRevision: UInt64) -> UInt64 { resetRevision }
}

struct IOSArticleNavigationHost<Content: View>: View {
    let resetRevision: UInt64
    @ViewBuilder let content: () -> Content

    init(resetRevision: UInt64, @ViewBuilder content: @escaping () -> Content) {
        self.resetRevision = resetRevision
        self.content = content
    }

    var body: some View {
        NavigationStack { content() }
            .id(IOSArticleNavigationPresentation.identity(for: resetRevision))
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var bootstrapper: CoreBootstrapper
    var newsreaderStore: NewsreaderStore
    @StateObject private var searchStore = IOSSearchStore()
    @State private var navigationPresented = false
    @State private var searchPresented = false
    @State private var diagnosticsPresented = false
    @State private var settingsPresented = false
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var browser: IOSBrowserURL?
    @State private var articleOpenError: String?
    @State private var articleOpenGeneration = 0
    @State private var readerArticle: IOSReaderArticle?
    @State private var readerDocument: ReaderDocument?
    @State private var readerIsLoading = false
    @State private var readerErrorMessage: String?
    @State private var readerGeneration = 0
    @State private var sharePayload: IOSSharePayload?
    @State private var actionConfirmation: String?
    @State private var actionError: String?
    @State private var markReadConfirmationPresented = false
    @State private var markReadWorkflow: IOSMarkReadWorkflow = .read

    private var usesSplitNavigation: Bool {
        NewsNavigationLayout.usesSplitView(for: UIDevice.current.userInterfaceIdiom)
    }

    var body: some View {
        Group {
            if case .ready = bootstrapper.state, newsreaderStore.core != nil {
                newsreader
            } else {
                StartupView(bootstrapper: bootstrapper)
            }
        }
        .sheet(isPresented: $diagnosticsPresented) { DeveloperDiagnosticsView(bootstrapper: bootstrapper) }
        .sheet(item: $browser) { item in IOSInAppBrowser(url: item.url) }
        .sheet(item: readerSheetBinding) { item in
            NavigationStack { readerView(for: item.article) }
        }
        .inspector(isPresented: readerInspectorBinding) {
            if let article = readerArticle?.article {
                NavigationStack { readerView(for: article) }
            }
        }
        .sheet(item: $sharePayload) { payload in IOSShareSheet(items: payload.items) }
        .alert("Unable to Open Article", isPresented: Binding(get: { articleOpenError != nil }, set: { if !$0 { articleOpenError = nil } })) {
            Button("OK", role: .cancel) { articleOpenError = nil }
        } message: { Text(articleOpenError ?? "") }
        .alert("Article Action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .alert("Article Action", isPresented: Binding(get: { actionConfirmation != nil }, set: { if !$0 { actionConfirmation = nil } })) {
            Button("OK", role: .cancel) { actionConfirmation = nil }
        } message: { Text(actionConfirmation ?? "") }
        .confirmationDialog(markReadDialogTitle, isPresented: $markReadConfirmationPresented, titleVisibility: .visible) {
            Button(markReadDialogTitle, role: .destructive) { performMarkReadWorkflow() }
        } message: { Text("Marks all unread articles in this scope as read.") }
        .task(id: bootstrapper.coreRevision) {
            if let core = newsreaderStore.core {
                searchStore.attach(to: core)
                searchStore.onLocalFirstMutation = { newsreaderStore.loadNavigationAndCounts() }
            } else { searchStore.detach() }
        }
    }

    @ViewBuilder
    private var newsreader: some View {
        Group {
            if usesSplitNavigation { iPadNewsreader } else { iPhoneNewsreader }
        }
        // These presentations outlive an article-navigation reset.
        .sheet(isPresented: $navigationPresented) {
            NavigationStack {
                NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sheet, onSearch: openSearch)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
    }

    private var iPadNewsreader: some View {
        NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
            NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sidebar, onSearch: openSearch).toolbar(removing: .sidebarToggle)
        } detail: {
            if searchPresented {
                searchView
            } else {
                IOSArticleNavigationHost(resetRevision: newsreaderStore.scrollResetRevision) { articleList }
            }
        }
    }

    private var iPhoneNewsreader: some View {
        IOSArticleNavigationHost(resetRevision: newsreaderStore.scrollResetRevision) {
            articleList
                .navigationDestination(isPresented: $searchPresented) { searchView }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { navigationPresented = true } label: {
                            Image(IOSNavigationButtonPresentation.imageName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: IOSNavigationButtonPresentation.glyphSize, height: IOSNavigationButtonPresentation.glyphSize)
                        }
                            .accessibilityLabel(IOSNavigationButtonPresentation.accessibilityLabel)
                    }
                }
        }
    }

    private var articleList: some View {
        ArticleListNavigationChrome(store: newsreaderStore) {
            ArticleListView(store: newsreaderStore, onArticleTap: openArticle, onArticleAction: handleArticleAction)
        }
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { Task { await newsreaderStore.syncManually() } } label: {
                        if IOSSyncButtonPresentation.showsProgress(isSyncing: newsreaderStore.isSyncing) {
                            ProgressView()
                                .frame(width: 20, height: 20)
                        } else {
                            Label("Sync", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(newsreaderStore.isSyncing)
                    .accessibilityLabel("Sync news")
                    .accessibilityValue(IOSSyncButtonPresentation.accessibilityValue(isSyncing: newsreaderStore.isSyncing))

                    Menu {
                        Section("Show") {
                            Button { newsreaderStore.setUnreadOnly(true) } label: {
                                filterMenuLabel("Unread Only", selected: newsreaderStore.unreadOnly)
                            }
                            Button { newsreaderStore.setUnreadOnly(false) } label: {
                                filterMenuLabel("All Articles", selected: !newsreaderStore.unreadOnly)
                            }
                        }
                        Section("Sort") {
                            Button { newsreaderStore.setNewestFirst(true) } label: {
                                filterMenuLabel("Newest First", selected: newsreaderStore.newestFirst)
                            }
                            Button { newsreaderStore.setNewestFirst(false) } label: {
                                filterMenuLabel("Oldest First", selected: !newsreaderStore.newestFirst)
                            }
                        }
                    } label: {
                        Label("Filter and Sort", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("articleList.filterSort")

                    Menu {
                        ForEach(IOSMoreAction.actions(for: newsreaderStore.scope, hasNextScope: nextScope != nil), id: \.self) { action in
                            switch action {
                            case .markAllRead:
                                Button("Mark All as Read", role: .destructive) { presentMarkReadConfirmation(.read) }
                            case .markAllReadAndNext:
                                Button("Mark All as Read & Next", role: .destructive) { presentMarkReadConfirmation(.readAndNext) }
                            case .settings:
                                Divider()
                                Button { settingsPresented = true } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("articleList.more")
                }
            }
    }

    private var searchView: some View {
        SearchView(store: searchStore, newsreaderStore: newsreaderStore, onArticleTap: openSearchArticle, onArticleAction: handleSearchArticleAction, onSetRead: { article, read in searchStore.setRead(article, read: read) }, onSetStarred: { article, starred in searchStore.setStarred(article, starred: starred) })
    }

    private func openSearch() {
        navigationPresented = false
        searchPresented = true
    }

    private func openArticle(_ article: ArticleSummary) {
        switch ArticleOpenRouting.action(clickOnNews: newsreaderStore.clickOnNews, openInMiniflux: false) {
        case .detail:
            openReader(article)
            return
        case .original, .miniflux:
            openOriginalArticle(article)
            return
        }
    }

    private func openOriginalArticle(_ article: ArticleSummary) {
        articleOpenGeneration += 1
        let generation = articleOpenGeneration
        newsreaderStore.open(article) { original in
            guard let url = ArticleOpenRoutingPolicy.validWebURL(original) else {
                present(.invalid)
                return
            }
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { succeeded in
                Task { @MainActor in
                    guard generation == articleOpenGeneration else { return }
                    present(ArticleOpenRoutingPolicy.destination(originalURL: original, universalLinkSucceeded: succeeded))
                }
            }
        }
    }

    private func openSearchArticle(_ article: ArticleSummary) {
        switch ArticleOpenRouting.action(clickOnNews: newsreaderStore.clickOnNews, openInMiniflux: false) {
        case .detail: openSearchReader(article)
        case .original, .miniflux: openSearchOriginalArticle(article)
        }
    }

    private func openSearchOriginalArticle(_ article: ArticleSummary) {
        articleOpenGeneration += 1
        let generation = articleOpenGeneration
        searchStore.open(article) { original in
            guard let url = ArticleOpenRoutingPolicy.validWebURL(original) else {
                present(.invalid)
                return
            }
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { succeeded in
                Task { @MainActor in
                    guard generation == articleOpenGeneration else { return }
                    present(ArticleOpenRoutingPolicy.destination(originalURL: original, universalLinkSucceeded: succeeded))
                }
            }
        }
    }

    private func handleArticleAction(_ article: ArticleSummary, _ action: IOSArticleContextAction) {
        switch action {
        case .starred:
            newsreaderStore.setStarred(article, starred: !article.isStarred)
        case .read:
            newsreaderStore.setRead(article, read: !article.isRead)
        case .original:
            openOriginalArticle(article)
        case .reader:
            openReader(article)
        case .miniflux:
            newsreaderStore.minifluxEntryURL(for: article) { result in
                switch result {
                case let .success(value):
                    guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else {
                        actionError = "Flux could not resolve a valid Miniflux entry URL."
                        return
                    }
                    browser = IOSBrowserURL(url: url)
                case let .failure(error): actionError = error.localizedDescription
                }
            }
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            browser = IOSBrowserURL(url: url)
        case .copyLink:
            UIPasteboard.general.string = article.url
            actionConfirmation = "Link copied"
        case .share:
            guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else {
                actionError = "The article does not have a valid web URL."
                return
            }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            newsreaderStore.saveToService(article) { result in
                switch result {
                case .success(.saved): actionConfirmation = "Saved to third-party service"
                case .success(.noIntegrationConfigured): actionConfirmation = "No third-party integration is configured in Miniflux"
                case let .failure(error): actionError = error.localizedDescription
                }
            }
        }
    }

    private func handleSearchArticleAction(_ article: ArticleSummary, _ action: IOSArticleContextAction) {
        switch action {
        case .starred: searchStore.setStarred(article, starred: !article.isStarred)
        case .read: searchStore.setRead(article, read: !article.isRead)
        case .original: openSearchOriginalArticle(article)
        case .reader: openSearchReader(article)
        case .miniflux: openMiniflux(article, using: searchStore)
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            browser = IOSBrowserURL(url: url)
        case .copyLink:
            UIPasteboard.general.string = article.url
            actionConfirmation = "Link copied"
        case .share:
            guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else { actionError = "The article does not have a valid web URL."; return }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            searchStore.saveToService(article) { result in
                switch result {
                case .success(.saved): actionConfirmation = "Saved to third-party service"
                case .success(.noIntegrationConfigured): actionConfirmation = "No third-party integration is configured in Miniflux"
                case let .failure(error): actionError = error.localizedDescription
                }
            }
        }
    }

    private func openMiniflux(_ article: ArticleSummary, using store: IOSSearchStore) {
        store.minifluxEntryURL(for: article) { result in
            switch result {
            case let .success(value):
                guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else { actionError = "Flux could not resolve a valid Miniflux entry URL."; return }
                browser = IOSBrowserURL(url: url)
            case let .failure(error): actionError = error.localizedDescription
            }
        }
    }

    private func openReader(_ article: ArticleSummary) {
        readerGeneration += 1
        let generation = readerGeneration
        readerArticle = IOSReaderArticle(article: article)
        readerDocument = nil
        readerErrorMessage = nil
        readerIsLoading = true
        newsreaderStore.openReader(article) { result in
            guard generation == readerGeneration else { return }
            readerIsLoading = false
            switch result {
            case let .success(document): readerDocument = document
            case let .failure(error): readerErrorMessage = error.localizedDescription
            }
        }
    }

    private func openSearchReader(_ article: ArticleSummary) {
        readerGeneration += 1
        let generation = readerGeneration
        readerArticle = IOSReaderArticle(article: article)
        readerDocument = nil
        readerErrorMessage = nil
        readerIsLoading = true
        searchStore.openReader(article) { result in
            guard generation == readerGeneration else { return }
            readerIsLoading = false
            switch result {
            case let .success(document): readerDocument = document
            case let .failure(error): readerErrorMessage = error.localizedDescription
            }
        }
    }

    private func present(_ destination: ArticleOpenDestination) {
        switch destination {
        case .universalLink: break
        case .browser(let url): browser = IOSBrowserURL(url: url)
        case .invalid: articleOpenError = "The article does not have a valid web URL."
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private var markReadDialogTitle: String {
        markReadWorkflow == .readAndNext ? "Mark All as Read & Next" : "Mark All as Read"
    }

    private var nextScope: BrowserScope? {
        IOSScopeNavigation.nextScope(
            after: newsreaderStore.scope,
            catalog: newsreaderStore.catalog,
            hidingEmpty: newsreaderStore.hideEmptyNavigationEntries,
            counts: newsreaderStore.feedCounts
        )
    }

    private func presentMarkReadConfirmation(_ workflow: IOSMarkReadWorkflow) {
        markReadWorkflow = workflow
        markReadConfirmationPresented = true
    }

    private func performMarkReadWorkflow() {
        let target = markReadWorkflow == .readAndNext ? nextScope : nil
        newsreaderStore.markCurrentScopeAsRead { succeeded in
            guard succeeded, let target else { return }
            newsreaderStore.select(target)
        }
    }
}

enum ArticleListTitlePresentation {
    static func title(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        scopeTitle(scope: scope, catalog: catalog)
    }

    private static func scopeTitle(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        switch scope {
        case .all: "All News"
        case .starred: "Starred"
        case .category(let id): catalog.categories.first { $0.id == id }?.title ?? "Category"
        case .feed(let id): catalog.feeds.first { $0.id == id }?.title ?? "Feed"
        case .search: "Search"
        case .listeningList: "Listening List"
        }
    }
}

enum ArticleListCounterPresentation {
    static func compactCount(_ count: UInt64) -> String { String(count) }
    static func isVisible(showArticleCount: Bool) -> Bool { showArticleCount }
    static func usesNativeSubtitle(showArticleCount: Bool, supportsNativeSubtitle: Bool) -> Bool {
        showArticleCount && supportsNativeSubtitle
    }
    static func usesToolbarFallback(showArticleCount: Bool, supportsNativeSubtitle: Bool) -> Bool {
        showArticleCount && !supportsNativeSubtitle
    }

    static func expandedLabel(scope: BrowserScope, unreadOnly: Bool, count: UInt64) -> String {
        if unreadOnly && scope != .starred { return "\(count) unread" }
        return "\(count) articles"
    }
}

enum IOSSyncButtonPresentation {
    static func showsProgress(isSyncing: Bool) -> Bool { isSyncing }
    static func accessibilityValue(isSyncing: Bool) -> String { isSyncing ? "Syncing" : "Ready" }
}

private struct ArticleListNavigationChrome<Content: View>: View {
    var store: NewsreaderStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        let title = ArticleListTitlePresentation.title(scope: store.scope, catalog: store.catalog)
        let subtitle = ArticleListCounterPresentation.expandedLabel(scope: store.scope, unreadOnly: store.unreadOnly, count: store.selectionTotal)

        if #available(iOS 26.0, *) {
            if ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: store.showArticleCount, supportsNativeSubtitle: true) {
                content()
                    .navigationTitle(title)
                    .navigationSubtitle(Text(subtitle))
            } else {
                content()
                    .navigationTitle(title)
            }
        } else {
            content()
                .navigationTitle(title)
                .toolbar {
                    if ArticleListCounterPresentation.usesToolbarFallback(showArticleCount: store.showArticleCount, supportsNativeSubtitle: false) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text(ArticleListCounterPresentation.compactCount(store.selectionTotal))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(subtitle)
                        }
                    }
                }
        }
    }
}

extension ContentView {
    private var usesReaderInspector: Bool {
        ReaderPresentationPolicy.kind(isPad: usesSplitNavigation, isRegularWidth: horizontalSizeClass == .regular) == .inspector
    }

    private var readerSheetBinding: Binding<IOSReaderArticle?> {
        Binding(
            get: { usesReaderInspector ? nil : readerArticle },
            set: { if $0 == nil { readerArticle = nil; readerGeneration += 1 } }
        )
    }

    private var readerInspectorBinding: Binding<Bool> {
        Binding(
            get: { usesReaderInspector && readerArticle != nil },
            set: { if !$0 { readerArticle = nil; readerGeneration += 1 } }
        )
    }

    @ViewBuilder
    private func readerView(for article: ArticleSummary) -> some View {
        VStack(spacing: 0) {
            ReaderArticleHeader(article: article)
            Group {
                if readerIsLoading {
                    ProgressView("Loading article...")
                } else if let readerErrorMessage {
                    ContentUnavailableView("Unable to load article", systemImage: "exclamationmark.triangle", description: Text(readerErrorMessage))
                } else if let readerDocument {
                    ScrollView { ReaderDocumentContent(document: readerDocument, openOriginal: { openOriginal(article) }) }
                } else {
                    ContentUnavailableView("No article selected", systemImage: "doc.text")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url, options: [:])
            return .handled
        })
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(IOSReaderDismissalPresentation.title, action: dismissReader)
            }
        }
    }

    private func dismissReader() {
        readerArticle = nil
        readerGeneration += 1
    }

    private func openOriginal(_ article: ArticleSummary) {
        guard let url = ArticleOpenRoutingPolicy.validWebURL(article.url) else {
            readerErrorMessage = "The article does not have a valid web URL."
            return
        }
        UIApplication.shared.open(url, options: [:])
    }
}

private struct IOSInAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
