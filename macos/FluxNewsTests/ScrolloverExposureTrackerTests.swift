import CoreGraphics
import XCTest

final class ScrolloverExposureTrackerTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let unread: Set<Int64> = [1]

    private func frame(_ y: CGFloat) -> [Int64: CGRect] {
        [1: CGRect(x: 0, y: y, width: 100, height: 100)]
    }

    func testFirstQualifiedItemIsProcessedWhenItCrossesViewport() {
        var tracker = ScrolloverExposureTracker()
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0.7)

        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 0.8, offsetDelta: 50, userInitiated: true), [1])
    }

    func testBriefExposureIsNotProcessed() {
        var tracker = ScrolloverExposureTracker()
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0.69)

        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 0.7, offsetDelta: 50, userInitiated: true), [])
    }

    func testProgrammaticAndLargeScrollsDoNotProcess() {
        var tracker = ScrolloverExposureTracker()
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0.7)

        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 0.8, offsetDelta: 50, userInitiated: false), [])
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 1)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 1.7)
        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 1.8, offsetDelta: 86, userInitiated: true), [])
    }

    func testLaterQualifiedItemStillProcessesAfterRejectedScroll() {
        var tracker = ScrolloverExposureTracker()
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 0.7)
        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 0.8, offsetDelta: 86, userInitiated: true), [])

        tracker.rebase(frames: frame(0), unread: unread)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 1)
        tracker.observe(frames: frame(0), viewport: viewport, unread: unread, now: 1.7)
        XCTAssertEqual(tracker.process(frames: frame(-100), viewport: viewport, unread: unread, now: 1.8, offsetDelta: 50, userInitiated: true), [1])
    }

    func testUndoBatchAccumulatesMultipleFlushesInOneScroll() {
        var batch = ScrolloverUndoBatch()
        batch.beginScroll()
        XCTAssertEqual(batch.append([1]), [1])
        XCTAssertFalse(batch.showsUndo)
        XCTAssertEqual(batch.append([2]), [1, 2])
        XCTAssertTrue(batch.showsUndo)
    }

    func testUndoBatchDeduplicatesFlushes() {
        var batch = ScrolloverUndoBatch()
        batch.beginScroll()
        XCTAssertEqual(batch.append([1, 2]), [1, 2])
        XCTAssertEqual(batch.append([2, 3]), [1, 2, 3])
        XCTAssertTrue(batch.showsUndo)
    }

    func testNewScrollReplacesUndoBatchOnlyAfterItMarksArticles() {
        var batch = ScrolloverUndoBatch()
        batch.beginScroll()
        XCTAssertEqual(batch.append([1, 2]), [1, 2])
        batch.beginScroll()
        XCTAssertEqual(batch.articleIDs, [1, 2])
        XCTAssertEqual(batch.append([3]), [3])
        XCTAssertFalse(batch.showsUndo)
    }

    func testFeedIconRequestStateCompletesEveryTerminalOutcome() {
        var requests = FeedIconRequestState()
        XCTAssertTrue(requests.begin("1-normal", cached: false))
        XCTAssertFalse(requests.begin("1-normal", cached: false))
        requests.complete("1-normal")
        XCTAssertFalse(requests.isInFlight("1-normal"))

        XCTAssertTrue(requests.begin("1-dark", cached: false))
        requests.complete("1-dark")
        XCTAssertTrue(requests.begin("1-dark", cached: false))
        XCTAssertFalse(requests.begin("1-normal", cached: true))
    }

    func testArticleThumbnailRequestStateDoesNotSuppressTerminalOutcomes() {
        var requests = ArticleThumbnailRequestState()
        XCTAssertTrue(requests.begin("1-image", cached: false))
        XCTAssertFalse(requests.begin("1-image", cached: false))
        requests.complete("1-image")
        XCTAssertFalse(requests.isInFlight("1-image"))

        XCTAssertTrue(requests.begin("1-image", cached: false))
        requests.complete("1-image")
        XCTAssertFalse(requests.begin("1-image", cached: true))
    }

    func testManualSyncAlwaysReplacesAndResetsSnapshot() {
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: true, dataChanged: false, popoverVisible: true, hasMeaningfullyInteracted: true), .replace)
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: true, dataChanged: true, popoverVisible: true, hasMeaningfullyInteracted: true), .replace)
    }

    func testAutomaticUntouchedSnapshotReplacesWhenDataChanges() {
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: true, popoverVisible: true, hasMeaningfullyInteracted: false), .replace)
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: true, popoverVisible: false, hasMeaningfullyInteracted: true), .replace)
    }

    func testAutomaticInteractedSnapshotSignalsNewDataWithoutReplacement() {
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: true, popoverVisible: true, hasMeaningfullyInteracted: true), .signalNewData)
    }

    func testUnchangedAutomaticSyncAndLocalMutationDoNotReplaceSnapshot() {
        XCTAssertEqual(SnapshotRefreshPolicy.action(manual: false, dataChanged: false, popoverVisible: true, hasMeaningfullyInteracted: false), .preserve)
        XCTAssertNotEqual(SnapshotRefreshPolicy.Action.preserve, .replace)
    }
}
