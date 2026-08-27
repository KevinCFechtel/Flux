import Foundation

enum WidgetSnapshotWriter {
    static func refresh(core: Flux, store: WidgetSnapshotStore) throws {
        let data = try core.widgetData()
        var iconReferences: [Int64: (normal: String?, dark: String?)] = [:]
        for feedID in Set(data.articles.map(\.feedId)) {
            let normal = (try? core.feedIcon(feedId: feedID, variant: .normal)).flatMap { try? store.writeIcon(Data($0.pngData), feedID: feedID, dark: false) }
            let dark = (try? core.feedIcon(feedId: feedID, variant: .dark)).flatMap { try? store.writeIcon(Data($0.pngData), feedID: feedID, dark: true) }
            iconReferences[feedID] = (normal, dark)
        }
        try store.write(WidgetSnapshotV1(schemaVersion: 1, state: data.lastSuccessfulSyncAt == nil ? .awaitingSuccessfulSync : .ready, generatedAt: ISO8601DateFormatter().string(from: Date()), lastSuccessfulSyncAt: data.lastSuccessfulSyncAt, feeds: data.feeds.map { .init(id: $0.id, categoryID: $0.categoryId, title: $0.title, normalIconFile: iconReferences[$0.id]?.normal, darkIconFile: iconReferences[$0.id]?.dark) }, categories: data.categories.map { .init(id: $0.id, title: $0.title) }, articles: data.articles.map { .init(id: $0.id, feedID: $0.feedId, categoryID: $0.categoryId, feedTitle: $0.feedTitle, title: $0.title, publishedAt: $0.publishedAt, isRead: $0.isRead, isStarred: $0.isStarred) }, counts: .init(allUnread: data.counts.allUnread, bookmarks: data.counts.bookmarks, feedUnread: data.counts.feedUnread.map { .init(id: $0.id, count: $0.count) }, categoryUnread: data.counts.categoryUnread.map { .init(id: $0.id, count: $0.count) })))
    }
}
