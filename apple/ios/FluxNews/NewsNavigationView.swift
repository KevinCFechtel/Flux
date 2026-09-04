import SwiftUI

enum NewsNavigationPresentation: Equatable {
    case sidebar
    case sheet
}

struct NewsNavigationView: View {
    @ObservedObject var store: NewsreaderStore
    @Binding var iPhoneSheetPresented: Bool
    let presentation: NewsNavigationPresentation
    let onSearch: () -> Void

    init(store: NewsreaderStore, iPhoneSheetPresented: Binding<Bool>, presentation: NewsNavigationPresentation, onSearch: @escaping () -> Void = {}) {
        self.store = store
        self._iPhoneSheetPresented = iPhoneSheetPresented
        self.presentation = presentation
        self.onSearch = onSearch
    }

    var body: some View {
        if presentation == .sidebar {
            sidebarList
        } else {
            sheetList
        }
    }

    private var sidebarList: some View {
        List(selection: selection) {
            navigationRows
        }
        .listStyle(.sidebar)
        .navigationTitle("News")
    }

    private var sheetList: some View {
        List(selection: selection) {
            Section("News") {
                searchRow
                scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
                scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
                scopeRow("Listening List", systemImage: "headphones", scope: .listeningList, count: 0)
            }
            Section("Feeds") {
                ForEach(groups) { group in
                    if group.categoryID != nil {
                        OutlineGroup([sidebarItem(for: group)], children: \.children) { item in
                            if item.children != nil {
                                categoryRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                            } else {
                                scopeRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                            }
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

    @ViewBuilder
    private var navigationRows: some View {
        Section {
            searchRow
            scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
            scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
        }
        Section("Feeds") {
            ForEach(groups) { group in
                if group.categoryID != nil {
                    OutlineGroup([sidebarItem(for: group)], children: \.children) { item in
                        if item.children != nil {
                            categoryRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                        } else {
                            scopeRow(item.title, systemImage: item.systemImage, scope: item.scope, count: item.count)
                        }
                    }
                } else {
                    ForEach(group.feeds, id: \.id) { feed in
                        scopeRow(feedTitle(feed.id), systemImage: "dot.radiowaves.left.and.right", scope: .feed(feed.id), count: store.feedCounts[feed.id] ?? 0)
                    }
                }
            }
        }
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

    private var searchRow: some View {
        Button {
            onSearch()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("navigation.search")
    }

    @ViewBuilder
    private func scopeRow(_ title: String, systemImage: String, scope: BrowserScope, count: UInt64) -> some View {
        scopeLabel(title, systemImage: systemImage, count: count)
            .tag(scope)
            .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
    }

    private func categoryRow(_ title: String, systemImage: String, scope: BrowserScope, count: UInt64) -> some View {
        Button {
            store.select(scope)
            iPhoneSheetPresented = false
        } label: {
            scopeLabel(title, systemImage: systemImage, count: count)
        }
        .buttonStyle(.plain)
        .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
    }

    @ViewBuilder
    private func scopeLabel(_ title: String, systemImage: String, count: UInt64) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text(count > 999 ? "999+" : "\(count)").foregroundStyle(.secondary).font(.caption) }
            }
        } icon: {
            Image(systemName: systemImage)
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
