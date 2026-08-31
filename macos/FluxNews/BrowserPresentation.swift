import Foundation

enum BrowserScope: Hashable { case all, starred, search, listeningList, category(Int64), feed(Int64) }

enum StartupScopePreference: String, CaseIterable {
    case allNews
    case starred
    case category
    case feed
}

enum StartupScopeResolver {
    static func resolve(_ preference: StartupScopePreference, categoryID: Int64?, feedID: Int64?, categoryIDs: Set<Int64>, feedIDs: Set<Int64>) -> BrowserScope {
        switch preference {
        case .allNews:
            return .all
        case .starred:
            return .starred
        case .category:
            guard let categoryID, categoryIDs.contains(categoryID) else { return .all }
            return .category(categoryID)
        case .feed:
            guard let feedID, feedIDs.contains(feedID) else { return .all }
            return .feed(feedID)
        }
    }
}

struct NavigationPresentationFeed: Equatable {
    let id: Int64
    let categoryID: Int64
}

enum NavigationVisibility {
    static func visibleFeeds(_ feeds: [NavigationPresentationFeed], hidingEmpty: Bool, counts: [Int64: UInt64]) -> [NavigationPresentationFeed] {
        hidingEmpty ? feeds.filter { counts[$0.id, default: 0] > 0 } : feeds
    }

    static func visibleCategoryIDs(_ categoryIDs: [Int64], feeds: [NavigationPresentationFeed]) -> [Int64] {
        let visibleCategoryIDs = Set(feeds.map(\.categoryID))
        return categoryIDs.filter { visibleCategoryIDs.contains($0) }
    }
}

enum ArticleListPresentationPolicy {
    static func removesMarkedReadArticle(removeWhenMarkedRead: Bool, unreadOnly: Bool, scope: BrowserScope) -> Bool {
        removeWhenMarkedRead && unreadOnly && scope != .search && scope != .listeningList
    }
}
