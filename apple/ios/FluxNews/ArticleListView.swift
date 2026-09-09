import SwiftUI

enum IOSArticleScrollDirection: Equatable {
    case forward
    case backward
}

enum IOSArticleImagePrefetchPolicy {
    static func candidateIDs(
        orderedIDs: [Int64],
        visibleIDs: [Int64],
        imageIDs: Set<Int64>,
        direction: IOSArticleScrollDirection,
        excludedIDs: Set<Int64> = [],
        limit: Int = 2,
        searchHorizon: Int = 12
    ) -> [Int64] {
        IOSArticleImagePrefetchMetadata(orderedIDs: orderedIDs, imageIDs: imageIDs)
            .candidateIDs(visibleIDs: visibleIDs, direction: direction, excludedIDs: excludedIDs, limit: limit, searchHorizon: searchHorizon)
    }
}

/// Derived only with a structural article snapshot, never from a visibility update.
struct IOSArticleImagePrefetchMetadata {
    private(set) var orderedIDs: [Int64] = []
    private var positions: [Int64: Int] = [:]
    private var imageIDs = Set<Int64>()
    private var imageURLs: [Int64: URL] = [:]

    init() {}

    init(orderedIDs: [Int64], imageIDs: Set<Int64>) {
        self.orderedIDs = orderedIDs
        positions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        self.imageIDs = imageIDs
    }

    mutating func update(articles: [ArticleSummary]) -> Bool {
        let ids = articles.map(\.id)
        guard ids != orderedIDs else { return false }
        orderedIDs = ids
        positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        imageURLs = Dictionary(uniqueKeysWithValues: articles.compactMap { article in
            article.imageUrl.flatMap(URL.init(string:)).map { (article.id, $0) }
        })
        imageIDs = Set(imageURLs.keys)
        return true
    }

    func imageURL(for id: Int64) -> URL? { imageURLs[id] }

    func candidateIDs(
        visibleIDs: [Int64],
        direction: IOSArticleScrollDirection,
        excludedIDs: Set<Int64> = [],
        limit: Int = 2,
        searchHorizon: Int = 12
    ) -> [Int64] {
        guard limit > 0, searchHorizon > 0 else { return [] }
        var anchor: Int?
        for id in visibleIDs {
            guard let position = positions[id] else { continue }
            if let current = anchor {
                anchor = direction == .forward ? max(current, position) : min(current, position)
            } else {
                anchor = position
            }
        }
        guard let anchor else { return [] }

        var result: [Int64] = []
        for offset in 1...searchHorizon {
            let position = direction == .forward ? anchor + offset : anchor - offset
            guard orderedIDs.indices.contains(position) else { break }
            let id = orderedIDs[position]
            if imageIDs.contains(id) && !excludedIDs.contains(id) {
                result.append(id)
                if result.count == limit { break }
            }
        }
        return result
    }
}

/// iOS 18 visibility reports need not include every intermediate row. The ordered
/// snapshot fills those gaps without using row geometry or exposure timing.
struct IOSScrolloverOrderTracker {
    private var orderedIDs: [Int64] = []
    private var positions: [Int64: Int] = [:]
    private var previousLeadingArticleID: Int64?
    private var emittedIDs = Set<Int64>()
    private var isUserScrolling = false
    private var hasForwardScrollInteraction = false
    private var lastVisibilityMoveWasForward = false
    private var deferredLeadingArticleID: Int64?
    private(set) var lastVisibilityDirection: IOSArticleScrollDirection?

    mutating func updateSnapshot(_ ids: [Int64]) {
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        // A changed ordering can be a sync/filter/layout snapshot, not a scroll.
        previousLeadingArticleID = nil
        emittedIDs.removeAll()
        isUserScrolling = false
        hasForwardScrollInteraction = false
        lastVisibilityMoveWasForward = false
        deferredLeadingArticleID = nil
        lastVisibilityDirection = nil
    }

    mutating func setUserScrolling(_ value: Bool) { isUserScrolling = value }

