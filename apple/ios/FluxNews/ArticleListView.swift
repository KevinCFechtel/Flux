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

/// Retains requests already handed to the pipeline without invalidating the list.
final class IOSArticleImagePrefetchCoordinator {
    private var submittedRequests = Set<ArticleImageRequest>()

    func accept(_ requests: [ArticleImageRequest]) -> [ArticleImageRequest] {
        requests.filter { submittedRequests.insert($0).inserted }
    }

    func reset() {
        submittedRequests.removeAll(keepingCapacity: true)
    }
}

struct IOSScrolloverBatch: Equatable {
    let articleIDs: [Int64]
}

enum IOSArticleRowViewportRegion: Equatable {
    case above
    case visible
    case below

    static func resolve(frame: CGRect, viewportHeight: CGFloat) -> Self {
        // `.scrollView` expresses row frames against the scroll viewport, whose
        // origin is the effective upper boundary used by Scrollover.
        if frame.maxY <= 0 { return .above }
        if frame.minY >= viewportHeight { return .below }
        return .visible
    }
}

struct IOSArticleRowGeometryState: Equatable {
    let region: IOSArticleRowViewportRegion
    let size: CGSize
}

struct IOSArticleScrollGeometry: Equatable {
    let visibleRect: CGRect
    let contentSize: CGSize
    let containerSize: CGSize
}

/// Non-observable geometry sensor for one stable List snapshot. Row frames are
/// reduced to viewport regions before reaching this controller; no continuous
/// geometry is published into SwiftUI state.
final class IOSScrolloverGeometryController {
    private static let geometryTolerance: CGFloat = 0.5

    private var orderedIDs: [Int64] = []
    private var positions: [Int64: Int] = [:]
    private var rowRegions: [Int64: IOSArticleRowViewportRegion] = [:]
    private var rowSizes: [Int64: CGSize] = [:]
    private var emittedIDs = Set<Int64>()
    private var pendingCrossingIDs = Set<Int64>()
    private var previousGeometry: IOSArticleScrollGeometry?
    private var phase: IOSScrolloverPresentationPhase = .idle
    private var lastDirection: IOSArticleScrollDirection?
    private var hasForwardInteraction = false
    private var wasAtBottom = false
    private var terminalCompletionActive = false

    var visibleIDs: [Int64] {
        rowRegions.compactMap { $0.value == .visible ? $0.key : nil }
            .sorted { positions[$0, default: .max] < positions[$1, default: .max] }
    }

    func updateSnapshot(_ ids: [Int64]) {
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        emittedIDs.removeAll()
        rebaseline()
    }

    func rebaseline() {
        rowRegions = [:]
        rowSizes = [:]
        pendingCrossingIDs = []
        previousGeometry = nil
        phase = .idle
        lastDirection = nil
        hasForwardInteraction = false
        wasAtBottom = false
        terminalCompletionActive = false
    }

    func releaseEmittedIDs() { emittedIDs.removeAll() }

    func setPhase(_ phase: IOSScrolloverPresentationPhase) {
        self.phase = phase
        if phase == .idle {
            lastDirection = nil
            hasForwardInteraction = false
            terminalCompletionActive = false
            pendingCrossingIDs = []
        }
    }

    func receiveScrollGeometry(_ geometry: IOSArticleScrollGeometry, enabled: Bool) -> (direction: IOSArticleScrollDirection?, batch: IOSScrolloverBatch) {
        if !enabled { pendingCrossingIDs = [] }
        guard let previousGeometry else {
            self.previousGeometry = geometry
            wasAtBottom = isAtBottom(geometry)
            return (nil, .init(articleIDs: []))
        }
        guard previousGeometry.containerSize == geometry.containerSize else {
            rebaseline()
            self.previousGeometry = geometry
            wasAtBottom = isAtBottom(geometry)
            return (nil, .init(articleIDs: []))
        }

        self.previousGeometry = geometry
        let delta = geometry.visibleRect.minY - previousGeometry.visibleRect.minY
        let direction: IOSArticleScrollDirection?
        if delta > Self.geometryTolerance { direction = .forward }
        else if delta < -Self.geometryTolerance { direction = .backward }
        else { direction = nil }

        guard let direction, phase.isScrolling else { return (nil, .init(articleIDs: [])) }
        lastDirection = direction
        if direction == .forward { hasForwardInteraction = true }
        else { pendingCrossingIDs = [] }

        var candidates = Set<Int64>()
        if direction == .forward, enabled { candidates.formUnion(pendingCrossingIDs) }
        pendingCrossingIDs.subtract(candidates)

        let atBottom = isAtBottom(geometry)
        if enabled,
           direction == .forward,
           hasForwardInteraction,
           !wasAtBottom,
           atBottom {
            // Terminal rows cannot cross the upper boundary. A real forward
            // arrival at the content bottom completes only observed visible rows.
            terminalCompletionActive = true
            candidates.formUnion(visibleIDs)
        }
        wasAtBottom = atBottom
        return (direction, batch(from: candidates))
    }

