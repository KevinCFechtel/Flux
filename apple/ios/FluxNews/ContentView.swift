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
    @State private var optionsPresented = false
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
                            Button { navigationPresented = true } label: { Image(systemName: "sidebar.leading") }
                                .accessibilityLabel("Choose news scope")
                        }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button {
                                Task { await newsreaderStore.syncManually() }
                            } label: {
                                Label("Sync", systemImage: "arrow.clockwise")
                            }
                            .disabled(newsreaderStore.isLoading)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { optionsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                                .accessibilityLabel("Newsreader options")
                        }
                    }
                    .sheet(isPresented: $navigationPresented) {
                        NavigationStack {
                            NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sheet, onSearch: openSearch)
                                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
                        }
                    }
                    .sheet(isPresented: $optionsPresented) { NewsreaderOptionsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
            }
        }
    }

    private var articleList: some View {
        ArticleListView(store: newsreaderStore, onArticleTap: openArticle, onArticleAction: handleArticleAction)
            .navigationTitle(scopeTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if usesSplitNavigation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await newsreaderStore.syncManually() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(newsreaderStore.isLoading)
                        .accessibilityLabel("Sync news")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { optionsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Newsreader options")
                    }
                }
            }
            .sheet(isPresented: $optionsPresented) { NewsreaderOptionsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
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
        case .miniflux:
            newsreaderStore.minifluxEntryURL(for: article) { result in
                switch result {
                case let .success(value):
                    guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else {
                        actionError = "Flux could not resolve a valid Miniflux entry URL."
                        return
                    }
                    UIApplication.shared.open(url, options: [:])
                case let .failure(error): actionError = error.localizedDescription
                }
            }
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            UIApplication.shared.open(url, options: [:])
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
        case .miniflux: openMiniflux(article, using: searchStore)
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            UIApplication.shared.open(url, options: [:])
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
                UIApplication.shared.open(url, options: [:])
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

    private var scopeTitle: String {
        switch newsreaderStore.scope {
        case .all: "All News"
        case .starred: "Starred"
        case .category(let id): newsreaderStore.catalog.categories.first { $0.id == id }?.title ?? "Category"
        case .feed(let id): newsreaderStore.catalog.feeds.first { $0.id == id }?.title ?? "Feed"
        case .search: "Search"
        case .listeningList: "Listening List"
        }
    }

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

private struct NewsreaderOptionsView: View {
    @ObservedObject var store: NewsreaderStore
    @ObservedObject var bootstrapper: CoreBootstrapper
    let onDiagnostics: () -> Void
    @State private var accountPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Button("Account") { accountPresented = true }
                    Button("Developer Diagnostics") { onDiagnostics() }
                }
                Section("Articles") {
                    Picker("Click on article", selection: Binding(get: { store.clickOnNews }, set: store.setClickOnNews)) {
                        Text("Open Link").tag(ClickOnNews.openLink)
                        Text("Open Reader").tag(ClickOnNews.openDetailView)
                    }
                    Picker("Presentation", selection: Binding(get: { store.articlePresentationMode }, set: store.setArticlePresentationMode)) {
                        ForEach(ArticlePresentationMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Preview", selection: Binding(get: { store.articlePreviewLines }, set: store.setArticlePreviewLines)) {
                        ForEach(ArticlePreviewLines.allCases, id: \.self) { Text("\($0.rawValue) lines").tag($0) }
                    }
                    Toggle("Unread only", isOn: Binding(get: { store.unreadOnly }, set: store.setUnreadOnly))
                    Toggle("Newest first", isOn: Binding(get: { store.newestFirst }, set: store.setNewestFirst))
                    Toggle("Remove articles when read", isOn: Binding(get: { store.removeArticlesWhenMarkedRead }, set: store.setRemoveArticlesWhenMarkedRead))
                    Toggle("Mark read on scrollover", isOn: Binding(get: { store.markReadOnScrolloverEnabled }, set: store.setMarkReadOnScrolloverEnabled))
                }
                Section("Navigation") {
                    Toggle("Hide empty feeds", isOn: Binding(get: { store.hideEmptyNavigationEntries }, set: store.setHideEmptyNavigationEntries))
                    Picker("Startup scope", selection: Binding(get: { store.startupScope }, set: store.setStartupScope)) {
                        Text("All News").tag(StartupScopePreference.allNews)
                        Text("Starred").tag(StartupScopePreference.starred)
                        Text("Category").tag(StartupScopePreference.category)
                        Text("Feed").tag(StartupScopePreference.feed)
                    }
                    if store.startupScope == .category {
                        Picker("Startup category", selection: Binding(get: { store.startupCategoryID ?? 0 }, set: { store.setStartupCategoryID($0) })) {
                            ForEach(store.catalog.categories, id: \.id) { Text($0.title).tag($0.id) }
                        }
                    }
                    if store.startupScope == .feed {
                        Picker("Startup feed", selection: Binding(get: { store.startupFeedID ?? 0 }, set: { store.setStartupFeedID($0) })) {
                            ForEach(store.catalog.feeds, id: \.id) { Text($0.title).tag($0.id) }
                        }
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $accountPresented) { AccountConfigurationView(bootstrapper: bootstrapper, allowsRemoval: true) }
        }
    }
}
