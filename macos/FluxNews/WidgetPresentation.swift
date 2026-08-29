import Foundation
import WidgetKit

enum HeadlinesPresentation {
    static func capacity(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 8
        case .systemExtraLarge: 12
        default: 1
        }
    }
}

enum WidgetContentScope: String, CaseIterable {
    case allNews, bookmarks, category, feed
}

struct WidgetContentSelection: Equatable {
    let scope: WidgetContentScope
    let categoryID: Int64?
    let feedID: Int64?
}

enum WidgetContentState: Equatable {
    case missingSnapshot
    case corruptSnapshot
    case noAccount
    case awaitingSuccessfulSync
    case unavailableSelection(String)
    case empty
    case ready
}

struct WidgetContentModel: Equatable {
    let state: WidgetContentState
    let title: String
    let count: UInt64
    let countLabel: String
    let articles: [WidgetSnapshotV1.Article]
    let lastSuccessfulSyncAt: String?

    func latestArticles(limit: Int) -> [WidgetSnapshotV1.Article] { Array(articles.prefix(limit)) }

    static func make(snapshotResult: Result<WidgetSnapshotV1?, Error>, selection: WidgetContentSelection) -> Self {
        guard case let .success(snapshot?) = snapshotResult else {
            return .init(state: snapshotResult.isSuccess ? .missingSnapshot : .corruptSnapshot, title: "FluxNews", count: 0, countLabel: "unread", articles: [], lastSuccessfulSyncAt: nil)
        }
        switch snapshot.state {
        case .noAccount:
            return .init(state: .noAccount, title: "FluxNews", count: 0, countLabel: "unread", articles: [], lastSuccessfulSyncAt: nil)
        case .awaitingSuccessfulSync:
            return .init(state: .awaitingSuccessfulSync, title: "FluxNews", count: 0, countLabel: "unread", articles: [], lastSuccessfulSyncAt: nil)
        case .ready:
            break
        }
        if selection.scope == .category,
           (selection.categoryID == nil || !snapshot.categories.contains(where: { $0.id == selection.categoryID })) {
            return .init(state: .unavailableSelection("Selected category unavailable"), title: "Category", count: 0, countLabel: "unread", articles: [], lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt)
        }
        if selection.scope == .feed,
           (selection.feedID == nil || !snapshot.feeds.contains(where: { $0.id == selection.feedID })) {
            return .init(state: .unavailableSelection("Selected feed unavailable"), title: "Feed", count: 0, countLabel: "unread", articles: [], lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt)
        }
        let resolved: (title: String, count: UInt64, label: String)
        switch selection.scope {
        case .allNews:
            resolved = ("All News", snapshot.counts.allUnread, "unread")
        case .bookmarks:
            resolved = ("Bookmarks", snapshot.counts.bookmarks, "bookmarked")
        case .category:
            let id = selection.categoryID!
            let category = snapshot.categories.first(where: { $0.id == id })!
            resolved = (category.title, snapshot.counts.categoryUnread.first(where: { $0.id == id })?.count ?? 0, "unread")
        case .feed:
            let id = selection.feedID!
            let feed = snapshot.feeds.first(where: { $0.id == id })!
            resolved = (feed.title, snapshot.counts.feedUnread.first(where: { $0.id == id })?.count ?? 0, "unread")
        }
        let articles = filtered(snapshot: snapshot, selection: selection)
        return .init(state: articles.isEmpty ? .empty : .ready, title: resolved.title, count: resolved.count, countLabel: resolved.label, articles: articles, lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt)
    }

    private static func filtered(snapshot: WidgetSnapshotV1, selection: WidgetContentSelection) -> [WidgetSnapshotV1.Article] {
        snapshot.articles.filter { article in
            switch selection.scope {
            case .allNews: !article.isRead
            case .bookmarks: article.isStarred
            case .category: !article.isRead && article.categoryID == selection.categoryID
            case .feed: !article.isRead && article.feedID == selection.feedID
            }
        }.sorted { ($0.publishedAt, $0.id) > ($1.publishedAt, $1.id) }
    }
}

private extension Result where Success == WidgetSnapshotV1?, Failure == Error {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
