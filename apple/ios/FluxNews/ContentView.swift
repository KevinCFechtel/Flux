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

enum IOSArticleListActionPlacement: Equatable {
    case bottomBar
    case topBarTrailing
}

enum IOSArticleListChromeMode: Equatable {
    case compactPortrait
    case compactLandscape
    case persistentSplit
}

enum IOSArticleListChromePresentation {
    static func mode(
        for presentation: AdaptivePresentation,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> IOSArticleListChromeMode {
        if presentation.usesPersistentSplitNavigation {
            return .persistentSplit
        }
        return verticalSizeClass == .compact ? .compactLandscape : .compactPortrait
    }

    static func actionPlacement(for mode: IOSArticleListChromeMode) -> IOSArticleListActionPlacement {
        mode == .compactPortrait ? .bottomBar : .topBarTrailing
    }
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

enum IOSNavigationButtonPresentation {
    static let imageName = "FluxNewsTemplate"
    static let accessibilityLabel = String(localized: "Choose news scope")
    static let glyphSize: CGFloat = 22
}

enum IOSReaderDismissalPresentation {
    static let title = String(localized: "Done")
}

enum IOSArticleNavigationPresentation {
    // UIKit derives system Large Title state from the Timeline collection view's
    // scroll edge. Semantic resets therefore preserve view identity and move the
    // collection view to its natural top position.
    static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var bootstrapper: CoreBootstrapper
    var newsreaderStore: NewsreaderStore
    @StateObject private var searchStore = IOSSearchStore()
    @State private var navigationPresented = false
    @State private var searchPresented = false
    /// Set while the navigation sheet is closing so that search opens once it is
    /// actually gone.
    @State private var searchPendingAfterNavigationSheet = false
    @State private var diagnosticsPresented = false
    @State private var settingsPresented = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
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
    @State private var syncPresentation: IOSSyncButtonPresentation.State = .idle
    @State private var syncPresentationGeneration: UInt64 = 0

    /// The capsule already opens the scope chooser, so a second control for the
    /// same action would be pure redundancy.
    private var capsuleCarriesScopeAction: Bool {
        !adaptivePresentation.usesPersistentSplitNavigation
    }

    private var adaptivePresentation: AdaptivePresentation {
        AdaptivePresentationPolicy.presentation(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    private var articleListChromeMode: IOSArticleListChromeMode {
        IOSArticleListChromePresentation.mode(
            for: adaptivePresentation,
            verticalSizeClass: verticalSizeClass
        )
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
        // A sheet rather than a pushed destination: the timeline is the detail
        // column of a split view that collapses on a phone, and a destination
        // registered there did not activate. A sheet behaves identically in both
        // size classes and needs no sequencing against the navigation sheet.
        .sheet(isPresented: $searchPresented) {
            NavigationStack {
                searchView
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { searchPresented = false }
                        }
                    }
            }
            // Only one sheet can be presented per view, so what the results open
            // has to hang off the search sheet while it is up.
            .sheet(item: gatedBrowser(active: true)) { item in IOSInAppBrowser(url: item.url) }
            .sheet(item: gatedReaderSheet(active: true)) { item in
                NavigationStack { readerView(for: item.article) }
            }
            .sheet(item: gatedShare(active: true)) { payload in IOSShareSheet(items: payload.items) }
        }
        .sheet(item: gatedBrowser(active: !searchPresented)) { item in IOSInAppBrowser(url: item.url) }
        .sheet(item: gatedReaderSheet(active: !searchPresented)) { item in
            NavigationStack { readerView(for: item.article) }
        }
        .sheet(item: gatedShare(active: !searchPresented)) { payload in IOSShareSheet(items: payload.items) }
        .alert("Unable to Open Article", isPresented: Binding(get: { articleOpenError != nil }, set: { if !$0 { articleOpenError = nil } })) {
            Button("OK", role: .cancel) { articleOpenError = nil }
        } message: { Text(articleOpenError ?? "") }
        .alert("Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .alert("Article Action", isPresented: Binding(get: { actionConfirmation != nil }, set: { if !$0 { actionConfirmation = nil } })) {
            Button("OK", role: .cancel) { actionConfirmation = nil }
        } message: { Text(actionConfirmation ?? "") }
        .confirmationDialog(markReadDialogTitle, isPresented: $markReadConfirmationPresented, titleVisibility: .visible) {
            Button(markReadDialogTitle, role: .destructive) { performMarkReadWorkflow() }
        } message: { Text("Marks all unread articles in this scope as read.") }
        .onChange(of: adaptivePresentation) { _, presentation in
            normalizeAdaptiveShell(for: presentation)
        }
        .onChange(of: searchPresented) { _, presented in
            if !presented { searchStore.invalidate() }
        }
        .onAppear { normalizeAdaptiveShell(for: adaptivePresentation) }
        .task(id: bootstrapper.coreRevision) {
            if let core = newsreaderStore.core {
                searchStore.attach(to: core)
                searchStore.onLocalFirstMutation = { newsreaderStore.loadNavigationAndCounts() }
            } else { searchStore.detach() }
        }
    }

    @ViewBuilder
    private var newsreader: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            NewsNavigationView(
                store: newsreaderStore,
                sheetPresented: $navigationPresented,
                presentation: .sidebar,
                onSearch: openSearch
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            adaptiveDetail
        }
        // These presentations outlive an article-navigation reset.
        .sheet(isPresented: $navigationPresented, onDismiss: {
            guard searchPendingAfterNavigationSheet else { return }
            searchPendingAfterNavigationSheet = false
            searchPresented = true
        }) {
            NavigationStack {
                NewsNavigationView(store: newsreaderStore, sheetPresented: $navigationPresented, presentation: .sheet, onSearch: openSearch)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
    }

    private var adaptiveDetail: some View {
        Group {
            articleList
                .inspector(isPresented: readerInspectorBinding) {
                    // Presentation and content derive from the same optional. If
                    // the article is gone the panel closes itself rather than
                    // standing there empty.
                    //
                    // Gated on the presentation kind as well: where the reader is
                    // a sheet, building this content anyway put `readerView`'s
                    // toolbar into the timeline's navigation bar — a second Done
                    // button that shoved the title capsule aside.
                    Group {
                        if usesReaderInspector, let article = readerArticle?.article {
                            NavigationStack { readerView(for: article) }
                        } else if usesReaderInspector {
                            Color.clear.onAppear { dismissReader() }
                        }
                    }
                }
                .toolbar {
                    if !adaptivePresentation.usesPersistentSplitNavigation, !capsuleCarriesScopeAction {
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
    }

    private var articleList: some View {
        ArticleListNavigationChrome(
            store: newsreaderStore,
            onSelectScope: adaptivePresentation.usesPersistentSplitNavigation ? nil : { navigationPresented = true },
            chromeMode: articleListChromeMode
        ) {
            ArticleListView(store: newsreaderStore, onArticleTap: openArticle, onArticleAction: handleArticleAction)
        }
            .navigationBarTitleDisplayMode(IOSArticleNavigationPresentation.titleDisplayMode)
            // A collapsed split view pushes the detail and offers a back button.
            // The Timeline is the root of this app's navigation: the branded
            // button opens the scope chooser, there is nothing to go back to.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItemGroup(placement: articleListActionToolbarPlacement) {
                    Button { Task { await performManualSync() } } label: {
                        Image(systemName: IOSSyncButtonPresentation.symbolName(for: syncPresentation))
                            .frame(width: 24, height: 24)
                    }
                    .disabled(newsreaderStore.isSyncing)
                    .accessibilityLabel(String(localized: "Sync news"))
                    .accessibilityValue(IOSSyncButtonPresentation.accessibilityValue(for: syncPresentation))

                    Menu {
                        Section("Show") {
                            Button { newsreaderStore.setUnreadOnly(true) } label: {
                                filterMenuLabel(String(localized: "Unread Only"), selected: newsreaderStore.unreadOnly)
                            }
                            Button { newsreaderStore.setUnreadOnly(false) } label: {
                                filterMenuLabel(String(localized: "All Articles"), selected: !newsreaderStore.unreadOnly)
                            }
                        }
                        Section("Sort") {
                            Button { newsreaderStore.setNewestFirst(true) } label: {
                                filterMenuLabel(String(localized: "Newest First"), selected: newsreaderStore.newestFirst)
                            }
                            Button { newsreaderStore.setNewestFirst(false) } label: {
                                filterMenuLabel(String(localized: "Oldest First"), selected: !newsreaderStore.newestFirst)
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
                                Button("Mark All as Read and Continue", role: .destructive) { presentMarkReadConfirmation(.readAndNext) }
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
                    .accessibilityLabel(String(localized: "More"))
                    .accessibilityIdentifier("articleList.more")
                }
            }
    }

    private var articleListActionToolbarPlacement: ToolbarItemPlacement {
        switch IOSArticleListChromePresentation.actionPlacement(for: articleListChromeMode) {
        case .bottomBar: .bottomBar
        case .topBarTrailing: .topBarTrailing
        }
    }

    private func performManualSync() async {
        syncPresentationGeneration &+= 1
        let generation = syncPresentationGeneration
        syncPresentation = .syncing

        await newsreaderStore.syncManually()

        guard IOSSyncButtonPresentation.canEndSuccess(
            generation: generation,
            currentGeneration: syncPresentationGeneration,
            isSyncing: newsreaderStore.isSyncing
        ) else { return }
        guard newsreaderStore.errorMessage == nil else {
            syncPresentation = .idle
            return
        }

        syncPresentation = .success
        do {
            try await Task.sleep(for: .milliseconds(1500))
        } catch {
            return
        }
        guard IOSSyncButtonPresentation.canEndSuccess(
            generation: generation,
            currentGeneration: syncPresentationGeneration,
            isSyncing: newsreaderStore.isSyncing
        ) else { return }
        syncPresentation = .idle
    }

    private var searchView: some View {
        SearchView(store: searchStore, newsreaderStore: newsreaderStore, onArticleTap: openSearchArticle, onArticleAction: handleSearchArticleAction, onSetRead: { article, read in searchStore.setRead(article, read: read) }, onSetStarred: { article, starred in searchStore.setStarred(article, starred: starred) })
    }

    private func openSearch() {
        // Presenting while the navigation sheet is still dismissing loses the
        // presentation, so its dismissal callback performs it.
        guard navigationPresented else {
            searchPresented = true
            return
        }
        searchPendingAfterNavigationSheet = true
        navigationPresented = false
    }

    private func normalizeAdaptiveShell(for presentation: AdaptivePresentation) {
        navigationPresented = AdaptiveShellTransitionPolicy.navigationSheetPresented(
            after: presentation,
            wasPresented: navigationPresented
        )
        splitColumnVisibility = AdaptiveShellTransitionPolicy.splitColumnVisibility(after: presentation)
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
                         actionError = String(localized: "Flux could not resolve a valid Miniflux entry URL.")
                        return
                    }
                    browser = IOSBrowserURL(url: url)
                case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
            }
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            browser = IOSBrowserURL(url: url)
        case .copyLink:
            UIPasteboard.general.string = article.url
             actionConfirmation = String(localized: "Link copied")
        case .share:
            guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else {
                 actionError = String(localized: "The article does not have a valid web URL.")
                return
            }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            newsreaderStore.saveToService(article) { result in
                switch result {
                 case .success(.saved): actionConfirmation = String(localized: "Saved to third-party service")
                 case .success(.noIntegrationConfigured): actionConfirmation = String(localized: "No third-party integration is configured in Miniflux")
                case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
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
             actionConfirmation = String(localized: "Link copied")
        case .share:
             guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else { actionError = String(localized: "The article does not have a valid web URL."); return }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            searchStore.saveToService(article) { result in
                switch result {
                 case .success(.saved): actionConfirmation = String(localized: "Saved to third-party service")
                 case .success(.noIntegrationConfigured): actionConfirmation = String(localized: "No third-party integration is configured in Miniflux")
                case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
            }
        }
    }

    private func openMiniflux(_ article: ArticleSummary, using store: IOSSearchStore) {
        store.minifluxEntryURL(for: article) { result in
            switch result {
            case let .success(value):
                guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else { actionError = String(localized: "Flux could not resolve a valid Miniflux entry URL."); return }
                browser = IOSBrowserURL(url: url)
            case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
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
            case let .failure(error): readerErrorMessage = IOSErrorPresentation.message(for: error, context: .reader)
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
            case let .failure(error): readerErrorMessage = IOSErrorPresentation.message(for: error, context: .reader)
            }
        }
    }

    private func present(_ destination: ArticleOpenDestination) {
        switch destination {
        case .universalLink: break
        case .browser(let url): browser = IOSBrowserURL(url: url)
        case .invalid: articleOpenError = String(localized: "The article does not have a valid web URL.")
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private var markReadDialogTitle: String {
        markReadWorkflow == .readAndNext ? String(localized: "Mark All as Read and Continue") : String(localized: "Mark All as Read")
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

private enum ArticleListTitleCapsuleLayout {
    case stacked
    case inline
}

private struct ArticleListTitleCapsule: View {
    let title: String
    let subtitle: String?
    let layout: ArticleListTitleCapsuleLayout
    var action: (() -> Void)?
    // Read so the derived glyph height is recomputed when the text size changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The combined height of the two lines, from the same font metrics that lay
    /// them out. A fixed point size would drift apart from them under Dynamic
    /// Type, and a flexible frame would let the glyph drive the capsule's height.
    private var glyphHeight: CGFloat {
        let titleHeight = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        guard layout == .stacked, subtitle != nil else { return titleHeight }
        return titleHeight + 1 + UIFont.preferredFont(forTextStyle: .caption1).lineHeight
    }

    var body: some View {
        // This capsule replaced the navigation title, so it has to carry that
        // role too: the label is what the screen *is* (the scope), the value is
        // its state, and the hint is what tapping does. Announcing the action as
        // the label would put the least useful part first.
        //
        // `.isHeader` restores what `.navigationTitle("")` gave up — without it
        // VoiceOver's heading rotor finds nothing on this screen.
        if let action {
            Button(action: action) { capsule }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(subtitle ?? "")
                .accessibilityHint(IOSNavigationButtonPresentation.accessibilityLabel)
                .accessibilityAddTraits(.isHeader)
        } else {
            // No action on a persistent sidebar, but the two lines would still be
            // read as separate, role-less elements without this.
            capsule
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(subtitle ?? "")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            if action != nil {
                Image(IOSNavigationButtonPresentation.imageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphHeight, height: glyphHeight)
                    // `.plain` hands its content the label colour. The brand mark
                    // keeps the accent it had as a standalone button.
                    .foregroundStyle(Color.accentColor)
            }
            titleAndSubtitle
            if action != nil {
                // Glass says "interactive", the chevron says what kind. No
                // explicit colour: an inherited one still flips with the glass
                // over dark content, a semantic one would not.
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.55)
            }
        }
        .padding(.leading, action == nil ? 16 : 12)
        .padding(.trailing, action == nil ? 16 : 12)
        .padding(.vertical, layout == .inline ? 5 : 7)
        .background { ArticleListTitleCapsuleBackground() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleAndSubtitle: some View {
        switch layout {
        case .stacked:
            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        case .inline:
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                if let subtitle {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            // A leading navigation-bar item is compressed before the trailing
            // action group. Reserve enough intrinsic width that the scope title
            // cannot collapse to zero while still allowing long names to truncate.
            .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
        }
    }
}

private struct ArticleListTitleCapsuleBackground: View {
    /// Whether the system is asked to avoid see-through backgrounds. Glass is
    /// exactly that, and the title has to stay legible over scrolling articles,
    /// so this substitutes an opaque fill rather than trusting the effect to
    /// adapt on its own.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Capsule().fill(Color(uiColor: .secondarySystemBackground))
        } else if #available(iOS 26.0, *) {
            ArticleListGlassCapsule()
        } else {
            // iOS 18 has no glass material; the closest stock equivalent.
            Capsule().fill(.regularMaterial)
        }
    }
}

@available(iOS 26.0, *)
private struct ArticleListGlassCapsule: UIViewRepresentable {

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        let view = UIVisualEffectView(effect: effect)
        // Resolves the capsule shape without a mask layer.
        view.cornerConfiguration = .capsule()
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        uiView.effect = effect
    }

    /// A `UIVisualEffectView` has no useful intrinsic size, so the representable
    /// has to answer for it. Returning the proposal unchanged also returns
    /// `.infinity` when the container offers unbounded space, and the effect then
    /// claims everything it is given — which is how a capsule background can end
    /// up as a full-height panel. Unbounded proposals collapse to zero instead;
    /// as a background it is always handed the concrete foreground size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIVisualEffectView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: .zero)
        return CGSize(
            width: size.width.isFinite ? size.width : 0,
            height: size.height.isFinite ? size.height : 0
        )
    }
}

enum ArticleListTitlePresentation {
    static func title(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        scopeTitle(scope: scope, catalog: catalog)
    }

    private static func scopeTitle(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        switch scope {
        case .all: String(localized: "All News")
        case .starred: String(localized: "Starred")
        case .category(let id): catalog.categories.first { $0.id == id }?.title ?? String(localized: "Category")
        case .feed(let id): catalog.feeds.first { $0.id == id }?.title ?? String(localized: "Feed")
        case .search: String(localized: "Search")
        case .listeningList: String(localized: "Listening List")
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

    static func expandedLabel(scope: BrowserScope, unreadOnly: Bool, count: UInt64, locale: Locale = .current) -> String {
        if unreadOnly && scope != .starred {
            return String(localized: "\(Int(count)) unread article", locale: locale)
        }
        return String(localized: "\(Int(count)) article", locale: locale)
    }
}

enum IOSSyncButtonPresentation {
    enum State: Equatable {
        case idle
        case syncing
        case success
    }

    static func symbolName(for state: State) -> String {
        state == .success ? "checkmark" : "arrow.clockwise"
    }

    static func rotationDegrees(for state: State, reduceMotion: Bool) -> Double {
        state == .syncing && !reduceMotion ? 360 : 0
    }

    static func accessibilityValue(for state: State) -> String {
        switch state {
        case .idle: String(localized: "Ready")
        case .syncing: String(localized: "Syncing")
        case .success: String(localized: "Sync complete")
        }
    }

    static func canEndSuccess(generation: UInt64, currentGeneration: UInt64, isSyncing: Bool) -> Bool {
        generation == currentGeneration && !isSyncing
    }
}

private struct ArticleListNavigationChrome<Content: View>: View {
    var store: NewsreaderStore
    /// Absent when a persistent sidebar already offers scope selection.
    var onSelectScope: (() -> Void)?
    var chromeMode: IOSArticleListChromeMode
    @ViewBuilder let content: () -> Content

    private func capsuleSubtitle(_ subtitle: String) -> String? {
        ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: store.showArticleCount, supportsNativeSubtitle: true) ? subtitle : nil
    }

    /// A large title cannot hand over to the capsule. Toolbar placements are
    /// additive, so each compact-height mode gives the capsule one explicit
    /// toolbar slot while the persistent split uses a native inline title.
    @ViewBuilder
    private func portraitCapsuleChrome(title: String, subtitle: String) -> some View {
        content()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ArticleListTitleCapsule(
                        title: title,
                        subtitle: capsuleSubtitle(subtitle),
                        layout: .stacked,
                        action: onSelectScope
                    )
                }
            }
    }

    @ViewBuilder
    private func landscapeCapsuleChrome(title: String, subtitle: String) -> some View {
        content()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ArticleListTitleCapsule(
                        title: title,
                        subtitle: capsuleSubtitle(subtitle),
                        layout: .inline,
                        action: onSelectScope
                    )
                }
            }
    }

    var body: some View {
        let title = ArticleListTitlePresentation.title(scope: store.scope, catalog: store.catalog)
        let countLabel = ArticleListCounterPresentation.expandedLabel(scope: store.scope, unreadOnly: store.unreadOnly, count: store.selectionTotal)
        // Portrait keeps the descriptive count label. Landscape preserves the
        // same count feature but uses the compact numeric form so the leading
        // title and trailing action group have predictable room.
        let portraitSubtitle = store.isSyncing ? String(localized: "Syncing…") : countLabel
        let landscapeSubtitle = store.isSyncing
            ? String(localized: "Syncing…")
            : ArticleListCounterPresentation.compactCount(store.selectionTotal)

        switch chromeMode {
        case .compactPortrait:
            portraitCapsuleChrome(title: title, subtitle: portraitSubtitle)
        case .compactLandscape:
            landscapeCapsuleChrome(title: title, subtitle: landscapeSubtitle)
        case .persistentSplit:
            // The persistent sidebar already communicates the selected scope.
            // Keep the detail navigation bar title-free and reserve its trailing
            // side for the article actions.
            content()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension ContentView {
    private var usesReaderInspector: Bool {
        adaptivePresentation.readerPresentationKind == .inspector
    }

    /// The browser, reader and share sheets follow whichever surface is
    /// frontmost. A view can present only one sheet, so exactly one side — the
    /// root or the search sheet — is active at a time.
    private func gatedBrowser(active: Bool) -> Binding<IOSBrowserURL?> {
        Binding(get: { active ? browser : nil }, set: { if active { browser = $0 } })
    }

    private func gatedShare(active: Bool) -> Binding<IOSSharePayload?> {
        Binding(get: { active ? sharePayload : nil }, set: { if active { sharePayload = $0 } })
    }

    private func gatedReaderSheet(active: Bool) -> Binding<IOSReaderArticle?> {
        Binding(
            get: { active && !usesReaderInspector ? readerArticle : nil },
            set: { if $0 == nil, active, !usesReaderInspector { dismissReader() } }
        )
    }


    private var readerInspectorBinding: Binding<Bool> {
        Binding(
            get: { usesReaderInspector && readerArticle != nil },
            set: { if !$0, usesReaderInspector { dismissReader() } }
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
            readerErrorMessage = String(localized: "The article does not have a valid web URL.")
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
