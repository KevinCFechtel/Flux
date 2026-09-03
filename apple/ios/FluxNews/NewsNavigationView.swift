import SwiftUI

enum NewsNavigationPresentation: Equatable {
    case sidebar
    case stack
}

struct NewsNavigationView: View {
    @ObservedObject var store: NewsreaderStore
    let presentation: NewsNavigationPresentation

    var body: some View {
        if presentation == .sidebar {
            sidebarList
        } else {
            stackList
        }
    }

    private var sidebarList: some View {
        List(selection: selection) {
            Section {
                scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
                scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
            }
            Section("Feeds") {
                ForEach(groups) { group in
                    if group.categoryID != nil {
                        OutlineGroup([sidebarItem(for: group)], children: \.children) { item in
                            scopeRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                        }
                    } else {
                        ForEach(group.feeds, id: \.id) { feed in
                            scopeRow(feedTitle(feed.id), systemImage: "dot.radiowaves.left.and.right", scope: .feed(feed.id), count: store.feedCounts[feed.id] ?? 0)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("News")
    }

    private var stackList: some View {
        List {
            Section {
                scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
                scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
            }
            Section("Feeds") {
                ForEach(groups) { group in
                    if group.categoryID != nil {
                        OutlineGroup([sidebarItem(for: group)], children: \.children) { item in
                            scopeRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                        }
                    } else {
                        ForEach(group.feeds, id: \.id) { feed in
                            scopeRow(feedTitle(feed.id), systemImage: "dot.radiowaves.left.and.right", scope: .feed(feed.id), count: store.feedCounts[feed.id] ?? 0)
                        }
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
            set: { if let value = $0 { store.select(value) } }
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

    private func sidebarItem(for group: NavigationPresentationGroup) -> NewsNavigationItem {
        let categoryID = group.categoryID!
        return NewsNavigationItem(
            id: "category-\(categoryID)",
            title: group.title,
            systemImage: "folder",
            scope: .category(categoryID),
            count: store.categoryCounts[categoryID] ?? 0,
            children: group.feeds.map { feed in
                NewsNavigationItem(
                    id: "feed-\(feed.id)",
                    title: feedTitle(feed.id),
                    systemImage: "dot.radiowaves.left.and.right",
                    scope: .feed(feed.id),
                    count: store.feedCounts[feed.id] ?? 0,
                    children: nil
                )
            }
        )
    }

    private func feedTitle(_ feedID: Int64) -> String {
        store.catalog.feeds.first { $0.id == feedID }?.title ?? "Feed"
    }

    @ViewBuilder
    private func scopeRow(_ title: String, systemImage: String, scope: BrowserScope, count: UInt64) -> some View {
        let label = Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text(count > 999 ? "999+" : "\(count)").foregroundStyle(.secondary).font(.caption) }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        if presentation == .stack {
            NavigationLink(value: scope) { label }
                .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
        } else {
            label
                .tag(scope)
                .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
        }
    }
}

private struct NewsNavigationItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let scope: BrowserScope
    let count: UInt64
    let children: [NewsNavigationItem]?
}
