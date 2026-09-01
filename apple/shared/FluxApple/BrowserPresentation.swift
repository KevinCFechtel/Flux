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

enum NavigationVisibility {
    static func visibleFeeds(_ feeds: [NavigationPresentationFeed], hidingEmpty: Bool, counts: [Int64: UInt64]) -> [NavigationPresentationFeed] {
        hidingEmpty ? feeds.filter { counts[$0.id, default: 0] > 0 } : feeds
    }
    static func visibleCategoryIDs(_ categoryIDs: [Int64], feeds: [NavigationPresentationFeed]) -> [Int64] {
        let visible = Set(feeds.map(\.categoryID)); return categoryIDs.filter { visible.contains($0) }
    }
}

enum ArticleListPresentationPolicy {
    static func removesMarkedReadArticle(removeWhenMarkedRead: Bool, unreadOnly: Bool, scope: BrowserScope) -> Bool {
        removeWhenMarkedRead && unreadOnly && scope != .search && scope != .listeningList
    }
}

enum ArticleListStyle: String { case row, card }
enum ArticlePreviewLines: Int, CaseIterable { case compact = 2, standard = 3, extended = 5 }