    mutating func reset() {
        previousLeadingArticleID = nil
        emittedIDs.removeAll()
        isUserScrolling = false
        hasForwardScrollInteraction = false
        lastVisibilityMoveWasForward = false
        deferredLeadingArticleID = nil
        lastVisibilityDirection = nil
    }

    mutating func releaseEmittedIDs() { emittedIDs.removeAll() }

    mutating func receiveVisibleIDs(_ visibleIDs: [Int64], enabled: Bool) -> IOSScrolloverBatch {
        let empty = IOSScrolloverBatch(articleIDs: [])
        guard let leadingID = visibleIDs.min(by: { positions[$0, default: .max] < positions[$1, default: .max] }),
              let leadingPosition = positions[leadingID] else { return empty }
        defer { previousLeadingArticleID = leadingID }

        guard isUserScrolling, enabled, let previousLeadingArticleID,
              let previousPosition = positions[previousLeadingArticleID] else {
            lastVisibilityDirection = nil
            return empty
        }
        guard leadingPosition != previousPosition else {
            lastVisibilityDirection = nil
            return empty
        }
        lastVisibilityDirection = leadingPosition > previousPosition ? .forward : .backward
        guard leadingPosition > previousPosition else {
            lastVisibilityMoveWasForward = false
            deferredLeadingArticleID = nil
            return empty
        }

        // Keep the immediately preceding leading card as a semantic crossing
        // candidate until the following target is reported. Intermediate IDs
        // in a fast jump are already past the semantic crossing and remain
        // gap-filled from this ordered segment.
        let adjacentMove = leadingPosition == previousPosition + 1
        var candidates: [Int64] = []
        if let deferredLeadingArticleID, emittedIDs.insert(deferredLeadingArticleID).inserted {
            candidates.append(deferredLeadingArticleID)
        }
        for id in orderedIDs[previousPosition..<leadingPosition] {
            guard !adjacentMove || id != previousLeadingArticleID else { continue }
            if emittedIDs.insert(id).inserted { candidates.append(id) }
        }
        deferredLeadingArticleID = adjacentMove ? previousLeadingArticleID : nil
        hasForwardScrollInteraction = true
        lastVisibilityMoveWasForward = true
        return IOSScrolloverBatch(articleIDs: candidates)
    }

    mutating func receiveTerminalVisibleIDs(_ visibleIDs: [Int64], enabled: Bool) -> IOSScrolloverBatch {
        guard enabled, isUserScrolling, hasForwardScrollInteraction, lastVisibilityMoveWasForward,
              let finalID = orderedIDs.last, visibleIDs.contains(finalID) else {
            return IOSScrolloverBatch(articleIDs: [])
        }
        // The final target is visible only after this interaction has advanced the
        // leading target, so complete the otherwise un-crossable terminal cards.
        let candidates = visibleIDs
            .filter { positions[$0] != nil && emittedIDs.insert($0).inserted }
            .sorted { positions[$0, default: .max] < positions[$1, default: .max] }
        return IOSScrolloverBatch(articleIDs: candidates)
    }
}

struct IOSScrolloverBatch: Equatable {
    let articleIDs: [Int64]
}

/// List-row visibility is a sensor only. The tracker remains the crossing authority.
struct IOSListVisibilityCoordinator {
    private var orderedIDs: [Int64] = []
    private var visibleIDs = Set<Int64>()

    mutating func updateSnapshot(_ ids: [Int64]) -> [Int64] {
        guard ids != orderedIDs else { return orderedVisibleIDs }
        orderedIDs = ids
        visibleIDs.formIntersection(Set(ids))
        return orderedVisibleIDs
    }

    mutating func receiveVisibility(articleID: Int64, isVisible: Bool) -> [Int64]? {
        guard orderedIDs.contains(articleID) else { return nil }
        if isVisible {
            guard visibleIDs.insert(articleID).inserted else { return nil }
        } else {
            guard visibleIDs.remove(articleID) != nil else { return nil }
        }
        return orderedVisibleIDs
    }

