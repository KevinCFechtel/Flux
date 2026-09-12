import XCTest
import ImageIO
import Observation
import UniformTypeIdentifiers
import UIKit
import CoreText
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
    func testSharedFeedIconBridgeDeliversToTimelineAndSearchWithoutStealingUpdates() {
        let sharedIconBridge = IOSUIKitArticleTimelinePresentationBridge()
        let timeline = makeTimelineController(presentationBridge: sharedIconBridge, feedIconBridge: sharedIconBridge)
        let searchArticleBridge = IOSUIKitArticleTimelinePresentationBridge()
        let search = makeTimelineController(presentationBridge: searchArticleBridge, feedIconBridge: sharedIconBridge)

        sharedIconBridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: UIImage(), revision: 1))

        XCTAssertEqual(timeline.feedIconPresentationApplicationCount, 1)
        XCTAssertEqual(search.feedIconPresentationApplicationCount, 1)

        search.detachPresentationBridges()
        sharedIconBridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: UIImage(), revision: 2))

        XCTAssertEqual(timeline.feedIconPresentationApplicationCount, 2)
        XCTAssertEqual(search.feedIconPresentationApplicationCount, 1)
    }

    @MainActor
    func testArticleStatusAndSharedFeedIconChannelsRemainIsolated() {
        let sharedIconBridge = IOSUIKitArticleTimelinePresentationBridge()
        let timeline = makeTimelineController(presentationBridge: sharedIconBridge, feedIconBridge: sharedIconBridge)
        let searchArticleBridge = IOSUIKitArticleTimelinePresentationBridge()
        let search = makeTimelineController(presentationBridge: searchArticleBridge, feedIconBridge: sharedIconBridge)

        sharedIconBridge.publishArticle(.init(articleID: 1, state: .init(isRead: true, isStarred: false, revision: 1), rearmScrollover: false))
        searchArticleBridge.publishArticle(.init(articleID: 1, state: .init(isRead: false, isStarred: true, revision: 1), rearmScrollover: false))

        XCTAssertEqual(timeline.articlePresentationApplicationCount, 1)
        XCTAssertEqual(search.articlePresentationApplicationCount, 1)
        XCTAssertEqual(sharedIconBridge.articleState(for: 1, fallback: timelineArticle(id: 1)).isRead, true)
        XCTAssertEqual(searchArticleBridge.articleState(for: 1, fallback: timelineArticle(id: 1)).isStarred, true)
    }

    @MainActor
    func testRepeatedBridgeUpdatesDoNotDuplicatePresentationDelivery() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)
        let structuralState = timelineStructuralState([timelineArticle(id: 1), timelineArticle(id: 2)], revision: 1)

        for _ in 0..<4 {
            controller.update(
                structuralState: structuralState,
                presentationBridge: bridge,
                feedIconPresentationBridge: bridge,
                mode: .visual,
                previewLines: .standard,
                iconVariant: .normal,
                scrollResetRevision: 0,
                markReadOnScrolloverEnabled: false,
                showsRefreshControl: false
            )
        }
        bridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: UIImage(), revision: 1))

        XCTAssertEqual(controller.feedIconPresentationApplicationCount, 1)
    }

    @MainActor
    func testPreparedCellReconcilesRetainedIconWithoutStructuralOrSizingWork() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let controller = makeTimelineController(bridge: bridge)
        let cell = makeUIKitArticleCell(mode: .visual, width: 390)
        let height = measureUIKitArticleCell(cell, width: 390)
        let solveCount = cell.measurementSolveCount
        let variant = cell.layoutVariantForTesting
        let variantRevision = cell.layoutVariantRevision
        let structuralCount = controller.structuralReconciliationCount
        let snapshotCount = controller.structuralSnapshotApplicationCount

        bridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: testImage(width: 30, height: 30), revision: 1))
        XCTAssertNil(cell.feedIconImageForTesting)

        controller.reconcilePresentationForDisplay(cell)
        cell.layoutIfNeeded()

        XCTAssertNotNil(cell.feedIconImageForTesting)
        XCTAssertEqual(cell.bounds.height, height, accuracy: 0.5)
        XCTAssertEqual(cell.measurementSolveCount, solveCount)
        XCTAssertEqual(cell.layoutVariantForTesting, variant)
        XCTAssertEqual(cell.layoutVariantRevision, variantRevision)
        XCTAssertEqual(controller.structuralReconciliationCount, structuralCount)
        XCTAssertEqual(controller.structuralSnapshotApplicationCount, snapshotCount)
    }

    @MainActor
    func testCachedAndStaleFeedIconBindingsReconcileOnlyTheCurrentFeed() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let articles = [timelineArticle(id: 1, feedID: 10), timelineArticle(id: 2, feedID: 20)]
        let controller = makeTimelineController(articles: articles, presentationBridge: bridge, feedIconBridge: bridge)
        bridge.publishFeedIcon(.init(key: .init(feedID: 10, variant: .normal), image: testImage(width: 30, height: 30), revision: 1))

        let reboundCell = makeUIKitArticleCell(mode: .visual, width: 390, articleID: 2, feedID: 20)
        controller.reconcilePresentationForDisplay(reboundCell)
        XCTAssertNil(reboundCell.feedIconImageForTesting)

        bridge.publishFeedIcon(.init(key: .init(feedID: 20, variant: .normal), image: testImage(width: 30, height: 30), revision: 1))
        controller.reconcilePresentationForDisplay(reboundCell)
        XCTAssertNotNil(reboundCell.feedIconImageForTesting)

        let cachedCell = makeUIKitArticleCell(mode: .visual, width: 390, articleID: 1, feedID: 10)
        controller.reconcilePresentationForDisplay(cachedCell)
        XCTAssertNotNil(cachedCell.feedIconImageForTesting)
    }

    @MainActor
    func testOneFeedIconDeltaUpdatesAllRelevantBoundCellsOnly() {
        let bridge = IOSUIKitArticleTimelinePresentationBridge()
        let articles = [timelineArticle(id: 1, feedID: 10), timelineArticle(id: 2, feedID: 10), timelineArticle(id: 3, feedID: 20)]
        let controller = makeTimelineController(articles: articles, presentationBridge: bridge, feedIconBridge: bridge)
        let first = makeUIKitArticleCell(mode: .visual, width: 390, articleID: 1, feedID: 10)
        let second = makeUIKitArticleCell(mode: .visual, width: 390, articleID: 2, feedID: 10)
        let unrelated = makeUIKitArticleCell(mode: .visual, width: 390, articleID: 3, feedID: 20)

        controller.applyFeedIconPresentation(.init(key: .init(feedID: 10, variant: .normal), image: testImage(width: 30, height: 30), revision: 1), to: [first, second, unrelated])

        XCTAssertNotNil(first.feedIconImageForTesting)
        XCTAssertNotNil(second.feedIconImageForTesting)
        XCTAssertNil(unrelated.feedIconImageForTesting)
    }

    @MainActor
    func testFeedIconTransientFailureRetriesAfterCooldownAndSuccessfulNilDoesNotRetry() async throws {
        let retryLoader = FeedIconLoader(results: [.failure(URLError(.notConnectedToInternet)), .success(try imageData(width: 40, height: 40))])
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setFeedIconLoaderForTesting { _, _ in try retryLoader.load() }
        let retryState = store.feedIconPresentationState(for: 10, variant: .normal)

        store.requestFeedIcon(10, variant: .normal, now: 0)
        await waitForFeedIconState(retryState, matching: .retryableFailure(retryAfter: 30))
        XCTAssertEqual(retryLoader.callCount, 1)

        store.requestFeedIcon(10, variant: .normal, now: 1)
        await Task.yield()
        XCTAssertEqual(retryLoader.callCount, 1)

        store.requestFeedIcon(10, variant: .normal, now: 30)
        await waitForFeedIconState(retryState, matching: .available)
        XCTAssertNotNil(retryState.image)
        XCTAssertEqual(retryLoader.callCount, 2)

        let unavailableLoader = FeedIconLoader(results: [.success(nil)])
        let unavailableStore = NewsreaderStore(defaults: UserDefaults())
        unavailableStore.setFeedIconLoaderForTesting { _, _ in try unavailableLoader.load() }
        let unavailableState = unavailableStore.feedIconPresentationState(for: 20, variant: .normal)
        unavailableStore.requestFeedIcon(20, variant: .normal, now: 0)
        await waitForFeedIconState(unavailableState, matching: .unavailable)
        unavailableStore.requestFeedIcon(20, variant: .normal, now: 1_000)
        await Task.yield()

        XCTAssertEqual(unavailableLoader.callCount, 1)
        XCTAssertEqual(unavailableState.loadState, .unavailable)

        let decodeFailureLoader = FeedIconLoader(results: [.success(Data("not an image".utf8))])
        let decodeFailureStore = NewsreaderStore(defaults: UserDefaults())
        decodeFailureStore.setFeedIconLoaderForTesting { _, _ in try decodeFailureLoader.load() }
        let decodeFailureState = decodeFailureStore.feedIconPresentationState(for: 30, variant: .normal)
        decodeFailureStore.requestFeedIcon(30, variant: .normal, now: 0)
        await waitForFeedIconState(decodeFailureState, matching: .retryableFailure(retryAfter: 30))
        XCTAssertEqual(decodeFailureLoader.callCount, 1)
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
        makeTimelineController(presentationBridge: bridge, feedIconBridge: bridge)
    }

    @MainActor
    private func makeTimelineController(
        articles: [ArticleSummary]? = nil,
        presentationBridge: IOSUIKitArticleTimelinePresentationBridge,
        feedIconBridge: IOSUIKitArticleTimelinePresentationBridge
    ) -> IOSUIKitArticleTimelineController {
        let articles = articles ?? [timelineArticle(id: 1), timelineArticle(id: 2)]
        let controller = IOSUIKitArticleTimelineController()
        presentationBridge.replaceArticleStates(Dictionary(uniqueKeysWithValues: articles.map { ($0.id, .init(isRead: $0.isRead, isStarred: $0.isStarred, revision: 0)) }))
        controller.update(
            structuralState: timelineStructuralState(articles, revision: 1),
            presentationBridge: presentationBridge,
            feedIconPresentationBridge: feedIconBridge,
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

    private func timelineArticle(id: Int64, feedID: Int64 = 10) -> ArticleSummary {
        .init(id: id, feedId: feedID, categoryId: 20, feedTitle: "Feed \(feedID)", title: "Article \(id)", url: "https://example.com/\(id)", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "Preview", imageUrl: nil)
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

    @MainActor
    func testUIKitPortraitArticleImagePixelsDoNotChangeMeasuredGeometry() {
        let cell = makeUIKitArticleCell(mode: .visual, width: 390)
        let baseline = measureUIKitArticleCell(cell, width: 390)
        let baselineSlot = cell.articleImageSlotFrameForTesting
        let baselineVariant = cell.layoutVariantForTesting
        let baselineVariantRevision = cell.layoutVariantRevision

        for image in [testImage(width: 400, height: 400), testImage(width: 200, height: 800), testImage(width: 1200, height: 200)] {
            cell.applyArticleImagePixelsForTesting(image)
            let height = measureUIKitArticleCell(cell, width: 390)

            XCTAssertEqual(height, baseline, accuracy: 0.5)
            XCTAssertEqual(cell.articleImageSlotFrameForTesting.width, baselineSlot.width, accuracy: 0.5)
            XCTAssertEqual(cell.articleImageSlotFrameForTesting.height, baselineSlot.height, accuracy: 0.5)
            XCTAssertEqual(cell.layoutVariantForTesting, baselineVariant)
            XCTAssertEqual(cell.layoutVariantRevision, baselineVariantRevision)
        }
    }

    @MainActor
    func testUIKitArticleImageArrivalBeforeAndAfterMeasurementHasIdenticalGeometry() {
        let before = makeUIKitArticleCell(mode: .visual, width: 390)
        before.applyArticleImagePixelsForTesting(testImage(width: 200, height: 800))
        let beforeHeight = measureUIKitArticleCell(before, width: 390)
        let beforeSlot = before.articleImageSlotFrameForTesting
        let beforeVariantRevision = before.layoutVariantRevision

        let after = makeUIKitArticleCell(mode: .visual, width: 390)
        let afterHeight = measureUIKitArticleCell(after, width: 390)
        after.applyArticleImagePixelsForTesting(testImage(width: 1200, height: 200))
        let afterImageHeight = measureUIKitArticleCell(after, width: 390)

        XCTAssertEqual(beforeHeight, afterHeight, accuracy: 0.5)
        XCTAssertEqual(beforeHeight, afterImageHeight, accuracy: 0.5)
        XCTAssertEqual(before.articleImageSlotFrameForTesting.width, beforeSlot.width, accuracy: 0.5)
        XCTAssertEqual(after.articleImageSlotFrameForTesting.width, beforeSlot.width, accuracy: 0.5)
        XCTAssertEqual(after.articleImageSlotFrameForTesting.height, beforeSlot.height, accuracy: 0.5)
        XCTAssertEqual(before.layoutVariantForTesting, .visualPortrait)
        XCTAssertEqual(after.layoutVariantForTesting, .visualPortrait)
        XCTAssertEqual(before.layoutVariantRevision, beforeVariantRevision)
    }

    @MainActor
    func testUIKitLandscapeArticleImageAndPresentationUpdatesDoNotChangeGeometry() {
        let cell = makeUIKitArticleCell(mode: .visual, width: 760)
        let baseline = measureUIKitArticleCell(cell, width: 760)
        let baselineSlot = cell.articleImageSlotFrameForTesting
        let baselineVariantRevision = cell.layoutVariantRevision

        cell.applyArticleImagePixelsForTesting(testImage(width: 200, height: 800))
        XCTAssertEqual(measureUIKitArticleCell(cell, width: 760), baseline, accuracy: 0.5)
        XCTAssertEqual(cell.articleImageSlotFrameForTesting.width, baselineSlot.width, accuracy: 0.5)
        XCTAssertEqual(cell.articleImageSlotFrameForTesting.height, baselineSlot.height, accuracy: 0.5)

        cell.applyArticleImagePixelsForTesting(testImage(width: 1200, height: 200))
        cell.updateStatus(isRead: true, isStarred: true)
        cell.updateFeedIcon(image: testImage(width: 80, height: 20), title: "Feed")
        XCTAssertEqual(measureUIKitArticleCell(cell, width: 760), baseline, accuracy: 0.5)
        XCTAssertEqual(cell.articleImageSlotFrameForTesting.width, baselineSlot.width, accuracy: 0.5)
        XCTAssertEqual(cell.articleImageSlotFrameForTesting.height, baselineSlot.height, accuracy: 0.5)
        XCTAssertEqual(cell.layoutVariantForTesting, .visualLandscape)
        XCTAssertEqual(cell.layoutVariantRevision, baselineVariantRevision)

        cell.updateStatus(isRead: false, isStarred: false)
        cell.updateFeedIcon(image: nil, title: "Feed")
        cell.applyArticleImagePixelsForTesting(nil)
        XCTAssertEqual(measureUIKitArticleCell(cell, width: 760), baseline, accuracy: 0.5)
        XCTAssertEqual(cell.layoutVariantForTesting, .visualLandscape)
        XCTAssertEqual(cell.layoutVariantRevision, baselineVariantRevision)
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

    func testArticleImagePipelineBoundsWorkAndPrioritizesVisibleRequests() async throws {
        let gate = PrioritizedImageLoadGate(data: try imageData(width: 800, height: 400))
        let pipeline = ArticleImagePipeline { url in try await gate.load(url: url) }
        let requests = (0...4).map {
            ArticleImageRequest(
                url: URL(string: "https://example.com/\($0).jpg")!,
                targetSize: CGSize(width: 200, height: 100),
                displayScale: 1
            )
        }

        let activePrefetches = requests.prefix(3).map { request in
            Task { try await pipeline.prefetch(request) }
        }
        await gate.waitUntilStarted(count: 3)
        let queuedPrefetch = Task { try await pipeline.prefetch(requests[3]) }
        let visible = Task { try await pipeline.image(for: requests[4]) }
        for _ in 0..<8 { await Task.yield() }

        let saturated = await pipeline.metrics()
        XCTAssertEqual(saturated.activeOperations, ArticleImagePipeline.maximumConcurrentOperations)
        XCTAssertEqual(saturated.queuedVisibleRequests, 1)
        XCTAssertEqual(saturated.queuedPrefetchRequests, 1)
        XCTAssertEqual(saturated.trackedRequests, 5)

        await gate.releaseOne()
        await gate.waitUntilStarted(count: 4)
        let startedURLs = await gate.startedURLs()
        XCTAssertEqual(startedURLs.last, requests[4].url)

        await gate.releaseAll()
        await gate.waitUntilStarted(count: 5)
        await gate.releaseAll()
        for task in activePrefetches { _ = try await task.value }
        _ = try await queuedPrefetch.value
        _ = try await visible.value
        let completed = await pipeline.metrics()
        XCTAssertEqual(completed.trackedRequests, 0)
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
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled consumer must not receive an image")
        } catch is CancellationError {}
        let active = Task { try await sharedPipeline.image(for: request) }
        await gate.release()
        await gate.waitUntilStarted(count: 2)
        await gate.release()
        _ = try await active.value
        let sharedCalls = await gate.callCount()
        XCTAssertEqual(sharedCalls, 2)
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

    @MainActor
    func testTimelinePerformanceMetricsKeepArticleSizingOutOfAutoLayout() {
        let cell = makeUIKitArticleCell(mode: .visual, width: 390)
        let metrics = IOSUIKitTimelinePerformanceMetrics()
        cell.performanceMetrics = metrics

        let firstHeight = measureUIKitArticleCell(cell, width: 390)
        let first = metrics.snapshot()
        XCTAssertEqual(first.preferredLayoutAttributesFittingCalls, 1)
        XCTAssertEqual(firstHeight, cell.preparedLayoutMetrics?.cellSize.height)
        XCTAssertEqual(first.systemLayoutSizeFittingCalls, 0)
        XCTAssertEqual(cell.measurementSolveCount, 0)

        _ = measureUIKitArticleCell(cell, width: 390)
        let second = metrics.snapshot()
        XCTAssertEqual(second.preferredLayoutAttributesFittingCalls, 2)
        XCTAssertEqual(second.systemLayoutSizeFittingCalls, 0)
        metrics.reset()
        XCTAssertEqual(metrics.snapshot().systemLayoutSizeFittingCalls, 0)
    }

    func testDeterministicArticleLayoutEngineSelectsCurrentPresentationVariants() {
        XCTAssertEqual(layoutMetrics(mode: .compact, width: 390, hasImage: true).variant, .compact)
        XCTAssertEqual(layoutMetrics(mode: .visual, width: 390, hasImage: false).variant, .visualTextOnly)
        XCTAssertEqual(layoutMetrics(mode: .visual, width: 390, hasImage: true).variant, .visualPortrait)
        XCTAssertEqual(layoutMetrics(mode: .visual, width: 760, hasImage: true).variant, .visualLandscape)
    }

    func testDeterministicArticleLayoutEngineUsesCurrentWidthTransitionsAndPixelRounding() {
        let narrow = layoutMetrics(mode: .visual, width: 401, hasImage: false, scale: 3)
        let wide = layoutMetrics(mode: .visual, width: 402, hasImage: false, scale: 3)
        XCTAssertEqual(narrow.metadataHeight, wide.metadataHeight)
        XCTAssertEqual((narrow.cellSize.height * 3).rounded(), narrow.cellSize.height * 3, accuracy: 0.001)
        XCTAssertEqual(layoutMetrics(mode: .visual, width: 700, hasImage: true).horizontalInset, 16)
        XCTAssertEqual(layoutMetrics(mode: .visual, width: 701, hasImage: true).horizontalInset, 28)
    }

    func testDeterministicArticleLayoutEngineKeyCanonicalizesGeometryIdentity() {
        let input = layoutInput(mode: .visual, width: 390, hasImage: true)
        let key = IOSUIKitArticleLayoutKey(input)
        XCTAssertEqual(key, IOSUIKitArticleLayoutKey(layoutInput(mode: .visual, width: 390.1, hasImage: true)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(layoutInput(mode: .visual, width: 391, hasImage: true)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(layoutInput(mode: .compact, width: 390, hasImage: true)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: .extraLarge, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: .rightToLeft)))
        XCTAssertEqual(key, IOSUIKitArticleLayoutKey(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: "ar_SA", layoutDirection: input.layoutDirection)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(.init(title: "Updated title", feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: false, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection)))
        XCTAssertNotEqual(key, IOSUIKitArticleLayoutKey(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: .compact, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection)))
    }

    @MainActor
    func testPreparedLayoutMetricsReuseCanonicalIdentityAndRekeyLayoutChanges() {
        let cache = IOSUIKitPreparedArticleLayoutMetricsCache(capacity: 4)
        let input = layoutInput(mode: .visual, width: 390, hasImage: true)
        let metrics = IOSUIKitArticleLayoutEngine.metrics(for: input)
        cache.insert(metrics, for: .init(input))
        let mutablePresentationEquivalent = IOSUIKitArticleLayoutInput(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection)
        XCTAssertEqual(cache.metrics(for: .init(mutablePresentationEquivalent)), metrics)
        XCTAssertNil(cache.metrics(for: .init(layoutInput(mode: .visual, width: 391, hasImage: true))))
        XCTAssertNil(cache.metrics(for: .init(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: .accessibilityExtraExtraExtraLarge, localeIdentifier: input.localeIdentifier, layoutDirection: input.layoutDirection))))
        XCTAssertNil(cache.metrics(for: .init(.init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: .rightToLeft))))
        XCTAssertNil(cache.metrics(for: .init(layoutInput(mode: .compact, width: 390, hasImage: true))))
    }

    @MainActor
    func testPreparedLayoutMetricsCacheHasDeterministicBound() {
        let cache = IOSUIKitPreparedArticleLayoutMetricsCache(capacity: 2)
        let first = layoutInput(mode: .visual, width: 390, hasImage: false)
        let second = IOSUIKitArticleLayoutInput(title: "Second", feedTitle: first.feedTitle, publishedDate: first.publishedDate, preview: first.preview, hasImage: first.hasImage, hasComments: first.hasComments, mode: first.mode, previewLines: first.previewLines, containerWidth: first.containerWidth, displayScale: first.displayScale, contentSizeCategory: first.contentSizeCategory, localeIdentifier: first.localeIdentifier, layoutDirection: first.layoutDirection)
        let third = IOSUIKitArticleLayoutInput(title: "Third", feedTitle: first.feedTitle, publishedDate: first.publishedDate, preview: first.preview, hasImage: first.hasImage, hasComments: first.hasComments, mode: first.mode, previewLines: first.previewLines, containerWidth: first.containerWidth, displayScale: first.displayScale, contentSizeCategory: first.contentSizeCategory, localeIdentifier: first.localeIdentifier, layoutDirection: first.layoutDirection)
        for input in [first, second, third] { cache.insert(IOSUIKitArticleLayoutEngine.metrics(for: input), for: .init(input)) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.metrics(for: .init(first)))
        XCTAssertNotNil(cache.metrics(for: .init(second)))
        XCTAssertNotNil(cache.metrics(for: .init(third)))
    }

    @MainActor
    func testPreparedLayoutWindowIsBoundedAndCoalescesIdenticalKeys() async {
        let coordinator = IOSUIKitArticleLayoutPreparationCoordinator(maximumConcurrency: 2)
        let input = layoutInput(mode: .visual, width: 390, hasImage: true)
        coordinator.replaceWindow(with: Array(repeating: input, count: 100), visibleCount: 1)
        for _ in 0..<20 where coordinator.snapshot().measurementsCompleted == 0 { await Task.yield() }
        let snapshot = coordinator.snapshot()
        XCTAssertEqual(snapshot.requests, UInt64(IOSUIKitArticleLayoutPreparationCoordinator.nearbyWindowLimit + 1))
        XCTAssertEqual(snapshot.measurementsStarted, 1)
        XCTAssertLessThanOrEqual(snapshot.maximumConcurrentMeasurements, 2)
        XCTAssertEqual(snapshot.measurementsCompleted, 1)
    }

    @MainActor
    func testPreparedLayoutPrioritizesVisibleAndDiscardsReplacedGeneration() async {
        let gate = LayoutMeasurementGate()
        let coordinator = IOSUIKitArticleLayoutPreparationCoordinator(maximumConcurrency: 1) { input in
            await gate.measure(input)
        }
        let far = IOSUIKitArticleLayoutInput(title: "far", feedTitle: "Feed", publishedDate: "Today", preview: "Preview", hasImage: false, hasComments: false, mode: .visual, previewLines: .standard, containerWidth: 390, displayScale: 2, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .leftToRight)
        let visible = IOSUIKitArticleLayoutInput(title: "visible", feedTitle: far.feedTitle, publishedDate: far.publishedDate, preview: far.preview, hasImage: far.hasImage, hasComments: far.hasComments, mode: far.mode, previewLines: far.previewLines, containerWidth: far.containerWidth, displayScale: far.displayScale, contentSizeCategory: far.contentSizeCategory, localeIdentifier: far.localeIdentifier, layoutDirection: far.layoutDirection)
        let replacement = IOSUIKitArticleLayoutInput(title: "replacement", feedTitle: far.feedTitle, publishedDate: far.publishedDate, preview: far.preview, hasImage: far.hasImage, hasComments: far.hasComments, mode: far.mode, previewLines: far.previewLines, containerWidth: far.containerWidth, displayScale: far.displayScale, contentSizeCategory: far.contentSizeCategory, localeIdentifier: far.localeIdentifier, layoutDirection: far.layoutDirection)
        coordinator.prepare([far], priority: .prefetch)
        await gate.waitUntilStarted(count: 1)
        coordinator.prepare([visible], priority: .visible)
        await gate.releaseAll()
        await gate.waitUntilStarted(count: 2)
        let startedAfterPriority = await gate.startedTitles()
        XCTAssertEqual(startedAfterPriority, ["far", "visible"])
        coordinator.replaceWindow(with: [replacement], visibleCount: 1)
        await gate.waitUntilStarted(count: 3)
        let startedAfterReplacement = await gate.startedTitles()
        XCTAssertEqual(startedAfterReplacement, ["far", "visible", "replacement"])
        await gate.releaseAll()
        for _ in 0..<100 where coordinator.snapshot().discardedResults == 0 { await Task.yield() }
        for _ in 0..<100 where coordinator.snapshot().measurementsCompleted == 0 { await Task.yield() }
        let snapshot = coordinator.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.cancellations, 1)
        XCTAssertGreaterThanOrEqual(snapshot.discardedResults, 1)
    }

    @MainActor
    func testCoreTextUIKitMetricDiagnostics() {
        let fixtures = [
            ("title-one", "Short title", UIFont.preferredFont(forTextStyle: .headline), 358 as CGFloat, 0),
            ("title-multi", "A deliberately multiline article title for Core Text diagnostics that wraps across the current iPhone width.", UIFont.preferredFont(forTextStyle: .headline), 358 as CGFloat, 0),
            ("preview-three", String(repeating: "A preview line measures UIKit and Core Text semantics. ", count: 8), UIFont.preferredFont(forTextStyle: .subheadline), 358 as CGFloat, 3),
        ]
        for fixture in fixtures {
            let font = fixture.2
            let ctFont = font as CTFont
            let label = UILabel()
            label.font = font
            label.numberOfLines = fixture.4
            label.lineBreakMode = .byWordWrapping
            label.text = fixture.1
            let fitted = label.sizeThatFits(.init(width: fixture.3, height: .greatestFiniteMagnitude))
            let intrinsic = label.intrinsicContentSize
            let text = NSAttributedString(string: fixture.1, attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont])
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            var index = 0
            var lines: [String] = []
            while index < text.length, fixture.4 == 0 || lines.count < fixture.4 {
                let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(fixture.3))
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: count))
                var ascent: CGFloat = 0; var descent: CGFloat = 0; var leading: CGFloat = 0
                let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                lines.append(String(format: "line=%d range=%d,%d width=%.6f ascent=%.6f descent=%.6f leading=%.6f", lines.count, index, count, width, ascent, descent, leading))
                index += count
            }
            let frameSize = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: index), nil, .init(width: fixture.3, height: .greatestFiniteMagnitude), nil)
            print(String(format: "[Text metrics] %@ font=%@ size=%.6f asc=%.6f desc=%.6f lead=%.6f line=%.6f cap=%.6f x=%.6f ctPostScript=%@ ctSize=%.6f ctAsc=%.6f ctDesc=%.6f ctLead=%.6f labelFit=(%.6f,%.6f) intrinsic=(%.6f,%.6f) frame=(%.6f,%.6f) lines=%@", fixture.0, font.fontName, font.pointSize, font.ascender, font.descender, font.leading, font.lineHeight, font.capHeight, font.xHeight, CTFontCopyPostScriptName(ctFont) as String, CTFontGetSize(ctFont), CTFontGetAscent(ctFont), CTFontGetDescent(ctFont), CTFontGetLeading(ctFont), fitted.width, fitted.height, intrinsic.width, intrinsic.height, frameSize.width, frameSize.height, lines.joined(separator: " | ")))
        }
    }

    @MainActor
    func testCoreTextUIKitCompatibleHeightMatrix() {
        let categories: [UIContentSizeCategory] = [.large, .extraExtraLarge, .accessibilityExtraExtraExtraLarge]
        let fixtures: [(String, String, UIFont.TextStyle, Int, CGFloat)] = [
            ("title-one", "Short title", .headline, 0, 358),
            ("title-multi", String(repeating: "A title that wraps using production UIKit font metrics. ", count: 4), .headline, 0, 358),
            ("preview-two", String(repeating: "A preview line wraps with bounded Core Text counting. ", count: 8), .subheadline, 2, 358),
            ("preview-three", String(repeating: "A preview line wraps with bounded Core Text counting. ", count: 8), .subheadline, 3, 358),
            ("preview-five", String(repeating: "A preview line wraps with bounded Core Text counting. ", count: 12), .subheadline, 5, 358),
        ]
        for category in categories {
            let trait = UITraitCollection(preferredContentSizeCategory: category)
            for fixture in fixtures {
                let font = UIFont.preferredFont(forTextStyle: fixture.2, compatibleWith: trait)
                let text = NSAttributedString(string: fixture.1, attributes: [kCTFontAttributeName as NSAttributedString.Key: font as CTFont])
                let typesetter = CTTypesetterCreateWithAttributedString(text)
                var index = 0
                var lineCount = 0
                while index < text.length, fixture.3 == 0 || lineCount < fixture.3 {
                    let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(fixture.4))
                    guard count > 0 else { break }
                    index += count
                    lineCount += 1
                }
                for scale in [2 as CGFloat, 3] {
                    let scaleTrait = UITraitCollection(traitsFrom: [trait, UITraitCollection(displayScale: scale)])
                    var fitted = CGSize.zero
                    scaleTrait.performAsCurrent {
                        let label = UILabel()
                        label.font = font
                        label.numberOfLines = fixture.3
                        label.lineBreakMode = .byWordWrapping
                        label.text = fixture.1
                        fitted = label.sizeThatFits(.init(width: fixture.4, height: .greatestFiniteMagnitude))
                    }
                    let raw = CGFloat(lineCount) * font.lineHeight + CGFloat(max(0, lineCount - 1)) * font.leading
                    let predicted = ceil(raw * scale) / scale
                    let actualScale = 3 as CGFloat // UILabel sizing follows the simulator display, not a synthetic trait scale.
                    let actualPrediction = ceil(raw * actualScale) / actualScale
                    XCTAssertEqual(fitted.height, actualPrediction, accuracy: 0.001, "\(category.rawValue) \(fixture.0) @\(actualScale)x")
                    print(String(format: "[Text matrix] category=%@ fixture=%@ requestedScale=%.0f point=%.6f line=%.6f leading=%.6f lines=%d raw=%.6f predicted=%.6f actualLabelScale=%.0f actual=%.6f delta=%.6f", category.rawValue, fixture.0, scale, font.pointSize, font.lineHeight, font.leading, lineCount, raw, predicted, actualScale, fitted.height, fitted.height - actualPrediction))
                }
            }
        }
    }

    @MainActor
    func testArticleLayoutKeyExcludesMutablePresentationState() {
        let item = oracleItem(title: "Title", preview: "Preview", hasImage: true, hasComments: true)
        let updated = IOSUIKitArticleTimelineItem(article: item.article, content: item.content, isRead: true, isStarred: true, feedIconImage: testImage(width: 80, height: 20))
        let input = IOSUIKitArticleLayoutInput(item: item, mode: .visual, previewLines: .standard, containerWidth: 390, displayScale: 2, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .leftToRight)
        let updatedInput = IOSUIKitArticleLayoutInput(item: updated, mode: .visual, previewLines: .standard, containerWidth: 390, displayScale: 2, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .leftToRight)
        XCTAssertEqual(IOSUIKitArticleLayoutKey(input), IOSUIKitArticleLayoutKey(updatedInput))
    }

    @MainActor
    func testDeterministicArticleLayoutEngineMatchesUIKitCellOracle() {
        let titles = [
            "Short title",
            "A deliberately multiline article title that exercises the exact bounded text measurement used by the production UIKit cell.",
            "Emoji headline \u{1F680} with Arabic \u{0645}\u{0631}\u{062D}\u{0628}\u{0627} and Japanese \u{65E5}\u{672C}\u{8A9E}",
        ]
        let previews = ["", "Short preview", String(repeating: "A longer preview exercises bounded UIKit text wrapping. ", count: 8)]
        let cases: [(ArticlePresentationMode, CGFloat, Bool, ArticlePreviewLines)] = [
            (.compact, 320, false, .standard),
            (.compact, 390, true, .compact),
            (.visual, 390, false, .standard),
            (.visual, 430, false, .standard),
            (.visual, 390, true, .extended),
            (.visual, 760, true, .standard),
            (.visual, 401, false, .standard),
            (.visual, 402, false, .standard),
            (.visual, 700, true, .standard),
            (.visual, 701, true, .standard),
        ]
        for (index, testCase) in cases.enumerated() {
            let item = oracleItem(title: titles[index % titles.count], preview: previews[index % previews.count], hasImage: testCase.2, hasComments: index.isMultiple(of: 2))
            let cell = configuredOracleCell(item: item, mode: testCase.0, previewLines: testCase.3, width: testCase.1)
            let actual = measureUIKitArticleCell(cell, width: testCase.1)
            let input = IOSUIKitArticleLayoutInput(item: item, mode: testCase.0, previewLines: testCase.3, containerWidth: testCase.1, displayScale: cell.traitCollection.displayScale, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .leftToRight)
            let expected = IOSUIKitArticleLayoutEngine.metrics(for: input)
            let diagnostics = cell.layoutDiagnosticsForTesting
            XCTAssertEqual(actual, expected.cellSize.height, accuracy: 0.5, "case \(index) variant \(expected.variant) cell=\(diagnostics) engine title=\(expected.titleFrame) metadata=\(expected.metadataFrame) preview=\(String(describing: expected.previewFrame)) image=\(String(describing: expected.imageFrame))")
            assertFrameEqual(diagnostics.titleFrame, expected.titleFrame)
            assertFrameEqual(diagnostics.metadataFrame, expected.metadataFrame)
            assertFrameEqual(diagnostics.unreadFrame, expected.unreadFrame)
            assertFrameEqual(diagnostics.feedIconFrame, expected.feedIconFrame)
            assertFrameEqual(diagnostics.feedTitleFrame, expected.feedTitleFrame)
            assertOptionalFrameEqual(diagnostics.commentsFrame, expected.commentsFrame)
            assertFrameEqual(diagnostics.starFrame, expected.starFrame)
            assertFrameEqual(diagnostics.dateFrame, expected.dateFrame)
            assertOptionalFrameEqual(diagnostics.previewFrame, expected.previewFrame)
        }
    }

    @MainActor
    func testDeterministicArticleLayoutEngineMatchesUIKitCellOracleInRightToLeft() {
        let cases: [(ArticlePresentationMode, CGFloat, Bool, Bool, String)] = [
            (.visual, 390, false, false, "Oracle Feed"),
            (.visual, 390, true, true, "Oracle Feed"),
            (.visual, 390, false, false, String(repeating: "An exceptionally long feed title ", count: 12)),
            (.compact, 320, false, true, "Oracle Feed"),
            (.visual, 760, true, true, "Oracle Feed"),
        ]
        for (index, testCase) in cases.enumerated() {
            let item = oracleItem(title: "A deliberately multiline article title for RTL component geometry.", preview: "A preview long enough to exercise the complete text stack.", hasImage: testCase.2, hasComments: testCase.3, feedTitle: testCase.4)
            let cell = configuredOracleCell(item: item, mode: testCase.0, previewLines: .standard, width: testCase.1, layoutDirection: .rightToLeft)
            let actual = measureUIKitArticleCell(cell, width: testCase.1)
            let input = IOSUIKitArticleLayoutInput(item: item, mode: testCase.0, previewLines: .standard, containerWidth: testCase.1, displayScale: cell.traitCollection.displayScale, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .rightToLeft)
            let expected = IOSUIKitArticleLayoutEngine.metrics(for: input)
            let ltr = IOSUIKitArticleLayoutEngine.metrics(for: .init(title: input.title, feedTitle: input.feedTitle, publishedDate: input.publishedDate, preview: input.preview, hasImage: input.hasImage, hasComments: input.hasComments, mode: input.mode, previewLines: input.previewLines, containerWidth: input.containerWidth, displayScale: input.displayScale, contentSizeCategory: input.contentSizeCategory, localeIdentifier: input.localeIdentifier, layoutDirection: .leftToRight))
            let diagnostics = cell.layoutDiagnosticsForTesting
            XCTAssertEqual(actual, expected.cellSize.height, accuracy: 0.5, "RTL case \(index) cell=\(diagnostics)")
            XCTAssertEqual(expected.cellSize.height, ltr.cellSize.height, accuracy: 0.001)
            assertFrameEqual(diagnostics.titleFrame, expected.titleFrame)
            assertFrameEqual(diagnostics.metadataFrame, expected.metadataFrame)
            assertFrameEqual(diagnostics.unreadFrame, expected.unreadFrame)
            assertFrameEqual(diagnostics.feedIconFrame, expected.feedIconFrame)
            assertFrameEqual(diagnostics.feedTitleFrame, expected.feedTitleFrame)
            assertOptionalFrameEqual(diagnostics.commentsFrame, expected.commentsFrame)
            assertFrameEqual(diagnostics.starFrame, expected.starFrame)
            assertFrameEqual(diagnostics.dateFrame, expected.dateFrame)
            assertOptionalFrameEqual(diagnostics.previewFrame, expected.previewFrame)
        }
    }

    @MainActor
    func testUIKitMetadataMutablePresentationUpdatesAreGeometryNeutral() {
        let cell = makeUIKitArticleCell(mode: .visual, width: 390)
        let baselineHeight = measureUIKitArticleCell(cell, width: 390)
        let baseline = cell.layoutDiagnosticsForTesting

        cell.updateStatus(isRead: true, isStarred: true)
        cell.updateFeedIcon(image: testImage(width: 80, height: 20), title: "Feed")
        XCTAssertEqual(measureUIKitArticleCell(cell, width: 390), baselineHeight, accuracy: 0.5)
        let updated = cell.layoutDiagnosticsForTesting
        assertFrameEqual(updated.titleFrame, baseline.titleFrame)
        assertFrameEqual(updated.metadataFrame, baseline.metadataFrame)
        assertFrameEqual(updated.unreadFrame, baseline.unreadFrame)
        assertFrameEqual(updated.feedIconFrame, baseline.feedIconFrame)
        assertFrameEqual(updated.feedTitleFrame, baseline.feedTitleFrame)
        assertFrameEqual(updated.starFrame, baseline.starFrame)
        assertFrameEqual(updated.dateFrame, baseline.dateFrame)
    }

    @MainActor
    func testUIKitMetadataMutablePresentationUpdatesAreGeometryNeutralInRightToLeft() {
        let cell = makeUIKitArticleCell(mode: .visual, width: 390, layoutDirection: .rightToLeft)
        let baselineHeight = measureUIKitArticleCell(cell, width: 390)
        let baseline = cell.layoutDiagnosticsForTesting

        cell.updateStatus(isRead: true, isStarred: true)
        cell.updateFeedIcon(image: testImage(width: 80, height: 20), title: "Feed")
        XCTAssertEqual(measureUIKitArticleCell(cell, width: 390), baselineHeight, accuracy: 0.5)
        let updated = cell.layoutDiagnosticsForTesting
        assertFrameEqual(updated.unreadFrame, baseline.unreadFrame)
        assertFrameEqual(updated.feedIconFrame, baseline.feedIconFrame)
        assertFrameEqual(updated.feedTitleFrame, baseline.feedTitleFrame)
        assertFrameEqual(updated.starFrame, baseline.starFrame)
    }

    @MainActor
    func testUIKitMetadataCommentsUseFixedAccessorySlotAndLongFeedTitleTruncates() {
        let title = String(repeating: "An exceptionally long feed title ", count: 12)
        let withoutComments = oracleItem(title: "Title", preview: "", hasImage: false, hasComments: false, feedTitle: title)
        let withComments = oracleItem(title: "Title", preview: "", hasImage: false, hasComments: true, feedTitle: title)
        let withoutCell = configuredOracleCell(item: withoutComments, mode: .visual, previewLines: .standard, width: 390)
        let withCell = configuredOracleCell(item: withComments, mode: .visual, previewLines: .standard, width: 390)
        let withoutHeight = measureUIKitArticleCell(withoutCell, width: 390)
        let withHeight = measureUIKitArticleCell(withCell, width: 390)
        let without = withoutCell.layoutDiagnosticsForTesting
        let with = withCell.layoutDiagnosticsForTesting

        XCTAssertEqual(withoutHeight, withHeight, accuracy: 0.5)
        XCTAssertEqual(with.metadataFrame.height, without.metadataFrame.height, accuracy: 0.5)
        assertFrameEqual(with.starFrame, without.starFrame)
        XCTAssertNotNil(with.commentsFrame)
        XCTAssertNil(without.commentsFrame)
        XCTAssertEqual(with.commentsFrame!.width, IOSUIKitArticleGeometry.commentSlotSize, accuracy: 0.5)
        XCTAssertEqual(without.feedTitleFrame.width - with.feedTitleFrame.width, IOSUIKitArticleGeometry.commentSlotSize + IOSUIKitArticleGeometry.metadataAccessorySpacing, accuracy: 0.5)
        XCTAssertEqual(without.feedTitleFrame.height, without.metadataFrame.height, accuracy: 0.5)
        XCTAssertEqual(withoutCell.feedTitlePresentationForTesting.lineCount, 1)
        XCTAssertEqual(withoutCell.feedTitlePresentationForTesting.lineBreakMode, .byTruncatingTail)
    }

    @MainActor
    func testUIKitPortraitAspectFrameResolutionDiagnostics() {
        // These widths deliberately span distinct 16:9 physical-pixel residues.
        var floorMatches = 0; var nearestMatches = 0; var ceilMatches = 0
        for width in [386 as CGFloat, 387, 388, 389, 390, 391, 392, 393, 394, 395] {
            let item = oracleItem(title: "Short", preview: "", hasImage: true, hasComments: false)
            let cell = configuredOracleCell(item: item, mode: .visual, previewLines: .standard, width: width)
            _ = measureUIKitArticleCell(cell, width: width)
            let diagnostics = cell.portraitAspectConstraintDiagnosticsForTesting
            let imageWidth = diagnostics.imageFrame.width
            let exactHeight = imageWidth * 9 / 16
            let scale = diagnostics.displayScale
            let exactPixels = exactHeight * scale
            let resolvedPixels = diagnostics.imageFrame.height * scale
            let floorPixels = floor(exactPixels)
            let nearestPixels = exactPixels.rounded()
            let ceilPixels = ceil(exactPixels)
            floorMatches += resolvedPixels == floorPixels ? 1 : 0
            nearestMatches += resolvedPixels == nearestPixels ? 1 : 0
            ceilMatches += resolvedPixels == ceilPixels ? 1 : 0
            let frame = diagnostics.imageFrame
            print(String(format: "[Portrait aspect] container=%.6f x=[%.6f,%.6f] width=%.6f y=[%.6f,%.6f] height=%.6f scale=%.6f exactHeight=%.9f exactPx=%.9f residue=%.9f resolvedPx=%.6f floor=%.0f nearest=%.0f ceil=%.0f", width, frame.minX, frame.maxX, frame.width, frame.minY, frame.maxY, frame.height, scale, exactHeight, exactPixels, exactPixels - floorPixels, resolvedPixels, floorPixels, nearestPixels, ceilPixels))
            XCTAssertEqual(diagnostics.multiplier, 9 / 16, accuracy: .ulpOfOne * 8)
            XCTAssertEqual(diagnostics.imageFrame.height * scale, (diagnostics.imageFrame.height * scale).rounded(), accuracy: 0.000_001, "width=\(width) exact=\(exactHeight) frame=\(diagnostics.imageFrame) scale=\(scale) px=\(diagnostics.imageFrame.height * scale)")
            XCTAssertEqual(resolvedPixels, nearestPixels, accuracy: 0.000_001, "width=\(width)")
        }
        print("[Portrait aspect] matches floor=\(floorMatches)/10 nearest=\(nearestMatches)/10 ceil=\(ceilMatches)/10")
        XCTAssertEqual(nearestMatches, 10)
    }

    private func layoutMetrics(mode: ArticlePresentationMode, width: CGFloat, hasImage: Bool, scale: CGFloat = 2) -> IOSUIKitArticleLayoutMetrics {
        IOSUIKitArticleLayoutEngine.metrics(for: layoutInput(mode: mode, width: width, hasImage: hasImage, scale: scale))
    }

    private func assertFrameEqual(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.5, file: StaticString = #filePath, line: UInt = #line) {
        let message = "actual=\(actual) expected=\(expected)"
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, file: file, line: line)
    }

    private func assertOptionalFrameEqual(_ actual: CGRect?, _ expected: CGRect?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual == nil, expected == nil, file: file, line: line)
        if let actual, let expected { assertFrameEqual(actual, expected, file: file, line: line) }
    }

    private func layoutInput(mode: ArticlePresentationMode, width: CGFloat, hasImage: Bool, scale: CGFloat = 2) -> IOSUIKitArticleLayoutInput {
        .init(title: "A deliberately multiline article title that exercises deterministic bounded text measurement", feedTitle: "A feed title", publishedDate: "January 1", preview: "A preview long enough to occupy multiple lines and preserve the production card text stack.", hasImage: hasImage, hasComments: true, mode: mode, previewLines: .standard, containerWidth: width, displayScale: scale, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: .leftToRight)
    }

    @MainActor
    private func oracleItem(title: String, preview: String, hasImage: Bool, hasComments: Bool, feedTitle: String = "Oracle Feed") -> IOSUIKitArticleTimelineItem {
        let article = ArticleSummary(id: 91, feedId: 10, categoryId: 20, feedTitle: feedTitle, title: title, url: "https://example.com/article", commentsUrl: hasComments ? "https://example.com/comments" : "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: preview, imageUrl: hasImage ? "https://example.com/image.jpg" : nil)
        return .init(article: article, content: .init(article: article), isRead: false, isStarred: false, feedIconImage: nil)
    }

    @MainActor
    private func configuredOracleCell(item: IOSUIKitArticleTimelineItem, mode: ArticlePresentationMode, previewLines: ArticlePreviewLines, width: CGFloat, layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight) -> IOSUIKitArticleCell {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        let cell = IOSUIKitArticleCell(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        let semanticAttribute: UISemanticContentAttribute = layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        container.semanticContentAttribute = semanticAttribute
        cell.semanticContentAttribute = semanticAttribute
        cell.contentView.semanticContentAttribute = semanticAttribute
        container.addSubview(cell)
        let displayScale = cell.traitCollection.displayScale
        let input = IOSUIKitArticleLayoutInput(item: item, mode: mode, previewLines: previewLines, containerWidth: width, displayScale: displayScale, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: layoutDirection)
        cell.configure(item: item, mode: mode, previewLines: previewLines, metrics: .init(mode: mode, containerWidth: width), displayScale: displayScale, preparedLayoutMetrics: IOSUIKitArticleLayoutEngine.metrics(for: input))
        container.layoutIfNeeded()
        return cell
    }

    @MainActor
    private func makeUIKitArticleCell(
        mode: ArticlePresentationMode,
        width: CGFloat,
        articleID: Int64 = 1,
        feedID: Int64 = 10,
        layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> IOSUIKitArticleCell {
        let article = ArticleSummary(
            id: articleID,
            feedId: feedID,
            categoryId: 20,
            feedTitle: "Feed \(feedID)",
            title: "A deliberately multiline article title that exercises the real UIKit sizing path",
            url: "https://example.com/article",
            commentsUrl: "https://example.com/comments",
            publishedAt: "2026-01-01T00:00:00Z",
            isRead: false,
            isStarred: false,
            preview: "A preview long enough to occupy multiple lines and preserve the production card text stack.",
            imageUrl: "https://example.com/image.jpg"
        )
        let item = IOSUIKitArticleTimelineItem(
            article: article,
            content: ArticleRowContent(article: article),
            isRead: false,
            isStarred: false,
            feedIconImage: nil
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        let cell = IOSUIKitArticleCell(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        let semanticAttribute: UISemanticContentAttribute = layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        container.semanticContentAttribute = semanticAttribute
        cell.semanticContentAttribute = semanticAttribute
        cell.contentView.semanticContentAttribute = semanticAttribute
        container.addSubview(cell)
        let displayScale = cell.traitCollection.displayScale
        let input = IOSUIKitArticleLayoutInput(item: item, mode: mode, previewLines: .standard, containerWidth: width, displayScale: displayScale, contentSizeCategory: .large, localeIdentifier: "en_US", layoutDirection: layoutDirection)
        cell.configure(
            item: item,
            mode: mode,
            previewLines: .standard,
            metrics: .init(mode: mode, containerWidth: width),
            displayScale: displayScale,
            preparedLayoutMetrics: IOSUIKitArticleLayoutEngine.metrics(for: input)
        )
        container.layoutIfNeeded()
        return cell
    }

    @MainActor
    private func measureUIKitArticleCell(_ cell: IOSUIKitArticleCell, width: CGFloat) -> CGFloat {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: width, height: 1)
        let measured = cell.preferredLayoutAttributesFitting(attributes)
        cell.frame.size = measured.size
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return measured.size.height
    }

    @MainActor
    private func testImage(width: CGFloat, height: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @MainActor
    private func waitForFeedIconState(_ state: IOSFeedIconPresentationState, matching expected: IOSFeedIconLoadState) async {
        for _ in 0..<100 {
            if state.loadState == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for feed icon state \(expected)")
    }

    private final class FeedIconLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Data?, Error>]
        private var calls = 0

        init(results: [Result<Data?, Error>]) {
            self.results = results
        }

        func load() throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            guard !results.isEmpty else { throw URLError(.badServerResponse) }
            return try results.removeFirst().get()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
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

private actor LayoutMeasurementGate {
    private var inputs: [IOSUIKitArticleLayoutInput] = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func measure(_ input: IOSUIKitArticleLayoutInput) async -> IOSUIKitArticleLayoutMetrics {
        inputs.append(input)
        let readyCounts = startWaiters.keys.filter { inputs.count >= $0 }
        for count in readyCounts { startWaiters.removeValue(forKey: count)?.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return IOSUIKitArticleLayoutEngine.metrics(for: input)
    }

    func waitUntilStarted(count: Int) async {
        guard inputs.count < count else { return }
        await withCheckedContinuation { startWaiters[count] = $0 }
    }

    func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func startedTitles() -> [String] { inputs.map(\.title) }
}

private actor ImageLoadGate {
    private let data: Data
    private var calls = 0
    private var didStart: CheckedContinuation<Void, Never>?
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }

    func load() async throws -> Data {
        calls += 1
        didStart?.resume()
        didStart = nil
        let readyCounts = startWaiters.keys.filter { calls >= $0 }
        for count in readyCounts { startWaiters.removeValue(forKey: count)?.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return data
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { didStart = $0 }
    }

    func waitUntilStarted(count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { startWaiters[count] = $0 }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCount() -> Int { calls }
}

private actor PrioritizedImageLoadGate {
    private let data: Data
    private var urls: [URL] = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }

    func load(url: URL) async throws -> Data {
        urls.append(url)
        resumeStartWaiters()
        await withCheckedContinuation { releaseWaiters.append($0) }
        return data
    }

    func waitUntilStarted(count: Int) async {
        guard urls.count < count else { return }
        await withCheckedContinuation { startWaiters[count] = $0 }
    }

    func releaseOne() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }

    func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func startedURLs() -> [URL] { urls }

    private func resumeStartWaiters() {
        let readyCounts = startWaiters.keys.filter { urls.count >= $0 }
        for count in readyCounts { startWaiters.removeValue(forKey: count)?.resume() }
    }
}
