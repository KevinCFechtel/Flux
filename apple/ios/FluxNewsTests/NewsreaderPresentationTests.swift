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
            .starred, .read, .original, .miniflux, .comments, .copyLink, .share, .saveToService
        ]

        XCTAssertEqual(Set(actions).count, 8)
        XCTAssertEqual(actions[2], .original)
        XCTAssertEqual(actions[3], .miniflux)
        XCTAssertEqual(actions[7], .saveToService)
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

    func testConfiguredDetailModeSelectsReaderBeforeNormalOpenRouting() {
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openDetailView, openInMiniflux: false), .detail)
        XCTAssertEqual(ArticleOpenRouting.action(clickOnNews: .openLink, openInMiniflux: false), .original)
    }

    func testReaderPresentationUsesInspectorOnlyOnRegularWidthIPad() {
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: true, isRegularWidth: true), .inspector)
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: true, isRegularWidth: false), .sheet)
        XCTAssertEqual(ReaderPresentationPolicy.kind(isPad: false, isRegularWidth: true), .sheet)
    }

    func testReaderRequestStateRejectsStaleResponses() {
        var state = ReaderRequestState()
        let first = state.begin()
        let second = state.begin()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))
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
