import SwiftUI

struct SearchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: IOSSearchStore
    var newsreaderStore: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    let onSetRead: (ArticleSummary, Bool) -> Void
    let onSetStarred: (ArticleSummary, Bool) -> Void

    var body: some View {
        let iconVariant = IOSFeedIconPresentation.variant(isDark: colorScheme == .dark)

        Group {
            if store.isSearching && store.results.isEmpty {
                ProgressView("Searching")
            } else if let errorMessage = store.errorMessage, store.results.isEmpty {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
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
                IOSUIKitArticleTimelineView(
                    items: timelineItems(iconVariant: iconVariant),
                    mode: newsreaderStore.articlePresentationMode,
                    previewLines: newsreaderStore.articlePreviewLines,
                    iconVariant: iconVariant,
                    scrollResetRevision: 0,
                    markReadOnScrolloverEnabled: false,
                    showsRefreshControl: false,
                    onArticleTap: onArticleTap,
                    onArticleAction: onArticleAction,
                    onSetRead: onSetRead,
                    onSetStarred: onSetStarred,
                    onRequestFeedIcon: { feedID, variant in
                        newsreaderStore.requestFeedIcon(feedID, variant: variant)
                    },
                    onRefresh: {},
                    onApproachingEnd: { store.loadMore() },
                    onMeaningfulInteraction: {},
                    onScrolloverBatch: { _ in },
                    onScrolloverDirection: { _ in },
                    onScrolloverPhase: { _ in }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationTitle(store.hasSearched ? "Search Results" : "Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Miniflux")
        .onSubmit(of: .search) { store.submit() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { store.clear() }
                    .disabled(!store.hasSearched && store.query.isEmpty)
            }
        }
        .onDisappear { store.invalidate() }
    }

    private func timelineItems(iconVariant: FeedIconVariant) -> [IOSUIKitArticleTimelineItem] {
        store.results.map { article in
            let feedIcon = newsreaderStore.feedIconPresentationState(for: article.feedId, variant: iconVariant)
            return IOSUIKitArticleTimelineItem(
                article: article,
                content: ArticleRowContent(article: article),
                isRead: article.isRead,
                isStarred: article.isStarred,
                feedIconImage: feedIcon.image
            )
        }
    }
}
