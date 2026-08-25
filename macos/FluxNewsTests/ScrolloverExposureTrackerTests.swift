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
}