    func receiveRowRegion(articleID: Int64, region: IOSArticleRowViewportRegion, enabled: Bool) -> IOSScrolloverBatch {
        receiveRowGeometry(articleID: articleID, state: .init(region: region, size: .zero), enabled: enabled)
    }

    func receiveRowGeometry(articleID: Int64, state: IOSArticleRowGeometryState, enabled: Bool) -> IOSScrolloverBatch {
        guard positions[articleID] != nil else { return .init(articleIDs: []) }
        if let previousSize = rowSizes[articleID],
           previousSize != .zero,
           (abs(previousSize.width - state.size.width) > Self.geometryTolerance ||
               abs(previousSize.height - state.size.height) > Self.geometryTolerance) {
            rebaseline()
            rowSizes[articleID] = state.size
            rowRegions[articleID] = state.region
            return .init(articleIDs: [])
        }
        rowSizes[articleID] = state.size
        let previous = rowRegions.updateValue(state.region, forKey: articleID)
        var candidates = Set<Int64>()
        // Only a measured visible row is qualified. A below-to-above jump has
        // no observed exposure and must not manufacture a read intent.
        if enabled,
           phase.isScrolling,
           previous == .visible,
           state.region == .above,
           lastDirection != .backward {
            pendingCrossingIDs.insert(articleID)
        }
        if enabled,
           phase.isScrolling,
           lastDirection == .forward {
            candidates.formUnion(pendingCrossingIDs)
            pendingCrossingIDs.subtract(candidates)
            if terminalCompletionActive, state.region == .visible { candidates.insert(articleID) }
        }
        return batch(from: candidates)
    }

    private func isAtBottom(_ geometry: IOSArticleScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - Self.geometryTolerance
    }

