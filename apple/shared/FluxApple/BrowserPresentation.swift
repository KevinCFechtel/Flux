import Foundation

enum BrowserScope: Hashable { case all, starred, search, listeningList, category(Int64), feed(Int64) }

enum StartupScopePreference: String, CaseIterable { case allNews, starred, category, feed }

enum StartupScopeResolver {
    static func resolve(_ preference: StartupScopePreference, categoryID: Int64?, feedID: Int64?, categoryIDs: Set<Int64>, feedIDs: Set<Int64>) -> BrowserScope {
        switch preference {
        case .allNews: .all
        case .starred: .starred
        case .category: categoryID.map { categoryIDs.contains($0) ? .category($0) : .all } ?? .all
        case .feed: feedID.map { feedIDs.contains($0) ? .feed($0) : .all } ?? .all
        }
    }
}

struct NavigationPresentationFeed: Equatable { let id: Int64; let categoryID: Int64 }
struct NavigationPresentationCategory: Equatable { let id: Int64; let title: String }

struct NavigationPresentationGroup: Identifiable, Equatable {
    let id: Int64
    let title: String
    let categoryID: Int64?
    let feeds: [NavigationPresentationFeed]
}

enum NavigationVisibility {
    static func visibleFeeds(_ feeds: [NavigationPresentationFeed], hidingEmpty: Bool, counts: [Int64: UInt64]) -> [NavigationPresentationFeed] {
        hidingEmpty ? feeds.filter { counts[$0.id, default: 0] > 0 } : feeds
    }
    static func visibleCategoryIDs(_ categoryIDs: [Int64], feeds: [NavigationPresentationFeed]) -> [Int64] {
        let visible = Set(feeds.map(\.categoryID)); return categoryIDs.filter { visible.contains($0) }
    }

    static func groups(categories: [NavigationPresentationCategory], feeds: [NavigationPresentationFeed], hidingEmpty: Bool, counts: [Int64: UInt64]) -> [NavigationPresentationGroup] {
        let visibleFeeds = visibleFeeds(feeds, hidingEmpty: hidingEmpty, counts: counts)
        let visibleIDs = Set(visibleFeeds.map(\.id))
        let categoryIDs = Set(categories.map(\.id))
        var groups = categories.compactMap { category -> NavigationPresentationGroup? in
            let categoryFeeds = feeds.filter { $0.categoryID == category.id && visibleIDs.contains($0.id) }
            guard !hidingEmpty || !categoryFeeds.isEmpty else { return nil }
            return NavigationPresentationGroup(id: category.id, title: category.title, categoryID: category.id, feeds: categoryFeeds)
        }
        let orphanFeeds = feeds.filter { visibleIDs.contains($0.id) && !categoryIDs.contains($0.categoryID) }
        if !orphanFeeds.isEmpty {
            groups.append(NavigationPresentationGroup(id: Int64.min, title: "Other Feeds", categoryID: nil, feeds: orphanFeeds))
        }
        return groups
    }
}

enum ArticleListPresentationPolicy {
    static func removesMarkedReadArticle(removeWhenMarkedRead: Bool, unreadOnly: Bool, scope: BrowserScope) -> Bool {
        removeWhenMarkedRead && unreadOnly && scope != .search && scope != .listeningList
    }
}

enum ArticlePresentationMode: String, CaseIterable { case visual, compact }
extension ArticlePresentationMode {
    var showsArticleImage: Bool { self == .visual }
}
enum ArticlePresentationLayout {
    static let portraitImageAspectRatio: CGFloat = 16.0 / 9.0
    static let landscapeImageAspectRatio: CGFloat = 4.0 / 3.0
    static let cardHorizontalPadding: CGFloat = 24

    static func usesLandscapeVisual(mode: ArticlePresentationMode, availableWidth: CGFloat) -> Bool {
        mode == .visual && availableWidth > 600
    }

    static func boundedArticleWidth(_ availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth)
    }

    static func articleContentWidth(_ availableWidth: CGFloat) -> CGFloat {
        max(0, boundedArticleWidth(availableWidth) - cardHorizontalPadding)
    }

    static func portraitImageHeight(contentWidth: CGFloat) -> CGFloat {
        contentWidth / portraitImageAspectRatio
    }

    static func landscapeImageWidth(availableWidth: CGFloat) -> CGFloat {
        min(260, articleContentWidth(availableWidth) * 0.36)
    }

    static func landscapeImageHeight(imageWidth: CGFloat) -> CGFloat {
        imageWidth / landscapeImageAspectRatio
    }

    static func showsInternalUnreadIndicator(isRead: Bool) -> Bool { !isRead }
}
enum ArticlePreviewLines: Int, CaseIterable { case compact = 2, standard = 3, extended = 5 }
