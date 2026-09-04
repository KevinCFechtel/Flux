import SwiftUI

enum NewsNavigationPresentation: Equatable { case sidebar, sheet }

enum NewsNavigationSelection {
    static func isSelected(_ rowScope: BrowserScope, activeScope: BrowserScope) -> Bool { rowScope == activeScope }
}

struct NewsNavigationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: NewsreaderStore
    @Binding var iPhoneSheetPresented: Bool
    let presentation: NewsNavigationPresentation
    let onSearch: () -> Void
    @State private var addDestination: IOSNavigationAddDestination?
    @State private var feedSettingsTarget: IOSFeedSettingsTarget?

    init(store: NewsreaderStore, iPhoneSheetPresented: Binding<Bool>, presentation: NewsNavigationPresentation, onSearch: @escaping () -> Void = {}) {
        self.store = store
        self._iPhoneSheetPresented = iPhoneSheetPresented
        self.presentation = presentation
        self.onSearch = onSearch
    }

    var body: some View {
        Group {
            if presentation == .sidebar { listContent.listStyle(.sidebar) }
            else { listContent.listStyle(.insetGrouped) }
        }
        .navigationTitle("News")
        .toolbar { addToolbar }
        .sheet(item: $addDestination) { destination in NavigationStack { addView(destination) } }
        .sheet(item: $feedSettingsTarget) { target in NavigationStack { IOSFeedSettingsView(store: store, target: target) } }
    }

    private var listContent: some View {
        List(selection: selection) {
            Section("News") {
                searchRow
                scopeRow("All News", systemImage: "newspaper", scope: .all, count: store.unreadTotal)
                scopeRow("Starred", systemImage: "star", scope: .starred, count: store.starredTotal)
                if presentation == .sheet { scopeRow("Listening List", systemImage: "headphones", scope: .listeningList, count: 0) }
            }
            Section("Feeds") {
                ForEach(groups) { group in
                    if group.categoryID != nil {
                        OutlineGroup([sidebarItem(for: group)], children: \.children) { item in
                            if item.children != nil { categoryRow(item) }
                            else { feedRow(item.title, feedID: feedID(for: item.scope), count: item.count) }
                        }
                    } else {
                        ForEach(group.feeds, id: \.id) { feed in
                            feedRow(feedTitle(feed.id), feedID: feed.id, count: store.feedCounts[feed.id] ?? 0)
                        }
                    }
                }
            }
        }
    }

    private var selection: Binding<BrowserScope?> {
        Binding(get: { store.scope }, set: { if let value = $0 { store.select(value); iPhoneSheetPresented = false } })
    }

    private var groups: [NavigationPresentationGroup] {
        NavigationVisibility.groups(categories: store.catalog.categories.map { .init(id: $0.id, title: $0.title) }, feeds: store.catalog.feeds.map { .init(id: $0.id, categoryID: $0.categoryId) }, hidingEmpty: store.hideEmptyNavigationEntries, counts: store.feedCounts)
    }

    private func sidebarItem(for group: NavigationPresentationGroup) -> NewsNavigationItem {
        let categoryID = group.categoryID!
        return NewsNavigationItem(id: "category-\(categoryID)", title: group.title, scope: .category(categoryID), count: store.categoryCounts[categoryID] ?? 0, children: group.feeds.map { .init(id: "feed-\($0.id)", title: feedTitle($0.id), scope: .feed($0.id), count: store.feedCounts[$0.id] ?? 0, children: nil) })
    }

    private func feedTitle(_ feedID: Int64) -> String { store.catalog.feeds.first { $0.id == feedID }?.title ?? "Feed" }
    private var searchRow: some View { Button(action: onSearch) { Label("Search", systemImage: "magnifyingglass") }.accessibilityIdentifier("navigation.search") }

    private func scopeRow(_ title: String, systemImage: String, scope: BrowserScope, count: UInt64) -> some View {
        Label { labelTitle(title, count: count) } icon: { Image(systemName: systemImage) }
            .tag(scope)
            .accessibilityValue(count > 0 ? "\(count) unread articles" : "No unread articles")
    }

    private func categoryRow(_ item: NewsNavigationItem) -> some View {
        Button { store.select(item.scope); iPhoneSheetPresented = false } label: {
            Label { labelTitle(item.title, count: item.count) } icon: { Image(systemName: "folder") }
        }
        .buttonStyle(.plain)
        .tag(item.scope)
    }

    private func feedRow(_ title: String, feedID: Int64?, count: UInt64) -> some View {
        let scope = feedID.map(BrowserScope.feed) ?? .all
        return HStack(spacing: 8) {
            if let feedID {
                FeedIconView(feedID: feedID, title: title, data: store.feedIcons[IOSFeedIconKey(feedID: feedID, variant: iconVariant)], onRequest: { store.requestFeedIcon(feedID, variant: iconVariant) }, size: 16)
            }
            labelTitle(title, count: count)
        }
        .tag(scope)
        .contextMenu { if let feedID { Button("Feed Settings") { feedSettingsTarget = .init(id: feedID, title: title) } } }
    }

    private func labelTitle(_ title: String, count: UInt64) -> some View {
        HStack { Text(title); Spacer(); if count > 0 { Text(count > 999 ? "999+" : "\(count)").foregroundStyle(.secondary).font(.caption) } }
    }

    private var iconVariant: FeedIconVariant { IOSFeedIconPresentation.variant(isDark: colorScheme == .dark) }
    private func feedID(for scope: BrowserScope) -> Int64? { if case let .feed(id) = scope { id } else { nil } }

    @ToolbarContentBuilder private var addToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Add Feed", systemImage: "plus") { addDestination = .feed }
                Button("Add Category", systemImage: "folder.badge.plus") { addDestination = .category }
            } label: { Label("Add", systemImage: "plus") }
        }
    }

    @ViewBuilder private func addView(_ destination: IOSNavigationAddDestination) -> some View {
        switch destination {
        case .feed: IOSAddFeedView(store: store)
        case .category: IOSAddCategoryView(store: store)
        }
    }
}

private enum IOSNavigationAddDestination: Identifiable { case feed, category; var id: Self { self } }
private struct NewsNavigationItem: Identifiable { let id: String; let title: String; let scope: BrowserScope; let count: UInt64; let children: [NewsNavigationItem]? }
