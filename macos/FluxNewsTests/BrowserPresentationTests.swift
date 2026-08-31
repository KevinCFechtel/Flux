import XCTest
@testable import FluxNews

@MainActor
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
        XCTAssertFalse(ArticleListPresentationPolicy.removesMarkedReadArticle(removeWhenMarkedRead: true, unreadOnly: true, scope: .listeningList))
    }

    func testListeningListScopeAndDefaults() {
        let store = BrowserStore()
        XCTAssertEqual(store.scope, .all)
        XCTAssertEqual(store.listeningListSort, .recentlyAdded)
        XCTAssertNil(store.listeningListFeedID)
        XCTAssertEqual(BrowserScope.listeningList, .listeningList)
    }

    func testListeningListFeedSelectionFallsBackWhenFeedIsNoLongerRepresented() {
        let feeds = [ListeningListFeed(feedId: 11, feedTitle: "News", itemCount: 1)]
        XCTAssertEqual(ListeningListPresentation.validatedFeedID(11, feeds: feeds), 11)
        XCTAssertNil(ListeningListPresentation.validatedFeedID(12, feeds: feeds))
        XCTAssertNil(ListeningListPresentation.validatedFeedID(nil, feeds: feeds))
    }

    func testListeningListUsesOneNewsRowAndActiveEnclosureForPlayback() {
        let first = listeningEnclosure(id: 1, positionMs: 12_000, durationMs: 45_000, status: .inProgress)
        let second = listeningEnclosure(id: 2, positionMs: 3_000, durationMs: 8_000, status: .inProgress)
        let item = listeningItem(enclosures: [first, second], activeID: 2)

        XCTAssertEqual(item.articleId, 7)
        XCTAssertNil(ListeningListPresentation.preferredEnclosure(listeningItem(enclosures: [first, second], activeID: nil)))
        XCTAssertEqual(ListeningListPresentation.preferredEnclosure(item)?.id, 2)
        XCTAssertEqual(ListeningListPresentation.progress(item)?.positionMs, 3_000)
        XCTAssertEqual(ListeningListPresentation.progress(item)?.durationMs, 8_000)
    }

    func testListeningListProgressStatesAvoidMisleadingNotStartedAndUnknownDuration() {
        let notStarted = listeningItem(enclosures: [listeningEnclosure(id: 1, positionMs: 0, durationMs: 42_000, status: .notStarted)], activeID: 1)
        XCTAssertNil(ListeningListPresentation.progress(notStarted))

        let unknown = listeningItem(enclosures: [listeningEnclosure(id: 1, positionMs: 28 * 60_000, durationMs: nil, status: .inProgress)], activeID: 1)
        XCTAssertEqual(ListeningListPresentation.progress(unknown)?.positionMs, 28 * 60_000)
        XCTAssertNil(ListeningListPresentation.progress(unknown)?.durationMs)

        let completed = listeningItem(enclosures: [listeningEnclosure(id: 1, positionMs: 42_000, durationMs: 42_000, status: .completed)], activeID: 1)
        XCTAssertEqual(ListeningListPresentation.progress(completed)?.status, .completed)
    }

    func testListeningListProgressClampsInconsistentPositionAndIgnoresZeroDuration() {
        let inconsistent = listeningItem(enclosures: [listeningEnclosure(id: 1, positionMs: 90_000, durationMs: 42_000, status: .inProgress)], activeID: 1)
        XCTAssertEqual(ListeningListPresentation.progress(inconsistent)?.positionMs, 42_000)

        let zeroDuration = listeningItem(enclosures: [listeningEnclosure(id: 1, positionMs: 12_000, durationMs: 0, status: .inProgress)], activeID: 1)
        XCTAssertNil(ListeningListPresentation.progress(zeroDuration)?.durationMs)
    }

    func testMediaTextFallbackTreatsWhitespaceAsMissing() {
        XCTAssertEqual(ListeningListPresentation.textOrFallback("  \n", fallback: "Untitled News"), "Untitled News")
        XCTAssertEqual(ListeningListPresentation.textOrFallback("Episode", fallback: "Untitled News"), "Episode")
    }

    func testListeningListDownloadSummarySupportsSingleAndMultipleEnclosures() {
        let downloaded = listeningEnclosure(id: 1, positionMs: 0, durationMs: nil, status: .notStarted, downloadState: .downloaded)
        let pending = listeningEnclosure(id: 2, positionMs: 0, durationMs: nil, status: .notStarted, downloadState: .requested)
        let item = listeningItem(enclosures: [downloaded, pending], activeID: nil)

        XCTAssertEqual(ListeningListPresentation.downloadedCount(item).downloaded, 1)
        XCTAssertEqual(ListeningListPresentation.downloadedCount(item).total, 2)
        XCTAssertEqual(ListeningListPresentation.downloadedCount(item).pending, 1)
        XCTAssertEqual(ListeningListPresentation.downloadedCount(listeningItem(enclosures: [downloaded], activeID: 1)).downloaded, 1)
    }

    private func listeningItem(enclosures: [ListeningListEnclosure], activeID: Int64?) -> ListeningListItem {
        ListeningListItem(articleId: 7, feedId: 11, title: "Episode", feedTitle: "Feed", publishedAt: "2026-01-01T00:00:00Z", addedAt: "2026-01-02T00:00:00Z", remotePresent: true, audioEnclosures: enclosures, activeEnclosureId: activeID)
    }

    private func listeningEnclosure(id: Int64, positionMs: UInt64, durationMs: UInt64?, status: PlaybackStatus, downloadState: DownloadState? = nil) -> ListeningListEnclosure {
        let enclosure = Enclosure(id: id, articleId: 7, url: "https://example.test/\(id).mp3", mimeType: "audio/mpeg", sizeBytes: nil, remoteMediaProgressionSeconds: 0, mediaKind: .audio)
        let playback = PlaybackState(enclosureId: id, positionMs: positionMs, durationMs: durationMs, status: status, updatedAt: nil)
        let download = downloadState.map { MediaDownload(enclosureId: id, state: $0, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil) }
        return ListeningListEnclosure(enclosure: enclosure, remotePresent: true, playbackState: playback, download: download, durationMs: durationMs)
    }
}