    private var orderedVisibleIDs: [Int64] {
        orderedIDs.filter { visibleIDs.contains($0) }
    }
}

enum IOSArticleContextAction: Equatable {
    case starred
    case read
    case original
    case reader
    case miniflux
    case comments
    case copyLink
    case share
    case saveToService
}

enum IOSArticleContextMenuPolicy {
    static func commentsURL(_ value: String) -> URL? {
        ArticleOpenRoutingPolicy.validWebURL(value)
    }

    static func originalURL(_ value: String) -> URL? {
        ArticleOpenRoutingPolicy.validWebURL(value)
    }
}

enum IOSArticleListEmptyState: Equatable {
    case syncing
    case loading
    case noNews
    case error(String)

    static func resolve(isSyncing: Bool, isLoading: Bool, errorMessage: String?, hasArticles: Bool) -> Self? {
        guard !hasArticles else { return nil }
        if let errorMessage { return .error(errorMessage) }
        if isSyncing { return .syncing }
        if isLoading { return .loading }
        return .noNews
    }
}

struct ArticleListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    var store: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    @State private var scrolloverTracker = IOSScrolloverOrderTracker()
    @State private var listVisibility = IOSListVisibilityCoordinator()
    @State private var imagePrefetchMetadata = IOSArticleImagePrefetchMetadata()
    // 15% admits a target that is only barely visible, so tall cards still give
    // the ordered tracker a reliable leading target. It is not a read threshold.
    private let scrolloverVisibilityThreshold: CGFloat = 0.15

    var body: some View {
        let emptyState = IOSArticleListEmptyState.resolve(
            isSyncing: store.isSyncing,
            isLoading: store.isLoading,
            errorMessage: store.errorMessage,
            hasArticles: !store.articles.isEmpty
        )

        Group {
            if case let .error(message) = emptyState {
                ContentUnavailableView("Unable to Load Articles", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if case .syncing = emptyState {
                ProgressView("News syncing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .loading = emptyState {
                ProgressView("Loading articles")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .noNews = emptyState {
                ContentUnavailableView("No News", systemImage: "newspaper")
            } else {
                GeometryReader { proxy in
                    let horizontalInset: CGFloat = proxy.size.width > 700 ? 28 : 16
                    let articleSpacing: CGFloat = ArticlePresentationLayout.usesLandscapeVisual(
                        mode: store.articlePresentationMode,
                        availableWidth: proxy.size.width - horizontalInset * 2
                    ) ? 20 : 26

                    List {
                        ForEach(store.articles, id: \.id) { article in
                            let rowState = store.rowPresentationState(for: article)
                            let iconVariant = IOSFeedIconPresentation.variant(isDark: colorScheme == .dark)
                            let feedIcon = store.feedIconPresentationState(for: article.feedId, variant: iconVariant)

                            ArticlePresentationView(
                                content: rowState.content,
                                fallbackRead: article.isRead,
                                fallbackStarred: article.isStarred,
                                rowState: rowState,
                                mode: store.articlePresentationMode,
                                previewLines: store.articlePreviewLines,
                                availableWidth: proxy.size.width - horizontalInset * 2,
                                feedIcon: feedIcon,
                                iconVariant: iconVariant,
                                onRequestFeedIcon: { store.requestFeedIcon(article.feedId, variant: iconVariant) },
                                onTap: { onArticleTap(article) },
                                onAction: { onArticleAction(article, $0) },
                                onSetRead: { store.setRead(article, read: $0) },
                                onSetStarred: { store.setStarred(article, starred: $0) }
                            )
                            .equatable()
                            .padding(.horizontal, horizontalInset)
                            .padding(.vertical, articleSpacing / 2)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden, edges: .all)
                            .listRowSeparatorTint(.clear, edges: .all)
                            .listRowBackground(Color.clear)
                            .onScrollVisibilityChange(threshold: scrolloverVisibilityThreshold) { isVisible in
                                receiveListVisibility(articleID: article.id, isVisible: isVisible, availableWidth: proxy.size.width - horizontalInset * 2)
                            }
                            .onDisappear {
                                receiveListVisibility(articleID: article.id, isVisible: false, availableWidth: proxy.size.width - horizontalInset * 2)
                            }
                        }.listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .listRowSeparatorTint(.clear, edges: .all)
                    .scrollContentBackground(.hidden)
                    .id(store.scrollResetRevision)
                    .refreshable { await store.syncManually() }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        rebuildPrefetchMetadata()
                    }
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .interacting:
                            scrolloverTracker.setUserScrolling(true)
                            store.setScrolloverPresentationPhase(.interacting)
                            store.markMeaningfulInteraction()
                        case .decelerating:
                            scrolloverTracker.setUserScrolling(true)
                            store.setScrolloverPresentationPhase(.decelerating)
                        case .idle:
                            scrolloverTracker.setUserScrolling(false)
                            store.setScrolloverPresentationPhase(.idle)
                        default:
                            break
                        }
                    }
                    .onChange(of: store.snapshotRevision) { _, _ in
                        rebuildPrefetchMetadata()
                    }
                    .onChange(of: store.scrolloverRearmRevision) { _, _ in
                        scrolloverTracker.releaseEmittedIDs()
                    }
                }
            }
        }
        .background(.background)
        .overlay(alignment: .bottom) {
              ArticleListBottomOverlay(store: store)
           }
    }

}

