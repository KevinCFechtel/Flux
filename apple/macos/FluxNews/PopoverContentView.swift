import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    let playbackState: MediaPlaybackPresentationState
    let playbackCoordinator: MediaPlaybackCoordinator?
    let transferState: MediaTransferPresentationState
    let layoutChanged: (Bool) -> Void
    let dismiss: () -> Void
    @State private var sidebarVisible = false
    @State private var showingPlayer = false

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                NavigationSidebar(store: store, onNavigate: { scope in
                    showingPlayer = false
                    store.select(scope)
                })
                    .frame(width: PopoverLayout.sidebarWidth)
                    .overlay(alignment: .trailing) { Divider() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ArticlePane(
                store: store,
                playbackState: playbackState,
                playbackCoordinator: playbackCoordinator,
                transferState: transferState,
                sidebarVisible: $sidebarVisible,
                showingPlayer: $showingPlayer,
                layoutChanged: layoutChanged,
                dismiss: dismiss
            )
            .frame(width: PopoverLayout.contentWidth(for: store.articleListStyle))
        }
        .frame(width: PopoverLayout.width(style: store.articleListStyle, sidebarVisible: sidebarVisible))
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $store.settingsVisible) { SettingsView(store: store) }
        .sheet(item: $store.feedSettingsTarget) { target in FeedSettingsView(store: store, target: target) }
        .sheet(isPresented: $store.addFeedVisible) { AddFeedView(store: store) }
        .sheet(isPresented: $store.addCategoryVisible) { AddCategoryView(store: store) }
    }
}

