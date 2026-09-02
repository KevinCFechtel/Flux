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
            ForEach(groups) { group in
                Section {
                    if let categoryID = group.categoryID {
                        scopeRow(group.title, systemImage: "folder", scope: .category(categoryID), count: store.categoryCounts[categoryID] ?? 0)
                    }
                    ForEach(group.feeds, id: \.id) { feed in
                        scopeRow(feedTitle(feed.id), systemImage: "dot.radiowaves.left.and.right", scope: .feed(feed.id), count: store.feedCounts[feed.id] ?? 0)
                            .padding(.leading, group.categoryID == nil ? 0 : 16)
                    }
                } header: {
                    if group.categoryID == nil { Text(group.title) }
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

    private var groups: [NavigationPresentationGroup] {
        NavigationVisibility.groups(
            categories: store.catalog.categories.map { NavigationPresentationCategory(id: $0.id, title: $0.title) },
            feeds: store.catalog.feeds.map { NavigationPresentationFeed(id: $0.id, categoryID: $0.categoryId) },
            hidingEmpty: store.hideEmptyNavigationEntries,
            counts: store.feedCounts
        )
    }

    private func feedTitle(_ feedID: Int64) -> String {
        store.catalog.feeds.first { $0.id == feedID }?.title ?? "Feed"
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
