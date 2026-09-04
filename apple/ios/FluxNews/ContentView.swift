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

enum NewsNavigationLayout {
    static func usesSplitView(for idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .pad
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var bootstrapper: CoreBootstrapper
    @ObservedObject var newsreaderStore: NewsreaderStore
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
        .sheet(item: readerSheetBinding) { item in readerView(for: item.article) }
        .inspector(isPresented: readerInspectorBinding) {
            if let article = readerArticle?.article { readerView(for: article) }
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
        .confirmationDialog(scopeMarkReadTitle, isPresented: $markReadConfirmationPresented, titleVisibility: .visible) {
            Button(scopeMarkReadTitle, role: .destructive) { newsreaderStore.markCurrentScopeAsRead() }
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
        if usesSplitNavigation {
            NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
                NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sidebar, onSearch: openSearch).toolbar(removing: .sidebarToggle)
            } detail: {
                if searchPresented { searchView } else { articleList }
            }
        } else {
            NavigationStack {
                articleList
                    .navigationDestination(isPresented: $searchPresented) { searchView }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { navigationPresented = true } label: {
                                Image("FluxNewsTemplate")
                                    .renderingMode(.template)
                            }
                                .accessibilityLabel("Choose news scope")
                        }
                    }
                    .sheet(isPresented: $navigationPresented) {
                        NavigationStack {
                            NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sheet, onSearch: openSearch)
                                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
                        }
                    }
                    .sheet(isPresented: $settingsPresented) { SettingsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
            }
        }
    }

    private var articleList: some View {
        ArticleListView(store: newsreaderStore, onArticleTap: openArticle, onArticleAction: handleArticleAction)
            .navigationTitle(ArticleListTitlePresentation.title(scope: newsreaderStore.scope, catalog: newsreaderStore.catalog, count: newsreaderStore.selectionTotal))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { Task { await newsreaderStore.syncManually() } } label: {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                    .disabled(newsreaderStore.isLoading)
                    .accessibilityLabel("Sync news")

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
                        if scopeSupportsMarkRead {
                            Section {
                                Button(scopeMarkReadTitle, role: .destructive) { markReadConfirmationPresented = true }
                            }
                        }
                    } label: {
                        Label("Filter and Sort", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("articleList.filterSort")

                    Button { settingsPresented = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("articleList.settings")
                }
            }
            .sheet(isPresented: $settingsPresented) { SettingsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
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

    private var scopeSupportsMarkRead: Bool {
        switch newsreaderStore.scope {
        case .all, .category, .feed: true
        case .starred, .search, .listeningList: false
        }
    }

    private var scopeMarkReadTitle: String {
        switch newsreaderStore.scope {
        case .all: "Mark All as Read"
        case .category: "Mark Category as Read"
        case .feed: "Mark Feed as Read"
        case .starred, .search, .listeningList: "Mark as Read"
        }
    }
}

enum ArticleListTitlePresentation {
    static func title(scope: BrowserScope, catalog: NavigationCatalog, count: UInt64) -> String {
        "\(scopeTitle(scope: scope, catalog: catalog)) (\(count))"
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
                Button("Done") { readerArticle = nil; readerGeneration += 1 }
            }
        }
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
