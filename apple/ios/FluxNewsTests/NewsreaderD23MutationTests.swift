import XCTest
@testable import FluxNews

final class NewsreaderD23MutationTests: XCTestCase {
    private func article(_ id: Int64, read: Bool = false, starred: Bool = false) -> ArticleSummary {
        ArticleSummary(id: id, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: read, isStarred: starred, preview: "Preview", imageUrl: nil)
    }

    func testContentMinYDeltaIsConvertedToTrackerDownwardDirection() {
        XCTAssertEqual(IOSScrolloverDirection.offsetDelta(contentMinYDelta: -40), 40)
        XCTAssertEqual(IOSScrolloverDirection.offsetDelta(contentMinYDelta: 40), -40)
    }

    func testDisabledScrolloverGateRejectsProcessing() {
        XCTAssertFalse(IOSScrolloverProcessingGate.shouldProcess(enabled: false))
        XCTAssertTrue(IOSScrolloverProcessingGate.shouldProcess(enabled: true))
    }

    @MainActor
    func testReadMutationUpdatesVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1)])
        store.applyReadMutationForTesting([1], read: true)
        XCTAssertTrue(store.articles[0].isRead)
    }

    @MainActor
    func testRemoveWhenReadRemovesOnlyUnreadScopeRows() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2, read: true)])
        store.applyReadMutationForTesting([1], read: true)
        XCTAssertEqual(store.articles.map(\.id), [2])
    }

    @MainActor
    func testStarMutationUpdatesVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        store.applyStarredMutationForTesting([1], starred: true)
        XCTAssertTrue(store.articles[0].isStarred)
    }

    @MainActor
    func testUnstarRemovesArticleFromStarredScope() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .starred
        store.setArticlesForTesting([article(1, starred: true), article(2, starred: true)])
        store.applyStarredMutationForTesting([1], starred: false)
        XCTAssertEqual(store.articles.map(\.id), [2])
    }

    func testOppositeDirectionDoesNotQualifyTracker() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 1)
        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: 120, width: 100, height: 100)], viewport: viewport, unread: [1], now: 2, offsetDelta: -40, userInitiated: true).isEmpty)
    }

    func testScrolloverIDsAreDeduplicatedAndUndoRequiresTwo() {
        var batch = ScrolloverUndoBatch()
        batch.beginScroll()
        XCTAssertEqual(batch.append([1, 1, 2, 2]), [1, 2])
        XCTAssertTrue(batch.showsUndo)
    }

    @MainActor
    func testUndoRestoresRemovedArticlesInOriginalOrder() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.beginScrolloverUndoBatch()
        store.applyReadMutationForTesting([1, 3], read: true, retainingForScrolloverUndo: true)
        store.restoreScrolloverRemovedArticlesForTesting()
        XCTAssertEqual(store.articles.map(\.id), [1, 2, 3])
    }

    @MainActor
    func testFailedMutationPathDoesNotChangeVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let value = article(1)
        store.setArticlesForTesting([value])
        store.setRead(value, read: true)
        store.setStarred(value, starred: true)
        XCTAssertFalse(store.articles[0].isRead)
        XCTAssertFalse(store.articles[0].isStarred)
    }

    func testAutomaticRefreshPreservesInteractedSnapshotAndSignalsNewData() {
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: true, hasMeaningfullyInteracted: true), .signalNewData)
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: true, hasMeaningfullyInteracted: false), .replace)
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: false, hasMeaningfullyInteracted: true), .preserve)
    }

    func testPendingNewDataAdoptionIsScopeAware() {
        var pending = PendingNewData()
        pending.accumulate([(feedID: 1, count: 2), (feedID: 2, count: 1)])
        pending.adoptFeeds(in: [1])
        XCTAssertEqual(pending.byFeed, [2: 1])
        XCTAssertTrue(pending.hasPending)
    }

    @MainActor
    func testAccumulatedNewDataPublishesAdoptionSignal() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.accumulateNewData([(feedID: 10, count: 3)])
        XCTAssertTrue(store.hasPendingNewData)
        XCTAssertTrue(store.newDataAvailable)
        store.resetVisibleSnapshot()
        XCTAssertEqual(store.articles.count, 0)
    }

    func testInvalidStartupTargetsFallBackToAllNews() {
        XCTAssertEqual(StartupScopeResolver.resolve(.category, categoryID: 99, feedID: nil, categoryIDs: [1], feedIDs: []), .all)
        XCTAssertEqual(StartupScopeResolver.resolve(.feed, categoryID: nil, feedID: 99, categoryIDs: [], feedIDs: [1]), .all)
    }
}
