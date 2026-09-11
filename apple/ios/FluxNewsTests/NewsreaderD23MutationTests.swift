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

    func testInitialVisibleTargetsEstablishABaseline() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3])
        XCTAssertTrue(tracker.receiveVisibleIDs([1, 2], enabled: true).articleIDs.isEmpty)
        tracker.setUserScrolling(true)
        XCTAssertTrue(tracker.receiveVisibleIDs([2], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([3], enabled: true).articleIDs, [1])
    }

    func testSkippedAndLargeForwardJumpsUseTheOrderedRange() {
        var tracker = IOSScrolloverOrderTracker()
        let ids = Array(0...50).map(Int64.init)
        tracker.updateSnapshot(ids)
        _ = tracker.receiveVisibleIDs([20], enabled: true)
        tracker.setUserScrolling(true)
        let first = tracker.receiveVisibleIDs([35], enabled: true)
        XCTAssertEqual(first.articleIDs, Array(20..<35).map(Int64.init))
        let second = tracker.receiveVisibleIDs([50], enabled: true)
        XCTAssertEqual(second.articleIDs, Array(35..<50).map(Int64.init))
    }

    func testLargeSnapshotKeepsCandidateGenerationLocalToTheCrossing() {
        var tracker = IOSScrolloverOrderTracker()
        let ids = Array(0..<8_000).map(Int64.init)
        tracker.updateSnapshot(ids)
        _ = tracker.receiveVisibleIDs([100], enabled: true)
        tracker.setUserScrolling(true)

        XCTAssertTrue(tracker.receiveVisibleIDs([101], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([102], enabled: true).articleIDs, [100])
        XCTAssertEqual(tracker.receiveVisibleIDs([200], enabled: true).articleIDs, Array(101..<200).map(Int64.init))
    }

    func testInitialBaselineAndStructuralRebaselineDoNotQualify() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot(Array(1...10).map(Int64.init))
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: true).articleIDs.isEmpty)
        XCTAssertNil(tracker.lastVisibilityDirection)
        tracker.setUserScrolling(true)
        tracker.updateSnapshot(Array(20...30).map(Int64.init))
        XCTAssertTrue(tracker.receiveVisibleIDs([30], enabled: true).articleIDs.isEmpty)
        XCTAssertNil(tracker.lastVisibilityDirection)
    }

    func testVisibilityDirectionTracksForwardAndBackwardMovementWithoutChangingScrolloverOutput() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], enabled: true)
        tracker.setUserScrolling(true)

        XCTAssertEqual(tracker.receiveVisibleIDs([3], enabled: true).articleIDs, [1, 2])
        XCTAssertEqual(tracker.lastVisibilityDirection, .forward)
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.lastVisibilityDirection, .backward)
    }

    func testDisabledScrolloverStillReportsDirectionWithoutReadCandidates() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], enabled: false)
        tracker.setUserScrolling(true)

        XCTAssertTrue(tracker.receiveVisibleIDs([3], enabled: false).articleIDs.isEmpty)
        XCTAssertEqual(tracker.lastVisibilityDirection, .forward)
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: false).articleIDs.isEmpty)
        XCTAssertEqual(tracker.lastVisibilityDirection, .backward)
    }

    func testTerminalScrolloverCompletesVisibleArticlesAfterForwardScroll() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([1, 2], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([3, 4], enabled: true).articleIDs, [1, 2])
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([3, 4], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([5], enabled: true).articleIDs, [3, 4])
        XCTAssertEqual(tracker.receiveTerminalVisibleIDs([5], enabled: true).articleIDs, [5])
    }

    func testTerminalScrolloverCompletesSeveralTrailingRowsThatRemainVisible() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([1, 2], enabled: true)
        tracker.setUserScrolling(true)

        XCTAssertEqual(tracker.receiveVisibleIDs([3, 4, 5], enabled: true).articleIDs, [1, 2])
        XCTAssertEqual(tracker.receiveTerminalVisibleIDs([3, 4, 5], enabled: true).articleIDs, [3, 4, 5])
    }

    func testTerminalScrolloverRetainsTrailingCandidatesAcrossStaggeredVisibilityCallbacks() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([1, 2], enabled: true)
        tracker.setUserScrolling(true)

        XCTAssertTrue(tracker.receiveVisibleIDs([1, 2, 5], enabled: true).articleIDs.isEmpty)
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([1, 2, 5], enabled: true).articleIDs.isEmpty)
        XCTAssertTrue(tracker.receiveVisibleIDs([2, 5], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveTerminalVisibleIDs([2, 5], enabled: true).articleIDs, [2, 5])
        XCTAssertEqual(tracker.receiveVisibleIDs([5], enabled: true).articleIDs, [1, 3, 4])
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([5], enabled: true).articleIDs.isEmpty)
    }

    func testTerminalScrolloverIgnoresInitialShortListAndStructuralRebaseline() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2])
        _ = tracker.receiveVisibleIDs([1, 2], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([1, 2], enabled: true).articleIDs.isEmpty)
        tracker.updateSnapshot([3, 4, 5])
        tracker.setUserScrolling(true)
        _ = tracker.receiveVisibleIDs([5], enabled: true)
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([5], enabled: true).articleIDs.isEmpty)
    }

    func testTerminalScrolloverIgnoresBackwardMovementAtTheEnd() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([2], enabled: true)
        tracker.setUserScrolling(true)
        _ = tracker.receiveVisibleIDs([5], enabled: true)
        _ = tracker.receiveVisibleIDs([3], enabled: true)
        XCTAssertTrue(tracker.receiveTerminalVisibleIDs([5], enabled: true).articleIDs.isEmpty)
    }

    func testBackwardAndDuplicateVisibilityUpdatesDoNotEmit() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4, 5])
        _ = tracker.receiveVisibleIDs([2], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [2, 3])
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([5], enabled: true).articleIDs, [1, 4])
        XCTAssertTrue(tracker.receiveVisibleIDs([5], enabled: true).articleIDs.isEmpty)
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

    func testCandidatesAreIndependentOfReadStateAndStructuralSnapshotsRebaseline() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [1, 2, 3])
        tracker.updateSnapshot([9, 1, 2, 3, 4])
        XCTAssertTrue(tracker.receiveVisibleIDs([4], enabled: true).articleIDs.isEmpty)
        tracker.setUserScrolling(true)
        XCTAssertTrue(tracker.receiveVisibleIDs([4], enabled: true).articleIDs.isEmpty)
    }

    func testReleasedScrolloverIDsCanBeEmittedAfterUndo() {
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [1, 2, 3])
        tracker.releaseEmittedIDs()
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [1, 2, 3])
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

    func testListVisibilityOrdersIDsBySnapshotRatherThanCallbackOrder() {
        var visibility = IOSListVisibilityCoordinator()
        _ = visibility.updateSnapshot([10, 20, 30])

        XCTAssertEqual(visibility.receiveVisibility(articleID: 30, isVisible: true), [30])
        XCTAssertEqual(visibility.receiveVisibility(articleID: 10, isVisible: true), [10, 30])
    }

    func testListVisibilityCallbackOrderAndDuplicatesAreIdempotent() {
        var first = IOSListVisibilityCoordinator()
        var second = IOSListVisibilityCoordinator()
        _ = first.updateSnapshot([10, 20, 30])
        _ = second.updateSnapshot([10, 20, 30])

        _ = first.receiveVisibility(articleID: 30, isVisible: true)
        let firstOutput = first.receiveVisibility(articleID: 10, isVisible: true)
        _ = second.receiveVisibility(articleID: 10, isVisible: true)
        let secondOutput = second.receiveVisibility(articleID: 30, isVisible: true)

        XCTAssertEqual(firstOutput, secondOutput)
        XCTAssertNil(first.receiveVisibility(articleID: 10, isVisible: true))
        XCTAssertEqual(first.receiveVisibility(articleID: 10, isVisible: false), [30])
        XCTAssertNil(first.receiveVisibility(articleID: 10, isVisible: false))
    }

    func testListVisibilitySnapshotReconciliationRemovesStaleRows() {
        var visibility = IOSListVisibilityCoordinator()
        _ = visibility.updateSnapshot([10, 20, 30])
        _ = visibility.receiveVisibility(articleID: 10, isVisible: true)
        _ = visibility.receiveVisibility(articleID: 20, isVisible: true)

        XCTAssertEqual(visibility.updateSnapshot([20, 30, 40]), [20])
        XCTAssertNil(visibility.receiveVisibility(articleID: 10, isVisible: false))
        XCTAssertEqual(visibility.receiveVisibility(articleID: 40, isVisible: true), [20, 40])
    }

    func testListVisibilityLargeSnapshotOrdersOnlyTheVisibleRows() {
        var visibility = IOSListVisibilityCoordinator()
        let ids = Array(0..<8_000).map(Int64.init)
        _ = visibility.updateSnapshot(ids)

        _ = visibility.receiveVisibility(articleID: 7_999, isVisible: true)
        _ = visibility.receiveVisibility(articleID: 17, isVisible: true)
        _ = visibility.receiveVisibility(articleID: 4_000, isVisible: true)

        XCTAssertEqual(visibility.receiveVisibility(articleID: 123, isVisible: true), [17, 123, 4_000, 7_999])
    }

    func testListVisibilityOnlySuppliesOrderedInputToTheExistingTracker() {
        var visibility = IOSListVisibilityCoordinator()
        var tracker = IOSScrolloverOrderTracker()
        let ids: [Int64] = [10, 20, 30]
        _ = visibility.updateSnapshot(ids)
        tracker.updateSnapshot(ids)
        _ = visibility.receiveVisibility(articleID: 10, isVisible: true).map { tracker.receiveVisibleIDs($0, enabled: true) }
        tracker.setUserScrolling(true)

        _ = visibility.receiveVisibility(articleID: 20, isVisible: true)
        let visible = visibility.receiveVisibility(articleID: 10, isVisible: false)!
        XCTAssertTrue(tracker.receiveVisibleIDs(visible, enabled: true).articleIDs.isEmpty)
        _ = visibility.receiveVisibility(articleID: 30, isVisible: true)
        let advanced = visibility.receiveVisibility(articleID: 20, isVisible: false)!
        XCTAssertEqual(tracker.receiveVisibleIDs(advanced, enabled: true).articleIDs, [10])
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
        var tracker = IOSScrolloverOrderTracker()
        tracker.updateSnapshot([1, 2, 3, 4])
        _ = tracker.receiveVisibleIDs([1], enabled: true)
        tracker.setUserScrolling(true)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [1, 2, 3])

        store.applyScrolloverMutationForTesting([1, 2, 3])
        let revision = store.scrolloverRearmRevision
        store.applyScrolloverUndoForTesting()
        XCTAssertEqual(store.scrolloverRearmRevision, revision + 1)

        tracker.releaseEmittedIDs()
        XCTAssertTrue(tracker.receiveVisibleIDs([1], enabled: true).articleIDs.isEmpty)
        XCTAssertEqual(tracker.receiveVisibleIDs([4], enabled: true).articleIDs, [1, 2, 3])
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
