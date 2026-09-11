import XCTest
import ImageIO
import Observation
import UniformTypeIdentifiers
import UIKit
@testable import FluxNews

final class NewsreaderPresentationTests: XCTestCase {
    @MainActor
    private final class ObservationFlag {
        var value = false
    }

    @MainActor
    func testUnconfiguredFeedPreferenceOperationsFail() async {
        let store = NewsreaderStore(defaults: UserDefaults())
        let read = expectation(description: "read failure")
        let write = expectation(description: "write failure")
        store.loadFeedPreferences(feedID: 42) { result in
            if case .success = result { XCTFail("Unexpected read success") }
            read.fulfill()
        }
        store.setFeedOpenInMiniflux(feedID: 42, enabled: true) { result in
            if case .success = result { XCTFail("Unexpected write success") }
            write.fulfill()
        }
        await fulfillment(of: [read, write], timeout: 1)
    }

    func testFeedSettingsRequestLifecycleRejectsStaleResults() {
        var lifecycle = IOSFeedSettingsRequestLifecycle()
        let first = lifecycle.begin()
        let second = lifecycle.begin()

        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.isCurrent(second))
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.isCurrent(second))
    }

    func testDefaultBottomActionsAreSyncFilterAndMore() {
        XCTAssertEqual(IOSBottomAction.defaultActions, [.sync, .filterAndSort, .more])
        XCTAssertFalse(IOSBottomAction.defaultActions.contains(.settings))
    }

    func testMoreActionsKeepSettingsAndOnlyOfferNextForSupportedScopes() {
        XCTAssertEqual(IOSMoreAction.actions(for: .feed(1), hasNextScope: true), [.markAllRead, .markAllReadAndNext, .settings])
        XCTAssertEqual(IOSMoreAction.actions(for: .feed(1), hasNextScope: false), [.markAllRead, .settings])
        XCTAssertEqual(IOSMoreAction.actions(for: .all, hasNextScope: true), [.markAllRead, .settings])
        XCTAssertEqual(IOSMoreAction.actions(for: .starred, hasNextScope: true), [.settings])
        XCTAssertEqual(IOSMoreAction.actions(for: .listeningList, hasNextScope: true), [.settings])
    }

    func testNextFeedUsesNavigationOrderAndDoesNotWrap() {
        let catalog = NavigationCatalog(categories: [], feeds: [
            .init(id: 10, categoryId: 1, title: "First"),
            .init(id: 20, categoryId: 1, title: "Second")
        ])
        XCTAssertEqual(IOSScopeNavigation.nextScope(after: .feed(10), catalog: catalog, hidingEmpty: false, counts: [:]), .feed(20))
        XCTAssertNil(IOSScopeNavigation.nextScope(after: .feed(20), catalog: catalog, hidingEmpty: false, counts: [:]))
    }

    func testNextCategoryUsesNavigationOrderAndDoesNotWrap() {
        let catalog = NavigationCatalog(
            categories: [.init(id: 1, title: "First"), .init(id: 2, title: "Second")],
            feeds: [.init(id: 10, categoryId: 1, title: "Feed"), .init(id: 20, categoryId: 2, title: "Feed")]
        )
        XCTAssertEqual(IOSScopeNavigation.nextScope(after: .category(1), catalog: catalog, hidingEmpty: false, counts: [:]), .category(2))
        XCTAssertNil(IOSScopeNavigation.nextScope(after: .category(2), catalog: catalog, hidingEmpty: false, counts: [:]))
    }

    func testNextScopeUsesVisibleNavigationProjectionAndNeverAppliesToGlobalScopes() {
        let catalog = NavigationCatalog(
            categories: [.init(id: 1, title: "First"), .init(id: 2, title: "Second"), .init(id: 3, title: "Third")],
            feeds: [.init(id: 10, categoryId: 1, title: "Current"), .init(id: 20, categoryId: 2, title: "Empty"), .init(id: 30, categoryId: 3, title: "Visible")]
        )
        XCTAssertEqual(IOSScopeNavigation.nextScope(after: .feed(10), catalog: catalog, hidingEmpty: true, counts: [10: 1, 20: 0, 30: 1]), .feed(30))
        XCTAssertNil(IOSScopeNavigation.nextScope(after: .all, catalog: catalog, hidingEmpty: false, counts: [:]))
        XCTAssertNil(IOSScopeNavigation.nextScope(after: .starred, catalog: catalog, hidingEmpty: false, counts: [:]))
    }

    func testNewsNavigationPresentationMatchesDeviceRoutes() {
        XCTAssertEqual(NewsNavigationPresentation.sidebar, .sidebar)
        XCTAssertEqual(NewsNavigationPresentation.sheet, .sheet)
    }

    func testNewsNavigationUsesSplitViewOnlyOnIPad() {
        XCTAssertFalse(NewsNavigationLayout.usesSplitView(for: .phone))
        XCTAssertTrue(NewsNavigationLayout.usesSplitView(for: .pad))
    }

    func testIPhoneNavigationButtonUsesTheFluxTemplateAsset() {
        XCTAssertEqual(IOSNavigationButtonPresentation.imageName, "FluxNewsTemplate")
        XCTAssertEqual(IOSNavigationButtonPresentation.accessibilityLabel, String(localized: "Choose news scope"))
        XCTAssertEqual(IOSNavigationButtonPresentation.glyphSize, 22)
    }

    func testNavigationBrandingUsesTheExistingFluxNewsTemplateAsset() {
        XCTAssertEqual(IOSNavigationBranding.assetName, "FluxNewsTemplate")
        XCTAssertEqual(IOSNavigationBranding.accessibilityLabel, String(localized: "FluxNews"))
        XCTAssertTrue(IOSNavigationBranding.iconUsesSolidAccentColor)
    }

    func testArticleNavigationHostUsesTheExistingResetRevisionAsItsIdentity() {
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 0), 0)
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 1), 1)
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 2), 2)
    }

    func testArticleListTitleDoesNotContainSelectionCount() {
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .all, catalog: NavigationCatalog(categories: [], feeds: [])), String(localized: "All News"))
    }

    func testArticleListTitleUsesCategorySelectionCount() {
        let catalog = NavigationCatalog(categories: [Category(id: 1, title: "Technology")], feeds: [])
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .category(1), catalog: catalog), "Technology")
    }

    func testArticleListTitleUsesFeedSelectionCount() {
        let catalog = NavigationCatalog(categories: [], feeds: [Feed(id: 10, categoryId: 1, title: "Ars Technica")])
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .feed(10), catalog: catalog), "Ars Technica")
    }

    func testArticleListTitleUsesStarredSelectionCount() {
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .starred, catalog: NavigationCatalog(categories: [], feeds: [])), String(localized: "Starred"))
    }

    @MainActor
    func testArticleListTitleReflectsUpdatedSelectionCount() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .all
        store.setSelectionTotalForTesting(4)
        XCTAssertEqual(ArticleListCounterPresentation.compactCount(store.selectionTotal), "4")

        store.setSelectionTotalForTesting(3)
        XCTAssertEqual(ArticleListCounterPresentation.compactCount(store.selectionTotal), "3")
    }

    func testArticleListCounterUsesCurrentScopeAndFilterSemantics() {
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: true, count: 117), String(localized: "\(117) unread article"))
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: false, count: 842), String(localized: "\(842) article"))
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .starred, unreadOnly: true, count: 8), String(localized: "\(8) article"))
        XCTAssertEqual(ArticleListCounterPresentation.compactCount(1000), "1000")
    }

    func testArticleListCounterUsesEnglishAndGermanPluralVariations() {
        let english = Locale(identifier: "en")
        let appBundle = Bundle(identifier: "dev.kevincfechtel.fluxNews.nativeDev")!

        XCTAssertEqual(String(localized: "\(1) article", bundle: appBundle, locale: english), "1 article")
        XCTAssertEqual(String(localized: "\(2) article", bundle: appBundle, locale: english), "2 articles")
    }

    func testArticleListCounterUsesGermanPluralVariations() throws {
        try XCTSkipUnless(Locale.current.language.languageCode?.identifier == "de")

        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: false, count: 1), "1 Artikel")
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: false, count: 2), "2 Artikel")
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: true, count: 1), "1 ungelesener Artikel")
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: true, count: 2), "2 ungelesene Artikel")
    }

    @MainActor
    func testArticleCountPreferenceDefaultsPersistsAndOnlyControlsCounterPresentation() {
        let suiteName = "FluxNews.CounterSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NewsreaderStore(defaults: defaults)
        XCTAssertTrue(store.showArticleCount)
        XCTAssertTrue(ArticleListCounterPresentation.isVisible(showArticleCount: store.showArticleCount))

        store.setShowArticleCount(false)
        XCTAssertFalse(store.showArticleCount)
        XCTAssertFalse(ArticleListCounterPresentation.isVisible(showArticleCount: store.showArticleCount))
        XCTAssertFalse(ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: store.showArticleCount, supportsNativeSubtitle: true))
        XCTAssertFalse(ArticleListCounterPresentation.usesToolbarFallback(showArticleCount: store.showArticleCount, supportsNativeSubtitle: false))
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .all, catalog: store.catalog), String(localized: "All News"))
        XCTAssertEqual(store.selectionTotal, 0)

        let reloaded = NewsreaderStore(defaults: defaults)
        XCTAssertFalse(reloaded.showArticleCount)
    }

    func testArticleCountPresentationSelectsNativeSubtitleOrToolbarFallback() {
        XCTAssertTrue(ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: true, supportsNativeSubtitle: true))
        XCTAssertFalse(ArticleListCounterPresentation.usesToolbarFallback(showArticleCount: true, supportsNativeSubtitle: true))
        XCTAssertFalse(ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: true, supportsNativeSubtitle: false))
        XCTAssertTrue(ArticleListCounterPresentation.usesToolbarFallback(showArticleCount: true, supportsNativeSubtitle: false))
    }

    func testEmptyStatePresentationUsesSyncingAndNoNews() {
        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: true, isLoading: false, errorMessage: nil, hasArticles: false), .syncing)
        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: false, isLoading: true, errorMessage: nil, hasArticles: false), .loading)
        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: false, isLoading: false, errorMessage: nil, hasArticles: false), .noNews)
        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: true, isLoading: true, errorMessage: nil, hasArticles: false), .syncing)
        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: true, isLoading: true, errorMessage: "Offline", hasArticles: false), .error("Offline"))
        XCTAssertNil(IOSArticleListEmptyState.resolve(isSyncing: true, isLoading: true, errorMessage: nil, hasArticles: true))
    }

    @MainActor
    func testSyncReplacementRemainsLoadingUntilSnapshotResolves() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.completeSyncForTesting(SyncCompleted(reason: .manual, newArticles: 0, updatedArticles: 0, mutationsDelivered: 0, dataChanged: true, navigationChanged: false, newArticlesByFeed: [], systemNotificationCandidates: []))

        XCTAssertEqual(IOSArticleListEmptyState.resolve(isSyncing: store.isSyncing, isLoading: store.isLoading, errorMessage: store.errorMessage, hasArticles: !store.articles.isEmpty), .loading)
    }

    func testSyncButtonPresentationUsesTheSameRotatingSymbolForEverySyncState() {
        XCTAssertEqual(IOSSyncButtonPresentation.symbolName(for: .idle), "arrow.clockwise")
        XCTAssertEqual(IOSSyncButtonPresentation.symbolName(for: .syncing), "arrow.clockwise")
        XCTAssertEqual(IOSSyncButtonPresentation.symbolName(for: .success), "checkmark")
        XCTAssertEqual(IOSSyncButtonPresentation.rotationDegrees(for: .idle, reduceMotion: false), 0)
        XCTAssertEqual(IOSSyncButtonPresentation.rotationDegrees(for: .syncing, reduceMotion: false), 360)
        XCTAssertEqual(IOSSyncButtonPresentation.rotationDegrees(for: .success, reduceMotion: false), 0)
        XCTAssertEqual(IOSSyncButtonPresentation.rotationDegrees(for: .syncing, reduceMotion: true), 0)
        XCTAssertEqual(IOSSyncButtonPresentation.accessibilityValue(for: .idle), String(localized: "Ready"))
        XCTAssertEqual(IOSSyncButtonPresentation.accessibilityValue(for: .syncing), String(localized: "Syncing"))
        XCTAssertEqual(IOSSyncButtonPresentation.accessibilityValue(for: .success), String(localized: "Sync complete"))
    }

    func testSyncButtonSuccessTimeoutCannotOverwriteNewerSync() {
        XCTAssertTrue(IOSSyncButtonPresentation.canEndSuccess(generation: 2, currentGeneration: 2, isSyncing: false))
        XCTAssertFalse(IOSSyncButtonPresentation.canEndSuccess(generation: 1, currentGeneration: 2, isSyncing: false))
        XCTAssertFalse(IOSSyncButtonPresentation.canEndSuccess(generation: 2, currentGeneration: 2, isSyncing: true))
    }

    @MainActor
    func testEmptyStatePresentationUsesSyncLifecycle() {
        let store = NewsreaderStore(defaults: UserDefaults())
        XCTAssertFalse(store.isSyncing)
        store.setSyncingForTesting(true)
        XCTAssertTrue(store.isSyncing)
        store.setSyncingForTesting(false)
        XCTAssertFalse(store.isSyncing)
    }

    @MainActor
    func testCountOnlyChangeDoesNotInvalidateArticleListDependencies() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let articleListInvalidated = ObservationFlag()

        withObservationTracking {
            _ = store.articles
            _ = store.isLoading
            _ = store.errorMessage
            _ = store.articlePresentationMode
            _ = store.articlePreviewLines
            _ = store.snapshotRevision
            _ = store.scrollResetRevision
            _ = store.markReadOnScrolloverEnabled
            _ = store.scrolloverRearmRevision
            _ = store.hasPendingNewData
            _ = store.hasUnscopedNewDataSignal
        } onChange: {
            MainActor.assumeIsolated { articleListInvalidated.value = true }
        }

        store.setSelectionTotalForTesting(3)

        XCTAssertFalse(articleListInvalidated.value)
    }

    @MainActor
    func testFeedIconCompletionInvalidatesOnlyItsPresentationState() {
        let store = NewsreaderStore(defaults: UserDefaults())
        let icon = store.feedIconPresentationState(for: 10, variant: .normal)
        let otherIcon = store.feedIconPresentationState(for: 20, variant: .normal)
        let otherInvalidated = ObservationFlag()

        withObservationTracking {
            _ = otherIcon.image
        } onChange: {
            MainActor.assumeIsolated { otherInvalidated.value = true }
        }

        icon.image = UIImage()

        XCTAssertFalse(otherInvalidated.value)
    }

    @MainActor
    func testRowReadStateDoesNotInvalidateTheStructuralArticleSnapshot() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([.init(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: nil)])
        let articleListInvalidated = ObservationFlag()

        withObservationTracking {
            _ = store.articles
        } onChange: {
            MainActor.assumeIsolated { articleListInvalidated.value = true }
        }

        let rowState = store.rowPresentationStateForTesting(1)!
        rowState.setRead(true)

        XCTAssertFalse(articleListInvalidated.value)
        XCTAssertTrue(rowState.isRead)
    }

    @MainActor
    func testRowStatusMutationsDoNotInvalidateImmutableRowContent() {
        let article = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "https://example.com/comments", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: "https://example.com/image.jpg")
        let rowState = ArticleRowPresentationState(article: article)
        let invalidated = ObservationFlag()

        withObservationTracking {
            _ = rowState.content
        } onChange: {
            MainActor.assumeIsolated { invalidated.value = true }
        }

        rowState.setRead(true)
        rowState.setStarred(true)

        XCTAssertFalse(invalidated.value)
        XCTAssertEqual(rowState.content.article, ArticleRowArticle(article: article))
        XCTAssertEqual(rowState.content.imageURL, URL(string: "https://example.com/image.jpg"))
        XCTAssertTrue(rowState.content.hasComments)
        XCTAssertNotEqual(rowState.content.publishedDate, article.publishedAt)
    }

    @MainActor
    func testReadOnlySnapshotReconciliationKeepsImmutableContent() {
        let original = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let state = ArticleRowPresentationState(article: original)
        let content = state.content

        state.reconcile(with: ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: true, isStarred: false, preview: "Preview", imageUrl: nil))

        XCTAssertEqual(state.content, content)
        XCTAssertTrue(state.isRead)
    }

    @MainActor
    func testStarredOnlySnapshotReconciliationKeepsImmutableContent() {
        let original = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let state = ArticleRowPresentationState(article: original)
        let content = state.content

        state.reconcile(with: ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: true, preview: "Preview", imageUrl: nil))

        XCTAssertEqual(state.content, content)
        XCTAssertTrue(state.isStarred)
    }

    @MainActor
    func testImmutableSnapshotReconciliationUpdatesContent() {
        let original = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let state = ArticleRowPresentationState(article: original)

        state.reconcile(with: ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Updated", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil))

        XCTAssertEqual(state.content.article.title, "Updated")
    }

    func testFallbackReadChangeInvalidatesPresentationWithoutRowState() {
        let article = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let unread = makePresentation(article: article, fallbackRead: false, fallbackStarred: false, rowState: nil)
        let read = makePresentation(article: article, fallbackRead: true, fallbackStarred: false, rowState: nil)

        XCTAssertFalse(unread == read)
    }

    func testFallbackStarredChangeInvalidatesPresentationWithoutRowState() {
        let article = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let unstarred = makePresentation(article: article, fallbackRead: false, fallbackStarred: false, rowState: nil)
        let starred = makePresentation(article: article, fallbackRead: false, fallbackStarred: true, rowState: nil)

        XCTAssertFalse(unstarred == starred)
    }

    func testRowStatePresentationIgnoresFallbackStatusChanges() {
        let article = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let state = ArticleRowPresentationState(article: article)
        let feedIcon = IOSFeedIconPresentationState()
        let first = makePresentation(article: article, fallbackRead: false, fallbackStarred: false, rowState: state, feedIcon: feedIcon)
        let second = makePresentation(article: article, fallbackRead: true, fallbackStarred: true, rowState: state, feedIcon: feedIcon)

        XCTAssertTrue(first == second)
    }

    func testImmutableContentChangeInvalidatesStaticPresentation() {
        let original = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let updated = ArticleSummary(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Updated", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
        let first = makePresentation(article: original, fallbackRead: false, fallbackStarred: false, rowState: nil)
        let second = makePresentation(article: updated, fallbackRead: false, fallbackStarred: false, rowState: nil)

        XCTAssertFalse(first == second)
    }

    @MainActor
    func testTargetedReadAndStarredDeltasDoNotReconcileStructuralTimelineInput() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)
        let structuralCount = controller.structuralReconciliationCount
        let snapshotCount = controller.structuralSnapshotApplicationCount

        bridge.publishArticle(.init(articleID: 1, state: .init(isRead: true, isStarred: false, revision: 1), rearmScrollover: false))
        bridge.publishArticle(.init(articleID: 1, state: .init(isRead: true, isStarred: true, revision: 2), rearmScrollover: false))

        XCTAssertEqual(controller.structuralReconciliationCount, structuralCount)
        XCTAssertEqual(controller.structuralSnapshotApplicationCount, snapshotCount)
        XCTAssertEqual(controller.articlePresentationApplicationCount, 2)
    }

    @MainActor
    func testFeedIconDeltaDoesNotApplyStructuralSnapshot() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)
        let structuralCount = controller.structuralReconciliationCount
        let snapshotCount = controller.structuralSnapshotApplicationCount

        bridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: UIImage(), revision: 1))

        XCTAssertEqual(controller.structuralReconciliationCount, structuralCount)
        XCTAssertEqual(controller.structuralSnapshotApplicationCount, snapshotCount)
        XCTAssertEqual(controller.feedIconPresentationApplicationCount, 1)
    }

    @MainActor
    func testExplicitUnreadDeltaRearmsOnlyTargetedScrolloverArticle() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)

        bridge.publishArticle(.init(articleID: 1, state: .init(isRead: false, isStarred: false, revision: 1), rearmScrollover: true))

        XCTAssertEqual(controller.scrolloverRearmCount, 1)
        XCTAssertEqual(controller.structuralReconciliationCount, 1)
    }

    @MainActor
    func testBridgeRejectsStalePresentationAndRetainsLatestOffscreenState() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let article = timelineArticle(id: 1)
        bridge.publishArticle(.init(articleID: 1, state: .init(isRead: true, isStarred: true, revision: 2), rearmScrollover: false))
        bridge.publishArticle(.init(articleID: 1, state: .init(isRead: false, isStarred: false, revision: 1), rearmScrollover: true))

        XCTAssertEqual(bridge.articleState(for: 1, fallback: article), .init(isRead: true, isStarred: true, revision: 2))
    }

    @MainActor
    func testStructuralOrderChangeAppliesAnotherSnapshot() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)
        let firstSnapshots = controller.structuralSnapshotApplicationCount
        let articles = [timelineArticle(id: 2), timelineArticle(id: 1)]
        controller.update(
            structuralState: timelineStructuralState(articles, revision: 2),
            presentationBridge: bridge,
            feedIconPresentationBridge: bridge,
            mode: .visual,
            previewLines: .standard,
            iconVariant: .normal,
            scrollResetRevision: 0,
            markReadOnScrolloverEnabled: false,
            showsRefreshControl: false
        )
        XCTAssertEqual(controller.structuralSnapshotApplicationCount, firstSnapshots + 1)
    }

    @MainActor
    private func makeTimelineController(bridge: IOSUIKitArticleTimelinePresentationBridge) -> IOSUIKitArticleTimelineController {
        let controller = IOSUIKitArticleTimelineController()
        let articles = [timelineArticle(id: 1), timelineArticle(id: 2)]
        bridge.replaceArticleStates(Dictionary(uniqueKeysWithValues: articles.map { ($0.id, .init(isRead: $0.isRead, isStarred: $0.isStarred, revision: 0)) }))
        controller.update(
            structuralState: timelineStructuralState(articles, revision: 1),
            presentationBridge: bridge,
            feedIconPresentationBridge: bridge,
            mode: .visual,
            previewLines: .standard,
            iconVariant: .normal,
            scrollResetRevision: 0,
            markReadOnScrolloverEnabled: false,
            showsRefreshControl: false
        )
        return controller
    }

    private func timelineStructuralState(_ articles: [ArticleSummary], revision: UInt64) -> IOSUIKitArticleTimelineStructuralState {
        .init(items: articles.map { .init(article: $0, content: ArticleRowContent(article: $0)) }, revision: revision)
    }

    private func timelineArticle(id: Int64) -> ArticleSummary {
        .init(id: id, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
    }

    private func makePresentation(article: ArticleSummary, fallbackRead: Bool, fallbackStarred: Bool, rowState: ArticleRowPresentationState?, feedIcon: IOSFeedIconPresentationState? = nil) -> ArticlePresentationView {
        ArticlePresentationView(content: ArticleRowContent(article: article), fallbackRead: fallbackRead, fallbackStarred: fallbackStarred, rowState: rowState, mode: .compact, previewLines: .standard, availableWidth: 320, feedIcon: feedIcon ?? IOSFeedIconPresentationState(), iconVariant: .normal, onRequestFeedIcon: {}, onTap: {}, onAction: { _ in }, onSetRead: { _ in }, onSetStarred: { _ in })
    }

    func testScrolloverUndoFeedbackTriggersOnlyForNewlyVisiblePresentation() {
        XCTAssertFalse(ScrolloverUndoPresentationPolicy.shouldTriggerFeedback(previouslyVisible: false, currentlyVisible: false))
        XCTAssertTrue(ScrolloverUndoPresentationPolicy.shouldTriggerFeedback(previouslyVisible: false, currentlyVisible: true))
        XCTAssertFalse(ScrolloverUndoPresentationPolicy.shouldTriggerFeedback(previouslyVisible: true, currentlyVisible: true))
        XCTAssertFalse(ScrolloverUndoPresentationPolicy.shouldTriggerFeedback(previouslyVisible: true, currentlyVisible: false))
    }

    func testNewsNavigationSelectionMatchesOnlyTheActiveScope() {
        XCTAssertTrue(NewsNavigationSelection.isSelected(.all, activeScope: .all))
        XCTAssertTrue(NewsNavigationSelection.isSelected(.starred, activeScope: .starred))
        XCTAssertTrue(NewsNavigationSelection.isSelected(.category(1), activeScope: .category(1)))
        XCTAssertTrue(NewsNavigationSelection.isSelected(.feed(10), activeScope: .feed(10)))
        XCTAssertFalse(NewsNavigationSelection.isSelected(.category(1), activeScope: .feed(10)))
        XCTAssertFalse(NewsNavigationSelection.isSelected(.feed(11), activeScope: .feed(10)))
    }

    func testCategoryPresentationDistinguishesDirectSelectionAndSelectedFeedContext() {
        let catalog = NavigationCatalog(
            categories: [.init(id: 1, title: "Technology"), .init(id: 2, title: "World")],
            feeds: [.init(id: 10, categoryId: 1, title: "Ars"), .init(id: 11, categoryId: 2, title: "BBC")]
        )

        XCTAssertEqual(NewsNavigationSelection.categoryPresentation(categoryID: 1, activeScope: .category(1), catalog: catalog), .directlySelected)
        XCTAssertEqual(NewsNavigationSelection.categoryPresentation(categoryID: 1, activeScope: .feed(10), catalog: catalog), .containsSelectedFeed)
        XCTAssertEqual(NewsNavigationSelection.categoryPresentation(categoryID: 2, activeScope: .feed(10), catalog: catalog), .unselected)
        XCTAssertEqual(NewsNavigationSelection.categoryPresentation(categoryID: 1, activeScope: .all, catalog: catalog), .unselected)
        XCTAssertEqual(NewsNavigationSelection.categoryPresentation(categoryID: 1, activeScope: .starred, catalog: catalog), .unselected)
        XCTAssertTrue(NewsNavigationSelection.isSelected(.feed(10), activeScope: .feed(10)))
    }

    func testNavigationExpansionEnsuresTheSelectedFeedParentWithoutDiscardingManualExpansion() {
        let catalog = NavigationCatalog(
            categories: [.init(id: 1, title: "Technology"), .init(id: 2, title: "World")],
            feeds: [.init(id: 10, categoryId: 1, title: "Ars"), .init(id: 11, categoryId: 2, title: "BBC")]
        )
        var expansion = NewsNavigationExpansionState()

        expansion.setExpanded(true, categoryID: 1)
        expansion.ensureSelectedFeedIsExpanded(scope: .feed(11), catalog: catalog)

        XCTAssertTrue(expansion.isExpanded(1))
        XCTAssertTrue(expansion.isExpanded(2))
    }

    func testNavigationExpansionIgnoresNonFeedScopesAndExpandsNewActiveFeed() {
        let catalog = NavigationCatalog(
            categories: [.init(id: 1, title: "Technology"), .init(id: 2, title: "World")],
            feeds: [.init(id: 10, categoryId: 1, title: "Ars"), .init(id: 11, categoryId: 2, title: "BBC")]
        )
        var expansion = NewsNavigationExpansionState()

        expansion.ensureSelectedFeedIsExpanded(scope: .category(1), catalog: catalog)
        expansion.ensureSelectedFeedIsExpanded(scope: .all, catalog: catalog)
        expansion.ensureSelectedFeedIsExpanded(scope: .starred, catalog: catalog)
        XCTAssertFalse(expansion.isExpanded(1))
        XCTAssertFalse(expansion.isExpanded(2))

        expansion.ensureSelectedFeedIsExpanded(scope: .feed(10), catalog: catalog)
        XCTAssertTrue(expansion.isExpanded(1))
        XCTAssertFalse(expansion.isExpanded(2))
    }

    func testFeedIconAppearanceUsesCoreVariants() {
        XCTAssertEqual(IOSFeedIconPresentation.variant(isDark: false), .normal)
        XCTAssertEqual(IOSFeedIconPresentation.variant(isDark: true), .dark)
        XCTAssertNotEqual(IOSFeedIconKey(feedID: 1, variant: .normal), IOSFeedIconKey(feedID: 1, variant: .dark))
    }

    func testFeedCreationPoliciesValidateURLsAndTrimCategories() {
        XCTAssertEqual(IOSFeedCreationPolicy.validURL(" https://example.com/feed "), "https://example.com/feed")
        XCTAssertNil(IOSFeedCreationPolicy.validURL("not a url"))
        XCTAssertEqual(IOSFeedCreationPolicy.categoryTitle("  Technology  "), "Technology")
        XCTAssertNil(IOSFeedCreationPolicy.categoryTitle(" \n "))
    }

    func testSingleAndMultipleDiscoveryOutcomesRemainDistinct() {
        let item = DiscoveredSubscription(url: "https://example.com/feed", title: "Feed", feedType: "rss")
        XCTAssertEqual(IOSAddFeedDiscoveryOutcome.from([]), .none)
        XCTAssertEqual(IOSAddFeedDiscoveryOutcome.from([item]), .automatic(item))
        XCTAssertEqual(IOSAddFeedDiscoveryOutcome.from([item, item]), .choose)
    }

    func testArticlePresentationModesAreStableAndVisualIsFirst() {
        XCTAssertEqual(ArticlePresentationMode.allCases, [.visual, .compact])
        XCTAssertEqual(ArticlePresentationMode(rawValue: "visual"), .visual)
        XCTAssertEqual(ArticlePresentationMode(rawValue: "compact"), .compact)
    }

    func testUIKitTimelineUsesStructuralSnapshotsOnlyForMembershipOrOrderChanges() {
        XCTAssertFalse(IOSUIKitTimelineSnapshotPolicy.requiresStructuralUpdate(previousIDs: [1, 2, 3], newIDs: [1, 2, 3]))
        XCTAssertTrue(IOSUIKitTimelineSnapshotPolicy.requiresStructuralUpdate(previousIDs: [1, 2, 3], newIDs: [1, 3, 2]))
        XCTAssertTrue(IOSUIKitTimelineSnapshotPolicy.requiresStructuralUpdate(previousIDs: [1, 2, 3], newIDs: [1, 2]))
    }

    @MainActor
    func testManualSyncWithoutAttachedCoreIsIgnoredAndPreservesScope() async {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.scope = .starred

        await store.syncManually()

        XCTAssertEqual(store.scope, .starred)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testArticlePresentationLayoutKeepsSemanticModeIndependentOfGeometry() {
        XCTAssertTrue(ArticlePresentationLayout.usesLandscapeVisual(mode: .visual, availableWidth: 720))
        XCTAssertFalse(ArticlePresentationLayout.usesLandscapeVisual(mode: .visual, availableWidth: 390))
        XCTAssertFalse(ArticlePresentationLayout.usesLandscapeVisual(mode: .compact, availableWidth: 720))
        XCTAssertEqual(ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: false), 1)
        XCTAssertEqual(ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: true), 0)
        XCTAssertTrue(ArticlePresentationMode.visual.showsArticleImage)
        XCTAssertFalse(ArticlePresentationMode.compact.showsArticleImage)
    }

    func testArticlePresentationLayoutUsesBoundedDeterministicImageSlots() {
        let availableWidth: CGFloat = 390
        let contentWidth = ArticlePresentationLayout.articleContentWidth(availableWidth)

        XCTAssertEqual(ArticlePresentationLayout.boundedArticleWidth(availableWidth), availableWidth)
        XCTAssertEqual(contentWidth, 366)
        XCTAssertEqual(ArticlePresentationLayout.visualPortraitContentWidth(availableWidth), availableWidth)
        XCTAssertEqual(ArticlePresentationLayout.portraitImageHeight(contentWidth: contentWidth), 205.875, accuracy: 0.01)
        let landscapeImageWidth = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
        let landscapeTextWidth = ArticlePresentationLayout.landscapeTextWidth(availableWidth: availableWidth, imageWidth: landscapeImageWidth, interColumnSpacing: 14)
        XCTAssertEqual(landscapeImageWidth, 175.68, accuracy: 0.01)
        XCTAssertEqual(landscapeTextWidth, 176.32, accuracy: 0.01)
        XCTAssertEqual(ArticlePresentationLayout.landscapeImageHeight(imageWidth: landscapeImageWidth), 98.82, accuracy: 0.01)
        XCTAssertLessThanOrEqual(landscapeImageWidth + landscapeTextWidth + 14, contentWidth)
        XCTAssertEqual(ArticlePresentationLayout.boundedArticleWidth(availableWidth + 100), availableWidth + 100)
        XCTAssertEqual(ArticlePresentationLayout.boundedArticleWidth(-1), 0)
    }

    func testArticleImageRequestBucketsDisplayPixelsDeterministically() {
        let url = URL(string: "https://example.com/image.jpg")!
        XCTAssertEqual(ArticleImageRequest(url: url, targetSize: CGSize(width: 100, height: 50), displayScale: 2).maxPixelDimension, 256)
        XCTAssertEqual(ArticleImageRequest(url: url, targetSize: CGSize(width: 127.9, height: 20), displayScale: 1).maxPixelDimension, 128)
        XCTAssertEqual(ArticleImageRequest(url: url, targetSize: CGSize(width: 128.1, height: 20), displayScale: 1).maxPixelDimension, 192)
    }

    func testPrefetchMetadataReusesAnUnchangedStructuralSnapshot() {
        func article(_ id: Int64, imageURL: String? = nil) -> ArticleSummary {
            ArticleSummary(id: id, feedId: 1, categoryId: 1, feedTitle: "Feed", title: "Article", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: imageURL)
        }
        var metadata = IOSArticleImagePrefetchMetadata()
        XCTAssertTrue(metadata.update(articles: [article(1), article(2, imageURL: "https://example.com/2.jpg")]))
        XCTAssertFalse(metadata.update(articles: [article(1), article(2, imageURL: "https://example.com/changed.jpg")]))
        XCTAssertEqual(metadata.candidateIDs(visibleIDs: [1], direction: .forward), [2])
        XCTAssertTrue(metadata.update(articles: [article(2, imageURL: "https://example.com/2.jpg"), article(1)]))
    }

    func testArticleImagePrefetchSelectsAtMostTwoImagesForwardAndSkipsTextOnlyArticles() {
        XCTAssertEqual(
            IOSArticleImagePrefetchPolicy.candidateIDs(
                orderedIDs: [1, 2, 3, 4, 5, 6],
                visibleIDs: [2],
                imageIDs: [3, 5, 6],
                direction: .forward
            ),
            [3, 5]
        )
    }

    func testArticleImagePrefetchLooksBackwardFromTheLeadingVisibleArticle() {
        XCTAssertEqual(
            IOSArticleImagePrefetchPolicy.candidateIDs(
                orderedIDs: [1, 2, 3, 4, 5],
                visibleIDs: [4, 5],
                imageIDs: [1, 2, 3],
                direction: .backward
            ),
            [3, 2]
        )
    }

    func testArticleImagePrefetchRespectsEdgesHorizonAndExcludedRequests() {
        XCTAssertEqual(
            IOSArticleImagePrefetchPolicy.candidateIDs(
                orderedIDs: [1, 2, 3],
                visibleIDs: [1],
                imageIDs: [2, 3],
                direction: .backward
            ),
            []
        )
        XCTAssertEqual(
            IOSArticleImagePrefetchPolicy.candidateIDs(
                orderedIDs: [1, 2, 3, 4, 5, 6],
                visibleIDs: [1],
                imageIDs: [2, 3, 4, 5, 6],
                direction: .forward,
                excludedIDs: [2],
                searchHorizon: 3
            ),
            [3, 4]
        )
    }

    func testPrefetchCoordinatorCoalescesRequestsUntilTheSnapshotChanges() {
        let url = URL(string: "https://example.com/image.jpg")!
        let request = ArticleImageRequest(url: url, targetSize: CGSize(width: 100, height: 50), displayScale: 2)
        let secondRequest = ArticleImageRequest(url: URL(string: "https://example.com/second.jpg")!, targetSize: CGSize(width: 100, height: 50), displayScale: 2)
        let coordinator = IOSArticleImagePrefetchCoordinator()

        XCTAssertEqual(coordinator.accept([request, secondRequest]), [request, secondRequest])
        XCTAssertTrue(coordinator.accept([secondRequest, request]).isEmpty)

        coordinator.reset()

        XCTAssertEqual(coordinator.accept([request]), [request])
    }

    func testArticleImagePipelineUsesDecodedCacheAndSeparatesLargerRequests() async throws {
        let data = try imageData(width: 800, height: 400)
        let counter = ImageLoadCounter(data: data)
        let pipeline = ArticleImagePipeline { _ in await counter.load() }
        let url = URL(string: "https://example.com/image.jpg")!
        let small = ArticleImageRequest(url: url, targetSize: CGSize(width: 100, height: 50), displayScale: 1)
        let large = ArticleImageRequest(url: url, targetSize: CGSize(width: 400, height: 200), displayScale: 1)

        _ = try await pipeline.image(for: small)
        _ = try await pipeline.image(for: small)
        XCTAssertNotNil(pipeline.cachedImage(for: small))
        let cachedCalls = await counter.callCount()
        XCTAssertEqual(cachedCalls, 1)

        let image = try await pipeline.image(for: large)
        let largerCalls = await counter.callCount()
        XCTAssertEqual(largerCalls, 2)
        XCTAssertGreaterThan(image.width, small.maxPixelDimension)
    }

    func testArticleImagePipelineSynchronousLookupUsesTheSameNormalizedCacheKey() async throws {
        let pipeline = ArticleImagePipeline { _ in try self.imageData(width: 800, height: 400) }
        let url = URL(string: "https://example.com/image.jpg")!
        let cachedRequest = ArticleImageRequest(url: url, targetSize: CGSize(width: 100, height: 50), displayScale: 1)
        let equivalentRequest = ArticleImageRequest(url: url, targetSize: CGSize(width: 127.9, height: 20), displayScale: 1)
        let differentSizeRequest = ArticleImageRequest(url: url, targetSize: CGSize(width: 128.1, height: 20), displayScale: 1)

        XCTAssertNil(pipeline.cachedImage(for: cachedRequest))
        _ = try await pipeline.image(for: cachedRequest)

        XCTAssertNotNil(pipeline.cachedImage(for: equivalentRequest))
        XCTAssertNil(pipeline.cachedImage(for: differentSizeRequest))
    }

    func testArticleImagePipelineDeduplicatesEquivalentInFlightRequests() async throws {
        let gate = ImageLoadGate(data: try imageData(width: 800, height: 400))
        let pipeline = ArticleImagePipeline { _ in try await gate.load() }
        let request = ArticleImageRequest(url: URL(string: "https://example.com/image.jpg")!, targetSize: CGSize(width: 200, height: 100), displayScale: 1)

        async let first = pipeline.image(for: request)
        await gate.waitUntilStarted()
        async let second = pipeline.image(for: request)
        await Task.yield()
        await gate.release()

        _ = try await first
        _ = try await second
        let calls = await gate.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testArticleImagePipelinePrefetchBatchesDuplicateRequests() async throws {
        let gate = ImageLoadGate(data: try imageData(width: 800, height: 400))
        let pipeline = ArticleImagePipeline { _ in try await gate.load() }
        let request = ArticleImageRequest(url: URL(string: "https://example.com/image.jpg")!, targetSize: CGSize(width: 200, height: 100), displayScale: 1)

        let prefetch = Task { await pipeline.prefetch([request, request]) }
        await gate.waitUntilStarted()
        await gate.release()
        await prefetch.value

        let calls = await gate.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testArticleImagePipelineDownsamplesAndFailsSafely() async throws {
        let data = try imageData(width: 800, height: 400)
        let image = try ArticleImagePipeline.downsample(data: data, maxPixelDimension: 128)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128)

        let rotated = try ArticleImagePipeline.downsample(data: imageData(width: 800, height: 400, orientation: 6), maxPixelDimension: 128)
        XCTAssertGreaterThan(rotated.height, rotated.width)

        let url = URL(string: "https://example.com/image.jpg")!
        let corrupt = ArticleImagePipeline { _ in Data("not an image".utf8) }
        let failing = ArticleImagePipeline { _ in throw URLError(.badServerResponse) }
        let request = ArticleImageRequest(url: url, targetSize: CGSize(width: 100, height: 50), displayScale: 1)
        do {
            _ = try await corrupt.image(for: request)
            XCTFail("Corrupt data must fail")
        } catch {}
        do {
            _ = try await failing.image(for: request)
            XCTFail("Network failure must fail")
        } catch {}
    }

    func testArticleImagePipelineCanLoadAfterCacheEvictionAndCancelledWaiter() async throws {
        let data = try imageData(width: 800, height: 400)
        let counter = ImageLoadCounter(data: data)
        let pipeline = ArticleImagePipeline { _ in await counter.load() }
        let request = ArticleImageRequest(url: URL(string: "https://example.com/image.jpg")!, targetSize: CGSize(width: 100, height: 50), displayScale: 1)
        _ = try await pipeline.image(for: request)
        await pipeline.removeAllCachedImages()
        _ = try await pipeline.image(for: request)
        let reloadCalls = await counter.callCount()
        XCTAssertEqual(reloadCalls, 2)

        let gate = ImageLoadGate(data: data)
        let sharedPipeline = ArticleImagePipeline { _ in try await gate.load() }
        let cancelled = Task { try await sharedPipeline.image(for: request) }
        await gate.waitUntilStarted()
        cancelled.cancel()
        let active = Task { try await sharedPipeline.image(for: request) }
        await Task.yield()
        await gate.release()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled consumer must not receive an image")
        } catch is CancellationError {}
        _ = try await active.value
        let sharedCalls = await gate.callCount()
        XCTAssertEqual(sharedCalls, 1)
    }

    private func imageData(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil), let image = context.makeImage() else {
            throw XCTSkip("Unable to create image fixture")
        }
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Unable to encode image fixture") }
        return data as Data
    }

    func testNavigationGroupsNestFeedsUnderCategoriesAndKeepOrphansVisible() {
        let categories = [NavigationPresentationCategory(id: 1, title: "Tech"), NavigationPresentationCategory(id: 2, title: "World")]
        let feeds = [
            NavigationPresentationFeed(id: 10, categoryID: 1),
            NavigationPresentationFeed(id: 11, categoryID: 1),
            NavigationPresentationFeed(id: 12, categoryID: 99)
        ]

        let groups = NavigationVisibility.groups(categories: categories, feeds: feeds, hidingEmpty: false, counts: [:])

        XCTAssertEqual(groups.map(\.title), ["Tech", "World", "Other Feeds"])
        XCTAssertEqual(groups[0].feeds.map(\.id), [10, 11])
        XCTAssertEqual(groups[0].categoryID, 1)
        XCTAssertEqual(groups[2].feeds.map(\.id), [12])
        XCTAssertNil(groups[2].categoryID)
    }

    func testNavigationGroupsHideEmptyCategoriesAndFeeds() {
        let categories = [NavigationPresentationCategory(id: 1, title: "Tech"), NavigationPresentationCategory(id: 2, title: "World")]
        let feeds = [NavigationPresentationFeed(id: 10, categoryID: 1), NavigationPresentationFeed(id: 11, categoryID: 2)]

        let groups = NavigationVisibility.groups(categories: categories, feeds: feeds, hidingEmpty: true, counts: [10: 0, 11: 2])

        XCTAssertEqual(groups.map(\.title), ["World"])
        XCTAssertEqual(groups[0].feeds.map(\.id), [11])
    }

    func testArticleRoutingUsesValidOriginalURLForUniversalLinkHandoff() {
        let original = URL(string: "https://example.com/article")!
        XCTAssertEqual(
            ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, universalLinkSucceeded: true),
            .universalLink(original)
        )
    }

    func testArticleRoutingFallsBackWhenUniversalLinkIsNotHandled() {
        let original = URL(string: "https://example.com/article")!
        XCTAssertEqual(
            ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, universalLinkSucceeded: false),
            .browser(original)
        )
    }

    func testArticleRoutingAlwaysUsesOriginalURLForBrowserFallback() {
        let original = URL(string: "https://example.com/article")!
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, universalLinkSucceeded: false), .browser(original))
    }

    func testArticleRoutingRejectsInvalidOriginalURL() {
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: "not a URL", universalLinkSucceeded: true), .invalid)
    }

    func testUniversalLinkRoutingDoesNotUseMinifluxEntryURLOrCanOpenURL() {
        let original = URL(string: "https://publisher.example/article")!
        let miniflux = URL(string: "https://miniflux.example/entry/42")!
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, universalLinkSucceeded: false), .browser(original))
        XCTAssertNotEqual(ArticleOpenRoutingPolicy.destination(originalURL: miniflux.absoluteString, universalLinkSucceeded: true), .universalLink(original))
    }

    func testOpenInMinifluxRemainsSeparateFromUniversalLinkRouting() {
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: true), .miniflux)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: false), .original)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openDetailView, openInMiniflux: true), .detail)
    }

    func testArticleContextMenuExposesDistinctNativeActions() {
        let actions: [IOSArticleContextAction] = [
            .starred, .read, .original, .reader, .miniflux, .comments, .copyLink, .share, .saveToService
        ]

        XCTAssertEqual(Set(actions).count, 9)
        XCTAssertEqual(actions[2], .original)
        XCTAssertEqual(actions[3], .reader)
        XCTAssertEqual(actions[4], .miniflux)
        XCTAssertEqual(actions[8], .saveToService)
    }

    func testArticleContextMenuOnlyAcceptsHTTPAndHTTPSURLs() {
        XCTAssertEqual(
            IOSArticleContextMenuPolicy.commentsURL("https://example.com/comments")?.absoluteString,
            "https://example.com/comments"
        )
        XCTAssertEqual(
            IOSArticleContextMenuPolicy.originalURL("http://example.com/article")?.absoluteString,
            "http://example.com/article"
        )
        XCTAssertNil(IOSArticleContextMenuPolicy.commentsURL("mailto:comments@example.com"))
        XCTAssertNil(IOSArticleContextMenuPolicy.originalURL("not a URL"))
        XCTAssertNil(IOSArticleContextMenuPolicy.commentsURL("https:///missing-host"))
    }

    func testCommentsIndicatorUsesTheSameValidatedURLContract() {
        XCTAssertNotNil(IOSArticleContextMenuPolicy.commentsURL("https://example.com/comments"))
        XCTAssertNil(IOSArticleContextMenuPolicy.commentsURL(""))
        XCTAssertNil(IOSArticleContextMenuPolicy.commentsURL("mailto:comments@example.com"))
    }

    func testConfiguredDetailModeSelectsReaderBeforeNormalOpenRouting() {
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openDetailView, openInMiniflux: false), .detail)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: false), .original)
    }

    func testReaderPresentationUsesInspectorOnlyOnRegularWidthIPad() {
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: true, isRegularWidth: true), .inspector)
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: true, isRegularWidth: false), .sheet)
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: false, isRegularWidth: true), .sheet)
    }

    func testReaderPresentationExposesTheExplicitDismissAction() {
        XCTAssertEqual(IOSReaderDismissalPresentation.title, String(localized: "Done"))
    }

    func testReaderRequestStateRejectsStaleResponses() {
        var state = ReaderRequestState()
        let first = state.begin()
        let second = state.begin()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))
    }

    func testNewerArticleReadSupersedesOlderReadAndOwnsPublication() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let first = lifecycle.beginArticle()
        let second = lifecycle.beginArticle()

        XCTAssertFalse(lifecycle.isCurrentArticle(first))
        XCTAssertFalse(lifecycle.isCurrentSelectionCount(first))
        XCTAssertFalse(lifecycle.ownsError(first))
        XCTAssertTrue(lifecycle.isCurrentArticle(second))
        XCTAssertTrue(lifecycle.isCurrentSelectionCount(second))
        XCTAssertTrue(lifecycle.ownsError(second))
    }

    func testStaleArticleFailureCannotReplaceNewerSuccessOrLoadingOwner() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let stale = lifecycle.beginArticle()
        let current = lifecycle.beginArticle()

        XCTAssertFalse(lifecycle.isCurrentArticle(stale))
        XCTAssertFalse(lifecycle.ownsError(stale))
        XCTAssertTrue(lifecycle.isCurrentArticle(current))
        XCTAssertTrue(lifecycle.ownsError(current))
    }

    func testNavigationReadPublishesOnlyForItsCurrentGeneration() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let stale = lifecycle.beginNavigation()
        let current = lifecycle.beginNavigation()

        XCTAssertFalse(lifecycle.isCurrentNavigation(stale))
        XCTAssertFalse(lifecycle.ownsError(stale))
        XCTAssertTrue(lifecycle.isCurrentNavigation(current))
        XCTAssertTrue(lifecycle.ownsError(current))
    }

    func testDetachAndReattachInvalidateAllPriorReadRequests() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let article = lifecycle.beginArticle()
        let navigation = lifecycle.beginNavigation()

        lifecycle.invalidateSession()
        let reattachedArticle = lifecycle.beginArticle()

        XCTAssertFalse(lifecycle.isCurrentArticle(article))
        XCTAssertFalse(lifecycle.isCurrentNavigation(navigation))
        XCTAssertFalse(lifecycle.ownsError(article))
        XCTAssertTrue(lifecycle.isCurrentArticle(reattachedArticle))
    }

    func testPresentationResetInvalidatesCurrentArticleAndSelectionCount() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let request = lifecycle.beginArticle()

        lifecycle.invalidateArticle()

        XCTAssertFalse(lifecycle.isCurrentArticle(request))
        XCTAssertFalse(lifecycle.isCurrentSelectionCount(request))
        XCTAssertFalse(lifecycle.ownsError(request))
    }

    func testNewSelectionCountReadInvalidatesOlderArticleCount() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let article = lifecycle.beginArticle()
        let count = lifecycle.beginSelectionCount()

        XCTAssertFalse(lifecycle.isCurrentSelectionCount(article))
        XCTAssertTrue(lifecycle.isCurrentSelectionCount(count))
    }

    func testArticleDataSyncRefreshesEveryCount() {
        XCTAssertEqual(IOSSyncCountRefreshPolicy.resolve(dataChanged: true, navigationChanged: false), .allCounts)
    }

    func testNavigationSyncReloadsCatalogAndEveryCount() {
        XCTAssertEqual(IOSSyncCountRefreshPolicy.resolve(dataChanged: false, navigationChanged: true), .navigationAndAllCounts)
        XCTAssertEqual(IOSSyncCountRefreshPolicy.resolve(dataChanged: true, navigationChanged: true), .navigationAndAllCounts)
    }

    func testSyncWithoutDataOrNavigationChangesDoesNotRefreshCounts() {
        XCTAssertEqual(IOSSyncCountRefreshPolicy.resolve(dataChanged: false, navigationChanged: false), .none)
    }

    func testCountCompletionAfterSelectionChangeCannotPublishAsCurrent() {
        var lifecycle = IOSNewsreaderReadLifecycle()
        let syncCount = lifecycle.beginSelectionCount()
        _ = lifecycle.beginArticle()

        XCTAssertFalse(lifecycle.isCurrentSelectionCount(syncCount))
    }

    func testReaderDocumentNoticePreservesAllContentStates() {
        XCTAssertNil(ReaderDocumentNotice.text(simplified: false, truncated: false))
        XCTAssertEqual(ReaderDocumentNotice.text(simplified: true, truncated: false), "Some content was simplified")
        XCTAssertEqual(ReaderDocumentNotice.text(simplified: false, truncated: true), "Some content was truncated")
        XCTAssertEqual(ReaderDocumentNotice.text(simplified: true, truncated: true), "Some content was simplified and truncated")
    }

    func testReaderDocumentVariantsAreRepresentedByCoreProjection() {
        let inline: [ReaderInline] = [
            .text(text: "text"),
            .bold(inlines: [.text(text: "bold")]),
            .italic(inlines: [.text(text: "italic")]),
            .code(text: "code"),
            .link(url: "https://example.com", inlines: [.text(text: "link")])
        ]
        let blocks: [ReaderBlock] = [
            .paragraph(inlines: inline),
            .heading(level: 2, inlines: inline),
            .image(url: "https://example.com/image.png", alt: "image", link: nil),
            .list(ordered: false, items: [.init(blocks: [.paragraph(inlines: inline)])]),
            .quote(blocks: [.paragraph(inlines: inline)]),
            .codeBlock(text: "code"),
            .horizontalRule,
            .externalContent(url: "https://example.com", label: "external")
        ]
        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(inline.count, 5)
    }

}

private actor ImageLoadCounter {
    private let data: Data
    private var calls = 0

    init(data: Data) { self.data = data }

    func load() -> Data {
        calls += 1
        return data
    }

    func callCount() -> Int { calls }
}

private actor ImageLoadGate {
    private let data: Data
    private var calls = 0
    private var didStart: CheckedContinuation<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }

    func load() async throws -> Data {
        calls += 1
        didStart?.resume()
        didStart = nil
        await withCheckedContinuation { releaseWaiters.append($0) }
        return data
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { didStart = $0 }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCount() -> Int { calls }
}
