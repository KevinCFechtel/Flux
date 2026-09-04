import SwiftUI

struct SearchView: View {
    @ObservedObject var store: IOSSearchStore
    @ObservedObject var newsreaderStore: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    let onSetRead: (ArticleSummary, Bool) -> Void
    let onSetStarred: (ArticleSummary, Bool) -> Void
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        Group {
            if store.isSearching && store.results.isEmpty {
                ProgressView("Searching")
            } else if let errorMessage = store.errorMessage, store.results.isEmpty {
                ContentUnavailableView {
                    Label("Unable to Search", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { store.retry() }
                }
            } else if !store.hasSearched {
                ContentUnavailableView.search
            } else if store.results.isEmpty {
                ContentUnavailableView.search(text: store.submittedQuery)
            } else {
                GeometryReader { proxy in
                    let horizontalInset: CGFloat = proxy.size.width > 700 ? 28 : 16
                    let spacing: CGFloat = ArticlePresentationLayout.usesLandscapeVisual(mode: newsreaderStore.articlePresentationMode, availableWidth: proxy.size.width - horizontalInset * 2) ? 20 : 26
                    ScrollView {
                        LazyVStack(spacing: spacing) {
                            ForEach(store.results, id: \.id) { article in
                                ArticlePresentationView(article: article, mode: newsreaderStore.articlePresentationMode, previewLines: newsreaderStore.articlePreviewLines, availableWidth: proxy.size.width - horizontalInset * 2, feedIconData: newsreaderStore.feedIcons[article.feedId], onRequestFeedIcon: { newsreaderStore.requestFeedIcon(article.feedId) }, onTap: { onArticleTap(article) }, onAction: { onArticleAction(article, $0) }, onSetRead: onSetRead, onSetStarred: onSetStarred)
                                    .equatable()
                                    .onAppear { if article.id == store.results.last?.id { store.loadMore() } }
                            }
                            if store.isLoadingMore { ProgressView().padding() }
                            if let errorMessage = store.errorMessage, !store.results.isEmpty {
                                VStack(spacing: 8) {
                                    Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    Button("Retry") { store.retry() }
                                }
                                .padding()
                            } else if store.hasSearched {
                                Text("Showing \(store.results.count) of \(store.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 8)
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationTitle(store.hasSearched ? "Search Results" : "Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Miniflux")
        .searchFocused($searchFieldFocused)
        .onSubmit(of: .search) { store.submit() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.hasSearched || !store.query.isEmpty {
                    Button("Clear") { store.clear() }
                }
            }
        }
        .onAppear { searchFieldFocused = true }
        .onDisappear { store.invalidate() }
    }
}