private extension ArticleListView {
    func receiveListVisibility(articleID: Int64, isVisible: Bool, availableWidth: CGFloat) {
        guard let visibleIDs = listVisibility.receiveVisibility(articleID: articleID, isVisible: isVisible) else { return }
        receiveVisibleIDs(visibleIDs, availableWidth: availableWidth)
    }

    func receiveVisibleIDs(_ visibleIDs: [Int64], availableWidth: CGFloat) {
        let batch = scrolloverTracker.receiveVisibleIDs(visibleIDs, enabled: store.markReadOnScrolloverEnabled)
        if !batch.articleIDs.isEmpty { store.flushScrollover(batch) }
        if let direction = scrolloverTracker.lastVisibilityDirection {
            prefetchImages(visibleIDs: visibleIDs, direction: direction, availableWidth: availableWidth)
        }
        let terminalBatch = scrolloverTracker.receiveTerminalVisibleIDs(visibleIDs, enabled: store.markReadOnScrolloverEnabled)
        if !terminalBatch.articleIDs.isEmpty { store.flushScrollover(terminalBatch) }
    }

    func prefetchImages(visibleIDs: [Int64], direction: IOSArticleScrollDirection, availableWidth: CGFloat) {
        guard store.articlePresentationMode.showsArticleImage else { return }
        let ids = imagePrefetchMetadata.candidateIDs(visibleIDs: visibleIDs, direction: direction)
        for id in ids {
            guard let url = imagePrefetchMetadata.imageURL(for: id) else { continue }
            let targetSize: CGSize
            if ArticlePresentationLayout.usesLandscapeVisual(mode: store.articlePresentationMode, availableWidth: availableWidth) {
                let width = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
                targetSize = CGSize(width: width, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: width))
            } else {
                let width = ArticlePresentationLayout.visualPortraitContentWidth(availableWidth)
                targetSize = CGSize(width: width, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: width))
            }
            let request = ArticleImageRequest(url: url, targetSize: targetSize, displayScale: displayScale)
            Task.detached(priority: .utility) {
                _ = try? await ArticleImagePipeline.shared.image(for: request)
            }
        }
    }

    func rebuildPrefetchMetadata() {
        _ = imagePrefetchMetadata.update(articles: store.articles)
        scrolloverTracker.updateSnapshot(imagePrefetchMetadata.orderedIDs)
        let visibleIDs = listVisibility.updateSnapshot(imagePrefetchMetadata.orderedIDs)
        _ = scrolloverTracker.receiveVisibleIDs(visibleIDs, enabled: store.markReadOnScrolloverEnabled)
    }
}

