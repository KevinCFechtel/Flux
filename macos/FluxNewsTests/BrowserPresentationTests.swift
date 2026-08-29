import XCTest

final class BrowserPresentationTests: XCTestCase {
    func testStartupScopeResolvesKnownTargets() {
        XCTAssertEqual(StartupScopeResolver.resolve(.allNews, categoryID: nil, feedID: nil, categoryIDs: [7], feedIDs: [42]), .all)
        XCTAssertEqual(StartupScopeResolver.resolve(.starred, categoryID: nil, feedID: nil, categoryIDs: [7], feedIDs: [42]), .starred)
        XCTAssertEqual(StartupScopeResolver.resolve(.category, categoryID: 7, feedID: nil, categoryIDs: [7], feedIDs: [42]), .category(7))
        XCTAssertEqual(StartupScopeResolver.resolve(.feed, categoryID: nil, feedID: 42, categoryIDs: [7], feedIDs: [42]), .feed(42))
    }

    func testStartupScopeFallsBackForMissingTarget() {
        XCTAssertEqual(StartupScopeResolver.resolve(.category, categoryID: 7, feedID: nil, categoryIDs: [], feedIDs: []), .all)
        XCTAssertEqual(StartupScopeResolver.resolve(.feed, categoryID: nil, feedID: 42, categoryIDs: [], feedIDs: []), .all)
    }

    func testHideEmptyFiltersFeedsAndThenCategories() {
        let feeds = [NavigationPresentationFeed(id: 1, categoryID: 10), .init(id: 2, categoryID: 10), .init(id: 3, categoryID: 20)]
        let visible = NavigationVisibility.visibleFeeds(feeds, hidingEmpty: true, counts: [1: 0, 2: 3, 3: 0])

        XCTAssertEqual(visible, [.init(id: 2, categoryID: 10)])
        XCTAssertEqual(NavigationVisibility.visibleCategoryIDs([10, 20], feeds: visible), [10])
        XCTAssertEqual(NavigationVisibility.visibleFeeds(feeds, hidingEmpty: false, counts: [:]), feeds)
    }

    func testRemoveOnReadOnlyAppliesToUnreadLocalSnapshots() {
        XCTAssertTrue(ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: true, unreadOnly: true, scope: .all))
        XCTAssertFalse(ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: false, unreadOnly: true, scope: .all))
        XCTAssertFalse(ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: true, unreadOnly: false, scope: .all))
        XCTAssertFalse(ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: true, unreadOnly: true, scope: .search))
    }
}
