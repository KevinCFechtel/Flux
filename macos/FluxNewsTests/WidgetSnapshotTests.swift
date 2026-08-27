import Foundation
import WidgetKit
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testRoundTripAndInvalidationAreAtomicAndCredentialFree() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = WidgetSnapshotStore(root: temporary)
        let snapshot = WidgetSnapshotV1(
            schemaVersion: 1, state: .ready, generatedAt: "2026-08-27T12:00:00Z", lastSuccessfulSyncAt: "2026-08-27T11:00:00Z",
            feeds: [.init(id: 42, categoryID: 7, title: "Development", normalIconFile: "icons/feed-42-normal.png", darkIconFile: nil)],
            categories: [.init(id: 7, title: "Work")],
            articles: [.init(id: 999_999_999, feedID: 42, categoryID: 7, feedTitle: "Development", title: "Article", publishedAt: "2026-08-27T10:00:00Z", isRead: false, isStarred: true)],
            counts: .init(allUnread: 10_000, bookmarks: 1, feedUnread: [.init(id: 42, count: 10_000)], categoryUnread: [.init(id: 7, count: 10_000)])
        )
        try store.write(snapshot)
        XCTAssertEqual(try store.read(), snapshot)
        let serialized = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(serialized.contains("apiKey"))
        XCTAssertFalse(serialized.contains("server"))
        XCTAssertTrue(serialized.contains("999999999"))
        _ = try store.writeIcon(Data([1, 2]), feedID: 42, dark: false)
        try store.invalidate()
        XCTAssertNil(try store.read())
    }

    func testUnsupportedAndCorruptSnapshotsAreRejectedSafely() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = WidgetSnapshotStore(root: temporary)
        let unsupported = WidgetSnapshotV1(schemaVersion: 2, state: .noAccount, generatedAt: "", lastSuccessfulSyncAt: nil, feeds: [], categories: [], articles: [], counts: .init(allUnread: 0, bookmarks: 0, feedUnread: [], categoryUnread: []))
        XCTAssertThrowsError(try store.write(unsupported))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: temporary.appendingPathComponent("widget-snapshot-v1.json"))
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? WidgetSnapshotStoreError, .corruptSnapshot) }
    }

    func testPresentationUsesAuthoritativeCountsAndFiltersBookmarksIndependentlyOfReadState() {
        let model = WidgetContentModel.make(snapshotResult: .success(sampleSnapshot), selection: .init(scope: .bookmarks, categoryID: nil, feedID: nil))

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.title, "Bookmarks")
        XCTAssertEqual(model.count, 99)
        XCTAssertEqual(model.countLabel, "bookmarked")
        XCTAssertEqual(model.articles.map(\.id), [3, 1])
        XCTAssertEqual(model.lastSuccessfulSyncAt, "2026-08-27T11:00:00Z")
    }

    func testPresentationMarksDeletedConfiguredSourceUnavailable() {
        let model = WidgetContentModel.make(snapshotResult: .success(sampleSnapshot), selection: .init(scope: .feed, categoryID: nil, feedID: 404))

        XCTAssertEqual(model.state, .unavailableSelection("Selected feed unavailable"))
        XCTAssertTrue(model.articles.isEmpty)
    }

    func testPresentationDistinguishesSnapshotAndAccountStates() {
        XCTAssertEqual(WidgetContentModel.make(snapshotResult: .success(nil), selection: .init(scope: .allNews, categoryID: nil, feedID: nil)).state, .missingSnapshot)
        XCTAssertEqual(WidgetContentModel.make(snapshotResult: .success(WidgetSnapshotV1(schemaVersion: 1, state: .noAccount, generatedAt: "", lastSuccessfulSyncAt: nil, feeds: [], categories: [], articles: [], counts: .init(allUnread: 0, bookmarks: 0, feedUnread: [], categoryUnread: []))), selection: .init(scope: .allNews, categoryID: nil, feedID: nil)).state, .noAccount)
        XCTAssertEqual(WidgetContentModel.make(snapshotResult: .failure(WidgetSnapshotStoreError.corruptSnapshot), selection: .init(scope: .allNews, categoryID: nil, feedID: nil)).state, .corruptSnapshot)
    }

    func testReadIconRejectsPathsOutsideIconsDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = WidgetSnapshotStore(root: temporary)
        let path = try store.writeIcon(Data([1, 2]), feedID: 42, dark: false)

        XCTAssertEqual(store.readIcon(relativePath: path), Data([1, 2]))
        XCTAssertNil(store.readIcon(relativePath: "../widget-snapshot-v1.json"))
        XCTAssertNil(store.readIcon(relativePath: "icons/nested/file.png"))
    }

    func testWidgetActionsRoundTripOnlyStableIdentifiers() {
        let actions: [WidgetAction] = [.article(42), .sync, .open(.init(scope: .allNews, categoryID: nil, feedID: nil)), .open(.init(scope: .bookmarks, categoryID: nil, feedID: nil)), .open(.init(scope: .feed, categoryID: nil, feedID: 7)), .open(.init(scope: .category, categoryID: 8, feedID: nil))]
        for action in actions { XCTAssertEqual(WidgetAction(url: action.url()), action) }
        XCTAssertNil(WidgetAction(url: URL(string: "fluxnews://widget/v1/article?id=nope")!))
        XCTAssertNil(WidgetAction(url: URL(string: "fluxnews://widget/v1/open?scope=feed")!))
        XCTAssertNil(WidgetAction(url: URL(string: "https://example.com/v1/sync")!))
        XCTAssertNil(WidgetAction(url: URL(string: "fluxnews://widget/v1/unknown")!))
    }

    func testHeadlinesCapacitiesAndLatestArticlesAreBounded() {
        XCTAssertEqual(HeadlinesPresentation.capacity(for: .systemSmall), 1)
        XCTAssertEqual(HeadlinesPresentation.capacity(for: .systemMedium), 3)
        XCTAssertEqual(HeadlinesPresentation.capacity(for: .systemLarge), 7)
        XCTAssertEqual(HeadlinesPresentation.capacity(for: .systemExtraLarge), 12)
        let articles = (1...20).map { WidgetSnapshotV1.Article(id: Int64($0), feedID: 42, categoryID: 7, feedTitle: "Development", title: "\($0)", publishedAt: String(format: "2026-08-27T%02d:00:00Z", $0), isRead: false, isStarred: false) }.reversed()
        let snapshot = WidgetSnapshotV1(schemaVersion: 1, state: .ready, generatedAt: "", lastSuccessfulSyncAt: nil, feeds: [.init(id: 42, categoryID: 7, title: "Development", normalIconFile: nil, darkIconFile: nil)], categories: [.init(id: 7, title: "Work")], articles: Array(articles), counts: .init(allUnread: 100, bookmarks: 0, feedUnread: [.init(id: 42, count: 100)], categoryUnread: [.init(id: 7, count: 100)]))
        let model = WidgetContentModel.make(snapshotResult: .success(snapshot), selection: .init(scope: .allNews, categoryID: nil, feedID: nil))
        XCTAssertEqual(model.latestArticles(limit: HeadlinesPresentation.capacity(for: .systemMedium)).count, 3)
        XCTAssertEqual(model.latestArticles(limit: HeadlinesPresentation.capacity(for: .systemMedium)).map(\.id), [20, 19, 18])
        XCTAssertEqual(model.count, 100)
    }

    private var sampleSnapshot: WidgetSnapshotV1 {
        .init(schemaVersion: 1, state: .ready, generatedAt: "2026-08-27T12:00:00Z", lastSuccessfulSyncAt: "2026-08-27T11:00:00Z", feeds: [.init(id: 42, categoryID: 7, title: "Development", normalIconFile: nil, darkIconFile: nil)], categories: [.init(id: 7, title: "Work")], articles: [.init(id: 1, feedID: 42, categoryID: 7, feedTitle: "Development", title: "Unread bookmark", publishedAt: "2026-08-27T10:00:00Z", isRead: false, isStarred: true), .init(id: 2, feedID: 42, categoryID: 7, feedTitle: "Development", title: "Unread article", publishedAt: "2026-08-27T09:00:00Z", isRead: false, isStarred: false), .init(id: 3, feedID: 42, categoryID: 7, feedTitle: "Development", title: "Read bookmark", publishedAt: "2026-08-27T11:00:00Z", isRead: true, isStarred: true)], counts: .init(allUnread: 10, bookmarks: 99, feedUnread: [.init(id: 42, count: 10)], categoryUnread: [.init(id: 7, count: 10)]))
    }
}
