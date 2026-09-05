import XCTest
@testable import FluxNews

final class NewsreaderD23MutationTests: XCTestCase {
    private func article(_ id: Int64, read: Bool = false, starred: Bool = false) -> ArticleSummary {
        ArticleSummary(id: id, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: read, isStarred: starred, preview: "Preview", imageUrl: nil)
    }

    func testInitialVisibleTargetsEstablishABaseline() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3])
        XCTAssertTrue(tracker.receiveVisibleIDs([1, 2], unread: [1, 2, 3], enabled: true).isEmpty)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([2], unread: [1, 2, 3], enabled: true), [1])
    }

    func testSkippedAndLargeForwardJumpsUseTheOrderedRange() {
        var tracker = IOSScrolloverOrderTracker()
        let ids = Array(0...50).map(Int64.init)
        tracker.updateSnapshot(ids)
        _ = tracker.receiveVisibleIDs([20], unread: Set(ids), enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([35], unread: Set(ids), enabled: true), Array(20..<35).map(Int64.init))
        XCTAssertEqual(tracker.receiveVisibleIDs([50], unread: Set(ids), enabled: true), Array(35..<50).map(Int64.init))
    }

    func testBackwardAndDuplicateVisibilityUpdatesDoNotEmit() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([2], unread: [1, 2, 3, 4, 5], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], unread: [1, 2, 3, 4, 5], enabled: true), [2, 3])
        XCTAssertTrue(tracker.receiveVisibleIDs([1], unread: [1, 2, 3, 4, 5], enabled: true).isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([5], unread: [1, 2, 3, 4, 5], enabled: true), [1, 4])
        XCTAssertTrue(tracker.receiveVisibleIDs([5], unread: [1, 2, 3, 4, 5], enabled: true).isEmpty)
    }

    func testReadArticlesAndStructuralSnapshotsDoNotCreateCandidates() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], unread: [1, 3, 4], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], unread: [1, 3, 4], enabled: true), [1, 3])
        tracker.updateSnapshot([9, 1, 2, 3, 4])
        XCTAssertTrue(tracker.receiveVisibleIDs([4], unread: [9, 1, 2, 3, 4], enabled: true).isEmpty)
        XCTAssertTrue(tracker.receiveVisibleIDs([4], unread: [9, 1, 2, 3, 4], enabled: true).isEmpty)
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
    func testUnreadMutationUsesTheExistingReadMutationPath() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1, read: true)])
        store.applyReadMutationForTesting([1], read: false)
        XCTAssertFalse(store.articles[0].isRead)
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
    func testScrolloverReadDefersRemovalWhilePresentationScrollIsActive() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        store.beginScrolloverPresentationScrollForTesting()
        store.applyScrolloverMutationForTesting([1])

        XCTAssertEqual(store.articles.map(\.id), [1, 2])
        XCTAssertTrue(store.articles[0].isRead)
        XCTAssertEqual(store.scrolloverPendingRemovalsForTesting, [1])
    }

    @MainActor
    func testScrolloverReadIsRemovedOncePresentationScrollReachesIdle() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        store.beginScrolloverPresentationScrollForTesting()
        store.applyScrolloverMutationForTesting([1])

        let resetRevision = store.scrollResetRevision
        store.finishScrolloverPresentationScrollForTesting()

        XCTAssertEqual(store.articles.map(\.id), [2])
        XCTAssertTrue(store.scrolloverPendingRemovalsForTesting.isEmpty)
        XCTAssertGreaterThan(store.scrollResetRevision, resetRevision)
    }

    @MainActor
    func testScrolloverReadRemainsVisibleWhenPolicyKeepsReadArticles() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = false
        store.setArticlesForTesting([article(1)])
        store.beginScrolloverPresentationScrollForTesting()
        store.applyScrolloverMutationForTesting([1])

        XCTAssertEqual(store.articles.map(\.id), [1])
        XCTAssertTrue(store.articles[0].isRead)
        XCTAssertTrue(store.scrolloverPendingRemovalsForTesting.isEmpty)

        store.finishScrolloverPresentationScrollForTesting()

        XCTAssertTrue(store.articles[0].isRead)
    }

    @MainActor
    func testMultipleScrolloverReadsAreRemovedCoherentlyAtIdle() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        store.beginScrolloverPresentationScrollForTesting()
        store.applyScrolloverMutationForTesting([1])
        store.applyScrolloverMutationForTesting([2, 3])

        XCTAssertEqual(store.articles.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(store.scrolloverPendingRemovalsForTesting, [1, 2, 3])
        store.finishScrolloverPresentationScrollForTesting()
        XCTAssertEqual(store.articles.map(\.id), [4])
    }

    @MainActor
    func testUndoRestoresScrolloverReadAwaitingDeferredRemoval() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        store.beginScrolloverPresentationScrollForTesting()
        store.applyScrolloverMutationForTesting([1, 2])

        store.applyScrolloverUndoForTesting()

        XCTAssertEqual(store.articles.map(\.id), [1, 2])
        XCTAssertTrue(store.articles.allSatisfy { !$0.isRead })
        XCTAssertTrue(store.scrolloverPendingRemovalsForTesting.isEmpty)
    }

    @MainActor
    func testStarMutationUpdatesVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        store.applyStarredMutationForTesting([1], starred: true)
        XCTAssertTrue(store.articles[0].isStarred)
    }

    @MainActor
    func testUnstarMutationUsesTheExistingStarMutationPath() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1, starred: true)])
        store.applyStarredMutationForTesting([1], starred: false)
        XCTAssertFalse(store.articles[0].isStarred)
    }

    @MainActor
    func testUnstarRemovesArticleFromStarredScope() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .starred
        store.setArticlesForTesting([article(1, starred: true), article(2, starred: true)])
        store.applyStarredMutationForTesting([1], starred: false)
        XCTAssertEqual(store.articles.map(\.id), [2])
    }

    // Obsolete geometry/exposure tracker coverage was replaced by the ordered-ID
    // tracker tests above.
    /*
    func testScrolloverQualificationRequiresTheIdleDuration() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible: [Int64: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0.6)
        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.6, offsetDelta: 40, userInitiated: true).isEmpty)

        tracker = ScrolloverExposureTracker()
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0.6)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0.8)
        XCTAssertEqual(tracker.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.8, offsetDelta: 40, userInitiated: true), [1])
    }

    func testScrolloverQualificationResetsBelowVisibilityThreshold() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: [1: CGRect(x: 0, y: 80, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.6)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 1.0)
        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], now: 1.0, offsetDelta: 40, userInitiated: true).isEmpty)
    }

    func testRuntimeFrameProcessorProducesCandidateAfterIdleQualification() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible: [Int64: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 1)
        var lastOffset: CGFloat = 0
        let ids = IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 50, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: true, userInitiated: true)
        XCTAssertEqual(ids, [1])
    }

    func testRuntimeFrameProcessorRejectsDisabledButChecksLargeJumpGeometry() {
        var tracker = ScrolloverExposureTracker()
        var lastOffset: CGFloat = 0
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible: [Int64: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 1)

        XCTAssertTrue(IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: -20, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 20, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: false, userInitiated: true).isEmpty)
        XCTAssertEqual(IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 100, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: true, userInitiated: true), [1])
    }

    func testScrolloverForwardReverseForwardPreservesQualificationAndEmitsOnce() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.7)

        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: 30, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.8, offsetDelta: 30, userInitiated: true).isEmpty)
        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: 10, width: 100, height: 100)], viewport: viewport, unread: [1], now: 0.9, offsetDelta: -20, userInitiated: true).isEmpty)
        XCTAssertEqual(tracker.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], now: 1, offsetDelta: 20, userInitiated: true), [1])
        XCTAssertTrue(tracker.process(frames: [1: CGRect(x: 0, y: -140, width: 100, height: 100)], viewport: viewport, unread: [1], now: 1.1, offsetDelta: 40, userInitiated: true).isEmpty)
    }

    func testScrolloverUnqualifiedFastCrossingDoesNotProcess() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100), 2: CGRect(x: 0, y: 100, width: 100, height: 100)], viewport: viewport, unread: [1, 2], now: 0)
        tracker.observe(frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], viewport: viewport, unread: [1, 2], now: 0.8)

        XCTAssertEqual(tracker.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100), 2: CGRect(x: 0, y: -200, width: 100, height: 100)], viewport: viewport, unread: [1, 2], now: 0.9, offsetDelta: 200, userInitiated: true), [1])
    }

    @MainActor
    func testRuntimeFrameProcessorRejectsBackwardCanonicalPosition() {
        var tracker = ScrolloverExposureTracker()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible: [Int64: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 1)
        var lastOffset: CGFloat = 80

        XCTAssertTrue(IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: 100, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 40, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: true, userInitiated: true).isEmpty)
    }

    @MainActor
    func testRuntimeAdapterEmitsFirstQualifiedCrossingWithoutPrimingProcess() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates = $0 }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterEmitsFirstQualifiedCrossingWhenOffsetArrivesBeforeFrames() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.beginUserScroll()

        adapter.receiveContentOffsetY(120, unread: unread)
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(140, unread: unread)

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterEmitsFirstQualifiedCrossingWhenFramesArriveBeforeOffset() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.beginUserScroll()

        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)
        adapter.receiveContentOffsetY(140, unread: unread)

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterDoesNotProcessLayoutOnlyFrameChanges() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.beginUserScroll()

        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)

        XCTAssertTrue(candidates.isEmpty)
    }

    @MainActor
    func testRuntimeAdapterEmitsCandidateOnlyOnce() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()

        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)
        adapter.receiveFrames([1: CGRect(x: 0, y: -140, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(140, unread: unread)

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterDoesNotReemitArticleAfterItBecomesReadWhilePending() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)

        adapter.receiveFrames([1: CGRect(x: 0, y: -140, width: 100, height: 100)], unread: [])
        adapter.receiveContentOffsetY(160, unread: [])

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterRebasesAfterIdleGeometryChangeWithoutFalseCandidate() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 0, y: 100, width: 100, height: 100),
        ], unread: [1, 2])
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: [1, 2])
        adapter.beginUserScroll()
        adapter.receiveFrames([
            1: CGRect(x: 0, y: -100, width: 100, height: 100),
            2: CGRect(x: 0, y: 0, width: 100, height: 100),
        ], unread: [1, 2])
        adapter.receiveContentOffsetY(120, unread: [1, 2])
        XCTAssertEqual(candidates, [1])

        adapter.endUserScroll()
        adapter.receiveFrames([2: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: [2])
        adapter.receiveContentOffsetY(160, unread: [2])

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterPreservesQualifiedCrossingAcrossActiveViewportChanges() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(CGRect(x: 0, y: 0, width: 100, height: 100))
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()

        for height: CGFloat in [102, 105, 108, 110] {
            adapter.updateViewport(CGRect(x: 0, y: 0, width: 100, height: height))
        }
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)
        adapter.receiveFrames([1: CGRect(x: 0, y: -120, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(140, unread: unread)

        XCTAssertEqual(candidates, [1])
    }

    @MainActor
    func testRuntimeAdapterSnapshotResetClearsQualifiedExposure() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.reset() // ArticleListView invokes this for snapshotRevision changes.
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)

        XCTAssertTrue(candidates.isEmpty)
    }

    @MainActor
    func testRuntimeAdapterDisabledScrolloverDoesNotEmitAfterViewportChanges() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.updateEnabled(false)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()
        adapter.updateViewport(CGRect(x: 0, y: 0, width: 100, height: 105))
        adapter.receiveFrames([1: CGRect(x: 0, y: -100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(120, unread: unread)

        XCTAssertTrue(candidates.isEmpty)
    }

    @MainActor
    func testRuntimeAdapterDoesNotEmitForBackwardMovement() {
        let adapter = IOSScrolloverRuntimeAdapter()
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unread: Set<Int64> = [1]
        var candidates: [Int64] = []
        adapter.onCandidate = { candidates.append(contentsOf: $0) }
        adapter.updateViewport(viewport)
        adapter.receiveFrames([1: CGRect(x: 0, y: 0, width: 100, height: 100)], unread: unread)
        adapter.observeIdle(now: Date.timeIntervalSinceReferenceDate + 0.8)
        adapter.receiveContentOffsetY(100, unread: unread)
        adapter.beginUserScroll()

        adapter.receiveFrames([1: CGRect(x: 0, y: 100, width: 100, height: 100)], unread: unread)
        adapter.receiveContentOffsetY(80, unread: unread)

        XCTAssertTrue(candidates.isEmpty)
    }

    */
    func testSwipeConfigurationSupportsZeroOneAndTwoActions() {
        let empty = IOSArticleSwipeSideConfiguration(actions: [])
        let one = IOSArticleSwipeSideConfiguration(actions: [.read])
        let two = IOSArticleSwipeSideConfiguration(actions: [.unread, .star])

        XCTAssertNil(empty.fullSwipeAction)
        XCTAssertEqual(one.fullSwipeAction, .read)
        XCTAssertEqual(two.fullSwipeAction, .star)
    }

    func testSwipeConfigurationKeepsTheOuterVisualActionAsFullSwipe() {
        let leading = IOSArticleSwipeSideConfiguration(actions: [.star, .read])
        let trailing = IOSArticleSwipeSideConfiguration(actions: [.unread, .unstar])
        let configuration = IOSArticleSwipeConfiguration(leading: leading, trailing: trailing)

        XCTAssertEqual(configuration.leading.actions, [.star, .read])
        XCTAssertEqual(configuration.leading.fullSwipeAction, .read)
        XCTAssertEqual(configuration.trailing.actions, [.unread, .unstar])
        XCTAssertEqual(configuration.trailing.fullSwipeAction, .unstar)
    }

    func testPartialSwipeRevealsWithoutCommittingAMutation() {
        let configuration = IOSArticleSwipeConfiguration(
            leading: IOSArticleSwipeSideConfiguration(actions: [.read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [.star])
        )

        XCTAssertEqual(
            IOSArticleSwipeInteraction.endState(effectiveOffset: 80, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300),
            .revealed(.right)
        )
        XCTAssertEqual(
            IOSArticleSwipeInteraction.endState(effectiveOffset: -20, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300),
            .closed
        )
    }

    func testDeliberateFullSwipeCommitsOnlyTheOuterAction() {
        let configuration = IOSArticleSwipeConfiguration(
            leading: IOSArticleSwipeSideConfiguration(actions: [.star, .read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [.unread, .unstar])
        )

        XCTAssertEqual(
            IOSArticleSwipeInteraction.endState(effectiveOffset: 300, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300),
            .fullSwipe(.read)
        )
        XCTAssertEqual(
            IOSArticleSwipeInteraction.endState(effectiveOffset: -300, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300),
            .fullSwipe(.unstar)
        )
    }

    func testSwipeUsesEffectiveOffsetToCloseBeforeRevealingTheOppositeSide() {
        let configuration = IOSArticleSwipeConfiguration(
            leading: IOSArticleSwipeSideConfiguration(actions: [.read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [.star])
        )

        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: 76, rawTranslation: -40), 36)
        XCTAssertEqual(IOSArticleSwipeInteraction.visibleOffset(effectiveOffset: 36, configuration: configuration, swipeActionWidth: 76), 36)
        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: 76, rawTranslation: -76), 0)
        XCTAssertEqual(IOSArticleSwipeInteraction.endState(effectiveOffset: 0, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300), .closed)
        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: 76, rawTranslation: -120), -44)
        XCTAssertEqual(IOSArticleSwipeInteraction.endState(effectiveOffset: -44, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300), .revealed(.left))
    }

    func testSwipeMirrorsReversalFromTrailingToLeading() {
        let configuration = IOSArticleSwipeConfiguration(
            leading: IOSArticleSwipeSideConfiguration(actions: [.read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [.star])
        )

        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: -76, rawTranslation: 40), -36)
        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: -76, rawTranslation: 76), 0)
        XCTAssertEqual(IOSArticleSwipeInteraction.effectiveOffset(startOffset: -76, rawTranslation: 120), 44)
        XCTAssertEqual(IOSArticleSwipeInteraction.endState(effectiveOffset: 44, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300), .revealed(.right))
    }

    func testFullSwipeArmingUsesRawEffectiveProgressRatherThanVisibleOffset() {
        let configuration = IOSArticleSwipeConfiguration(
            leading: IOSArticleSwipeSideConfiguration(actions: [.star, .read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [.unstar])
        )

        XCTAssertEqual(IOSArticleSwipeInteraction.visibleOffset(effectiveOffset: 300, configuration: configuration, swipeActionWidth: 190), 300)
        XCTAssertEqual(IOSArticleSwipeInteraction.state(effectiveOffset: 299, configuration: configuration, fullSwipeDistance: 300), .dragging(.right))
        XCTAssertEqual(IOSArticleSwipeInteraction.state(effectiveOffset: 300, configuration: configuration, fullSwipeDistance: 300), .fullSwipeArmed(.right))
        XCTAssertEqual(IOSArticleSwipeInteraction.state(effectiveOffset: 250, configuration: configuration, fullSwipeDistance: 300), .dragging(.right))
        XCTAssertEqual(IOSArticleSwipeInteraction.endState(effectiveOffset: 250, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300), .revealed(.right))
        XCTAssertEqual(IOSArticleSwipeInteraction.endState(effectiveOffset: 300, configuration: configuration, revealThreshold: 38, fullSwipeDistance: 300), .fullSwipe(.read))
    }

    func testFullSwipeDistanceIsActionBasedAndIndependentOfArticleWidth() {
        XCTAssertEqual(IOSArticleSwipeInteraction.fullSwipeDistance(actionWidth: 76), 190)
        XCTAssertLessThan(IOSArticleSwipeInteraction.fullSwipeDistance(actionWidth: 76), 390 * 0.85)
    }

    func testArmedFeedbackTriggersOnlyWhenEnteringArmedState() {
        XCTAssertTrue(IOSArticleSwipeInteraction.shouldTriggerArmedFeedback(from: .dragging(.right), to: .fullSwipeArmed(.right)))
        XCTAssertFalse(IOSArticleSwipeInteraction.shouldTriggerArmedFeedback(from: .fullSwipeArmed(.right), to: .fullSwipeArmed(.right)))
        XCTAssertFalse(IOSArticleSwipeInteraction.shouldTriggerArmedFeedback(from: .fullSwipeArmed(.right), to: .dragging(.right)))
        XCTAssertTrue(IOSArticleSwipeInteraction.shouldTriggerArmedFeedback(from: .dragging(.right), to: .fullSwipeArmed(.right)))
    }

    func testSwipeActionsRouteToExistingArticleMutationsAndExposeAccessibilityLabels() {
        XCTAssertEqual(IOSArticleSwipeAction.read.mutation, .read(true))
        XCTAssertEqual(IOSArticleSwipeAction.unread.mutation, .read(false))
        XCTAssertEqual(IOSArticleSwipeAction.star.mutation, .starred(true))
        XCTAssertEqual(IOSArticleSwipeAction.unstar.mutation, .starred(false))
        XCTAssertEqual(IOSArticleSwipeAction.read.accessibilityLabel, "Mark as Read")
        XCTAssertEqual(IOSArticleSwipeAction.unread.accessibilityLabel, "Mark as Unread")
        XCTAssertEqual(IOSArticleSwipeAction.star.accessibilityLabel, "Star")
        XCTAssertEqual(IOSArticleSwipeAction.unstar.accessibilityLabel, "Unstar")
    }

    @MainActor
    func testRollingUndoAggregatesDeduplicatesAndRestoresAllReads() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting((1...9).map { article(Int64($0)) })
        store.beginScrolloverPresentationScrollForTesting()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        store.applyScrolloverMutationForTesting([1, 2, 3, 4], now: start)
        store.applyScrolloverMutationForTesting([4, 5, 6, 7, 8, 9], now: start.addingTimeInterval(3))
        store.finishScrolloverPresentationScrollForTesting()
        store.applyScrolloverUndoForTesting()
        XCTAssertEqual(store.articles.map(\.id), Array(1...9).map(Int64.init))
        XCTAssertTrue(store.articles.allSatisfy { !$0.isRead })
    }

    @MainActor
    func testTransientArticleFiltersAreNotPersistedAsSettings() {
        let suiteName = "FluxNews.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NewsreaderStore(defaults: defaults)

        store.setUnreadOnly(false)
        store.setNewestFirst(true)

        XCTAssertNil(defaults.object(forKey: "FluxNews.iOS.unreadOnly"))
        XCTAssertNil(defaults.object(forKey: "FluxNews.iOS.newestFirst"))
    }

    @MainActor
    func testFilterAndSortActionsUpdateOnlyTransientStoreState() {
        let store = NewsreaderStore(defaults: UserDefaults())

        store.setUnreadOnly(false)
        store.setNewestFirst(true)

        XCTAssertFalse(store.unreadOnly)
        XCTAssertTrue(store.newestFirst)
    }

    @MainActor
    func testScopeFilterAndSortChangesRequestScrollReset() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let initial = store.scrollResetRevision

        store.select(.starred)
        let afterScope = store.scrollResetRevision
        store.setUnreadOnly(false)
        let afterFilter = store.scrollResetRevision
        store.setNewestFirst(true)

        XCTAssertGreaterThan(afterScope, initial)
        XCTAssertGreaterThan(afterFilter, afterScope)
        XCTAssertGreaterThan(store.scrollResetRevision, afterFilter)
    }

    @MainActor
    func testManualSnapshotReplacementRequestsScrollReset() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let revision = store.scrollResetRevision

        store.completeSyncForTesting(syncMetadata(reason: .manual, dataChanged: true))

        XCTAssertGreaterThan(store.scrollResetRevision, revision)
    }

    @MainActor
    func testImmediateReadAndUnrelatedRowMutationsDoNotRequestScrollReset() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1), article(2)])
        let revision = store.scrollResetRevision

        store.applyReadMutationForTesting([1], read: true)
        store.applyStarredMutationForTesting([2], starred: true)
        store.setArticlesForTesting([article(1, read: true), article(2, starred: true)])

        XCTAssertEqual(store.scrollResetRevision, revision)
    }

    @MainActor
    func testSettingsBackedArticleAndNavigationPreferencesRoundTrip() {
        let suiteName = "FluxNews.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NewsreaderStore(defaults: defaults)

        store.setClickOnNews(.openDetailView)
        store.setArticlePreviewLines(.extended)
        store.setHideEmptyNavigationEntries(true)
        store.setStartupScope(.starred)

        let reloaded = NewsreaderStore(defaults: defaults)
        XCTAssertEqual(reloaded.clickOnNews, .openDetailView)
        XCTAssertEqual(reloaded.articlePreviewLines, .extended)
        XCTAssertTrue(reloaded.hideEmptyNavigationEntries)
        XCTAssertEqual(reloaded.startupScope, .starred)
    }

    @MainActor
    func testRollingUndoInactivityExtendsButHardLifetimeDoesNot() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        let start = Date(timeIntervalSinceReferenceDate: 100)
        store.applyScrolloverMutationForTesting([1, 2], now: start)
        store.applyScrolloverMutationForTesting([3], now: start.addingTimeInterval(3.5))
        store.expireScrolloverUndoGroupForTesting(now: start.addingTimeInterval(4.1))
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3])
        store.expireScrolloverUndoGroupForTesting(now: start.addingTimeInterval(15))
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        store.applyScrolloverMutationForTesting([1], now: start.addingTimeInterval(16))
        XCTAssertEqual(store.scrolloverUndoIDs, [1])
    }

    @MainActor
    func testExplicitReadMutationDoesNotAlterScrolloverUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.applyScrolloverMutationForTesting([1, 2])
        store.applyReadMutationForTesting([3], read: true)
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2])
        XCTAssertTrue(store.scrolloverUndoVisible)
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
        XCTAssertFalse(store.hasUnscopedNewDataSignal)
        store.resetVisibleSnapshot()
        XCTAssertEqual(store.articles.count, 0)
    }

    func testInvalidStartupTargetsFallBackToAllNews() {
        XCTAssertEqual(StartupScopeResolver.resolve(.category, categoryID: 99, feedID: nil, categoryIDs: [1], feedIDs: []), .all)
        XCTAssertEqual(StartupScopeResolver.resolve(.feed, categoryID: nil, feedID: 99, categoryIDs: [], feedIDs: [1]), .all)
    }

    @MainActor
    func testAutomaticSyncBeforeInteractionUsesReplaceSemantics() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let revision = store.snapshotRevision
        store.completeSyncForTesting(syncMetadata(reason: .background, dataChanged: true))
        XCTAssertGreaterThan(store.snapshotRevision, revision)
        XCTAssertFalse(store.hasUnscopedNewDataSignal)
    }

    @MainActor
    func testAutomaticSyncAfterInteractionPreservesAndSignalsSnapshot() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.markMeaningfulInteraction()
        let revision = store.snapshotRevision
        store.completeSyncForTesting(syncMetadata(reason: .background, dataChanged: true))
        XCTAssertEqual(store.snapshotRevision, revision)
        XCTAssertTrue(store.hasUnscopedNewDataSignal)
    }

    @MainActor
    func testSuccessfulMutationSeamMarksMeaningfulInteraction() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        store.applyReadMutationForTesting([1], read: true)
        XCTAssertTrue(store.meaningfullyInteractedForTesting)
    }

    @MainActor
    func testPendingDataSurvivesPresentationOptionChanges() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.accumulateNewData([(feedID: 10, count: 2)])
        store.setArticlePresentationMode(.compact)
        store.setArticlePreviewLines(.extended)
        XCTAssertEqual(store.pendingByFeedForTesting, [10: 2])
        XCTAssertTrue(store.hasPendingNewData)
    }

    @MainActor
    func testCurrentFeedAdoptionLeavesUnrelatedPendingFeed() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .feed(10)
        store.accumulateNewData([(feedID: 10, count: 2), (feedID: 20, count: 3)])
        store.adoptVisibleSnapshot()
        XCTAssertEqual(store.pendingByFeedForTesting, [20: 3])
        XCTAssertTrue(store.hasPendingNewData)
    }

    @MainActor
    func testCategoryAdoptionLeavesUnrelatedPendingFeed() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .category(1)
        store.setCatalogForTesting(NavigationCatalog(categories: [Category(id: 1, title: "Category")], feeds: [Feed(id: 10, categoryId: 1, title: "Included"), Feed(id: 20, categoryId: 2, title: "Unrelated")]))
        store.accumulateNewData([(feedID: 10, count: 2), (feedID: 20, count: 3)])
        store.adoptVisibleSnapshot()
        XCTAssertEqual(store.pendingByFeedForTesting, [20: 3])
    }

    @MainActor
    func testManualAdoptionClearsCurrentScopeSignal() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .feed(10)
        store.accumulateNewData([(feedID: 10, count: 2), (feedID: 20, count: 3)])
        store.adoptVisibleSnapshot()
        XCTAssertEqual(store.pendingByFeedForTesting, [20: 3])
        XCTAssertTrue(store.hasPendingNewData)
    }

    @MainActor
    func testStaleStartupCategoryNormalizationPersistsAllNews() {
        let defaults = UserDefaults(suiteName: "FluxNews.D24.category.\(UUID().uuidString)")!
        let store = NewsreaderStore(defaults: defaults)
        store.setStartupScope(.category)
        store.setStartupCategoryID(99)
        store.normalizeStartupScopeForTesting(categoryIDs: [1], feedIDs: [10])
        XCTAssertEqual(store.startupScope, .allNews)
        XCTAssertNil(store.startupCategoryID)
        XCTAssertEqual(defaults.string(forKey: "FluxNews.iOS.startupScope"), StartupScopePreference.allNews.rawValue)
    }

    @MainActor
    func testStaleStartupFeedNormalizationPersistsAllNews() {
        let defaults = UserDefaults(suiteName: "FluxNews.D24.feed.\(UUID().uuidString)")!
        let store = NewsreaderStore(defaults: defaults)
        store.setStartupScope(.feed)
        store.setStartupFeedID(99)
        store.normalizeStartupScopeForTesting(categoryIDs: [1], feedIDs: [10])
        XCTAssertEqual(store.startupScope, .allNews)
        XCTAssertNil(store.startupFeedID)
        XCTAssertEqual(defaults.string(forKey: "FluxNews.iOS.startupScope"), StartupScopePreference.allNews.rawValue)
    }

    private func syncMetadata(reason: SyncReason, dataChanged: Bool) -> SyncCompleted {
        SyncCompleted(reason: reason, newArticles: 0, updatedArticles: 0, mutationsDelivered: 0, dataChanged: dataChanged, navigationChanged: false, newArticlesByFeed: [], systemNotificationCandidates: [])
    }
}
