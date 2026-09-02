import SwiftUI
import UIKit

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
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .all

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
    }

    @ViewBuilder
    private var newsreader: some View {
        if usesSplitNavigation {
            NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
                NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented)
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
                    }
                    .sheet(isPresented: $navigationPresented) {
                        NavigationStack {
                            NewsNavigationView(store: newsreaderStore, iPhoneSheetPresented: $navigationPresented)
                                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
                        }
                    }
            }
        }
    }

    private var articleList: some View {
        ArticleListView(store: newsreaderStore)
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
                        Button { diagnosticsPresented = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("Developer diagnostics")
                    }
                }
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