private struct ArticlePane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BrowserStore
    let playbackState: MediaPlaybackPresentationState
    let playbackCoordinator: MediaPlaybackCoordinator?
    let transferState: MediaTransferPresentationState
    @Binding var sidebarVisible: Bool
    @Binding var showingPlayer: Bool
    let layoutChanged: (Bool) -> Void
    let dismiss: () -> Void
    @State private var tracker = ScrolloverExposureTracker()
    @State private var frames: [Int64: CGRect] = [:]
    @State private var viewport = CGRect.zero
    @State private var trackerRevision: UInt64
    @State private var selectedID: Int64?
    @State private var hoveredID: Int64?
    @State private var scrollPhase = ScrollPhase.idle
    @State private var suppressUntil: TimeInterval = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var pendingAudioReplacement: Enclosure?
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(store: BrowserStore, playbackState: MediaPlaybackPresentationState, playbackCoordinator: MediaPlaybackCoordinator?, transferState: MediaTransferPresentationState, sidebarVisible: Binding<Bool>, showingPlayer: Binding<Bool>, layoutChanged: @escaping (Bool) -> Void, dismiss: @escaping () -> Void) {
        self.store = store
        self.playbackState = playbackState
        self.playbackCoordinator = playbackCoordinator
        self.transferState = transferState
        _sidebarVisible = sidebarVisible
        _showingPlayer = showingPlayer
        self.layoutChanged = layoutChanged
        self.dismiss = dismiss
        _trackerRevision = State(initialValue: store.listPresentationRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingPlayer {
                PlayerView(store: store, state: playbackState, coordinator: playbackCoordinator)
            } else {
                content
            }
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
        .onChange(of: store.scope) { _, _ in showingPlayer = false }
        .onChange(of: selectedID) { _, articleID in
            store.selectArticleAudioActions(for: articleID)
        }
        .onChange(of: store.popoverVisible) { _, _ in tracker.reset() }
        .onChange(of: store.articles.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .onReceive(timer) { _ in observe() }
        .alert("Replace Playing Audio?", isPresented: Binding(get: { pendingAudioReplacement != nil }, set: { if !$0 { pendingAudioReplacement = nil } })) {
            Button("Cancel", role: .cancel) { pendingAudioReplacement = nil }
            Button("Replace", role: .destructive) {
                if let enclosure = pendingAudioReplacement { pendingAudioReplacement = nil; startAudio(enclosure) }
            }
        } message: {
            Text("The currently playing audio will be replaced.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help(sidebarToggleLabel)
                .accessibilityLabel(sidebarToggleLabel)
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
            PlayerNavigationButton(playbackState: playbackState, showingPlayer: $showingPlayer)
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var moreMenu: some View {
        MoreMenu(
            isListeningList: store.isListeningList,
            unreadOnly: store.unreadOnly,
            newestFirst: store.newestFirst,
            articleListStyle: store.articleListStyle,
            listeningListSort: store.listeningListSort,
            listeningListFeedID: store.listeningListFeedID,
            listeningListFeeds: store.listeningListFeeds,
            setUnreadOnly: store.setUnreadOnly,
            setNewestFirst: store.setNewestFirst,
            setArticleListStyle: setArticleListStyle,
            setListeningListSort: store.setListeningListSort,
            setListeningListFeed: store.setListeningListFeed,
            showSettings: { store.settingsVisible = true },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    private var sidebarToggleLabel: String {
        sidebarVisible ? String(localized: "Hide navigation") : String(localized: "Show navigation")
    }

    @ViewBuilder private var content: some View {
        if store.isListeningList {
            ListeningListView(store: store, playbackState: playbackState, transferState: transferState, onPlay: playAudio, onDownload: { articleID, enclosureID in store.requestManualDownload(articleID: articleID, enclosureID: enclosureID) }, onDelete: { articleID, enclosureID in store.deleteDownload(articleID: articleID, enclosureID: enclosureID) }, onRemove: { articleID in store.removeFromListeningList(articleID: articleID) })
        } else if store.isSearchActive {
             SearchResultsView(store: store, transferState: transferState, onPlay: playAudio, onDownload: { enclosure in store.requestManualDownload(articleID: enclosure.articleId, enclosureID: enclosure.id) }, onDelete: { enclosure in store.deleteDownload(articleID: enclosure.articleId, enclosureID: enclosure.id) }, onAdd: { articleID in store.addToListeningList(articleID: articleID) })
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
                                 ArticleItem(article: article, style: store.articleListStyle, selected: selectedID == article.id, audioState: store.articleAudioActionStates[article.id], transferState: transferState, store: store, onSelect: { selectedID = article.id }, onPlayAudio: playAudio, onDownloadAudio: { enclosure in store.requestManualDownload(articleID: article.id, enclosureID: enclosure.id) }, onDeleteDownload: { enclosure in store.deleteDownload(articleID: article.id, enclosureID: enclosure.id) }, onAddToListeningList: { store.addToListeningList(articleID: article.id) }, onHoverChanged: { hovering in
                                    if hovering { hoveredID = article.id }
                                    else if hoveredID == article.id { hoveredID = nil }
                                })
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
        case .listeningList: "Listening List"
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
        case .openDetail: if let article = readerTarget { store.openDetail(article, togglesPreview: true) }
        case .toggleRead: if !store.isSearchActive, let article = selected { store.setRead(article, !article.isRead) }
        case .toggleStarred: if let article = selected { store.setStarred(article, !article.isStarred) }
        case .refresh: store.sync()
        case .dismiss: dismiss()
        }
    }
    private var selected: ArticleSummary? { selectedID.flatMap { id in store.articles.first { $0.id == id } } }
    private var readerTarget: ArticleSummary? {
        let id = ArticleReaderTarget.articleID(hoveredID: hoveredID, selectedID: selectedID, availableIDs: Set(store.articles.map(\.id)))
        return id.flatMap { targetID in store.articles.first { $0.id == targetID } }
    }
    private func playAudio(_ enclosure: Enclosure) {
        guard playbackCoordinator != nil else { return }
        if ArticleAudioActions.requiresReplacement(currentID: playbackState.loadedEnclosure?.id, currentStatus: playbackState.status, selectedID: enclosure.id) {
            pendingAudioReplacement = enclosure
            return
        }
        startAudio(enclosure)
    }
    private func startAudio(_ enclosure: Enclosure) {
        guard let coordinator = playbackCoordinator else { return }
        do {
            if playbackState.loadedEnclosure?.id == enclosure.id, playbackState.status == .playing {
                showingPlayer = true
                return
            }
            try coordinator.play(enclosureID: enclosure.id)
            showingPlayer = true
        } catch {
            store.errorMessage = NativeErrorPresentation.message(for: error)
        }
    }
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
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Enclosure) -> Void
    let onDelete: (Enclosure) -> Void
    let onAdd: (Int64) -> Void

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
                                ArticleItem(article: article, style: store.articleListStyle, selected: false, audioState: store.articleAudioActionStates[article.id], transferState: transferState, store: store, onSelect: {}, onPlayAudio: onPlay, onDownloadAudio: onDownload, onDeleteDownload: onDelete, onAddToListeningList: { onAdd(article.id) }, onHoverChanged: { _ in })
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

private struct ListeningListView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var playbackState: MediaPlaybackPresentationState
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (Int64, Int64) -> Void
    let onRemove: (Int64) -> Void

    var body: some View {
        if let error = store.errorMessage, store.listeningListItems.isEmpty {
            ContentUnavailableView("Listening List unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.listeningListItems.isEmpty {
            ContentUnavailableView("Listening List is Empty", systemImage: "headphones", description: Text("Audio News added to the Listening List will appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.listeningListItems, id: \.articleId) { item in
                        ListeningListRow(item: item, store: store, playbackState: playbackState, transferState: transferState, onPlay: onPlay, onDownload: onDownload, onDelete: onDelete, onRemove: onRemove)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }
}

private struct ListeningListRow: View {
    let item: ListeningListItem
    @ObservedObject var store: BrowserStore
    @ObservedObject var playbackState: MediaPlaybackPresentationState
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (Int64, Int64) -> Void
    let onRemove: (Int64) -> Void
    @State private var confirmingRemoval = false
    @State private var pendingDeletion: ListeningListEnclosure?
    private static let isoFormatter = ISO8601DateFormatter()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ListeningListPresentation.textOrFallback(item.title, fallback: String(localized: "Untitled News")))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                HStack(spacing: 5) {
                    FeedIconSlot(feedID: item.feedId, store: store)
                    Text(ListeningListPresentation.textOrFallback(item.feedTitle, fallback: String(localized: "Unknown Feed"))).foregroundStyle(.secondary)
                    if let date = Self.isoFormatter.date(from: item.publishedAt) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                progress
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if let enclosure = ListeningListPresentation.preferredEnclosure(item) { onPlay(enclosure) } }
        .contextMenuIf(item.audioEnclosures.count > 1 && item.activeEnclosureId == nil) {
            ForEach(item.audioEnclosures, id: \.enclosure.id) { audio in
                Button("Play \(ArticleAudioActions.enclosureLabel(audio.enclosure, index: item.audioEnclosures.firstIndex(where: { $0.enclosure.id == audio.enclosure.id }) ?? 0))") { onPlay(audio.enclosure) }
            }
        }
        .alert("Remove from Listening List?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { confirmingRemoval = false }
            Button("Remove", role: .destructive) { confirmingRemoval = false; onRemove(item.articleId) }
        } message: {
            Text("Downloaded audio for this item will also be deleted.")
        }
        .alert("Delete Download?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let audio = pendingDeletion { pendingDeletion = nil; onDelete(item.articleId, audio.enclosure.id) }
            }
        } message: {
            Text("The downloaded audio file will be deleted.")
        }
    }

    @ViewBuilder private var progress: some View {
        if let value = ListeningListPresentation.progress(item, runtime: playbackState) {
            if value.status == .completed {
                ProgressView(value: 1)
                    .progressViewStyle(.linear)
                    .tint(.green)
                Text("Completed").foregroundStyle(.secondary)
            } else if let duration = value.durationMs, duration > 0 {
                ProgressView(value: min(Double(value.positionMs) / Double(duration), 1))
                    .progressViewStyle(.linear)
                Text("\(Self.minutes(value.positionMs)) / \(Self.minutes(duration)) min").foregroundStyle(.secondary)
            } else if value.positionMs > 0 {
                Text("\(Self.minutes(value.positionMs)) min").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if ListeningListPresentation.preferredEnclosure(item) == nil {
                Menu {
                    ForEach(item.audioEnclosures.indices, id: \.self) { index in
                        let audio = item.audioEnclosures[index]
                        Button(ArticleAudioActions.enclosureLabel(audio.enclosure, index: index)) { onPlay(audio.enclosure) }
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Choose audio to play")
            }
            let count = ListeningListPresentation.downloadedCount(item)
            HStack(spacing: 4) {
                DownloadControl(item: item, transferState: transferState, onDownload: onDownload, onDelete: { pendingDeletion = $0 })
                if count.total > 1 {
                    Text("\(count.downloaded)/\(count.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                if ArticleAudioActions.hasLocalDownload(item) { confirmingRemoval = true }
                else { onRemove(item.articleId) }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from Listening List")
                .accessibilityLabel("Remove from Listening List")
        }
    }

    private static func minutes(_ milliseconds: UInt64) -> String {
        String(max(0, Int(milliseconds / 60_000)))
    }

}

private struct DownloadControl: View {
    let item: ListeningListItem
    @ObservedObject var transferState: MediaTransferPresentationState
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (ListeningListEnclosure) -> Void
    @State private var hoveredDownloadedID: Int64?

    var body: some View {
        if item.audioEnclosures.isEmpty {
            EmptyView()
        } else if item.audioEnclosures.count == 1, let audio = item.audioEnclosures.first {
            control(for: audio)
        } else {
            Menu {
                ForEach(item.audioEnclosures.indices, id: \.self) { index in
                    let audio = item.audioEnclosures[index]
                    Button {
                        activate(audio)
                    } label: {
                        Label(actionTitle(audio, index: index), systemImage: symbol(for: audio))
                    }
                    .disabled(!isActionable(audio))
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Download")
            .accessibilityLabel("Download")
        }
    }

    @ViewBuilder private func control(for audio: ListeningListEnclosure) -> some View {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        switch action {
        case .downloading:
            ProgressView(value: transferState.runtime(for: audio.enclosure.id)?.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Downloading")
                .accessibilityLabel("Downloading")
        case .pending, .pendingDeletion:
            ProgressView()
                .controlSize(.small)
                .help(action == .pending ? "Download pending" : "Delete Download pending")
                .accessibilityLabel(action == .pending ? "Download pending" : "Delete Download pending")
        default:
            Button { activate(audio) } label: {
                Image(systemName: symbol(for: audio))
                    .foregroundStyle(action == .delete ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isActionable(audio))
            .onHover { isHovered in
                hoveredDownloadedID = isHovered && action == .delete ? audio.enclosure.id : nil
            }
            .help(action == .delete && hoveredDownloadedID == audio.enclosure.id ? "Delete Download" : action == .retry ? "Retry Download" : "Download")
            .accessibilityLabel(action == .delete ? "Downloaded" : action == .retry ? "Retry Download" : "Download")
        }
    }

    private func activate(_ audio: ListeningListEnclosure) {
        if ArticleAudioActions.canDeleteDownload(audio.download) { onDelete(audio) }
        else if ArticleAudioActions.canRequestDownload(audio.download) { onDownload(item.articleId, audio.enclosure.id) }
    }

    private func isActionable(_ audio: ListeningListEnclosure) -> Bool {
        ArticleAudioActions.canRequestDownload(audio.download) || ArticleAudioActions.canDeleteDownload(audio.download)
    }

    private func symbol(for audio: ListeningListEnclosure) -> String {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        if action == .delete && hoveredDownloadedID == audio.enclosure.id { return "trash" }
        switch action {
        case .delete: return "checkmark.circle.fill"
        case .retry: return "arrow.clockwise.circle"
        default: return "arrow.down.circle"
        }
    }

    private func actionTitle(_ audio: ListeningListEnclosure, index: Int) -> String {
        let label = ArticleAudioActions.enclosureLabel(audio.enclosure, index: index)
        switch ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id)) {
        case .delete: return String(localized: "Delete Download: \(label)")
        case .pending: return String(localized: "Download pending: \(label)")
        case .downloading: return String(localized: "Downloading: \(label)")
        case .pendingDeletion: return String(localized: "Delete Download pending: \(label)")
        case .retry: return String(localized: "Retry Download: \(label)")
        case .download: return String(localized: "Download: \(label)")
        }
    }
}

private struct NavigationSidebar: View {
    @ObservedObject var store: BrowserStore
    let onNavigate: (BrowserScope) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectedScope) {
                Section {
                    sidebarRow(SidebarItem(id: "all", scope: .all, title: "All News", count: store.unreadTotal, systemImage: "tray.full", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
                    sidebarRow(SidebarItem(id: "starred", scope: .starred, title: "Starred", count: store.starredTotal, systemImage: "star.fill", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
                    sidebarRow(SidebarItem(id: "listening-list", scope: .listeningList, title: "Listening List", count: 0, systemImage: "headphones", feedID: nil, categoryID: nil, pendingNewCount: 0, children: nil))
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
        Binding { store.scope } set: { scope in if let scope { onNavigate(scope) } }
    }
    private var categoryItems: [SidebarItem] {
        let visibleFeeds = NavigationVisibility.visibleFeeds(
            store.catalog.feeds.map { NavigationPresentationFeed(id: $0.id, categoryID: $0.categoryId) },
            hidingEmpty: store.hideEmptyNavigationEntries,
            counts: store.feedSidebarCounts
        )
        let visibleFeedIDs = Set(visibleFeeds.map(\.id))
        let visibleCategoryIDs = Set(NavigationVisibility.visibleCategoryIDs(store.catalog.categories.map(\.id), feeds: visibleFeeds))
        return store.catalog.categories.compactMap { category in
            guard !store.hideEmptyNavigationEntries || visibleCategoryIDs.contains(category.id) else { return nil }
            let feeds = store.catalog.feeds.filter { $0.categoryId == category.id && visibleFeedIDs.contains($0.id) }
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
        Button { onNavigate(item.scope) } label: {
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
        .contextMenu {
            if FeedSettingsRouting.isAvailable(feedID: item.feedID), let feedID = item.feedID {
                Button("Feed Settings...") {
                    store.feedSettingsTarget = FeedSettingsTarget(id: feedID, title: item.title)
                }
            }
        }
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

private struct PlayerNavigationButton: View {
    @ObservedObject var playbackState: MediaPlaybackPresentationState
    @Binding var showingPlayer: Bool

    var body: some View {
        Button { showingPlayer.toggle() } label: {
            Image(systemName: PlayerPresentation.navigationSymbol(showingPlayer: showingPlayer))
        }
        .buttonStyle(.borderless)
        .disabled(PlayerPresentation.navigationDisabled(showingPlayer: showingPlayer, hasLoadedMedia: playbackState.loadedEnclosure != nil))
        .help(showingPlayer ? "Show News List" : "Show Player")
        .accessibilityLabel(showingPlayer ? "Show News List" : "Show Player")
    }
}

private struct MoreMenu: View {
    let isListeningList: Bool
    let unreadOnly: Bool
    let newestFirst: Bool
    let articleListStyle: ArticleListStyle
    let listeningListSort: ListeningListSort
    let listeningListFeedID: Int64?
    let listeningListFeeds: [ListeningListFeed]
    let setUnreadOnly: (Bool) -> Void
    let setNewestFirst: (Bool) -> Void
    let setArticleListStyle: (ArticleListStyle) -> Void
    let setListeningListSort: (ListeningListSort) -> Void
    let setListeningListFeed: (Int64?) -> Void
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        Menu {
            if isListeningList {
                listeningListFeedFilter
                Menu {
                    Button { setListeningListSort(.recentlyAdded) } label: { Label("Recently Added", systemImage: listeningListSort == .recentlyAdded ? "checkmark" : "clock") }
                    Button { setListeningListSort(.publicationDate) } label: { Label("Publication Date", systemImage: listeningListSort == .publicationDate ? "checkmark" : "calendar") }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            } else {
                Button { setUnreadOnly(true) } label: { Label("Show Unread News Only", systemImage: unreadOnly ? "checkmark.circle.fill" : "circle") }
                Button { setUnreadOnly(false) } label: { Label("Show All News", systemImage: unreadOnly ? "circle" : "checkmark.circle.fill") }
                Divider()
                Menu {
                    Button { setNewestFirst(true) } label: { Label("Newest First", systemImage: newestFirst ? "checkmark" : "arrow.down") }
                    Button { setNewestFirst(false) } label: { Label("Oldest First", systemImage: newestFirst ? "arrow.up" : "checkmark") }
                } label: { Label("Sort Order", systemImage: "arrow.up.arrow.down") }
                Menu {
                    Button { setArticleListStyle(.row) } label: { Label("Rows", systemImage: articleListStyle == .row ? "checkmark" : "list.bullet") }
                    Button { setArticleListStyle(.card) } label: { Label("Cards", systemImage: articleListStyle == .card ? "checkmark" : "rectangle.grid.1x2") }
                } label: { Label("Layout", systemImage: "rectangle.3.group") }
            }
            Divider()
            Button { showSettings() } label: { Label("Settings...", systemImage: "gearshape") }
            Button { quit() } label: { Label("Quit FluxNews", systemImage: "power") }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More")
            .accessibilityLabel("More")
    }

    private var listeningListFeedFilter: some View {
        Menu {
            Button { setListeningListFeed(nil) } label: { Label("All Feeds", systemImage: listeningListFeedID == nil ? "checkmark" : "circle") }
            ForEach(listeningListFeeds, id: \.feedId) { feed in
                Button { setListeningListFeed(feed.feedId) } label: { Label(feed.feedTitle, systemImage: listeningListFeedID == feed.feedId ? "checkmark" : "circle") }
            }
        } label: { Label("Filter by Feed", systemImage: "line.3.horizontal.decrease.circle") }
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
    let audioState: ArticleAudioActionState?
    let transferState: MediaTransferPresentationState?
    @ObservedObject var store: BrowserStore
    let onSelect: () -> Void
    let onPlayAudio: (Enclosure) -> Void
    let onDownloadAudio: (Enclosure) -> Void
    let onDeleteDownload: (Enclosure) -> Void
    let onAddToListeningList: () -> Void
    let onHoverChanged: (Bool) -> Void
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
        .onHover { hovering in hovered = hovering; onHoverChanged(hovering) }.contextMenu { actionMenu }
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
        .contentShape(Rectangle()).onHover { hovering in hovered = hovering; onHoverChanged(hovering) }.contextMenu { actionMenu }
        .onDisappear { store.retryUnavailableArticleThumbnail(article) }
    }
    private var textComposition: some View {
        VStack(alignment: .leading, spacing: 5) {
            metadata
            Text(ListeningListPresentation.textOrFallback(article.title, fallback: String(localized: "Untitled News"))).font(.system(size: 14, weight: article.isRead ? .regular : .semibold))
                .foregroundStyle(article.isRead ? .secondary : .primary).lineLimit(3).multilineTextAlignment(.leading)
            if !article.preview.isEmpty { Text(article.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(store.articlePreviewLines.rawValue).multilineTextAlignment(.leading) }
            if ArticleAudioActions.shouldRender(audioState, transferStateAvailable: transferState != nil), let audioState, let transferState { AudioActionsView(state: audioState, transferState: transferState, onPlay: onPlayAudio, onDownload: onDownloadAudio, onDelete: onDeleteDownload, onAdd: onAddToListeningList) }
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
                iconButton(article.isRead ? "circle.fill" : "checkmark.circle", label: readActionLabel) { store.setRead(article, !article.isRead) }
            }
            iconButton(article.isStarred ? "star.fill" : "star", label: starActionLabel) { store.setStarred(article, !article.isStarred) }
            Menu { actionMenu } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("More").accessibilityLabel("More")
        }
    }
    private var interactionBackground: Color { selected ? Color.accentColor.opacity(0.16) : hovered ? Color.primary.opacity(0.055) : .clear }
    @ViewBuilder private var actionMenu: some View {
        Button { store.open(article) } label: { Label("Open", systemImage: "safari") }
        Button { store.openDetail(article) } label: { Label("Open Detail View", systemImage: "doc.text") }
        Button { store.setStarred(article, !article.isStarred) } label: { Label(starActionLabel, systemImage: article.isStarred ? "star.slash" : "star") }
        if !store.isSearchActive {
            Button { store.setRead(article, !article.isRead) } label: { Label(readActionLabel, systemImage: article.isRead ? "circle.fill" : "checkmark.circle") }
            Button { store.saveToService(article) } label: { Label("Save to Third-Party Service", systemImage: "tray.and.arrow.down") }
            Divider()
            Button { store.copyLink(article) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button { store.share(article) } label: { Label("Share...", systemImage: "square.and.arrow.up") }
            Button { store.openOriginal(article) } label: { Label("Open Original", systemImage: "safari") }
            Button { store.openInMiniflux(article) } label: { Label("Open in Miniflux", systemImage: "arrow.up.forward.app") }
            Button { store.select(.feed(article.feedId)) } label: { Label("Show Feed", systemImage: "line.3.horizontal.decrease.circle") }
            if !article.commentsUrl.isEmpty { Button { store.openComments(article) } label: { Label("Open Comments", systemImage: "bubble.left") } }
        }
    }
    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
    private var readActionLabel: String { article.isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read") }
    private var starActionLabel: String { article.isStarred ? String(localized: "Unstar") : String(localized: "Star") }
    private var relativeDate: String {
        guard let date = Self.isoFormatter.date(from: article.publishedAt) else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AudioActionsView: View {
    let state: ArticleAudioActionState
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Enclosure) -> Void
    let onDelete: (Enclosure) -> Void
    let onAdd: () -> Void
    @State private var pendingDeletion: Enclosure?

    var body: some View {
        HStack(spacing: 8) {
            enclosureAction(title: "Play", symbol: "play.fill", action: onPlay)
            enclosureAction(title: "Download", symbol: "arrow.down.circle", action: onDownload)
            Button(action: onAdd) {
                Label(state.isInListeningList ? "In Listening List" : "Add to Listening List", systemImage: state.isInListeningList ? "checkmark.circle" : "text.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(state.isInListeningList)
            .help(state.isInListeningList ? "In Listening List" : "Add to Listening List")
        }
        .font(.caption)
        .padding(.top, 3)
        .alert("Delete Download?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let enclosure = pendingDeletion { pendingDeletion = nil; onDelete(enclosure) }
            }
        } message: {
            Text("The downloaded audio file will be deleted.")
        }
    }

    @ViewBuilder private func enclosureAction(title: String, symbol: String, action: @escaping (Enclosure) -> Void) -> some View {
        if state.enclosures.count == 1, let enclosure = state.enclosures.first {
            Button { perform(title: title, enclosure: enclosure, action: action) } label: { Label(actionTitle(title, enclosure: enclosure), systemImage: symbol) }
                .buttonStyle(.borderless)
                .disabled(title == "Download" && !ArticleAudioActions.canRequestDownload(state.downloads[enclosure.id]) && !ArticleAudioActions.canDeleteDownload(state.downloads[enclosure.id]))
        } else {
            Menu {
                ForEach(state.enclosures.indices, id: \.self) { index in
                    let enclosure = state.enclosures[index]
                    Button {
                        perform(title: title, enclosure: enclosure, action: action)
                    } label: {
                        Label(actionTitle(title, enclosure: enclosure, index: index), systemImage: symbol)
                    }
                    .disabled(title == "Download" && !ArticleAudioActions.canRequestDownload(state.downloads[enclosure.id]) && !ArticleAudioActions.canDeleteDownload(state.downloads[enclosure.id]))
                }
            } label: {
                Label(title, systemImage: symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func actionTitle(_ title: String, enclosure: Enclosure, index: Int = 0) -> String {
        guard title == "Download" else { return title }
        switch ArticleAudioActions.downloadAction(state.downloads[enclosure.id], runtime: transferState.runtime(for: enclosure.id)) {
        case .delete: return String(localized: "Delete Download")
        case .pending: return String(localized: "Pending")
        case .downloading:
            if let fraction = transferState.runtime(for: enclosure.id)?.fraction { return String(localized: "Downloading \(Int((fraction * 100).rounded()))%") }
            return String(localized: "Downloading...")
        case .pendingDeletion: return String(localized: "Pending deletion")
        case .retry: return String(localized: "Retry Download")
        case .download: return index == 0 ? title : ArticleAudioActions.enclosureLabel(enclosure, index: index)
        }
    }

    private func perform(title: String, enclosure: Enclosure, action: @escaping (Enclosure) -> Void) {
        if title == "Download", ArticleAudioActions.canDeleteDownload(state.downloads[enclosure.id]) { pendingDeletion = enclosure }
        else { action(enclosure) }
    }
}

private extension View {
    @ViewBuilder
    func contextMenuIf<Content: View>(_ enabled: Bool, @ViewBuilder content: @escaping () -> Content) -> some View {
        if enabled {
            contextMenu { content() }
        } else {
            self
        }
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

struct FeedIconSlot: View {
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
    case media
    case reading
    case systemNotifications
    case general
    case data

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .account: "Account"
        case .syncStorage: "Sync & Storage"
        case .media: "Media / Listening List"
        case .reading: "Reading"
        case .systemNotifications: "System Notifications"
        case .general: "General"
        case .data: "Data & Backup"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @State private var server = ""
    @State private var key = ""
    @State private var customHeaders: [CustomHTTPHeader] = []
    @State private var scrollover = true
    @State private var syncOnStart = true
    @State private var launchAtLogin = false
    @State private var globalShortcut = GlobalShortcutChoice.optionCommandF
    @State private var section: SettingsSection = .account
    @State private var backupFlow: BackupPasswordFlow?
    @State private var settingsWindow: NSWindow?

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
            HStack {
                Spacer()
                Button { store.settingsVisible = false } label: {
                    if section == .account { Text("Cancel") } else { Text("Done") }
                }
                if section == .account {
                    Button { store.saveAccount(server: server.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), customHeaders: customHeaders, launchAtLogin: launchAtLogin, scrollover: scrollover, syncOnStart: syncOnStart, globalShortcut: globalShortcut) } label: {
                        if store.isSavingAccount { Text("Validating…") } else { Text("Save") }
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(server.isEmpty || key.isEmpty || store.isSavingAccount)
                }
            }
                .padding(16)
        }
        .frame(width: 900, height: 500)
        .overlay(alignment: .bottom) {
            if let confirmation = store.actionConfirmation {
                Text(confirmation)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 16)
            }
        }
        .background(SettingsWindowReader { window in
            guard settingsWindow !== window else { return }
            settingsWindow = window
        })
        .sheet(item: $backupFlow) { flow in
            BackupPasswordSheet(flow: flow, submit: { password in
                switch flow {
                case let .export(url):
                    do {
                        try store.exportConfigurationBackup(password: password).write(to: url, options: .atomic)
                        store.showActionConfirmation("Configuration backup exported")
                        return .success()
                    } catch {
                        return .failure(NativeErrorPresentation.message(for: error))
                    }
                case let .importBackup(data):
                    do {
                        let outcome = try await store.importConfigurationBackup(bytes: data, password: password)
                        return .success(outcome.confirmationMessage)
                    } catch {
                        return .failure(backupImportErrorMessage(error))
                    }
                }
            }, onSuccess: { message in
                store.showActionConfirmation(message)
            })
        }
        .onAppear {
            if let credentials = try? CredentialStore.load() { server = credentials.server; key = credentials.apiKey; customHeaders = credentials.resolvedCustomHeaders }
            launchAtLogin = CredentialStore.launchAtLoginEnabled
            scrollover = store.markReadOnScrolloverEnabled
            syncOnStart = store.syncOnStartEnabled
            globalShortcut = store.globalShortcut
        }
    }
    @ViewBuilder private var settingsPage: some View {
        switch section {
        case .account:
            AccountSettingsView(server: $server, key: $key, customHeaders: $customHeaders, configuredServer: store.configuredServer, version: store.minifluxVersion, validationError: store.accountValidationError)
        case .syncStorage:
            SyncStorageSettingsView(store: store, syncOnStart: $syncOnStart, retention: retention, deliveryMode: deliveryMode, backgroundSyncEnabled: backgroundSyncEnabled)
        case .media:
            MediaSettingsView(store: store, autoDownloadListeningList: autoDownloadListeningList, deleteAfterPlayback: deleteAfterPlayback, removeCompletedListeningList: removeCompletedListeningList)
        case .reading:
            ReadingSettingsView(store: store, scrollover: $scrollover, detailCharacterLimit: detailCharacterLimit)
        case .systemNotifications:
            SystemNotificationsSettingsView(store: store)
        case .general:
            GeneralSettingsView(launchAtLogin: $launchAtLogin, globalShortcut: $globalShortcut, registrationError: store.globalShortcutRegistrationError)
        case .data:
            DataBackupSettingsView(store: store, export: chooseExportDestination, importBackup: chooseImportSource, filePanelsAvailable: settingsWindow != nil)
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
    private var autoDownloadListeningList: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.autoDownloadListeningList ?? false },
            set: { store.setAutoDownloadListeningList($0) }
        )
    }
    private var deleteAfterPlayback: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.deleteAfterPlayback ?? false },
            set: { store.setDeleteAfterPlayback($0) }
        )
    }
    private var removeCompletedListeningList: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.removeCompletedListeningList ?? false },
            set: { store.setRemoveCompletedListeningList($0) }
        )
    }
    private var detailCharacterLimit: Binding<UInt32> {
        Binding(
            get: { store.coreSettings?.detailCharacterLimit ?? 10_000 },
            set: { store.setDetailCharacterLimit($0) }
        )
    }
    private func chooseExportDestination() {
        guard let settingsWindow, settingsWindow.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fluxbackup") ?? .data]
        panel.nameFieldStringValue = "FluxNews Backup.fluxbackup"
        panel.beginSheetModal(for: settingsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            // AppKit must finish detaching its sheet before SwiftUI presents the password sheet.
            DispatchQueue.main.async { backupFlow = .export(url) }
        }
    }
    private func chooseImportSource() {
        guard let settingsWindow, settingsWindow.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fluxbackup") ?? .data]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: settingsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                // AppKit must finish detaching its sheet before SwiftUI presents the password sheet.
                DispatchQueue.main.async { backupFlow = .importBackup(data) }
            } catch {
                store.errorMessage = NativeErrorPresentation.message(for: error)
            }
        }
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    let onWindowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> SettingsWindowReportingView {
        SettingsWindowReportingView(onWindowChanged: onWindowChanged)
    }

    func updateNSView(_ view: SettingsWindowReportingView, context: Context) {
        view.onWindowChanged = onWindowChanged
        onWindowChanged(view.window)
    }
}

private final class SettingsWindowReportingView: NSView {
    var onWindowChanged: (NSWindow?) -> Void

    init(onWindowChanged: @escaping (NSWindow?) -> Void) {
        self.onWindowChanged = onWindowChanged
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged(window)
    }
}

private enum BackupPasswordFlow: Identifiable {
    case export(URL)
    case importBackup(Data)
    var id: String { switch self { case .export: "export"; case .importBackup: "import" } }
    var isExport: Bool { if case .export = self { true } else { false } }
}

private struct BackupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let flow: BackupPasswordFlow
    let submit: (String) async -> BackupPasswordSubmissionResult
    let onSuccess: (String) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submission = BackupPasswordSubmissionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if flow.isExport { Text("Encrypt Configuration Backup") }
                else { Text("Import Configuration Backup") }
            }
                .font(.title2.bold())
            SecureField("Backup Password", text: $password)
            if flow.isExport { SecureField("Confirm Password", text: $confirmation) }
            if submission.isProcessing { ProgressView().controlSize(.small) }
            if let error = submission.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("FluxNews cannot recover this password.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(submission.isProcessing)
                Button { perform() } label: {
                    if submission.isProcessing { Text("Processing…") }
                    else if flow.isExport { Text("Export") }
                    else { Text("Import") }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submission.isProcessing)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: password) { _, _ in submission.clearError() }
        .onChange(of: confirmation) { _, _ in submission.clearError() }
    }
    private func perform() {
        guard submission.begin(isExport: flow.isExport, password: password, confirmation: confirmation) else { return }
        Task {
            switch await submit(password) {
            case let .success(confirmation):
                guard submission.complete(error: nil) else { return }
                dismiss()
                if let confirmation {
                    DispatchQueue.main.async { onSuccess(confirmation) }
                }
            case let .failure(error):
                _ = submission.complete(error: error)
            }
        }
    }
}

private struct DataBackupSettingsView: View {
    @ObservedObject var store: BrowserStore
    let export: () -> Void
    let importBackup: () -> Void
    let filePanelsAvailable: Bool
    @State private var confirmRebuild = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Configuration Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export or import your account, FluxNews settings, Feed Settings, and macOS preferences. Backups are password encrypted.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export Configuration Backup...") { export() }
                        Button("Import Configuration Backup...") { importBackup() }
                    }
                    .disabled(!filePanelsAvailable)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Destructive Operations") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Rebuild Local State...") { confirmRebuild = true }
                    Text("Discard synchronized local content. Miniflux becomes authoritative again; FluxNews and Feed Settings are preserved. Unsynchronized Read or Star changes may be lost.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button("Reset FluxNews...") { confirmReset = true }.foregroundStyle(.red)
                    Text("Remove the configured account, API key, Core and Feed Settings, local data, and FluxNews preferences.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            Spacer()
        }
        .alert("Rebuild Local State?", isPresented: $confirmRebuild) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) { store.rebuildLocalState() }
        } message: { Text("Synchronized local content will be discarded and Miniflux will become authoritative again. FluxNews and Feed Settings are preserved.") }
        .alert("Reset FluxNews?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.resetFluxNews() }
        } message: { Text("This removes your account, API key, settings, Feed Settings, and local data. FluxNews will return to its first-run state.") }
    }
}

private func backupImportErrorMessage(_ error: Error) -> String {
    switch error {
    case ConfigBackupError.NotFluxBackup: "Not a valid FluxNews backup."
    case ConfigBackupError.PlatformMismatch: "This backup was created for another platform."
    case ConfigBackupError.UnsupportedVersion: "This backup uses a newer unsupported format."
    case ConfigBackupError.DecryptionFailed: "The backup could not be decrypted. The password may be incorrect or the file may be damaged."
    default: String(localized: "The backup could not be imported. Please try again.")
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
    @Binding var customHeaders: [CustomHTTPHeader]
    let configuredServer: String?
    let version: String?
    let validationError: String?
    @State private var revealedHeaderIDs = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                  GridRow {
                      Text("Miniflux Server")
                          .frame(width: 140, alignment: .leading)

                      TextField("", text: $server)
                          .textFieldStyle(.roundedBorder)
                          .frame(maxWidth: .infinity)
                  }

                  GridRow {
                      Text("API Key")
                          .frame(width: 140, alignment: .leading)

                      SecureField("", text: $key)
                          .textFieldStyle(.roundedBorder)
                          .frame(maxWidth: .infinity)
                  }
              }
              .frame(maxWidth: .infinity, alignment: .leading)



            GroupBox("Custom HTTP Headers") {
                customHeadersEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                LabeledContent("Miniflux") { Text(version ?? "—").foregroundStyle(.secondary) }
                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("API keys and custom header values are stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: configuredServer) { _, server in
            if let server { self.server = server }
        }
        .onAppear { revealedHeaderIDs = [] }
    }

    private var customHeadersEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Header Name")
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: 300, alignment: .leading)
                Text("Value")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24)
                Text("Remove")
                    .hidden()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(customHeaders.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("", text: $customHeaders[index].name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
                    headerValueField(at: index)
                        .frame(minWidth: 300, maxWidth: .infinity)
                        .layoutPriority(1)
                    Button {
                        toggleHeaderValueVisibility(for: customHeaders[index].id)
                    } label: {
                        Image(systemName: revealedHeaderIDs.contains(customHeaders[index].id) ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealedHeaderIDs.contains(customHeaders[index].id) ? String(localized: "Hide header value") : String(localized: "Show header value"))
                    .accessibilityLabel(revealedHeaderIDs.contains(customHeaders[index].id) ? String(localized: "Hide header value") : String(localized: "Show header value"))
                    .frame(width: 24)
                    Button("Remove", role: .destructive) {
                        revealedHeaderIDs.remove(customHeaders[index].id)
                        customHeaders.remove(at: index)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Button("Add Header") { customHeaders.append(CustomHTTPHeader()) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerValueField(at index: Int) -> some View {
        if revealedHeaderIDs.contains(customHeaders[index].id) {
            TextField("", text: $customHeaders[index].value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        } else {
            SecureField("", text: $customHeaders[index].value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        }
    }

    private func toggleHeaderValueVisibility(for id: UUID) {
        if revealedHeaderIDs.contains(id) {
            revealedHeaderIDs.remove(id)
        } else {
            revealedHeaderIDs.insert(id)
        }
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
    @ObservedObject var store: BrowserStore
    @Binding var scrollover: Bool
    let detailCharacterLimit: Binding<UInt32>

    var body: some View {
        Form {
            Picker("Startup Scope", selection: Binding(get: { store.startupScope }, set: { store.setStartupScope($0) })) {
                Text("All News").tag(StartupScopePreference.allNews)
                Text("Starred").tag(StartupScopePreference.starred)
                Text("Category").tag(StartupScopePreference.category)
                Text("Feed").tag(StartupScopePreference.feed)
            }
            if store.startupScope == .category {
                Picker("Startup Category", selection: Binding(get: { store.startupCategoryID }, set: { store.setStartupCategoryID($0) })) {
                    ForEach(store.catalog.categories, id: \.id) { category in Text(category.title).tag(Optional(category.id)) }
                }
                .disabled(store.catalog.categories.isEmpty)
            }
            if store.startupScope == .feed {
                Picker("Startup Feed", selection: Binding(get: { store.startupFeedID }, set: { store.setStartupFeedID($0) })) {
                    ForEach(store.catalog.feeds, id: \.id) { feed in Text(feed.title).tag(Optional(feed.id)) }
                }
                .disabled(store.catalog.feeds.isEmpty)
            }
            Picker("Preview Lines", selection: Binding(get: { store.articlePreviewLines }, set: { store.setArticlePreviewLines($0) })) {
                Text("2 lines").tag(ArticlePreviewLines.compact)
                Text("3 lines").tag(ArticlePreviewLines.standard)
                Text("5 lines").tag(ArticlePreviewLines.extended)
            }
            Picker("Click on News", selection: Binding(get: { store.clickOnNews }, set: { store.setClickOnNews($0) })) {
                Text("Open Link").tag(ClickOnNews.openLink)
                Text("Open Detail View").tag(ClickOnNews.openDetailView)
            }
            Picker("Detail Character Limit", selection: detailCharacterLimit) {
                Text("5,000 characters").tag(UInt32(5_000))
                Text("10,000 characters").tag(UInt32(10_000))
                Text("20,000 characters").tag(UInt32(20_000))
            }
            .disabled(store.coreSettings == nil)
            Toggle("Mark articles as read when scrolling past", isOn: $scrollover)
            Toggle("Remove article from list when marked read", isOn: Binding(get: { store.removeArticlesWhenMarkedRead }, set: { store.setRemoveArticlesWhenMarkedRead($0) }))
            Toggle("Hide Empty Feeds / Categories", isOn: Binding(get: { store.hideEmptyNavigationEntries }, set: { store.setHideEmptyNavigationEntries($0) }))
        }
        .formStyle(.grouped)
    }
}

private struct MediaSettingsView: View {
    @ObservedObject var store: BrowserStore
    let autoDownloadListeningList: Binding<Bool>
    let deleteAfterPlayback: Binding<Bool>
    let removeCompletedListeningList: Binding<Bool>

    var body: some View {
        Form {
            Section("Media / Listening List") {
                Toggle("Automatically download items added to Listening List", isOn: autoDownloadListeningList)
                Text("Downloads audio automatically when an item is added to Listening List.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Delete download after playback", isOn: deleteAfterPlayback)
                Text("Removes the local download after playback is completed. The item remains in Listening List.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove completed items from Listening List", isOn: removeCompletedListeningList)
                Text("Removes the item from Listening List after all of its audio has been completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(store.coreSettings == nil)
        }
        .formStyle(.grouped)
    }
}

private struct FeedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BrowserStore
    let target: FeedSettingsTarget
    @State private var preferences: FeedPreferences?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Feed Settings").font(.title2.bold())
            Text(target.title).foregroundStyle(.secondary)
            if let preferences {
                Form {
                    Picker("Detail Rendering", selection: Binding(get: { preferences.detailRendering }, set: updateDetailRendering)) {
                        Text("Rendered").tag(DetailRenderingMode.rendered)
                        Text("Text Only").tag(DetailRenderingMode.textOnly)
                    }
                     Toggle("Truncate Detail", isOn: Binding(get: { preferences.truncateDetail }, set: updateTruncateDetail))
                     Toggle("Open in Miniflux", isOn: Binding(get: { preferences.openInMiniflux }, set: updateOpenInMiniflux))
                     Toggle("Automatically download audio from this feed", isOn: Binding(get: { preferences.autoDownloadAudio }, set: updateAutoDownloadAudio))
                 }
                .formStyle(.grouped)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    private func load() {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        do { preferences = try store.feedPreferences(feedID: target.id); error = nil }
        catch { self.error = NativeErrorPresentation.message(for: error) }
    }
    private func updateDetailRendering(_ mode: DetailRenderingMode) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        do { try store.setFeedDetailRendering(feedID: target.id, mode: mode); preferences = try store.feedPreferences(feedID: target.id) }
        catch { self.error = NativeErrorPresentation.message(for: error) }
    }
    private func updateTruncateDetail(_ enabled: Bool) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        do { try store.setFeedTruncateDetail(feedID: target.id, enabled: enabled); preferences = try store.feedPreferences(feedID: target.id) }
        catch { self.error = NativeErrorPresentation.message(for: error) }
    }
    private func updateOpenInMiniflux(_ enabled: Bool) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        do { try store.setFeedOpenInMiniflux(feedID: target.id, enabled: enabled); preferences = try store.feedPreferences(feedID: target.id) }
        catch { self.error = NativeErrorPresentation.message(for: error) }
    }
    private func updateAutoDownloadAudio(_ enabled: Bool) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        do { try store.setFeedAutoDownloadAudio(feedID: target.id, enabled: enabled); preferences = try store.feedPreferences(feedID: target.id) }
        catch { self.error = NativeErrorPresentation.message(for: error) }
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
                    Button { discover() } label: {
                        if isDiscovering { Text("Discovering...") } else { Text("Continue") }
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isDiscovering || isCreating || form.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button { createSelectedCandidate() } label: {
                        if isCreating { Text("Adding...") } else { Text("Add Feed") }
                    }
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
            case .failure:
                showError(String(localized: "Could not discover feeds. Please try again."))
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
            case .failure:
                showError(String(localized: "Could not add feed. Please try again."))
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
                Button { create() } label: {
                    if isCreating { Text("Adding...") } else { Text("Add") }
                }
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
            case .failure:
                let message = String(localized: "Could not add category. Please try again.")
                self.message = message
                store.errorMessage = message
            }
        }
    }
}
