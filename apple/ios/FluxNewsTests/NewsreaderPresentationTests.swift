import XCTest
import ImageIO
import Observation
import UniformTypeIdentifiers
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
        XCTAssertEqual(IOSNavigationButtonPresentation.accessibilityLabel, "Choose news scope")
        XCTAssertEqual(IOSNavigationButtonPresentation.glyphSize, 22)
    }

    func testNavigationBrandingUsesTheExistingFluxNewsTemplateAsset() {
        XCTAssertEqual(IOSNavigationBranding.assetName, "FluxNewsTemplate")
        XCTAssertEqual(IOSNavigationBranding.accessibilityLabel, "FluxNews")
        XCTAssertTrue(IOSNavigationBranding.iconUsesSolidAccentColor)
    }

    func testArticleNavigationHostUsesTheExistingResetRevisionAsItsIdentity() {
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 0), 0)
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 1), 1)
        XCTAssertEqual(IOSArticleNavigationPresentation.identity(for: 2), 2)
    }

    func testArticleListTitleDoesNotContainSelectionCount() {
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .all, catalog: NavigationCatalog(categories: [], feeds: [])), "All News")
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
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .starred, catalog: NavigationCatalog(categories: [], feeds: [])), "Starred")
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
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: true, count: 117), "117 unread")
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .all, unreadOnly: false, count: 842), "842 articles")
        XCTAssertEqual(ArticleListCounterPresentation.expandedLabel(scope: .starred, unreadOnly: true, count: 8), "8 articles")
        XCTAssertEqual(ArticleListCounterPresentation.compactCount(1000), "1000")
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
        XCTAssertEqual(ArticleListTitlePresentation.title(scope: .all, catalog: store.catalog), "All News")
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

    func testSyncButtonPresentationUsesStableSlotForEverySyncState() {
        XCTAssertFalse(IOSSyncButtonPresentation.showsProgress(isSyncing: false))
        XCTAssertTrue(IOSSyncButtonPresentation.showsProgress(isSyncing: true))
        XCTAssertEqual(IOSSyncButtonPresentation.accessibilityValue(isSyncing: false), "Ready")
        XCTAssertEqual(IOSSyncButtonPresentation.accessibilityValue(isSyncing: true), "Syncing")
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
            _ = store.feedIcons
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
    func testArticleListDependenciesInvalidateForScrolloverReadStateChange() {
        let store = NewsreaderStore(defaults: UserDefaults())
        store.setArticlesForTesting([.init(id: 1, feedId: 10, categoryId: 20, feedTitle: "Feed", title: "Article", url: "https://example.com/1", commentsUrl: "", publishedAt: "2026-01-01T00:00:00Z", isRead: false, isStarred: false, preview: "", imageUrl: nil)])
        let articleListInvalidated = ObservationFlag()

        withObservationTracking {
            _ = store.articles
        } onChange: {
            MainActor.assumeIsolated { articleListInvalidated.value = true }
        }

        store.applyScrolloverMutationForTesting([1])

        XCTAssertTrue(articleListInvalidated.value)
        XCTAssertTrue(store.articles[0].isRead)
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
        XCTAssertEqual(IOSReaderDismissalPresentation.title, "Done")
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
