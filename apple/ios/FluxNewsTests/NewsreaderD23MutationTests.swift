import XCTest
@testable import FluxNews

final class NewsreaderD23MutationTests: XCTestCase {
    private func article(_ id: Int64, read: Bool = false, starred: Bool = false) -> ArticleSummary {
        ArticleSummary(id: id, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: read, isStarred: starred, preview: "Preview", imageUrl: nil)
    }

    @MainActor
    private func readStates(_ store: NewsreaderStore) -> [Bool] {
        store.articles.compactMap { store.isArticleReadForTesting($0.id) }
    }

    private func geometry(y: CGFloat, contentHeight: CGFloat = 1_000, viewportHeight: CGFloat = 100) -> IOSArticleScrollGeometry {
        IOSArticleScrollGeometry(
            visibleRect: .init(x: 0, y: y, width: 320, height: viewportHeight),
            contentSize: .init(width: 320, height: contentHeight),
            containerSize: .init(width: 320, height: viewportHeight)
        )
    }

    private func uikitGeometry(
        y: CGFloat,
        frames: [Int64: CGRect],
        contentHeight: CGFloat = 400,
        viewportHeight: CGFloat = 100,
        generation: UInt64 = 0
    ) -> IOSUIKitScrolloverGeometrySample {
        .init(
            contentOffsetY: y,
            effectiveTop: y,
            effectiveBottom: y + viewportHeight,
            contentHeight: contentHeight,
            rowFrames: frames,
            layoutGeneration: generation
        )
    }

