import SwiftUI
import UIKit
import SafariServices

private struct IOSBrowserURL: Identifiable {
    let url: URL
    var id: URL { url }
}

enum NewsNavigationLayout {
    static func usesSplitView(for idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .pad
    }
}

struct ContentView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    @ObservedObject var newsreaderStore: NewsreaderStore
    @State private var navigationPresented = false
    @State private var diagnosticsPresented = false
    @State private var optionsPresented = false
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var browser: IOSBrowserURL?
    @State private var articleOpenError: String?
    @State private var articleOpenGeneration = 0

    private var usesSplitNavigation: Bool {
        NewsNavigationLayout.usesSplitView(for: UIDevice.current.userInterfaceIdiom)
    }

    var body: some View {
        Group {
            if case .ready = bootstrapper.state, newsreaderStore.core != nil {
                newsreader
            } else {
                DeveloperDiagnosticsView(bootstrapper: bootstrapper)
            }
        }
        .sheet(isPresented: $diagnosticsPresented) { DeveloperDiagnosticsView(bootstrapper: bootstrapper) }
        .sheet(item: $browser) { item in IOSInAppBrowser(url: item.url) }
        .alert("Unable to Open Article", isPresented: Binding(get: { articleOpenError != nil }, set: { if !$0 { articleOpenError = nil } })) {
            Button("OK", role: .cancel) { articleOpenError = nil }
        } message: { Text(articleOpenError ?? "") }
    }

    @ViewBuilder
    private var newsreader: some View {
        if usesSplitNavigation {
            NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
                NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sidebar).toolbar(removing: .sidebarToggle)
            } detail: {
                articleList
            }
        } else {
            NavigationStack {
                articleList
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
                            Button { diagnosticsPresented = true } label: {
                                Label("Diagnostics", systemImage: "info.circle")
                            }
                            .accessibilityLabel("Developer diagnostics")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { optionsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                                .accessibilityLabel("Newsreader options")
                        }
                    }
                    .sheet(isPresented: $navigationPresented) {
                        NavigationStack {
                            NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented, presentation: .sheet)
                                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
                        }
                    }
                    .sheet(isPresented: $optionsPresented) { NewsreaderOptionsView(store: newsreaderStore) }
            }
        }
    }

    private var articleList: some View {
        ArticleListView(store: newsreaderStore, onArticleTap: openArticle)
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { diagnosticsPresented = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Developer diagnostics")
                    }
                }
            }
            .sheet(isPresented: $optionsPresented) { NewsreaderOptionsView(store: newsreaderStore) }
    }

    private func openArticle(_ article: ArticleSummary) {
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
}

private struct IOSInAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct NewsreaderOptionsView: View {
    @ObservedObject var store: NewsreaderStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Articles") {
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
        }
    }
}
