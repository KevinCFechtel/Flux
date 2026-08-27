import AppKit
import SwiftUI

enum PopoverLayout {
    static let rowWidth: CGFloat = 620
    static let cardWidth: CGFloat = 390
    static let sidebarWidth: CGFloat = 240
    static let rowHeight: CGFloat = 620
    static let cardHeight: CGFloat = 760
    static let verticalScreenMargin: CGFloat = 32
    static let animation: TimeInterval = 0.2

    static func contentWidth(for style: ArticleListStyle) -> CGFloat {
        style == .row ? rowWidth : cardWidth
    }

    static func width(style: ArticleListStyle, sidebarVisible: Bool) -> CGFloat {
        contentWidth(for: style) + (sidebarVisible ? sidebarWidth : 0)
    }
}

private enum ArticleScrollSpace { static let name = "FluxNews.ArticleScroll" }
private struct ArticleFrameKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PopoverContentView: View {
    @ObservedObject var store: BrowserStore
    let layoutChanged: (Bool) -> Void
    let dismiss: () -> Void
    @State private var sidebarVisible = false

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                NavigationSidebar(store: store)
                    .frame(width: PopoverLayout.sidebarWidth)
                    .overlay(alignment: .trailing) { Divider() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ArticlePane(
                store: store,
                sidebarVisible: $sidebarVisible,
                layoutChanged: layoutChanged,
                dismiss: dismiss
            )
            .frame(width: PopoverLayout.contentWidth(for: store.articleListStyle))
        }
        .frame(width: PopoverLayout.width(style: store.articleListStyle, sidebarVisible: sidebarVisible))
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $store.settingsVisible) { SettingsView(store: store) }
        .sheet(isPresented: $store.addFeedVisible) { AddFeedView(store: store) }
        .sheet(isPresented: $store.addCategoryVisible) { AddCategoryView(store: store) }
    }
}