    func testUIKitForwardCrossingEmitsExactlyOnce() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: true).batch.articleIDs, [1])
        XCTAssertTrue(tracker.receive(uikitGeometry(y: 21, frames: frames), enabled: true).batch.articleIDs.isEmpty)
    }

    func testUIKitBackwardCrossingDoesNotEmit() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: true)

        let result = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)
        XCTAssertEqual(result.direction, .backward)
        XCTAssertTrue(result.batch.articleIDs.isEmpty)
    }

    func testUIKitForwardBackwardForwardOnlyEmitsTheLegitimateCrossing() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)
        XCTAssertTrue(tracker.receive(uikitGeometry(y: 10, frames: frames), enabled: true).batch.articleIDs.isEmpty)
        XCTAssertTrue(tracker.receive(uikitGeometry(y: 5, frames: frames), enabled: true).batch.articleIDs.isEmpty)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: true).batch.articleIDs, [1])
    }

    func testUIKitSlowSubPointMovementStillCrosses() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 1)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)
        _ = tracker.receive(uikitGeometry(y: 0.25, frames: frames), enabled: true)
        _ = tracker.receive(uikitGeometry(y: 0.5, frames: frames), enabled: true)
        _ = tracker.receive(uikitGeometry(y: 0.75, frames: frames), enabled: true)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 1, frames: frames), enabled: true).batch.articleIDs, [1])
    }

    func testUIKitLayoutGenerationChangeSuppressesFalseCrossingAndRebaselines() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 40)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)

        XCTAssertTrue(tracker.receive(uikitGeometry(y: 20, frames: frames, generation: 1), enabled: true).batch.articleIDs.isEmpty)
        XCTAssertEqual(tracker.receive(uikitGeometry(y: 40, frames: frames, generation: 1), enabled: true).batch.articleIDs, [1])
    }

    func testUIKitInitialBottomAndProgrammaticMovementEmitNothing() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 100, width: 320, height: 100)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        XCTAssertTrue(tracker.receive(uikitGeometry(y: 100, frames: frames, contentHeight: 200), enabled: true).batch.articleIDs.isEmpty)
        tracker.setPhase(.idle)

        XCTAssertTrue(tracker.receive(uikitGeometry(y: 200, frames: frames, contentHeight: 300), enabled: true).batch.articleIDs.isEmpty)
    }

    func testUIKitBottomCompletionRequiresPriorObservedTrailingRowAndForwardArrival() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 100, width: 320, height: 100)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.decelerating)
        _ = tracker.receive(uikitGeometry(y: 80, frames: frames, contentHeight: 200), enabled: true)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 100, frames: frames, contentHeight: 200), enabled: true).batch.articleIDs, [1])
    }

    func testUIKitExplicitUnreadRearmsForANewCrossing() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)
        XCTAssertEqual(tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: true).batch.articleIDs, [1])
        tracker.rearm([1])
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: true).batch.articleIDs, [1])
    }

    func testUIKitDisabledScrolloverDoesNotEmitOrLeakIntoTheNextGesture() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: frames), enabled: true)
        XCTAssertTrue(tracker.receive(uikitGeometry(y: 20, frames: frames), enabled: false).batch.articleIDs.isEmpty)
        tracker.setPhase(.idle)
        tracker.setPhase(.interacting)

        XCTAssertTrue(tracker.receive(uikitGeometry(y: 40, frames: frames), enabled: true).batch.articleIDs.isEmpty)
    }

    func testUIKitGeometryRetentionIsBoundedAcrossLongFeeds() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        tracker.updateSnapshot((1...8_000).map(Int64.init))
        tracker.setPhase(.interacting)
        for offset in stride(from: 0, through: 1_000, by: 10) {
            let frames = Dictionary(uniqueKeysWithValues: (0..<10).map { index in
                let id = Int64(offset + index + 1)
                return (id, CGRect(x: 0, y: CGFloat(offset + index) * 10, width: 320, height: 10))
            })
            _ = tracker.receive(uikitGeometry(y: CGFloat(offset) * 10, frames: frames, contentHeight: 100_000), enabled: true)
        }
        XCTAssertLessThanOrEqual(tracker.retainedGeometryCount, 96)
    }

    func testResolvedFrameSourceRetainsExitedCellForEitherCallbackOrder() {
        var source = IOSUIKitResolvedScrolloverFrameStore()
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let frame = CGRect(x: 0, y: 0, width: 320, height: 20)
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)

        // `willDisplay`/a prior visible-cell refresh established resolved geometry.
        source.record(articleID: 1, frame: frame, viewportTop: 0)
        _ = tracker.receive(uikitGeometry(y: 0, frames: source.frames), enabled: true)
        // `didEndDisplaying` may arrive before the scroll callback; it preserves
        // the same resolved frame rather than requiring a layout lookup.
        source.record(articleID: 1, frame: frame, viewportTop: 20)

        XCTAssertEqual(tracker.receive(uikitGeometry(y: 20, frames: source.frames), enabled: true).batch.articleIDs, [1])
    }

    func testResolvedFrameSourceIsBoundedIndependentlyOfLoadedArticles() {
        var source = IOSUIKitResolvedScrolloverFrameStore()
        for id in 1...8_000 {
            source.record(articleID: Int64(id), frame: .init(x: 0, y: CGFloat(id) * 10, width: 320, height: 10), viewportTop: CGFloat(id) * 10)
        }

        XCTAssertLessThanOrEqual(source.count, IOSUIKitResolvedScrolloverFrameStore.capacity)
    }

    func testUIKitStructuralSnapshotChangeResetsGeometrySafely() {
        let tracker = IOSUIKitScrolloverGeometryTracker()
        let firstFrames: [Int64: CGRect] = [1: .init(x: 0, y: 0, width: 320, height: 20)]
        tracker.updateSnapshot([1])
        tracker.setPhase(.interacting)
        _ = tracker.receive(uikitGeometry(y: 0, frames: firstFrames), enabled: true)
        tracker.updateSnapshot([2])
        let secondFrames: [Int64: CGRect] = [2: .init(x: 0, y: 0, width: 320, height: 20)]

        XCTAssertTrue(tracker.receive(uikitGeometry(y: 20, frames: secondFrames), enabled: true).batch.articleIDs.isEmpty)
    }

    func testUIKitStatusOnlyChangesDoNotRequireStructuralSnapshotReplacement() {
        XCTAssertFalse(IOSUIKitTimelineSnapshotPolicy.requiresStructuralUpdate(previousIDs: [1, 2], newIDs: [1, 2]))
        XCTAssertTrue(IOSUIKitTimelineSnapshotPolicy.requiresStructuralUpdate(previousIDs: [1, 2], newIDs: [2, 1]))
    }

    func testVisibleRowCrossingAboveDuringForwardScrollEmitsOnce() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        XCTAssertEqual(controller.receiveScrollGeometry(geometry(y: 20), enabled: true).direction, .forward)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
    }

    func testSlowSingleRowCrossingDoesNotRequireAnotherRowCallback() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 1), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
    }

    func testMultipleObservedCrossingsEmitOnlyObservedRows() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2, 3, 4])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        _ = controller.receiveRowRegion(articleID: 3, region: .visible, enabled: true)
        controller.setPhase(.decelerating)
        _ = controller.receiveScrollGeometry(geometry(y: 200), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
        XCTAssertEqual(controller.receiveRowRegion(articleID: 3, region: .above, enabled: true).articleIDs, [3])
        XCTAssertTrue(controller.receiveRowRegion(articleID: 2, region: .above, enabled: true).articleIDs.isEmpty)
    }

    func testGeometryAndRowCallbackOrderingProduceTheSameCrossing() {
        let first = IOSScrolloverGeometryController()
        let second = IOSScrolloverGeometryController()
        for controller in [first, second] {
            controller.updateSnapshot([1])
            _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
            _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
            controller.setPhase(.interacting)
        }
        let firstRow = first.receiveRowRegion(articleID: 1, region: .above, enabled: true)
        let firstScroll = first.receiveScrollGeometry(geometry(y: 20), enabled: true)
        let secondScroll = second.receiveScrollGeometry(geometry(y: 20), enabled: true)
        let secondRow = second.receiveRowRegion(articleID: 1, region: .above, enabled: true)

        XCTAssertEqual(firstRow.articleIDs + firstScroll.batch.articleIDs, [1])
        XCTAssertEqual(secondScroll.batch.articleIDs + secondRow.articleIDs, [1])
    }

    func testBackwardAndIdleGeometryCannotQualifyACrossing() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 10), enabled: true)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
        controller.rebaseline()
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
    }

    func testBackwardReturnThenNewForwardCrossingQualifies() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 10), enabled: true)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
    }

    func testInitialRowGeometryAndStructuralRebaselineDoNotEmit() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        controller.setPhase(.interacting)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
        controller.rebaseline()
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        controller.setPhase(.interacting)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs.isEmpty)
    }

    func testRowSizeChangeRebaselinesWithoutARead() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowGeometry(
            articleID: 1,
            state: .init(region: .visible, size: .init(width: 320, height: 80)),
            enabled: true
        )
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)

        XCTAssertTrue(controller.receiveRowGeometry(
            articleID: 1,
            state: .init(region: .above, size: .init(width: 320, height: 120)),
            enabled: true
        ).articleIDs.isEmpty)
    }

    func testForwardBottomArrivalCompletesObservedTrailingRowsOnly() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2, 3])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 2, region: .visible, enabled: true)
        _ = controller.receiveRowRegion(articleID: 3, region: .visible, enabled: true)
        controller.setPhase(.decelerating)

        XCTAssertEqual(controller.receiveScrollGeometry(geometry(y: 900), enabled: true).batch.articleIDs, [2, 3])
    }

    func testInitialOrRebaselinedBottomDoesNotCompleteRows() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2])
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        _ = controller.receiveRowRegion(articleID: 2, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        XCTAssertTrue(controller.receiveScrollGeometry(geometry(y: 0, contentHeight: 100), enabled: true).batch.articleIDs.isEmpty)
        controller.rebaseline()
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        XCTAssertTrue(controller.receiveScrollGeometry(geometry(y: 900), enabled: true).batch.articleIDs.isEmpty)
    }

    func testBackwardMovementAtTheBottomDoesNotCompleteRows() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2])
        _ = controller.receiveScrollGeometry(geometry(y: 900), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.decelerating)

        let update = controller.receiveScrollGeometry(geometry(y: 800), enabled: true)

        XCTAssertEqual(update.direction, .backward)
        XCTAssertTrue(update.batch.articleIDs.isEmpty)
    }

    func testDisabledScrolloverRetainsGeometryDirectionAndVisibleRows() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: false)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: false)
        controller.setPhase(.interacting)

        XCTAssertEqual(controller.receiveScrollGeometry(geometry(y: 20), enabled: false).direction, .forward)
        XCTAssertEqual(controller.visibleIDs, [1])
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: false).articleIDs.isEmpty)
        XCTAssertTrue(controller.visibleIDs.isEmpty)
    }

    func testDisabledOrIdleCrossingCannotLeakIntoANewInteraction() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: false)
        XCTAssertTrue(controller.receiveRowRegion(articleID: 1, region: .above, enabled: false).articleIDs.isEmpty)

        controller.setPhase(.idle)
        controller.setPhase(.interacting)
        XCTAssertTrue(controller.receiveScrollGeometry(geometry(y: 40), enabled: true).batch.articleIDs.isEmpty)
    }

    func testExplicitRearmPermitsAnotherGenuineCrossing() {
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
        controller.releaseEmittedIDs()
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        _ = controller.receiveScrollGeometry(geometry(y: 40), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
    }

    @MainActor
    func testNormalScrolloverReadDoesNotCreateUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting((1...4).map { article(Int64($0)) })
        store.applyScrolloverMutationForTesting([1])
        XCTAssertEqual(store.isArticleReadForTesting(1), true)
        XCTAssertFalse(store.scrolloverUndoVisible)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
    }

    @MainActor
    func testCommittedScrolloverPresentationUpdatesOnlyTheCrossedRow() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        let structuralRevision = store.snapshotRevision
        let unchangedRow = store.rowPresentationStateForTesting(2)!

        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        store.setScrolloverPresentationPhaseForTesting(.idle)

        XCTAssertEqual(store.isArticleReadForTesting(1), true)
        XCTAssertEqual(store.isArticleReadForTesting(2), false)
        XCTAssertEqual(store.snapshotRevision, structuralRevision)
        XCTAssertTrue(store.rowPresentationStateForTesting(2) === unchangedRow)
    }

    @MainActor
    func testScrolloverFailureBeforeCommitLeavesRowUnread() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.isArticleReadForTesting(1), false)

        store.failScrolloverMutationForTesting([1])

        XCTAssertEqual(store.isArticleReadForTesting(1), false)
        XCTAssertEqual(store.articles.map(\.id), [1, 2])
    }

    @MainActor
    func testSnapshotReconciliationReusesAndReconcilesRowStates() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        let retained = store.rowPresentationStateForTesting(2)!
        _ = store.enqueueScrolloverForTesting([2])

        store.setArticlesForTesting([article(2, read: false), article(3, starred: true)])

        XCTAssertTrue(store.rowPresentationStateForTesting(2) === retained)
        XCTAssertEqual(store.isArticleReadForTesting(2), false)
        XCTAssertNil(store.rowPresentationStateForTesting(1))
        XCTAssertEqual(store.isArticleStarredForTesting(3), true)
    }

    @MainActor
    func testScrolloverUndoQualifiesOnlyThreeSuccessfulReadsInRollingSecond() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting((1...6).map { article(Int64($0)) })
        store.applyScrolloverMutationForTesting([1], now: 0)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        store.applyScrolloverMutationForTesting([2], now: 0.4)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        store.applyScrolloverMutationForTesting([3], now: 1.0)
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3])
        store.applyScrolloverMutationForTesting([4], now: 1.5)
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3, 4])
    }

    @MainActor
    func testSlowAndStaleSuccessfulScrolloverReadsDoNotQualifyUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting((1...4).map { article(Int64($0)) })
        store.applyScrolloverMutationForTesting([1], now: 0)
        store.applyScrolloverMutationForTesting([2], now: 1.25)
        store.applyScrolloverMutationForTesting([3], now: 2.4)
        store.applyScrolloverMutationForTesting([4], now: 3.5)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
    }

    @MainActor
    func testRejectedAndAlreadyReadScrolloverCandidatesDoNotQualifyUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1, read: true), article(2), article(3), article(4)])
        store.applyScrolloverMutationForTesting([1], now: 0)
        store.applyScrolloverMutationForTesting([2], now: 0.2)
        store.applyScrolloverMutationForTesting([2, 3], now: 0.4)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        store.applyScrolloverMutationForTesting([4], now: 0.6)
        XCTAssertEqual(store.scrolloverUndoIDs, [2, 3, 4])
    }

    @MainActor
    func testQualifyingScrolloverUndoContainsOnlySuccessfullyChangedArticles() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2, read: true), article(3), article(4), article(5)])
        store.applyScrolloverMutationForTesting([1, 2, 3, 4])
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 3, 4])
        XCTAssertEqual(readStates(store), [true, true, true, true, false])
    }

    @MainActor
    func testReadMutationUpdatesVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1)])
        store.applyReadMutationForTesting([1], read: true)
        XCTAssertEqual(store.isArticleReadForTesting(1), true)
    }

    @MainActor
    func testUnreadMutationUsesTheExistingReadMutationPath() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1, read: true)])
        store.applyReadMutationForTesting([1], read: false)
        XCTAssertEqual(store.isArticleReadForTesting(1), false)
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
    func testScrolloverReadRemainsVisibleWhenRemoveWhenReadIsEnabled() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        store.applyScrolloverMutationForTesting([1])

        XCTAssertEqual(store.articles.map(\.id), [1, 2])
        XCTAssertEqual(store.isArticleReadForTesting(1), true)
    }

    @MainActor
    func testForwardCrossingQueuesPersistenceWithoutChangingPresentation() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)

        XCTAssertEqual(store.acceptScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [1])
        XCTAssertEqual(readStates(store), [false, false])
    }

    @MainActor
    func testForwardDecelerationAccumulatesPresentationUntilIdleAsOneRowStateBatch() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        let revision = store.snapshotRevision
        let unrelated = store.rowPresentationStateForTesting(4)!
        store.setScrolloverPresentationPhaseForTesting(.decelerating)

        _ = store.acceptScrolloverForTesting([1])
        _ = store.acceptScrolloverForTesting([2, 3])
        XCTAssertEqual(store.pendingScrolloverPresentationIDsForTesting, [1, 2, 3])
        XCTAssertEqual(readStates(store), [false, false, false, false])

        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertEqual(readStates(store), [true, true, true, false])
        XCTAssertEqual(store.snapshotRevision, revision)
        XCTAssertTrue(store.rowPresentationStateForTesting(4) === unrelated)
    }

    @MainActor
    func testForwardToBackwardDirectionReversalPublishesOnceAndForwardAgainCreatesNewGroup() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)
        _ = store.acceptScrolloverForTesting([1, 2])

        store.receiveScrolloverDirectionForTesting(.backward)
        XCTAssertEqual(readStates(store), [true, true, false])
        store.receiveScrolloverDirectionForTesting(.backward)
        XCTAssertEqual(readStates(store), [true, true, false])

        store.receiveScrolloverDirectionForTesting(.forward)
        _ = store.acceptScrolloverForTesting([3])
        XCTAssertEqual(readStates(store), [true, true, false])
        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertEqual(readStates(store), [true, true, true])
    }

    @MainActor
    func testInitialBackwardAndStructuralRebaselineDoNotPublishPendingPresentation() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        store.receiveScrolloverDirectionForTesting(.backward)
        XCTAssertFalse(store.isArticleReadForTesting(1)!)

        _ = store.acceptScrolloverForTesting([1])
        store.rebaselineScrolloverPresentationForTesting()
        store.receiveScrolloverDirectionForTesting(.backward)
        XCTAssertFalse(store.isArticleReadForTesting(1)!)
    }

    @MainActor
    func testTerminalScrolloverRemainsPendingDuringForwardMovementAndPublishesAtIdle() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3), article(4), article(5)])
        store.setScrolloverPresentationPhaseForTesting(.decelerating)

        XCTAssertEqual(store.acceptScrolloverForTesting([3, 4, 5]), [3, 4, 5])
        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [3, 4, 5])
        XCTAssertEqual(readStates(store), [false, false, false, false, false])
        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertEqual(readStates(store), [false, false, true, true, true])
    }

    @MainActor
    func testScrolloverFailureBeforePresentationCommitDiscardsPendingRead() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        _ = store.acceptScrolloverForTesting([1])

        store.failScrolloverMutationForTesting([1])
        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertFalse(store.isArticleReadForTesting(1)!)
    }

    @MainActor
    func testScrolloverFailureAfterPresentationCommitRestoresSafely() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        _ = store.acceptScrolloverForTesting([1])
        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertTrue(store.isArticleReadForTesting(1)!)

        store.failScrolloverMutationForTesting([1])
        XCTAssertFalse(store.isArticleReadForTesting(1)!)
    }

    @MainActor
    func testStaleScrolloverFailureCannotMutateANewSnapshotPresentation() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        let generation = store.scrolloverQueueGenerationForTesting
        _ = store.acceptScrolloverForTesting([1])
        store.rebaselineScrolloverPresentationForTesting()
        store.setArticlesForTesting([article(1, read: true)])

        store.failScrolloverMutationForTesting([1], generation: generation)
        XCTAssertEqual(store.isArticleReadForTesting(1), true)
    }

    @MainActor
    func testStaleScrolloverSuccessCannotUpdateANewerSnapshotPresentation() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        let generation = store.scrolloverQueueGenerationForTesting

        store.rebaselineScrolloverPresentationForTesting()
        store.setArticlesForTesting([article(1, read: true)])
        store.completeSuccessfulScrolloverMutationForTesting([1], generation: generation)

        XCTAssertEqual(store.isArticleReadForTesting(1), true)
        XCTAssertTrue(store.scrolloverUndoIDsForTesting.isEmpty)
    }

    @MainActor
    func testScrolloverNeverStructurallyRemovesRowsDuringActiveScrolling() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        let structuralRevision = store.snapshotRevision
        store.setScrolloverPresentationPhaseForTesting(.decelerating)

        store.applyScrolloverMutationForTesting([1])

        XCTAssertEqual(store.articles.map(\.id), [1, 2])
        XCTAssertEqual(store.snapshotRevision, structuralRevision)
    }

    @MainActor
    func testSuccessfulScrolloverPresentationIsCoalescedWhileDeceleratingAndFlushedWhenIdle() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.setScrolloverPresentationPhaseForTesting(.decelerating)
        _ = store.acceptScrolloverForTesting([1, 2])

        store.completeSuccessfulScrolloverMutationForTesting([1], now: 0)
        store.completeSuccessfulScrolloverMutationForTesting([2], now: 0.2)

        XCTAssertEqual(store.pendingScrolloverPresentationIDsForTesting, [1, 2])
        XCTAssertEqual(readStates(store), [false, false, false])
        store.setScrolloverPresentationPhaseForTesting(.idle)
        XCTAssertEqual(readStates(store), [true, true, false])
        XCTAssertEqual(store.pendingScrolloverPresentationIDsForTesting, [])
    }

    @MainActor
    func testScrolloverCompletionRacingIdleTransitionPublishesEachSuccessOnce() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)
        store.completeSuccessfulScrolloverMutationForTesting([1], now: 0)

        store.setScrolloverPresentationPhaseForTesting(.idle)
        store.completeSuccessfulScrolloverMutationForTesting([2, 3], now: 0.2)

        XCTAssertEqual(readStates(store), [false, false, false])
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3])
        XCTAssertEqual(store.pendingScrolloverPresentationIDsForTesting, [])
    }

    @MainActor
    func testStructuralRebaselineDiscardsDeferredScrolloverPresentation() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)
        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.isArticleReadForTesting(1), false)
        store.completeSuccessfulScrolloverMutationForTesting([1], now: 0)

        store.rebaselineScrolloverPresentationForTesting()

        XCTAssertTrue(store.pendingScrolloverPresentationIDsForTesting.isEmpty)
        XCTAssertEqual(store.isArticleReadForTesting(1), false)
    }

    @MainActor
    func testAlreadyReadTerminalCandidatesAreIgnoredAndRemainNonStructural() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1, read: true), article(2)])
        let revision = store.snapshotRevision
        store.applyScrolloverMutationForTesting([1, 2])
        XCTAssertEqual(store.articles.map(\.id), [1, 2])
        XCTAssertEqual(readStates(store), [true, true])
        XCTAssertEqual(store.snapshotRevision, revision)
    }

    @MainActor
    func testScrolloverEligibilityFiltersReadArticlesBeforeQueueing() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1, read: true), article(2), article(3, read: true), article(4)])

        XCTAssertEqual(store.enqueueScrolloverForTesting([1, 2, 3, 4]), [2, 4])
    }

    @MainActor
    func testMixedScrolloverBatchMarksOnlyUnreadArticles() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1, read: true), article(2), article(3, read: true), article(4)])

        store.setArticlesForTesting([article(1, read: true), article(2), article(3, read: true), article(4), article(5)])
        store.applyScrolloverMutationForTesting([1, 2, 3, 4, 5])

        XCTAssertEqual(store.scrolloverUndoIDs, [2, 4, 5])
        XCTAssertEqual(readStates(store), [true, true, true, true, true])
    }

    @MainActor
    func testScrolloverQueueDeduplicatesPendingAndInFlightCandidates() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])

        XCTAssertEqual(store.enqueueScrolloverForTesting([1, 2]), [1, 2])
        XCTAssertEqual(store.enqueueScrolloverForTesting([1, 2, 3]), [3])
        XCTAssertEqual(store.beginScrolloverMutationForTesting(), [1, 2, 3])
        XCTAssertTrue(store.enqueueScrolloverForTesting([1, 2, 3]).isEmpty)
    }

    @MainActor
    func testPresentationResetKeepsQueuedPersistenceAfterRunningBatch() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])

        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.beginScrolloverMutationForTesting(), [1])
        XCTAssertEqual(store.enqueueScrolloverForTesting([2]), [2])

        store.rebaselineScrolloverPresentationForTesting()

        XCTAssertEqual(store.pendingScrolloverIDsForTesting, [2])
        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [2])
    }

    @MainActor
    func testScrolloverBatchesAreBoundedAndContinueInFIFOOrder() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let maximum = NewsreaderStore.maximumScrolloverMutationBatchSizeForTesting
        let ids = Array(1...(maximum * 2 + 3)).map(Int64.init)
        store.setArticlesForTesting(ids.map { article($0) })

        XCTAssertEqual(store.enqueueScrolloverForTesting(ids), ids)
        let first = store.beginScrolloverMutationForTesting()
        let second = store.beginScrolloverMutationForTesting()
        let third = store.beginScrolloverMutationForTesting()

        XCTAssertEqual(first.count, maximum)
        XCTAssertEqual(second.count, maximum)
        XCTAssertEqual(third.count, 3)
        XCTAssertEqual(first + second + third, ids)
        XCTAssertTrue(store.pendingScrolloverIDsForTesting.isEmpty)
    }

    @MainActor
    func testDetachedSessionDropsQueuedScrolloverWork() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        _ = store.enqueueScrolloverForTesting([1, 2])
        let session = store.scrolloverSessionGenerationForTesting

        store.invalidateScrolloverSessionForTesting()

        XCTAssertGreaterThan(store.scrolloverSessionGenerationForTesting, session)
        XCTAssertTrue(store.pendingScrolloverIDsForTesting.isEmpty)
    }

    func testEventRoutingFiltersIgnoredEventsBeforeMainActorDispatch() {
        XCTAssertFalse(IOSNewsreaderEventRoutingPolicy.shouldDispatchSyncCompleted(reason: nil))
        XCTAssertFalse(IOSNewsreaderEventRoutingPolicy.shouldDispatchSyncCompleted(reason: .manual))
        XCTAssertTrue(IOSNewsreaderEventRoutingPolicy.shouldDispatchSyncCompleted(reason: .background))
        XCTAssertTrue(IOSNewsreaderEventRoutingPolicy.shouldDispatchSyncCompleted(reason: .periodic))
    }

    @MainActor
    func testScrolloverPersistenceQueueRemainsActiveWhileDecelerating() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        store.setScrolloverPresentationPhaseForTesting(.decelerating)

        XCTAssertEqual(store.enqueueScrolloverForTesting([1, 2]), [1, 2])
        XCTAssertEqual(store.beginScrolloverMutationForTesting(), [1, 2])
    }

    @MainActor
    func testSlowScrolloverRemainsBufferedUntilAnIdleOrLifecycleFlush() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)

        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [1])
        XCTAssertTrue(store.flushScrolloverPersistenceForTesting().isEmpty)
    }

    @MainActor
    func testMultipleScrolloversShareOnePersistenceBatchAtTheBoundary() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.setScrolloverPresentationPhaseForTesting(.interacting)

        XCTAssertEqual(store.enqueueScrolloverForTesting([1]), [1])
        XCTAssertEqual(store.enqueueScrolloverForTesting([2, 3]), [2, 3])
        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [1, 2, 3])
    }

    @MainActor
    func testExplicitMutationRemovesConflictingBufferedScrollover() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        XCTAssertEqual(store.enqueueScrolloverForTesting([1, 2]), [1, 2])

        store.discardPendingScrolloverForTesting([1])

        XCTAssertEqual(store.flushScrolloverPersistenceForTesting(), [2])
    }

    @MainActor
    func testMultipleScrolloverReadsRemainInOriginalVisibleOrder() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        store.applyScrolloverMutationForTesting([1])
        store.applyScrolloverMutationForTesting([2, 3])

        XCTAssertEqual(store.articles.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(readStates(store), [true, true, true, false])
    }

    @MainActor
    func testUndoChangesVisibleScrolloverReadsBackToUnread() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2), article(3)])
        store.applyScrolloverMutationForTesting([1, 2, 3])

        store.applyScrolloverUndoForTesting()

        XCTAssertEqual(store.articles.map(\.id), [1, 2, 3])
        XCTAssertEqual(readStates(store), [false, false, false])
    }

    @MainActor
    func testStarMutationUpdatesVisibleState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1)])
        store.applyStarredMutationForTesting([1], starred: true)
        XCTAssertEqual(store.isArticleStarredForTesting(1), true)
    }

    @MainActor
    func testUnstarMutationUsesTheExistingStarMutationPath() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1, starred: true)])
        store.applyStarredMutationForTesting([1], starred: false)
        XCTAssertEqual(store.isArticleStarredForTesting(1), false)
    }

    @MainActor
    func testUnstarRemovesArticleFromStarredScope() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .starred
        store.setArticlesForTesting([article(1, starred: true), article(2, starred: true)])
        store.applyStarredMutationForTesting([1], starred: false)
        XCTAssertEqual(store.articles.map(\.id), [2])
    }

    @MainActor
    func testRollingUndoAggregatesDeduplicatesAndRestoresAllReads() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting((1...9).map { article(Int64($0)) })
        let start: TimeInterval = 100
        store.applyScrolloverMutationForTesting([1, 2, 3, 4], now: start)
        store.applyScrolloverMutationForTesting([4, 5, 6, 7, 8, 9], now: start + 3)
        XCTAssertEqual(store.articles.map(\.id), Array(1...9).map(Int64.init))
        store.applyScrolloverUndoForTesting()
        XCTAssertEqual(store.articles.map(\.id), Array(1...9).map(Int64.init))
        XCTAssertTrue(store.articles.allSatisfy { !$0.isRead })
    }

    @MainActor
    func testAddingToAnActiveUndoGroupKeepsTrackerRearmRevisionStableAndCountLive() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        let revision = store.scrolloverRearmRevision

        store.applyScrolloverMutationForTesting([1, 2, 3])
        XCTAssertTrue(store.scrolloverUndoVisible)
        XCTAssertEqual(store.scrolloverUndoIDs.count, 3)
        XCTAssertEqual(store.scrolloverRearmRevision, revision)

        store.applyScrolloverMutationForTesting([4])
        XCTAssertEqual(store.scrolloverUndoIDs.count, 4)
        XCTAssertEqual(store.scrolloverRearmRevision, revision)
    }

    @MainActor
    func testUndoClearRearmsTrackerAndPermitsLaterScrolloverCandidates() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        let controller = IOSScrolloverGeometryController()
        controller.updateSnapshot([1, 2, 3, 4])
        _ = controller.receiveScrollGeometry(geometry(y: 0), enabled: true)
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        controller.setPhase(.interacting)
        _ = controller.receiveScrollGeometry(geometry(y: 20), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])

        store.applyScrolloverMutationForTesting([1, 2, 3])
        let revision = store.scrolloverRearmRevision
        store.applyScrolloverUndoForTesting()
        XCTAssertEqual(store.scrolloverRearmRevision, revision + 1)

        controller.releaseEmittedIDs()
        _ = controller.receiveRowRegion(articleID: 1, region: .visible, enabled: true)
        _ = controller.receiveScrollGeometry(geometry(y: 40), enabled: true)
        XCTAssertEqual(controller.receiveRowRegion(articleID: 1, region: .above, enabled: true).articleIDs, [1])
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
    func testScrolloverReadDoesNotTriggerStructuralRebaseline() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2)])
        let revision = store.snapshotRevision

        store.applyScrolloverMutationForTesting([1])

        XCTAssertEqual(store.snapshotRevision, revision)
    }

    @MainActor
    func testManualReadRemovalTriggersStructuralRebaseline() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.removeArticlesWhenMarkedRead = true
        store.unreadOnly = true
        store.setArticlesForTesting([article(1), article(2)])
        let revision = store.snapshotRevision

        store.applyReadMutationForTesting([1], read: true)

        XCTAssertGreaterThan(store.snapshotRevision, revision)
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
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        let start: TimeInterval = 100
        let rearmRevision = store.scrolloverRearmRevision
        store.applyScrolloverMutationForTesting([1, 2, 3], now: start)
        store.applyScrolloverMutationForTesting([4], now: start + 3.5)
        store.expireScrolloverUndoGroupForTesting(now: start + 4.1)
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3, 4])
        XCTAssertEqual(store.scrolloverRearmRevision, rearmRevision)
        store.expireScrolloverUndoGroupForTesting(now: start + 15)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        XCTAssertEqual(store.scrolloverRearmRevision, rearmRevision + 1)
        store.applyScrolloverMutationForTesting([1], now: start + 16)
        XCTAssertTrue(store.scrolloverUndoIDs.isEmpty)
        XCTAssertEqual(store.scrolloverRearmRevision, rearmRevision + 1)
    }

    @MainActor
    func testSuccessfulReadAfterInactivityStartsANewUndoGroupSynchronously() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        let start: TimeInterval = 100
        store.applyScrolloverMutationForTesting([1, 2, 3], now: start)
        let rearmRevision = store.scrolloverRearmRevision
        store.applyScrolloverMutationForTesting([4], now: start + 5)
        XCTAssertEqual(store.scrolloverUndoIDs, [4])
        XCTAssertEqual(store.scrolloverRearmRevision, rearmRevision)
    }

    @MainActor
    func testExplicitReadMutationDoesNotAlterScrolloverUndo() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.unreadOnly = false
        store.setArticlesForTesting([article(1), article(2), article(3), article(4)])
        store.applyScrolloverMutationForTesting([1, 2, 3])
        store.applyReadMutationForTesting([4], read: true)
        XCTAssertEqual(store.scrolloverUndoIDs, [1, 2, 3])
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