    private func batch(from candidates: Set<Int64>) -> IOSScrolloverBatch {
        let ids = candidates
            .filter { emittedIDs.insert($0).inserted }
            .sorted { positions[$0, default: .max] < positions[$1, default: .max] }
        return .init(articleIDs: ids)
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
    @State private var scrolloverController = IOSScrolloverGeometryController()
    @State private var imagePrefetchMetadata = IOSArticleImagePrefetchMetadata()
    @State private var imagePrefetchCoordinator = IOSArticleImagePrefetchCoordinator()

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
                    let rowMetrics = ArticleListRowMetrics(
                        mode: store.articlePresentationMode,
                        containerWidth: proxy.size.width
                    )

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
                                availableWidth: rowMetrics.availableWidth,
                                feedIcon: feedIcon,
                                iconVariant: iconVariant,
                                onRequestFeedIcon: { store.requestFeedIcon(article.feedId, variant: iconVariant) },
                                onTap: { onArticleTap(article) },
                                onAction: { onArticleAction(article, $0) },
                                onSetRead: { store.setRead(article, read: $0) },
                                onSetStarred: { store.setStarred(article, starred: $0) }
                            )
                            .equatable()
                            .padding(.horizontal, rowMetrics.horizontalInset)
                            .padding(.vertical, rowMetrics.outerVerticalPadding)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .onGeometryChange(for: IOSArticleRowGeometryState.self, of: { geometry in
                                let frame = geometry.frame(in: .scrollView)
                                return IOSArticleRowGeometryState(
                                    region: IOSArticleRowViewportRegion.resolve(
                                        frame: frame,
                                        viewportHeight: proxy.size.height
                                    ),
                                    size: frame.size
                                )
                            }) { _, state in
                                receiveRowGeometry(articleID: article.id, state: state)
                            }
                        }.listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
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
                            scrolloverController.setPhase(.interacting)
                            store.setScrolloverPresentationPhase(.interacting)
                            store.markMeaningfulInteraction()
                        case .decelerating:
                            scrolloverController.setPhase(.decelerating)
                            store.setScrolloverPresentationPhase(.decelerating)
                        case .idle:
                            scrolloverController.setPhase(.idle)
                            store.setScrolloverPresentationPhase(.idle)
                        default:
                            break
                        }
                    }
                    .onScrollGeometryChange(for: IOSArticleScrollGeometry.self, of: { geometry in
                        IOSArticleScrollGeometry(
                            visibleRect: geometry.visibleRect,
                            contentSize: geometry.contentSize,
                            containerSize: geometry.containerSize
                        )
                    }) { _, geometry in
                        receiveScrollGeometry(geometry, availableWidth: rowMetrics.availableWidth)
                    }
                    .onChange(of: store.snapshotRevision) { _, _ in
                        rebuildPrefetchMetadata()
                    }
                    .onChange(of: store.scrollResetRevision) { _, _ in
                        scrolloverController.rebaseline()
                    }
                    .onChange(of: proxy.size.width) { _, _ in
                        scrolloverController.rebaseline()
                    }
                    .onChange(of: store.scrolloverRearmRevision) { _, _ in
                        scrolloverController.releaseEmittedIDs()
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

private struct ArticleListRowMetrics {
    let horizontalInset: CGFloat
    let outerVerticalPadding: CGFloat
    let availableWidth: CGFloat

    init(mode: ArticlePresentationMode, containerWidth: CGFloat) {
        switch mode {
        case .compact:
            horizontalInset = containerWidth > 700 ? 28 : 10
            outerVerticalPadding = 0
        case .visual:
            horizontalInset = containerWidth > 700 ? 28 : 16
            outerVerticalPadding = 2
        }
        availableWidth = max(0, containerWidth - horizontalInset * 2)
    }
}

private extension ArticleListView {
    func receiveScrollGeometry(_ geometry: IOSArticleScrollGeometry, availableWidth: CGFloat) {
        let update = scrolloverController.receiveScrollGeometry(geometry, enabled: store.markReadOnScrolloverEnabled)
        if let direction = update.direction {
            store.receiveScrolloverDirection(direction)
            prefetchImages(visibleIDs: scrolloverController.visibleIDs, direction: direction, availableWidth: availableWidth)
        }
        if !update.batch.articleIDs.isEmpty { store.flushScrollover(update.batch) }
    }

    func receiveRowGeometry(articleID: Int64, state: IOSArticleRowGeometryState) {
        let batch = scrolloverController.receiveRowGeometry(
            articleID: articleID,
            state: state,
            enabled: store.markReadOnScrolloverEnabled
        )
        if !batch.articleIDs.isEmpty { store.flushScrollover(batch) }
    }

    func prefetchImages(visibleIDs: [Int64], direction: IOSArticleScrollDirection, availableWidth: CGFloat) {
        guard store.articlePresentationMode.showsArticleImage else { return }
        let ids = imagePrefetchMetadata.candidateIDs(visibleIDs: visibleIDs, direction: direction)
        let targetSize: CGSize
        if ArticlePresentationLayout.usesLandscapeVisual(mode: store.articlePresentationMode, availableWidth: availableWidth) {
            let width = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
            targetSize = CGSize(width: width, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: width))
        } else {
            let width = ArticlePresentationLayout.visualPortraitContentWidth(availableWidth)
            targetSize = CGSize(width: width, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: width))
        }
        let requests = ids.compactMap { id in
            imagePrefetchMetadata.imageURL(for: id).map {
                ArticleImageRequest(url: $0, targetSize: targetSize, displayScale: displayScale)
            }
        }
        let newRequests = imagePrefetchCoordinator.accept(requests)
        guard !newRequests.isEmpty else { return }
        Task.detached(priority: .utility) {
            await ArticleImagePipeline.shared.prefetch(newRequests)
        }
    }

    func rebuildPrefetchMetadata() {
        if imagePrefetchMetadata.update(articles: store.articles) {
            imagePrefetchCoordinator.reset()
        }
        scrolloverController.updateSnapshot(imagePrefetchMetadata.orderedIDs)
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
            .frame(maxWidth: .infinity, alignment: .leading)
    }
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
                .padding(.vertical, ArticleRowContentLayout.compactVerticalPadding)
                .padding(.horizontal, ArticleRowContentLayout.compactHorizontalPadding)
                .frame(width: articleWidth, alignment: .leading)
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

private enum ArticleRowContentLayout {
    static let compactHorizontalPadding: CGFloat = 1
    static let compactVerticalPadding: CGFloat = 2
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
