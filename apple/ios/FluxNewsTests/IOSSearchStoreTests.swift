import XCTest
@testable import FluxNews

final class IOSSearchStoreTests: XCTestCase {
    func testInitialSearchStateIsUnsubmitted() async {
        let store = await MainActor.run { IOSSearchStore() }
        let state = await MainActor.run { (store.query, store.submittedQuery, store.results.count, store.total, store.hasSearched, store.isSearching, store.isLoadingMore, store.errorMessage) }
        XCTAssertEqual(state.0, "")
        XCTAssertEqual(state.1, "")
        XCTAssertEqual(state.2, 0)
        XCTAssertEqual(state.3, 0)
        XCTAssertFalse(state.4)
        XCTAssertFalse(state.5)
        XCTAssertFalse(state.6)
        XCTAssertNil(state.7)
    }

    func testPaginationUsesLoadedCountAndStopsAtTotal() {
        XCTAssertEqual(IOSSearchPaginationPolicy.pageSize, 50)
        XCTAssertEqual(IOSSearchPaginationPolicy.nextOffset(resultCount: 0, total: 120), 0)
        XCTAssertEqual(IOSSearchPaginationPolicy.nextOffset(resultCount: 50, total: 120), 50)
        XCTAssertNil(IOSSearchPaginationPolicy.nextOffset(resultCount: 120, total: 120))
        XCTAssertTrue(IOSSearchPaginationPolicy.canLoadMore(resultCount: 50, total: 120, hasSearched: true, isSearching: false, isLoadingMore: false, hasError: false))
        XCTAssertFalse(IOSSearchPaginationPolicy.canLoadMore(resultCount: 50, total: 120, hasSearched: true, isSearching: false, isLoadingMore: true, hasError: false))
        XCTAssertFalse(IOSSearchPaginationPolicy.canLoadMore(resultCount: 50, total: 120, hasSearched: false, isSearching: false, isLoadingMore: false, hasError: false))
    }

    func testPaginationDeduplicatesArticleIDs() {
        let first = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "First", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: nil)
        let duplicate = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Duplicate", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: nil)
        let second = ArticleSummary(id: 2, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Second", url: "https://example.com/2", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: nil)
        XCTAssertEqual(IOSSearchPaginationPolicy.deduplicated([first, duplicate, second]).map(\.id), [1, 2])
    }

    func testStaleSearchRequestsAreRejectedAfterNewSearchOrClear() {
        var state = IOSSearchRequestState()
        let first = state.begin()
        let second = state.begin()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))
        state.invalidate()
        XCTAssertFalse(state.isCurrent(second))
    }

    @MainActor
    func testClearResetsAllTransientSearchState() {
        let store = IOSSearchStore()
        store.query = "  Apple  "
        store.clear()
        XCTAssertEqual(store.query, "")
        XCTAssertEqual(store.submittedQuery, "")
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(store.total, 0)
        XCTAssertFalse(store.hasSearched)
        XCTAssertFalse(store.isSearching)
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertNil(store.errorMessage)
    }
}