private struct ArticleListBottomOverlay: View {
    var store: NewsreaderStore
    @State private var sensoryFeedbackTrigger = 0

    var body: some View {
        Group {
            if store.scrolloverUndoVisible {
                ScrolloverUndoPresentation(store: store)
            } else if store.hasPendingNewData || store.hasUnscopedNewDataSignal {
                Button("New articles available") { store.adoptVisibleSnapshot() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
            }
        }
        .onChange(of: store.scrolloverUndoVisible) { previouslyVisible, currentlyVisible in
            if ScrolloverUndoPresentationPolicy.shouldTriggerFeedback(previouslyVisible: previouslyVisible, currentlyVisible: currentlyVisible) {
                sensoryFeedbackTrigger += 1
            }
        }
        .sensoryFeedback(.success, trigger: sensoryFeedbackTrigger)
    }
}

enum ScrolloverUndoPresentationPolicy {
    static func shouldTriggerFeedback(previouslyVisible: Bool, currentlyVisible: Bool) -> Bool {
        !previouslyVisible && currentlyVisible
    }
}

private struct ScrolloverUndoPresentation: View {
    var store: NewsreaderStore

    var body: some View {
        HStack(spacing: 10) {
            Text(scrolloverUndoCountLabel)
            Button("Undo") { store.undoScrollover() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private var scrolloverUndoCountLabel: String {
        let count = store.scrolloverUndoIDs.count
        return String(localized: "\(count) article marked as read")
    }
}

struct ArticlePresentationView: View, Equatable {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let fallbackStarred: Bool
    let rowState: ArticleRowPresentationState?
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    let feedIcon: IOSFeedIconPresentationState
    let iconVariant: FeedIconVariant
    let onRequestFeedIcon: () -> Void
    let onTap: () -> Void
    let onAction: (IOSArticleContextAction) -> Void
    let onSetRead: (Bool) -> Void
    let onSetStarred: (Bool) -> Void
    static func == (lhs: ArticlePresentationView, rhs: ArticlePresentationView) -> Bool {
        lhs.content == rhs.content &&
            (lhs.rowState != nil || rhs.rowState != nil || (lhs.fallbackRead == rhs.fallbackRead && lhs.fallbackStarred == rhs.fallbackStarred)) &&
            lhs.rowState === rhs.rowState &&
            lhs.mode == rhs.mode &&
            lhs.previewLines == rhs.previewLines &&
            lhs.availableWidth == rhs.availableWidth &&
            lhs.feedIcon === rhs.feedIcon &&
            lhs.iconVariant == rhs.iconVariant
    }

    var body: some View {
        ArticleRowStateInteractions(content: content, fallbackRead: fallbackRead, fallbackStarred: fallbackStarred, rowState: rowState, mode: mode, previewLines: previewLines, availableWidth: availableWidth, feedIcon: feedIcon, onRequestFeedIcon: onRequestFeedIcon, onTap: onTap, onAction: onAction, onSetRead: onSetRead, onSetStarred: onSetStarred)
    }
}

private struct ArticleRowStateInteractions: View {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let fallbackStarred: Bool
    let rowState: ArticleRowPresentationState?
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    let feedIcon: IOSFeedIconPresentationState
    let onRequestFeedIcon: () -> Void
    let onTap: () -> Void
    let onAction: (IOSArticleContextAction) -> Void
    let onSetRead: (Bool) -> Void
    let onSetStarred: (Bool) -> Void

    var body: some View {
        let isRead = rowState?.isRead ?? fallbackRead
        let isStarred = rowState?.isStarred ?? fallbackStarred
        ArticleRowSurface(content: content, fallbackRead: fallbackRead, fallbackStarred: fallbackStarred, rowState: rowState, mode: mode, previewLines: previewLines, availableWidth: availableWidth, feedIcon: feedIcon, onRequestFeedIcon: onRequestFeedIcon, onTap: onTap)
            .equatable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(content.article.title), \(content.article.feedTitle), \(content.publishedDate), \(isRead ? String(localized: "Read") : String(localized: "Unread"))\(isStarred ? String(localized: ", starred") : "")")
            .accessibilityValue(isRead ? (isStarred ? String(localized: "Read, starred") : String(localized: "Read")) : (isStarred ? String(localized: "Unread, starred") : String(localized: "Unread")))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: "Opens the article"))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { onSetRead(!isRead) } label: {
                    Label(isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read"), systemImage: isRead ? "envelope" : "envelope.open")
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { onSetStarred(!isStarred) } label: {
                    Label(isStarred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: isStarred ? "star.slash" : "star")
                }
                .tint(.orange)
            }
            .contextMenu {
                Button { onSetStarred(!isStarred) } label: { Label(isStarred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: isStarred ? "star.slash" : "star") }
                Button { onSetRead(!isRead) } label: { Label(isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read"), systemImage: isRead ? "envelope" : "envelope.open") }
                Divider()
                Button { onAction(.original) } label: { Label("Open Original", systemImage: "safari") }
                Button { onAction(.reader) } label: { Label("Open in Reader", systemImage: "doc.text") }
                Button { onAction(.miniflux) } label: { Label("Open in Miniflux", systemImage: "arrow.up.forward.app") }
                if content.hasComments { Button { onAction(.comments) } label: { Label("Open Comments", systemImage: "bubble.left") } }
                Button { onAction(.copyLink) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                Button { onAction(.share) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Divider()
                Button { onAction(.saveToService) } label: { Label("Save to Third-Party Service", systemImage: "tray.and.arrow.down") }
            }
    }

}

private struct ArticleRowSurface: View, Equatable {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let fallbackStarred: Bool
    let rowState: ArticleRowPresentationState?
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    let feedIcon: IOSFeedIconPresentationState
    let onRequestFeedIcon: () -> Void
    let onTap: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content &&
            (lhs.rowState != nil || rhs.rowState != nil || (lhs.fallbackRead == rhs.fallbackRead && lhs.fallbackStarred == rhs.fallbackStarred)) &&
            lhs.rowState === rhs.rowState && lhs.mode == rhs.mode && lhs.previewLines == rhs.previewLines && lhs.availableWidth == rhs.availableWidth && lhs.feedIcon === rhs.feedIcon
    }

    var body: some View {
        ArticleRowContentBody(content: content, fallbackRead: fallbackRead, fallbackStarred: fallbackStarred, rowState: rowState, mode: mode, previewLines: previewLines, availableWidth: availableWidth, feedIcon: feedIcon, onRequestFeedIcon: onRequestFeedIcon)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture(perform: onTap)
            .frame(width: articleWidth, alignment: .leading)
    }

    private var articleWidth: CGFloat { ArticlePresentationLayout.boundedArticleWidth(availableWidth) }
}

private struct ArticleRowContentBody: View {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let fallbackStarred: Bool
    let rowState: ArticleRowPresentationState?
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    let feedIcon: IOSFeedIconPresentationState
    let onRequestFeedIcon: () -> Void

    var body: some View {
        switch mode {
        case .visual:
            if ArticlePresentationLayout.usesLandscapeVisual(mode: mode, availableWidth: availableWidth) {
                landscapeVisual
            } else {
                portraitVisual
            }
        case .compact:
            articleText
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .frame(width: contentWidth, alignment: .leading)
        }
    }

    private var articleWidth: CGFloat { ArticlePresentationLayout.boundedArticleWidth(availableWidth) }
    private var contentWidth: CGFloat { ArticlePresentationLayout.articleContentWidth(articleWidth) }
    private var portraitContentWidth: CGFloat { ArticlePresentationLayout.visualPortraitContentWidth(articleWidth) }
    private var portraitVisual: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = content.imageURL {
                ArticleImageView(url: imageURL, targetSize: CGSize(width: portraitContentWidth, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: portraitContentWidth)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            articleText.frame(width: portraitContentWidth, alignment: .leading)
        }
        .frame(width: portraitContentWidth, alignment: .leading)
    }
    private var landscapeVisual: some View {
        HStack(alignment: .top, spacing: 14) {
            let imageWidth = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
            if let imageURL = content.imageURL {
                ArticleImageView(url: imageURL, targetSize: CGSize(width: imageWidth, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: imageWidth)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            articleText.frame(width: content.imageURL == nil ? contentWidth : ArticlePresentationLayout.landscapeTextWidth(availableWidth: availableWidth, imageWidth: imageWidth, interColumnSpacing: 14), alignment: .leading)
        }
        .frame(width: contentWidth, alignment: .leading)
    }
    private var articleText: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArticleTitlePresentation(title: content.article.title, rowState: rowState, fallbackRead: fallbackRead, fallbackStarred: fallbackStarred)
            ViewThatFits(in: .horizontal) {
                ArticleMetadataRow(content: content, fallbackRead: fallbackRead, rowState: rowState, feedIcon: feedIcon, onRequestFeedIcon: onRequestFeedIcon)
                ArticleMetadataColumn(content: content, fallbackRead: fallbackRead, rowState: rowState, feedIcon: feedIcon, onRequestFeedIcon: onRequestFeedIcon)
            }
            if !content.article.preview.isEmpty {
                Text(content.article.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLines.rawValue)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

private struct ArticleTitlePresentation: View {
    let title: String
    let rowState: ArticleRowPresentationState?
    let fallbackRead: Bool
    let fallbackStarred: Bool
    var body: some View {
        let isRead = rowState?.isRead ?? fallbackRead
        let isStarred = rowState?.isStarred ?? fallbackStarred
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(isRead ? .secondary : .primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if isStarred {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(String(localized: "Starred"))
            }
        }
    }
}

private struct ArticleMetadataRow: View {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let rowState: ArticleRowPresentationState?
    let feedIcon: IOSFeedIconPresentationState
    let onRequestFeedIcon: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ArticleUnreadIndicator(rowState: rowState, fallback: fallbackRead)
            FeedIconView(feedID: content.article.feedId, title: content.article.feedTitle, state: feedIcon, onRequest: onRequestFeedIcon)
            Text(content.article.feedTitle).font(.subheadline.weight(.medium))
            Text("•")
            Text(content.publishedDate)
            commentsIndicator
        }
        .foregroundStyle(.secondary)
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder private var commentsIndicator: some View {
        if content.hasComments { Image(systemName: "bubble.left").accessibilityLabel(String(localized: "Comments available")) }
    }
}

private struct ArticleMetadataColumn: View {
    let content: ArticleRowContent
    let fallbackRead: Bool
    let rowState: ArticleRowPresentationState?
    let feedIcon: IOSFeedIconPresentationState
    let onRequestFeedIcon: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ArticleUnreadIndicator(rowState: rowState, fallback: fallbackRead)
                FeedIconView(feedID: content.article.feedId, title: content.article.feedTitle, state: feedIcon, onRequest: onRequestFeedIcon)
                Text(content.article.feedTitle).font(.subheadline.weight(.medium))
                if content.hasComments { Image(systemName: "bubble.left").accessibilityLabel(String(localized: "Comments available")) }
            }
            Text(content.publishedDate)
        }
        .foregroundStyle(.secondary)
        .font(.caption)
    }
}

private struct ArticleUnreadIndicator: View {
    let rowState: ArticleRowPresentationState?
    let fallback: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: rowState?.isRead ?? fallback))
            .accessibilityHidden(true)
    }
}

struct FeedIconView: View {
    let feedID: Int64
    let title: String
    let state: IOSFeedIconPresentationState
    let onRequest: () -> Void
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = state.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(title.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.accentColor.gradient, in: Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task { onRequest() }
    }
}
