import XCTest
@testable import FluxNews

final class NewsreaderPresentationTests: XCTestCase {
    func testNewsNavigationPresentationMatchesDeviceRoutes() {
        XCTAssertEqual(NewsNavigationPresentation.sidebar, .sidebar)
        XCTAssertEqual(NewsNavigationPresentation.sheet, .sheet)
    }

    func testNewsNavigationUsesSplitViewOnlyOnIPad() {
        XCTAssertFalse(NewsNavigationLayout.usesSplitView(for: .phone))
        XCTAssertTrue(NewsNavigationLayout.usesSplitView(for: .pad))
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
        XCTAssertTrue(ArticlePresentationLayout.showsInternalUnreadIndicator(isRead: false))
        XCTAssertFalse(ArticlePresentationLayout.showsInternalUnreadIndicator(isRead: true))
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

    func testArticleRoutingFallsBackToOriginalURLWithoutExternalCandidate() {
        XCTAssertEqual(
            ArticleOpenRoutingPolicy.destination(originalURL: "https://example.com/article", externalCandidate: nil, canOpenExternal: false),
            .browser(URL(string: "https://example.com/article")!)
        )
    }

    func testArticleRoutingPrefersAvailableExternalCandidate() {
        let candidate = URL(string: "https://miniflux.example.com/entry/42")!
        XCTAssertEqual(
            ArticleOpenRoutingPolicy.destination(originalURL: "https://example.com/article", externalCandidate: candidate, canOpenExternal: true),
            .external(candidate)
        )
    }

    func testArticleRoutingFallsBackWhenExternalAppIsUnavailableOrOpenFails() {
        let original = URL(string: "https://example.com/article")!
        let candidate = URL(string: "https://miniflux.example.com/entry/42")!
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, externalCandidate: candidate, canOpenExternal: false), .browser(original))
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: original.absoluteString, externalCandidate: candidate, canOpenExternal: true, externalOpenSucceeded: false), .browser(original))
    }

    func testArticleRoutingUsesConfiguredFeedPreferenceAndValidatesURLs() {
        let candidate = ArticleOpenRoutingPolicy.externalCandidate(openInMiniflux: true, minifluxURL: "https://miniflux.example.com/entry/42")
        XCTAssertEqual(candidate, URL(string: "https://miniflux.example.com/entry/42"))
        XCTAssertNil(ArticleOpenRoutingPolicy.externalCandidate(openInMiniflux: false, minifluxURL: "https://miniflux.example.com/entry/42"))
        XCTAssertNil(ArticleOpenRoutingPolicy.externalCandidate(openInMiniflux: true, minifluxURL: "not a URL"))
        XCTAssertEqual(ArticleOpenRoutingPolicy.destination(originalURL: "not a URL", externalCandidate: candidate, canOpenExternal: true), .invalid)
    }

    func testSharedArticleRoutingSemanticsRemainTheSameForNativeClients() {
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: true), .miniflux)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: false), .original)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openDetailView, openInMiniflux: true), .detail)
    }

}
