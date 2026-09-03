import XCTest
@testable import FluxNews

final class NewsreaderD23MutationTests: XCTestCase {
    private func article(_ id: Int64, read: Bool = false, starred: Bool = false) -> ArticleSummary {
        ArticleSummary(id: id, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: read, isStarred: starred, preview: "Preview", imageUrl: nil)
    }

    func testIOS18ContentOffsetYUsesForwardIncreasingCanonicalPositions() {
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 40), previous: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 0)), 40)
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 80), previous: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 40)), 40)
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 40), previous: IOSScrolloverOffset.canonicalPosition(contentOffsetY: 80)), -40)
    }

    func testIOS17ContentMinYNormalizesToForwardIncreasingCanonicalPositions() {
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentMinY: -40), previous: IOSScrolloverOffset.canonicalPosition(contentMinY: 0)), 40)
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentMinY: -80), previous: IOSScrolloverOffset.canonicalPosition(contentMinY: -40)), 40)
        XCTAssertEqual(IOSScrolloverOffset.forwardDelta(current: IOSScrolloverOffset.canonicalPosition(contentMinY: -40), previous: IOSScrolloverOffset.canonicalPosition(contentMinY: -80)), -40)
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

    func testRuntimeFrameProcessorRejectsDisabledAndLargeJumpInput() {
        var tracker = ScrolloverExposureTracker()
        var lastOffset: CGFloat = 0
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible: [Int64: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 0)
        tracker.observe(frames: visible, viewport: viewport, unread: [1], now: 1)

        XCTAssertTrue(IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: -20, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 20, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: false, userInitiated: true).isEmpty)
        XCTAssertTrue(IOSScrolloverFrameProcessor.process(frames: [1: CGRect(x: 0, y: -100, width: 100, height: 100)], viewport: viewport, unread: [1], canonicalPosition: 100, lastProcessedOffset: &lastOffset, tracker: &tracker, enabled: true, userInitiated: true).isEmpty)
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

    func testSwipeArbitrationLocksVerticalInput() {
        var arbitration = IOSSwipeArbitration()
        arbitration.update(translation: CGSize(width: 4, height: 20))
        arbitration.update(translation: CGSize(width: 40, height: 20))
        XCTAssertEqual(arbitration.axis, .vertical)
        XCTAssertNil(arbitration.direction)
    }

    func testSwipeArbitrationLocksHorizontalDirection() {
        var right = IOSSwipeArbitration()
        right.update(translation: CGSize(width: 20, height: 4))
        right.update(translation: CGSize(width: -40, height: 4))
        XCTAssertEqual(right.axis, .horizontal)
        XCTAssertEqual(right.direction, .right)

        var left = IOSSwipeArbitration()
        left.update(translation: CGSize(width: -20, height: 4))
        XCTAssertEqual(left.direction, .left)
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
        let batchGeneration = store.beginScrolloverUndoBatch()
        store.applyScrolloverMutationForTesting([1, 3], batchGeneration: batchGeneration)
        store.restoreScrolloverRemovedArticlesForTesting()
        XCTAssertEqual(store.articles.map(\.id), [1, 2, 3])
    }

    @MainActor
    func testScrolloverUndoSurvivesAnEmptyNewScrollSession() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        let batchGeneration = store.beginScrolloverUndoBatch()
        store.applyScrolloverMutationForTesting([1, 2], batchGeneration: batchGeneration)

        store.beginScrolloverUndoBatch()
        store.finishScrolloverUndoBatch()

        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2])
        XCTAssertTrue(store.scrolloverUndoVisible)
    }

    @MainActor
    func testOutOfOrderScrolloverSuccessUpdatesVisibleStateWithoutJoiningNewerUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1), article(2)])
        let first = store.beginScrolloverUndoBatch()
        store.finishScrolloverUndoBatch()
        let second = store.beginScrolloverUndoBatch()

        store.applyScrolloverMutationForTesting([2], batchGeneration: second)
        store.applyScrolloverMutationForTesting([1], batchGeneration: first)

        XCTAssertTrue(store.articles.allSatisfy(\.isRead))
        XCTAssertEqual(store.scrolloverUndoIDsForTesting, [2])
        store.applyScrolloverUndoForTesting()
        XCTAssertTrue(store.articles.first(where: { $0.id == 1 })!.isRead)
        XCTAssertFalse(store.articles.first(where: { $0.id == 2 })!.isRead)
    }

    @MainActor
    func testOutOfOrderScrolloverSuccessDoesNotRetainStaleRemovedArticleForUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2), article(3)])
        let first = store.beginScrolloverUndoBatch()
        store.finishScrolloverUndoBatch()
        let second = store.beginScrolloverUndoBatch()

        store.applyScrolloverMutationForTesting([2], batchGeneration: second)
        store.applyScrolloverMutationForTesting([1], batchGeneration: first)

        XCTAssertEqual(store.articles.map(\.id), [3])
        XCTAssertEqual(store.scrolloverUndoIDsForTesting, [2])
        store.applyScrolloverUndoForTesting()
        XCTAssertEqual(store.articles.map(\.id), [2, 3])
    }

    @MainActor
    func testLateScrolloverMutationAfterIdleKeepsItsUndoBatch() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        let batchGeneration = store.beginScrolloverUndoBatch()
        store.finishScrolloverUndoBatch()

        store.applyScrolloverMutationForTesting([1, 2], batchGeneration: batchGeneration)

        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2])
        XCTAssertTrue(store.scrolloverUndoVisible)
    }

    @MainActor
    func testExplicitReadMutationDoesNotAlterScrolloverUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1), article(2), article(3)])
        let batchGeneration = store.beginScrolloverUndoBatch()
        store.applyScrolloverMutationForTesting([1, 2], batchGeneration: batchGeneration)

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
