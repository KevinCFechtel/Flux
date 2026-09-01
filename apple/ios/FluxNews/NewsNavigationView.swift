import SwiftUI

struct NewsNavigationView: View {
    @ObservedObject var store: NewsreaderStore
    @Binding var iPhoneSheetPresented: Bool

    var body: some View {
        List(selection: selection) {
            Section("News") {
                scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
                scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
            }
            if !store.catalog.categories.isEmpty {
                Section("Categories") {
                    ForEach(visibleCategories, id: \.id) { category in
                        scopeRow(category.title, systemImage: "folder", scope: .category(category.id), count: store.categoryCounts[category.id] ?? 0)
                    }
                }
            }
            if !visibleFeeds.isEmpty {
                Section("Feeds") {
                    ForEach(visibleFeeds, id: \.id) { feed in
                        scopeRow(feed.title, systemImage: "dot.radiowaves.left.and.right", scope: .feed(feed.id), count: store.feedCounts[feed.id] ?? 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("News")
    }

    private var selection: Binding<BrowserScope?> {
        Binding(
            get: { store.scope },
            set: { if let value = $0 { store.select(value); iPhoneSheetPresented = false } }
        )
    }

    private var visibleFeeds: [Feed] {
        let feeds = store.catalog.feeds
        guard store.hideEmptyNavigationEntries else { return feeds }
        return NavigationVisibility.visibleFeeds(feeds.map { NavigationPresentationFeed(id: $0.id, categoryID: $0.categoryId) }, hidingEmpty: true, counts: store.feedCounts).compactMap { id in feeds.first { $0.id == id.id } }
    }

    private var visibleCategories: [Category] {
        let categories = store.catalog.categories
        guard store.hideEmptyNavigationEntries else { return categories }
        let feedIDs = Set(visibleFeeds.map(\.categoryId))
        return categories.filter { feedIDs.contains($0.id) }
    }

    @ViewBuilder
    private func scopeRow(_ title: String, systemImage: String, scope: BrowserScope, count: UInt64) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text(count > 999 ? "999+" : "\(count)").foregroundStyle(.secondary).font(.caption) }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .tag(scope)
        .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
    }
}