private struct ArticlePane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BrowserStore
    @Binding var sidebarVisible: Bool
    let layoutChanged: (Bool) -> Void
    let dismiss: () -> Void
    @State private var tracker = ScrolloverExposureTracker()
    @State private var frames: [Int64: CGRect] = [:]
    @State private var viewport = CGRect.zero
    @State private var trackerRevision: UInt64
    @State private var selectedID: Int64?
    @State private var scrollPhase = ScrollPhase.idle
    @State private var suppressUntil: TimeInterval = 0
    @State private var scrollPosition = ScrollPosition()
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(store: BrowserStore, sidebarVisible: Binding<Bool>, layoutChanged: @escaping (Bool) -> Void, dismiss: @escaping () -> Void) {
        self.store = store
        _sidebarVisible = sidebarVisible
        self.layoutChanged = layoutChanged
        self.dismiss = dismiss
        _trackerRevision = State(initialValue: store.listPresentationRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background {
            if store.articles.isEmpty {
                KeyboardCommandObserver { command in
                    if command == .refresh { store.sync() }
                    if command == .dismiss { dismiss() }
                }
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            if let confirmation = store.actionConfirmation {
                Text(confirmation)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 12)
            } else if store.newDataAvailable {
                updateBanner.padding(.bottom, 12)
            } else if store.scrolloverUndoVisible {
                undoBanner.padding(.bottom, 12)
            }
        }
        .onChange(of: store.listPresentationRevision) { _, revision in
            tracker.reset()
            trackerRevision = revision
            selectedID = nil
            suppressUntil = ProcessInfo.processInfo.systemUptime + 0.4
        }
        .onChange(of: store.popoverVisible) { _, _ in tracker.reset() }
        .onChange(of: store.articles.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .onReceive(timer) { _ in observe() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help(sidebarVisible ? "Hide navigation" : "Show navigation")
                .accessibilityLabel(sidebarVisible ? "Hide navigation" : "Show navigation")
            Text(title).font(.headline).lineLimit(1)
            Text("\(store.selectionTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { store.sync() } label: {
                if store.isLoading { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
            .help("Refresh Miniflux now")
            .accessibilityLabel("Refresh")
            Menu {
                Button { store.setUnreadOnly(true) } label: { Label("Show Unread News Only", systemImage: store.unreadOnly ? "checkmark.circle.fill" : "circle") }
                Button { store.setUnreadOnly(false) } label: { Label("Show All News", systemImage: store.unreadOnly ? "circle" : "checkmark.circle.fill") }
                Divider()
                Menu {
                    Button { store.setNewestFirst(true) } label: { Label("Newest First", systemImage: "arrow.down") }
                    Button { store.setNewestFirst(false) } label: { Label("Oldest First", systemImage: "arrow.up") }
                } label: { Label("Sort Order", systemImage: "arrow.up.arrow.down") }
                Menu {
                    Button { setArticleListStyle(.row) } label: { Label("Rows", systemImage: store.articleListStyle == .row ? "checkmark" : "list.bullet") }
                    Button { setArticleListStyle(.card) } label: { Label("Cards", systemImage: store.articleListStyle == .card ? "checkmark" : "rectangle.grid.1x2") }
                } label: { Label("Layout", systemImage: "rectangle.3.group") }
                Button { store.settingsVisible = true } label: { Label("Settings...", systemImage: "gearshape") }
                Divider()
                Button { NSApplication.shared.terminate(nil) } label: { Label("Quit FluxNews", systemImage: "power") }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Settings...")
            .accessibilityLabel("Settings...")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if store.isSearchActive {
            SearchResultsView(store: store)
        } else if let error = store.errorMessage, store.articles.isEmpty {
            ContentUnavailableView("Refresh failed", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isLoading && store.articles.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Miniflux...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.articles.isEmpty {
            ContentUnavailableView("No articles", systemImage: "tray", description: Text("There are no articles in this selection."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: store.articleListStyle == .row ? 0 : 4) {
                            ForEach(store.articles, id: \.id) { article in
                                ArticleItem(article: article, style: store.articleListStyle, selected: selectedID == article.id, store: store, onSelect: { selectedID = article.id })
                                    .id(article.id)
                                    .background {
                                        GeometryReader { row in
                                            Color.clear.preference(key: ArticleFrameKey.self, value: [article.id: row.frame(in: .named(ArticleScrollSpace.name))])
                                        }
                                    }
                                if store.articleListStyle == .row { Divider().padding(.leading, 264) }
                            }
                        }
                    }
                    .scrollPosition($scrollPosition)
                    .coordinateSpace(name: ArticleScrollSpace.name)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in scrollChanged(new - old) }
                    .onScrollPhaseChange { previous, phase in
                        if !isUserScrollPhase(previous), isUserScrollPhase(phase) {
                            store.beginScrolloverUndoBatch()
                        }
                        if isUserScrollPhase(previous), !isUserScrollPhase(phase) {
                            store.finishScrolloverUndoBatch()
                        }
                        scrollPhase = phase
                        if !userScrolling { tracker.rebase(frames: frames, unread: unreadIDs) }
                    }
                    .onChange(of: store.snapshotResetRevision) { _, revision in
                        NativeLog.snapshot.debug("snapshot reset requested revision=\(revision, privacy: .public)")
                        tracker.reset()
                        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.4
                        scrollPosition.scrollTo(edge: .top)
                        NativeLog.snapshot.debug("snapshot reset completed revision=\(revision, privacy: .public)")
                    }
                    .background { KeyboardCommandObserver { command in handle(command, proxy: proxy) } }
                    .onAppear { viewport = CGRect(origin: .zero, size: geometry.size); observe() }
                    .onChange(of: geometry.size) { _, size in viewport = CGRect(origin: .zero, size: size); tracker.reset() }
                    .onPreferenceChange(ArticleFrameKey.self) { newFrames in
                        frames = newFrames
                        if !userScrolling { tracker.rebase(frames: newFrames, unread: unreadIDs) }
                        observe()
                    }
                }
            }
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 10) { Text("New articles available"); Button("Refresh") { store.applyNewData() }.buttonStyle(.borderless) }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).shadow(radius: 4, y: 2)
    }

    private var undoBanner: some View {
        HStack(spacing: 10) { Text("\(store.lastScrolloverBatch.count) articles marked as read"); Button("Undo") { store.undoScrollover() }.buttonStyle(.borderless) }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).shadow(radius: 4, y: 2)
    }

    private var title: String {
        switch store.scope {
        case .all: "All News"
        case .starred: "Starred"
        case .search: "Search"
        case let .category(id): store.catalog.categories.first(where: { $0.id == id })?.title ?? "Category"
        case let .feed(id): store.catalog.feeds.first(where: { $0.id == id })?.title ?? "Feed"
        }
    }

    private var unreadIDs: Set<Int64> { Set(store.articles.filter { !$0.isRead }.map(\.id)) }
    private var userScrolling: Bool { scrollPhase != .idle && scrollPhase != .animating }
    private func isUserScrollPhase(_ phase: ScrollPhase) -> Bool { phase != .idle && phase != .animating }
    private func setArticleListStyle(_ style: ArticleListStyle) { store.setArticleListStyle(style); layoutChanged(sidebarVisible) }
    private func toggleSidebar() {
        if reduceMotion { sidebarVisible.toggle() }
        else { withAnimation(.easeInOut(duration: PopoverLayout.animation)) { sidebarVisible.toggle() } }
        layoutChanged(sidebarVisible)
    }
    private func observe() {
        guard !store.isSearchActive, store.popoverVisible, store.markReadOnScrolloverEnabled, ProcessInfo.processInfo.systemUptime >= suppressUntil, !viewport.isEmpty else { return }
        tracker.observe(frames: frames, viewport: viewport, unread: unreadIDs, now: Date.timeIntervalSinceReferenceDate)
    }
    private func scrollChanged(_ delta: CGFloat) {
        guard userScrolling else { tracker.rebase(frames: frames, unread: unreadIDs); observe(); return }
        store.noteMeaningfulInteraction()
        guard !store.isSearchActive, store.markReadOnScrolloverEnabled, ProcessInfo.processInfo.systemUptime >= suppressUntil, trackerRevision == store.listPresentationRevision else { return }
        let ids = tracker.process(frames: frames, viewport: viewport, unread: unreadIDs, now: Date.timeIntervalSinceReferenceDate, offsetDelta: delta, userInitiated: true)
        if !ids.isEmpty { store.flushScrollover(ids) }
    }
    private func handle(_ command: ArticleKeyboardCommand, proxy: ScrollViewProxy) {
        switch command {
        case .moveUp: move(-1, proxy)
        case .moveDown: move(1, proxy)
        case .open: if let article = selected { store.open(article) }
        case .openDetail: if let article = selected { store.openDetail(article) }
        case .toggleRead: if !store.isSearchActive, let article = selected { store.setRead(article, !article.isRead) }
        case .toggleStarred: if let article = selected { store.setStarred(article, !article.isStarred) }
        case .refresh: store.sync()
        case .dismiss: dismiss()
        }
    }
    private var selected: ArticleSummary? { selectedID.flatMap { id in store.articles.first { $0.id == id } } }
    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !store.articles.isEmpty else { return }
        let current = selectedID.flatMap { id in store.articles.firstIndex { $0.id == id } }
        let index = min(max(0, (current ?? (delta < 0 ? store.articles.count : -1)) + delta), store.articles.count - 1)
        selectedID = store.articles[index].id
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.4
        tracker.reset()
        proxy.scrollTo(store.articles[index].id, anchor: .center)
    }
}

private struct SearchResultsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search Miniflux", text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.submitSearch() }
                if !store.searchQuery.isEmpty {
                    Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(12)

            if let error = store.errorMessage {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isSearching && store.articles.isEmpty {
                ProgressView("Searching Miniflux...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasSearched {
                ContentUnavailableView("Search Miniflux", systemImage: "magnifyingglass", description: Text("Enter a query and press Return."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.articles.isEmpty {
                ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text("No Miniflux entries matched your search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Text("\(store.searchTotal) results").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
                    ScrollView {
                        LazyVStack(spacing: store.articleListStyle == .row ? 0 : 4) {
                            ForEach(store.articles, id: \.id) { article in
                                ArticleItem(article: article, style: store.articleListStyle, selected: false, store: store, onSelect: {})
                                    .onAppear { if article.id == store.articles.last?.id { store.loadMoreSearchResults() } }
                                if store.articleListStyle == .row { Divider().padding(.leading, 264) }
                            }
                            if store.isSearching { ProgressView().padding() }
                        }
                    }
                }
            }
        }
    }
}

private struct NavigationSidebar: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectedScope) {
                Section {
                    sidebarRow(SidebarItem(id: "all", scope: .all, title: "All News", count: store.unreadTotal, systemImage: "tray.full", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
                    sidebarRow(SidebarItem(id: "starred", scope: .starred, title: "Starred", count: store.starredTotal, systemImage: "star.fill", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
                    sidebarRow(SidebarItem(id: "search", scope: .search, title: "Search", count: 0, systemImage: "magnifyingglass", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
                }
                Section("Feeds") {
                    OutlineGroup(categoryItems, children: \.children) { item in sidebarRow(item) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button { store.addFeedVisible = true } label: { Label("Add Feed...", systemImage: "plus") }
                Button { store.addCategoryVisible = true } label: { Label("Add Category...", systemImage: "folder.badge.plus") }
            }
            .buttonStyle(.plain)
            .labelStyle(SidebarManagementLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(.regularMaterial)
    }

    private var selectedScope: Binding<BrowserScope?> {
        Binding { store.scope } set: { scope in if let scope { store.select(scope) } }
    }
    private var categoryItems: [SidebarItem] {
        store.catalog.categories.map { category in
            let feeds = store.catalog.feeds.filter { $0.categoryId == category.id }
            return SidebarItem.category(
                category,
                count: store.categorySidebarCounts[category.id] ?? 0,
                pendingNewCount: PendingNewDataAggregation.count(feedIDs: feeds.map(\.id), pendingByFeed: store.pendingNewByFeed),
                feeds: feeds.map { SidebarItem.feed($0, count: store.feedSidebarCounts[$0.id] ?? 0, pendingNewCount: store.pendingNewByFeed[$0.id] ?? 0) }
            )
        }
    }
    @ViewBuilder private func sidebarRow(_ item: SidebarItem) -> some View {
        if item.feedID != nil || item.categoryID != nil {
            sidebarLabel(item, showUnreadText: true)
        } else {
            sidebarLabel(item, showUnreadText: false)
                .badge(Int(item.count))
        }
    }
    private func sidebarLabel(_ item: SidebarItem, showUnreadText: Bool) -> some View {
        Button { store.select(item.scope) } label: {
            HStack(spacing: 8) {
                if let image = item.systemImage { Image(systemName: image).frame(width: 16) }
                else if let feedID = item.feedID { FeedIconSlot(feedID: feedID, store: store) }
                Text(item.title).lineLimit(1)
                Spacer(minLength: 0)
                if showUnreadText, item.count > 0 {
                    Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if item.pendingNewCount > 0 {
                    NewDataIndicator(count: item.pendingNewCount)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .tag(item.scope)
    }
}

private struct NewDataIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus")
            Text("\(count) new")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) new articles")
    }
}

private struct SidebarManagementLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.frame(width: 25)
            configuration.title
        }
    }
}

private struct SidebarItem: Identifiable {
    let id: String
    let scope: BrowserScope
    let title: String
    let count: UInt64
    let systemImage: String?
    let feedID: Int64?
    let categoryID: Int64?
    let pendingNewCount: Int
    let children: [SidebarItem]?

    static func category(_ category: Category, count: UInt64, pendingNewCount: Int, feeds: [SidebarItem]) -> SidebarItem {
        SidebarItem(id: "category-\(category.id)", scope: .category(category.id), title: category.title, count: count, systemImage: nil, feedID: nil, categoryID: category.id, pendingNewCount: pendingNewCount, children: feeds.isEmpty ? nil : feeds)
    }
    static func feed(_ feed: Feed, count: UInt64, pendingNewCount: Int) -> SidebarItem {
        SidebarItem(id: "feed-\(feed.id)", scope: .feed(feed.id), title: feed.title, count: count, systemImage: nil, feedID: feed.id, categoryID: nil, pendingNewCount: pendingNewCount, children: nil)
    }
}

private struct ArticleItem: View {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    let article: ArticleSummary
    let style: ArticleListStyle
    let selected: Bool
    @ObservedObject var store: BrowserStore
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View { style == .row ? AnyView(row) : AnyView(card) }
    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { onSelect(); store.open(article) } label: {
                HStack(alignment: .top, spacing: 12) {
                    if article.imageUrl != nil, !store.unavailableArticleThumbnails.contains(store.articleThumbnailKey(article)) {
                        ThumbnailSlot(article: article, store: store, width: 240, height: 168)
                    }
                    textComposition
                }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            quickActions.opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle()).background(interactionBackground)
        .onHover { hovered = $0 }.contextMenu { actionMenu }
        .onDisappear { store.retryUnavailableArticleThumbnail(article) }
    }
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if article.imageUrl != nil, !store.unavailableArticleThumbnails.contains(store.articleThumbnailKey(article)) {
                Button { onSelect(); store.open(article) } label: { ThumbnailSlot(article: article, store: store, width: PopoverLayout.cardWidth - 24, height: 206, cornerRadius: 10) }
                    .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 10) {
                Button { onSelect(); store.open(article) } label: { textComposition.contentShape(Rectangle()) }.buttonStyle(.plain)
                quickActions.opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading).background(interactionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle()).onHover { hovered = $0 }.contextMenu { actionMenu }
        .onDisappear { store.retryUnavailableArticleThumbnail(article) }
    }
    private var textComposition: some View {
        VStack(alignment: .leading, spacing: 5) {
            metadata
            Text(article.title).font(.system(size: 14, weight: article.isRead ? .regular : .semibold))
                .foregroundStyle(article.isRead ? .secondary : .primary).lineLimit(3).multilineTextAlignment(.leading)
            if !article.preview.isEmpty { Text(article.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var metadata: some View {
        HStack(spacing: 5) {
            FeedIconSlot(feedID: article.feedId, store: store)
            Text(article.feedTitle).lineLimit(1)
            Text("·")
            Text(relativeDate)
            if !article.commentsUrl.isEmpty { Image(systemName: "bubble.left") }
            if article.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Unstar") }
        }
        .font(.caption).foregroundStyle(article.isRead ? .tertiary : .secondary)
    }
    private var quickActions: some View {
        VStack(spacing: 8) {
            if !store.isSearchActive {
                iconButton(article.isRead ? "circle.fill" : "checkmark.circle", label: article.isRead ? "Mark as Unread" : "Mark as Read") { store.setRead(article, !article.isRead) }
            }
            iconButton(article.isStarred ? "star.fill" : "star", label: article.isStarred ? "Unstar" : "Star") { store.setStarred(article, !article.isStarred) }
            Menu { actionMenu } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("More").accessibilityLabel("More")
        }
    }
    private var interactionBackground: Color { selected ? Color.accentColor.opacity(0.16) : hovered ? Color.primary.opacity(0.055) : .clear }
    @ViewBuilder private var actionMenu: some View {
        Button { store.open(article) } label: { Label("Open in Browser", systemImage: "safari") }
        Button { store.openDetail(article) } label: { Label("Open Detail View", systemImage: "doc.text") }
        Button { store.setStarred(article, !article.isStarred) } label: { Label(article.isStarred ? "Unstar" : "Star", systemImage: article.isStarred ? "star.slash" : "star") }
        if !store.isSearchActive {
            Button { store.setRead(article, !article.isRead) } label: { Label(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? "circle.fill" : "checkmark.circle") }
            Button { store.saveToService(article) } label: { Label("Save to Third-Party Service", systemImage: "tray.and.arrow.down") }
            Divider()
            Button { store.copyLink(article) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button { store.share(article) } label: { Label("Share...", systemImage: "square.and.arrow.up") }
            Button { store.openInMiniflux(article) } label: { Label("Open in Miniflux", systemImage: "arrow.up.forward.app") }
            Button { store.select(.feed(article.feedId)) } label: { Label("Show Feed", systemImage: "line.3.horizontal.decrease.circle") }
            if !article.commentsUrl.isEmpty { Button { store.openComments(article) } label: { Label("Open Comments", systemImage: "bubble.left") } }
        }
    }
    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
    private var relativeDate: String {
        guard let date = Self.isoFormatter.date(from: article.publishedAt) else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ThumbnailSlot: View {
    let article: ArticleSummary
    @ObservedObject var store: BrowserStore
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 7
    var body: some View {
        ZStack {
            if let image = store.articleThumbnails[store.articleThumbnailKey(article)] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.secondary.opacity(0.10))
                RoundedRectangle(cornerRadius: cornerRadius).fill(.primary.opacity(0.035))
            }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel("Article thumbnail")
        .onAppear { store.requestArticleThumbnail(article) }
    }
}

private struct FeedIconSlot: View {
    @Environment(\.colorScheme) private var colorScheme
    let feedID: Int64
    @ObservedObject var store: BrowserStore
    var body: some View {
        let dark = colorScheme == .dark
        let key = "\(feedID)-\(dark ? "dark" : "normal")"
        Group {
            if let data = store.feedIcons[key], let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel("Feed icon")
        .onAppear { store.requestFeedIcon(feedID, darkAppearance: dark) }
        .onChange(of: colorScheme) { _, appearance in
            store.requestFeedIcon(feedID, darkAppearance: appearance == .dark)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case account
    case syncStorage
    case reading
    case systemNotifications
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .syncStorage: "Sync & Storage"
        case .reading: "Reading"
        case .systemNotifications: "System Notifications"
        case .general: "General"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @State private var server = ""
    @State private var key = ""
    @State private var scrollover = true
    @State private var syncOnStart = true
    @State private var launchAtLogin = false
    @State private var globalShortcut = GlobalShortcutChoice.optionCommandF
    @State private var section: SettingsSection = .account

    var body: some View {
        VStack(spacing: 0) {
            Text("FluxNews Settings")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            NavigationSplitView {
                SettingsSidebar(selection: $section)
            } detail: {
                settingsPage
                    .padding(20)
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { store.settingsVisible = false }; Button("Save") { store.setScrolloverEnabled(scrollover); store.setSyncOnStartEnabled(syncOnStart); store.setGlobalShortcut(globalShortcut); if store.configure(server: server.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), launchAtLogin: launchAtLogin) { store.settingsVisible = false } }.keyboardShortcut(.defaultAction).disabled(server.isEmpty || key.isEmpty) }
                .padding(16)
        }
        .frame(width: 700, height: 430)
        .onAppear {
            if let credentials = try? CredentialStore.load() { server = credentials.server; key = credentials.apiKey }
            launchAtLogin = CredentialStore.launchAtLoginEnabled
            scrollover = store.markReadOnScrolloverEnabled
            syncOnStart = store.syncOnStartEnabled
            globalShortcut = store.globalShortcut
        }
    }
    @ViewBuilder private var settingsPage: some View {
        switch section {
        case .account:
            AccountSettingsView(server: $server, key: $key)
        case .syncStorage:
            SyncStorageSettingsView(store: store, syncOnStart: $syncOnStart, retention: retention, deliveryMode: deliveryMode, backgroundSyncEnabled: backgroundSyncEnabled)
        case .reading:
            ReadingSettingsView(scrollover: $scrollover)
        case .systemNotifications:
            SystemNotificationsSettingsView(store: store)
        case .general:
            GeneralSettingsView(launchAtLogin: $launchAtLogin, globalShortcut: $globalShortcut, registrationError: store.globalShortcutRegistrationError)
        }
    }
    private var retention: Binding<ReadArticleRetention> {
        Binding(
            get: { store.coreSettings?.retention ?? .days90 },
            set: { store.setRetention($0) }
        )
    }
    private var deliveryMode: Binding<DeliveryMode> {
        Binding(
            get: { store.coreSettings?.deliveryMode ?? .deferred },
            set: { store.setDeliveryMode($0) }
        )
    }
    private var backgroundSyncEnabled: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.backgroundSyncEnabled ?? false },
            set: { store.setBackgroundSyncEnabled($0) }
        )
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    Text(section.title)
                        .foregroundStyle(section == selection ? .white : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(section == selection ? Color.accentColor : .clear)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 190)
    }
}

private struct AccountSettingsView: View {
    @Binding var server: String
    @Binding var key: String

    var body: some View {
        Form {
            LabeledContent("Miniflux Server") { TextField("", text: $server) }
            LabeledContent("API Key") { SecureField("", text: $key) }
            Text("Credentials are stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SyncStorageSettingsView: View {
    @ObservedObject var store: BrowserStore
    @Binding var syncOnStart: Bool
    let retention: Binding<ReadArticleRetention>
    let deliveryMode: Binding<DeliveryMode>
    let backgroundSyncEnabled: Binding<Bool>

    var body: some View {
        Form {
            Toggle("Background Sync", isOn: backgroundSyncEnabled)
                .disabled(store.coreSettings == nil)
            Toggle("Sync on Start", isOn: $syncOnStart)
            Picker("Mutation Delivery", selection: deliveryMode) {
                Text("Deferred").tag(DeliveryMode.deferred)
                Text("Live").tag(DeliveryMode.live)
            }
            .disabled(store.coreSettings == nil)
            Picker("Retention", selection: retention) {
                Text("30 days").tag(ReadArticleRetention.days30)
                Text("60 days").tag(ReadArticleRetention.days60)
                Text("90 days").tag(ReadArticleRetention.days90)
                Text("180 days").tag(ReadArticleRetention.days180)
                Text("365 days").tag(ReadArticleRetention.days365)
            }
            .disabled(store.coreSettings == nil)
        }
        .formStyle(.grouped)
    }
}

private struct ReadingSettingsView: View {
    @Binding var scrollover: Bool

    var body: some View {
        Form {
            Toggle("Mark articles as read when scrolling past", isOn: $scrollover)
        }
        .formStyle(.grouped)
    }
}

private struct SystemNotificationsSettingsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Notifications").font(.title2.bold())
            Text("Choose which feeds may send macOS notifications.")
                .foregroundStyle(.secondary)
            if let error = store.systemNotificationSettingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if store.systemNotificationSettings.isEmpty {
                ContentUnavailableView("No feeds available.", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.systemNotificationSettings, id: \.feedId) { setting in
                    Toggle(setting.feedTitle, isOn: Binding(
                        get: { setting.systemNotificationsEnabled },
                        set: { store.setSystemNotificationsEnabled(feedID: setting.feedId, enabled: $0) }
                    ))
                    .disabled(store.updatingSystemNotificationFeedIDs.contains(setting.feedId))
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .onAppear { store.reloadSystemNotificationSettings() }
    }
}

private struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var globalShortcut: GlobalShortcutChoice
    let registrationError: String?

    var body: some View {
        Form {
            Toggle("Launch automatically at login", isOn: $launchAtLogin)
            Picker("Global Shortcut", selection: $globalShortcut) {
                ForEach(GlobalShortcutChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let registrationError {
                Text(registrationError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BrowserStore
    @State private var form = AddFeedForm()
    @State private var candidates: [DiscoveredSubscription] = []
    @State private var selectedCandidateIndex: Int?
    @State private var isDiscovering = false
    @State private var isCreating = false
    @State private var message: String?
    @State private var advancedVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if candidates.isEmpty {
                formContent
            } else {
                candidateContent
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack {
                if !candidates.isEmpty {
                    Button("Back") { candidates = []; selectedCandidateIndex = nil; message = nil }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                if candidates.isEmpty {
                    Button(isDiscovering ? "Discovering..." : "Continue") { discover() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isDiscovering || isCreating || form.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(isCreating ? "Adding..." : "Add Feed") { createSelectedCandidate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCandidateIndex == nil || isCreating)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Feed").font(.title2.bold())
            Text("Enter a website or feed URL. Flux asks Miniflux to discover available subscriptions.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("URL") { TextField("https://example.com", text: $form.url) }
            LabeledContent("Category") {
                Picker("Category", selection: $form.categoryID) {
                    Text("Use Miniflux default").tag(nil as Int64?)
                    ForEach(store.catalog.categories, id: \.id) { category in
                        Text(category.title).tag(Optional(category.id))
                    }
                }
                .labelsHidden()
            }
            DisclosureGroup("Advanced", isExpanded: $advancedVisible) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Username") { TextField("Optional", text: $form.username) }
                    LabeledContent("Password") { SecureField("Optional", text: $form.password) }
                    LabeledContent("User Agent") { TextField("Optional", text: $form.userAgent) }
                    optionalBooleanPicker("Crawler", selection: $form.crawler)
                    LabeledContent("Scraper Rules") { TextField("Optional", text: $form.scraperRules, axis: .vertical).lineLimit(2...4) }
                    LabeledContent("Rewrite Rules") { TextField("Optional", text: $form.rewriteRules, axis: .vertical).lineLimit(2...4) }
                    LabeledContent("Blocklist Rules") { TextField("Optional", text: $form.blocklistRules, axis: .vertical).lineLimit(2...4) }
                    LabeledContent("Keeplist Rules") { TextField("Optional", text: $form.keeplistRules, axis: .vertical).lineLimit(2...4) }
                    optionalBooleanPicker("Disabled", selection: $form.disabled)
                    optionalBooleanPicker("Ignore HTTP Cache", selection: $form.ignoreHttpCache)
                    optionalBooleanPicker("Fetch Via Proxy", selection: $form.fetchViaProxy)
                }
                .padding(.top, 10)
            }
        }
    }

    private var candidateContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Feed").font(.title2.bold())
            Text("Miniflux found multiple subscriptions for this URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(candidates.indices, id: \.self, selection: $selectedCandidateIndex) { index in
                let candidate = candidates[index]
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title.isEmpty ? candidate.url : candidate.title).fontWeight(.medium)
                    Text(candidate.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !candidate.feedType.isEmpty { Text(candidate.feedType.uppercased()).font(.caption2).foregroundStyle(.tertiary) }
                }
                .tag(Optional(index))
            }
            .frame(height: 220)
        }
    }

    private func optionalBooleanPicker(_ title: String, selection: Binding<AddFeedOptionalBoolean>) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach(AddFeedOptionalBoolean.allCases) { value in Text(value.title).tag(value) }
            }
            .labelsHidden()
        }
    }

    private func discover() {
        message = nil
        isDiscovering = true
        store.discoverSubscriptions(form.discoveryRequest()) { result in
            isDiscovering = false
            switch result {
            case let .success(subscriptions):
                switch AddFeedDiscoveryOutcome.from(subscriptions) {
                case .none:
                    showError("Miniflux did not find a subscription for this URL.")
                case let .automatic(subscription):
                    create(feedURL: subscription.url)
                case .choose:
                    candidates = subscriptions
                }
            case let .failure(error):
                showError("Could not discover feeds: \(error.localizedDescription)")
            }
        }
    }

    private func createSelectedCandidate() {
        guard let selectedCandidateIndex else { return }
        create(feedURL: candidates[selectedCandidateIndex].url)
    }

    private func create(feedURL: String) {
        message = nil
        isCreating = true
        store.createFeed(form.createRequest(feedURL: feedURL)) { result in
            isCreating = false
            switch result {
            case .success:
                store.showActionConfirmation("Feed added. It will appear after the next refresh.")
                dismiss()
            case let .failure(error):
                showError("Could not add feed: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        self.message = message
        store.errorMessage = message
    }
}

private struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BrowserStore
    @State private var title = ""
    @State private var isCreating = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Category").font(.title2.bold())
            LabeledContent("Name") { TextField("Category name", text: $title) }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isCreating ? "Adding..." : "Add") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        message = nil
        isCreating = true
        store.createCategory(title) { result in
            isCreating = false
            switch result {
            case .success:
                store.showActionConfirmation("Category added. It will appear after the next refresh.")
                dismiss()
            case let .failure(error):
                let message = "Could not add category: \(error.localizedDescription)"
                self.message = message
                store.errorMessage = message
            }
        }
    }
}
