import SwiftUI
import UIKit
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
import OSLog
#endif

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

enum IOSUIKitTimelineSnapshotPolicy {
    static func requiresStructuralUpdate(previousIDs: [Int64], newIDs: [Int64]) -> Bool {
        previousIDs != newIDs
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

enum IOSArticleMediaAction: Equatable {
    case play(enclosureID: Int64)
    case setListeningList(Bool)
    case requestDownload(enclosureID: Int64)
    case cancelDownload(enclosureID: Int64)
    case retryDownload(enclosureID: Int64)
    case deleteDownload(enclosureID: Int64)
    case configuredDownloadAudio
}

enum IOSArticleAudioPresentation {
    enum DownloadAction: Equatable {
        case download
        case pending
        case delete
        case retry
        case pendingDeletion
    }

    static func downloadAction(_ download: MediaDownload?) -> DownloadAction {
        switch download?.state {
        case .downloaded:
            .delete
        case .requested:
            .pending
        case .deleteRequested:
            .pendingDeletion
        case .failed:
            .retry
        case .notDownloaded, nil:
            .download
        }
    }

    static func downloadableEnclosures(
        _ state: IOSArticleAudioActionState?
    ) -> [Enclosure] {
        guard let state else { return [] }
        return state.audioEnclosures.filter { enclosure in
            switch downloadAction(state.downloads[enclosure.id]) {
            case .download, .retry:
                true
            case .pending, .delete, .pendingDeletion:
                false
            }
        }
    }

    static func enclosureLabel(_ enclosure: Enclosure, index: Int) -> String {
        IOSListeningListPresentation.enclosureLabel(enclosure, index: index)
    }
}

enum IOSArticleSwipeSide: Hashable {
    case leading
    case trailing
}

enum IOSArticleSwipeSlot: Hashable {
    case fullSwipe
    case additional
}

enum IOSArticleSwipeAction: String, CaseIterable, Hashable {
    case readUnread
    case starUnstar
    case openOriginal
    case openMiniflux
    case comments
    case share
    case saveToService
    case downloadAudio

    var title: String {
        switch self {
        case .readUnread: String(localized: "Read / Unread")
        case .starUnstar: String(localized: "Star / Unstar")
        case .openOriginal: String(localized: "Open Original")
        case .openMiniflux: String(localized: "Open in Miniflux")
        case .comments: String(localized: "Open Comments")
        case .share: String(localized: "Share")
        case .saveToService: String(localized: "Save to Third-Party Service")
        case .downloadAudio: String(localized: "Download Audio")
        }
    }

    var contextAction: IOSArticleContextAction? {
        switch self {
        case .readUnread, .starUnstar:
            nil
        case .openOriginal:
            .original
        case .openMiniflux:
            .miniflux
        case .comments:
            .comments
        case .share:
            .share
        case .saveToService:
            .saveToService
        case .downloadAudio:
            nil
        }
    }
}

struct IOSArticleSwipeConfiguration: Equatable {
    /// Stored in visual inner-to-outer order. The last element is therefore
    /// the deliberate Full Swipe action.
    let leading: [IOSArticleSwipeAction]
    let trailing: [IOSArticleSwipeAction]

    static let defaultConfiguration = IOSArticleSwipeConfiguration(
        leading: [.readUnread],
        trailing: [.starUnstar]
    )

    init(
        leading: [IOSArticleSwipeAction],
        trailing: [IOSArticleSwipeAction]
    ) {
        self.leading = Self.normalized(leading)
        self.trailing = Self.normalized(trailing)
    }

    func actions(for side: IOSArticleSwipeSide) -> [IOSArticleSwipeAction] {
        switch side {
        case .leading: leading
        case .trailing: trailing
        }
    }

    func fullSwipeAction(for side: IOSArticleSwipeSide) -> IOSArticleSwipeAction? {
        actions(for: side).last
    }

    func additionalAction(for side: IOSArticleSwipeSide) -> IOSArticleSwipeAction? {
        let actions = actions(for: side)
        return actions.count == 2 ? actions.first : nil
    }

    func setting(
        _ action: IOSArticleSwipeAction?,
        side: IOSArticleSwipeSide,
        slot: IOSArticleSwipeSlot
    ) -> IOSArticleSwipeConfiguration {
        let current = actions(for: side)
        let fullSwipe = current.last
        let additional = current.count == 2 ? current.first : nil
        let updated: [IOSArticleSwipeAction]

        switch slot {
        case .fullSwipe:
            guard let action else {
                updated = []
                break
            }
            if let additional, additional != action {
                updated = [additional, action]
            } else {
                updated = [action]
            }

        case .additional:
            guard let fullSwipe else {
                updated = []
                break
            }
            if let action, action != fullSwipe {
                updated = [action, fullSwipe]
            } else {
                updated = [fullSwipe]
            }
        }

        switch side {
        case .leading:
            return .init(leading: updated, trailing: trailing)
        case .trailing:
            return .init(leading: leading, trailing: updated)
        }
    }

    private static func normalized(
        _ actions: [IOSArticleSwipeAction]
    ) -> [IOSArticleSwipeAction] {
        var seen = Set<IOSArticleSwipeAction>()
        let unique = actions.filter { seen.insert($0).inserted }
        return Array(unique.suffix(2))
    }
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

struct IOSUIKitArticleTimelineStructuralItem {
    let article: ArticleSummary
    let content: ArticleRowContent
}

struct IOSUIKitArticlePresentationState: Equatable {
    let isRead: Bool
    let isStarred: Bool
    let revision: UInt64
}

struct IOSUIKitArticlePresentationDelta {
    let articleID: Int64
    let state: IOSUIKitArticlePresentationState
    let rearmScrollover: Bool
}

struct IOSUIKitFeedIconPresentationDelta {
    let key: IOSFeedIconKey
    let image: UIImage?
    let revision: UInt64
}

/// Owned by the presentation layer, not SwiftUI observation. It retains current
/// mutable state so a later cell binding never needs a complete row reconstruction.
@MainActor
final class IOSUIKitArticleTimelinePresentationBridge {
    private final class WeakControllerSubscription {
        weak var controller: IOSUIKitArticleTimelineController?

        init(_ controller: IOSUIKitArticleTimelineController) {
            self.controller = controller
        }
    }

    private var articleSubscribers: [ObjectIdentifier: WeakControllerSubscription] = [:]
    private var feedIconSubscribers: [ObjectIdentifier: WeakControllerSubscription] = [:]
    private var articleStates: [Int64: IOSUIKitArticlePresentationState] = [:]
    private var feedIcons: [IOSFeedIconKey: IOSUIKitFeedIconPresentationDelta] = [:]

    func subscribeArticles(_ controller: IOSUIKitArticleTimelineController) {
        pruneSubscriptions()
        articleSubscribers[ObjectIdentifier(controller)] = .init(controller)
        controller.applyPresentationBridgeState(self)
    }

    func unsubscribeArticles(_ controller: IOSUIKitArticleTimelineController) {
        articleSubscribers.removeValue(forKey: ObjectIdentifier(controller))
    }

    func subscribeFeedIcons(_ controller: IOSUIKitArticleTimelineController) {
        pruneSubscriptions()
        feedIconSubscribers[ObjectIdentifier(controller)] = .init(controller)
    }

    func unsubscribeFeedIcons(_ controller: IOSUIKitArticleTimelineController) {
        feedIconSubscribers.removeValue(forKey: ObjectIdentifier(controller))
    }

    func replaceArticleStates(_ states: [Int64: IOSUIKitArticlePresentationState]) {
        articleStates = states
    }

    func appendArticleStates(_ states: [Int64: IOSUIKitArticlePresentationState]) {
        for (id, state) in states where articleStates[id] == nil { articleStates[id] = state }
    }

    func removeArticleStates(_ ids: some Sequence<Int64>) {
        for id in ids { articleStates[id] = nil }
    }

    func publishArticle(_ delta: IOSUIKitArticlePresentationDelta) {
        guard delta.state.revision >= articleStates[delta.articleID]?.revision ?? 0 else { return }
        articleStates[delta.articleID] = delta.state
        for subscription in articleSubscribers.values {
            subscription.controller?.applyArticlePresentation(delta)
        }
    }

    func publishFeedIcon(_ delta: IOSUIKitFeedIconPresentationDelta) {
        guard delta.revision >= feedIcons[delta.key]?.revision ?? 0 else { return }
        feedIcons[delta.key] = delta
        for subscription in feedIconSubscribers.values {
            subscription.controller?.applyFeedIconPresentation(delta)
        }
    }

    func resetFeedIcons() {
        feedIcons = [:]
        for subscription in feedIconSubscribers.values {
            subscription.controller?.clearFeedIconPresentation()
        }
    }

    func articleState(for id: Int64, fallback: ArticleSummary) -> IOSUIKitArticlePresentationState {
        articleStates[id] ?? .init(isRead: fallback.isRead, isStarred: fallback.isStarred, revision: 0)
    }

    func feedIcon(for feedID: Int64, variant: FeedIconVariant) -> UIImage? {
        feedIcons[.init(feedID: feedID, variant: variant)]?.image
    }

    private func pruneSubscriptions() {
        articleSubscribers = articleSubscribers.filter { $0.value.controller != nil }
        feedIconSubscribers = feedIconSubscribers.filter { $0.value.controller != nil }
    }
}

final class IOSUIKitArticleTimelineStructuralStorage {
    var items: [IOSUIKitArticleTimelineStructuralItem] = []
}

enum IOSUIKitArticleTimelineStructuralChange {
    case replace
    case append([IOSUIKitArticleTimelineStructuralItem])
    case remove([Int64])
}

struct IOSUIKitArticleTimelineStructuralState {
    let storage: IOSUIKitArticleTimelineStructuralStorage
    let change: IOSUIKitArticleTimelineStructuralChange
    let revision: UInt64

    init(storage: IOSUIKitArticleTimelineStructuralStorage, change: IOSUIKitArticleTimelineStructuralChange, revision: UInt64) {
        self.storage = storage
        self.change = change
        self.revision = revision
    }

    init(items: [IOSUIKitArticleTimelineStructuralItem], revision: UInt64) {
        let storage = IOSUIKitArticleTimelineStructuralStorage()
        storage.items = items
        self.init(storage: storage, change: .replace, revision: revision)
    }
}

struct IOSUIKitArticleTimelineItem {
    let article: ArticleSummary
    let content: ArticleRowContent
    let isRead: Bool
    let isStarred: Bool
    let feedIconImage: UIImage?
}

@MainActor
struct IOSUIKitArticleTimelineView: UIViewControllerRepresentable {
    let structuralState: IOSUIKitArticleTimelineStructuralState
    let presentationBridge: IOSUIKitArticleTimelinePresentationBridge
    let feedIconPresentationBridge: IOSUIKitArticleTimelinePresentationBridge
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let showRelativePublicationTime: Bool
    let iconVariant: FeedIconVariant
    let feedIconRequestRevision: UInt64
    let scrollResetRevision: UInt64
    let markReadOnScrolloverEnabled: Bool
    var swipeConfiguration: IOSArticleSwipeConfiguration = .defaultConfiguration
    var audioActionStates: [Int64: IOSArticleAudioActionState] = [:]
    let showsRefreshControl: Bool
    let naturalTopContentInset: CGFloat
    var usesNativeTopEdgeEffect = true
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    var onArticleMediaAction: (ArticleSummary, IOSArticleMediaAction) -> Void = { _, _ in }
    let onSetRead: (ArticleSummary, Bool) -> Void
    let onSetStarred: (ArticleSummary, Bool) -> Void
    let onRequestFeedIcon: (Int64, FeedIconVariant, CGFloat) -> Void
    let onRefresh: () async -> Void
    let onApproachingEnd: (() -> Void)?
    let onMeaningfulInteraction: () -> Void
    let onScrolloverBatch: (IOSScrolloverBatch) -> Void
    let onScrolloverDirection: (IOSArticleScrollDirection) -> Void
    let onScrolloverPhase: (IOSScrolloverPresentationPhase) -> Void

    func makeUIViewController(context: Context) -> IOSUIKitArticleTimelineController {
        let controller = IOSUIKitArticleTimelineController()
        update(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: IOSUIKitArticleTimelineController, context: Context) {
        update(uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: IOSUIKitArticleTimelineController, coordinator: ()) {
        uiViewController.detachPresentationBridges()
    }

    private func update(_ controller: IOSUIKitArticleTimelineController) {
        controller.onArticleTap = onArticleTap
        controller.onArticleAction = onArticleAction
        controller.onArticleMediaAction = onArticleMediaAction
        controller.onSetRead = onSetRead
        controller.onSetStarred = onSetStarred
        controller.onRequestFeedIcon = onRequestFeedIcon
        controller.onRefresh = onRefresh
        controller.onApproachingEnd = onApproachingEnd
        controller.onMeaningfulInteraction = onMeaningfulInteraction
        controller.onScrolloverBatch = onScrolloverBatch
        controller.onScrolloverDirection = onScrolloverDirection
        controller.onScrolloverPhase = onScrolloverPhase
        controller.update(
            structuralState: structuralState,
            presentationBridge: presentationBridge,
            feedIconPresentationBridge: feedIconPresentationBridge,
            mode: mode,
            previewLines: previewLines,
            showRelativePublicationTime: showRelativePublicationTime,
            iconVariant: iconVariant,
            feedIconRequestRevision: feedIconRequestRevision,
            scrollResetRevision: scrollResetRevision,
            markReadOnScrolloverEnabled: markReadOnScrolloverEnabled,
            swipeConfiguration: swipeConfiguration,
            audioActionStates: audioActionStates,
            showsRefreshControl: showsRefreshControl,
            naturalTopContentInset: naturalTopContentInset,
            usesNativeTopEdgeEffect: usesNativeTopEdgeEffect
        )
    }
}

@MainActor
/// Protects the status-bar glyph band while leaving the Liquid Glass navigation
/// chrome itself unbacked over scrolling article content.
final class IOSUIKitTimelineTopScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        // A straight ramp has a constant slope, so the eye finds its lower edge.
        // Holding almost full strength across the glyph band and then easing out
        // makes the scrim read as shorter *and* softer than a linear one, without
        // taking protection away from where the status bar actually sits.
        gradient.locations = [0, 0.55, 0.75, 1]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateColors()
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Strength at the very top. The remaining stops are fractions of it, so
    /// this one number changes the whole scrim.
    static let peakAlpha: CGFloat = 0.68

    private func updateColors() {
        let base = UIColor.systemBackground.resolvedColor(with: traitCollection)
        gradient.colors = [
            base.withAlphaComponent(Self.peakAlpha).cgColor,
            base.withAlphaComponent(Self.peakAlpha * 0.95).cgColor,
            base.withAlphaComponent(Self.peakAlpha * 0.4).cgColor,
            base.withAlphaComponent(0).cgColor,
        ]
    }
}


final class IOSUIKitArticleTimelineController: UIViewController, UITableViewDelegate, UITableViewDataSourcePrefetching {
    private enum Section: Hashable { case main }

    var onArticleTap: ((ArticleSummary) -> Void)?
    var onArticleAction: ((ArticleSummary, IOSArticleContextAction) -> Void)?
    var onArticleMediaAction: ((ArticleSummary, IOSArticleMediaAction) -> Void)?
    var onSetRead: ((ArticleSummary, Bool) -> Void)?
    var onSetStarred: ((ArticleSummary, Bool) -> Void)?
    var onRequestFeedIcon: ((Int64, FeedIconVariant, CGFloat) -> Void)?
    var onRefresh: (() async -> Void)?
    var onApproachingEnd: (() -> Void)?
    var onMeaningfulInteraction: (() -> Void)?
    var onScrolloverBatch: ((IOSScrolloverBatch) -> Void)?
    var onScrolloverDirection: ((IOSArticleScrollDirection) -> Void)?
    var onScrolloverPhase: ((IOSScrolloverPresentationPhase) -> Void)?

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Section, Int64>!
    private var orderedIDs: [Int64] = []
    private var itemsByID: [Int64: IOSUIKitArticleTimelineStructuralItem] = [:]
    private var presentationByID: [Int64: IOSUIKitArticlePresentationState] = [:]
    private weak var presentationBridge: IOSUIKitArticleTimelinePresentationBridge?
    private weak var feedIconPresentationBridge: IOSUIKitArticleTimelinePresentationBridge?
    private var structuralRevision: UInt64?
    private var mode: ArticlePresentationMode = .visual
    private var previewLines: ArticlePreviewLines = .standard
    private var showRelativePublicationTime = false
    private var iconVariant: FeedIconVariant = .normal
    private var feedIconRequestRevision: UInt64?
    private var scrollResetRevision: UInt64?
    private var markReadOnScrolloverEnabled = false
    private var swipeConfiguration = IOSArticleSwipeConfiguration.defaultConfiguration
    private var audioActionStates: [Int64: IOSArticleAudioActionState] = [:]
    private var showsRefreshControl = true
    private var naturalTopContentInset: CGFloat = 0
    private var usesNativeTopEdgeEffect = true
    private var scrolloverPhase: IOSScrolloverPresentationPhase = .idle
    private var scrolloverLayoutGeneration: UInt64 = 0
    private var resolvedScrolloverFrames = IOSUIKitResolvedScrolloverFrameStore()
    private struct ScrollAnchor {
        let articleID: Int64
        let viewportOffset: CGFloat
    }

    private var geometryIdentity: IOSUIKitTimelineGeometryIdentity?
    private var geometryGeneration: UInt64 = 0
    /// Geometry changes may temporarily make UIKit recalculate its content
    /// offset before replacement row heights are ready. Capture the stable
    /// article identity before that transition so the asynchronous reload can
    /// restore the user's place rather than anchoring whatever UIKit happens to
    /// expose afterwards.
    private var pendingGeometryScrollAnchor: ScrollAnchor?
    private var preparedWindowTask: Task<Void, Never>?
    private var preparedWindowGeneration: UInt64 = 0
    private var scheduledPreparedWindowGeneration: UInt64?
    /// Keep image preparation narrowly ahead of the viewport. UIKit may offer
    /// a wider prefetch window, but the image pipeline receives at most the next
    /// two image-bearing articles in the inferred scroll direction.
    private static let maximumOffscreenArticleImagePrefetchCount = 2
    private var imageArticleIDs = Set<Int64>()
    private var prefetchTasks: [Int64: (request: ArticleImageRequest, task: Task<Void, Never>)] = [:]
    private let refreshControl = UIRefreshControl()
    private let statusBarScrim = IOSUIKitTimelineTopScrimView()
    private var statusBarScrimHeight: NSLayoutConstraint!
    private let scrolloverGeometryTracker = IOSUIKitScrolloverGeometryTracker()
    private let preparedLayoutCoordinator = IOSUIKitArticleLayoutPreparationCoordinator()
    /// Exact heights for every loaded row. Estimation is disabled, so a missing
    /// entry would force Core Text onto the main actor during layout.
    private let rowHeights = IOSUIKitArticleRowHeightStore()
    private var rowHeightTask: Task<Void, Never>?
    private var rowHeightGeneration: UInt64 = 0
    private var pendingStructuralApply: Task<Void, Never>?
    /// Monotonically identifies the newest structural snapshot publication.
    /// Cancellation alone is not sufficient because the detached height
    /// measurement may finish after cancellation; the generation check prevents
    /// such stale work from publishing an older diffable snapshot afterwards.
    private var structuralApplyGeneration: UInt64 = 0
    /// Held until the first layout pass resolves a geometry. Applying a snapshot
    /// before then publishes rows whose heights cannot exist yet, and the table
    /// answers by measuring every one of them synchronously while laying out.
    private var deferredSnapshot: NSDiffableDataSourceSnapshot<Section, Int64>?
    private let performanceMetrics = IOSUIKitTimelinePerformanceMetrics()
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
    private static let performanceSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews",
        category: "timeline-performance"
    )
#endif
    private(set) var structuralReconciliationCount = 0
    private(set) var structuralSnapshotApplicationCount = 0
    private(set) var articlePresentationApplicationCount = 0
    private(set) var feedIconPresentationApplicationCount = 0
    private(set) var scrolloverRearmCount = 0
#if DEBUG
    private(set) var fullPrefetchCancellationCountForTesting = 0
    private(set) var layoutInvalidationCountForTesting = 0
    private(set) var visibleCellReconfigurationPassCountForTesting = 0
    private(set) var layoutPrefetchInputCountForTesting = 0
    var articleImagePrefetchTaskCountForTesting: Int { prefetchTasks.count }
    var tableViewForTesting: UITableView { tableView }
    var preparedRowHeightCountForTesting: Int { rowHeights.preparedCount }
    private(set) var synchronousRowHeightFallbackCountForTesting = 0
    /// Structural updates and geometry changes measure heights off the main
    /// actor before they are applied. Tests await that work instead of polling.
    func settleForTesting() async {
        while pendingStructuralApply != nil || rowHeightTask != nil {
            await pendingStructuralApply?.value
            await rowHeightTask?.value
        }
    }
#endif
#if DEBUG
    private(set) var scrollResetApplicationCountForTesting = 0
    private(set) var lastScrollResetOffsetForTesting: CGPoint?
    var contentOffsetForTesting: CGPoint { tableView.contentOffset }
    var scrolloverLayoutGenerationForTesting: UInt64 { scrolloverLayoutGeneration }
    var orderedArticleIDsForTesting: [Int64] { orderedIDs }
    var scrollAnchorForTesting: (articleID: Int64, viewportOffset: CGFloat)? {
        currentScrollAnchor().map { ($0.articleID, $0.viewportOffset) }
    }
    func captureGeometryScrollAnchorForTesting() {
        captureGeometryScrollAnchorIfNeeded()
    }
    var nativeTopEdgeEffectEnabledForTesting: Bool {
        if #available(iOS 26.0, *) {
            return !tableView.topEdgeEffect.isHidden
        }
        return false
    }
    var nativeTopEdgeEffectUsesAutomaticStyleForTesting: Bool {
        if #available(iOS 26.0, *) {
            return tableView.topEdgeEffect.style.isEqual(UIScrollEdgeEffect.Style.automatic)
        }
        return false
    }
    var statusBarScrimVisibleForTesting: Bool { !statusBarScrim.isHidden }
    var naturalTopContentInsetForTesting: CGFloat { tableView.contentInset.top }
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isOpaque = true

        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.isOpaque = true
        tableView.contentInsetAdjustmentBehavior = .automatic
        // Every row height comes from the deterministic engine, so estimation is
        // switched off entirely. Estimated self-sizing rewrites `contentSize`
        // while the list scrolls, which moves the running deceleration target.
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        // A plain table reserves padding above its (absent) section header.
        tableView.sectionHeaderTopPadding = 0
        tableView.alwaysBounceVertical = true
        tableView.delegate = self
        tableView.prefetchDataSource = self
        for variant in [
            IOSUIKitArticleCellLayoutVariant.compact,
            .visualTextOnly,
            .visualPortrait,
            .visualLandscape,
            .visualSideTitle,
            .visualSideTitleWide,
            .visualSideTitleTextOnly,
        ] {
            tableView.register(IOSUIKitArticleCell.self, forCellReuseIdentifier: IOSUIKitArticleCell.reuseIdentifier(for: variant))
        }
        // Top-edge visibility is presentation-driven and may change on
        // rotation. The bottom edge effect remains disabled everywhere.
        if #available(iOS 26.0, *) {
            tableView.bottomEdgeEffect.isHidden = true
        }
        refreshControl.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self, UITraitLayoutDirection.self]) { (self: Self, _) in
            self.updateGeometryIfNeeded()
        }
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        statusBarScrim.translatesAutoresizingMaskIntoConstraints = false
        // The safe area of this view starts below the *navigation bar*, not below
        // the status bar, so anchoring to it would stretch the scrim across the
        // capsule. The status bar's own frame is the exact measure, and it is
        // zero in landscape, where there is nothing to protect.
        statusBarScrimHeight = statusBarScrim.heightAnchor.constraint(equalToConstant: 0)
        view.addSubview(statusBarScrim)
        NSLayoutConstraint.activate([
            statusBarScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarScrim.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarScrimHeight,
        ])
        applyTopEdgeEffectPolicy()

        dataSource = UITableViewDiffableDataSource<Section, Int64>(tableView: tableView) { [weak self] tableView, indexPath, id in
            guard let self,
                  let item = self.renderedItem(for: id)
            else { return nil }
            let geometry = IOSUIKitArticleGeometry(
                mode: self.mode,
                containerWidth: tableView.bounds.width
            )
            let variant = geometry.variant(hasImage: self.mode.showsArticleImage && item.content.imageURL != nil)
            guard let cell = tableView.dequeueReusableCell(withIdentifier: IOSUIKitArticleCell.reuseIdentifier(for: variant), for: indexPath) as? IOSUIKitArticleCell else { return nil }
            self.configure(cell, item: item)
            return cell
        }
        dataSource.defaultRowAnimation = .none
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateStatusBarScrimHeight()
        updateGeometryIfNeeded()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        captureGeometryScrollAnchorIfNeeded()
        super.viewWillTransition(to: size, with: coordinator)
    }

    private func applyTopEdgeEffectPolicy() {
        if #available(iOS 26.0, *) {
            tableView.topEdgeEffect.style = .automatic
            tableView.topEdgeEffect.isHidden = !usesNativeTopEdgeEffect
            tableView.bottomEdgeEffect.isHidden = true
            statusBarScrim.isHidden = usesNativeTopEdgeEffect
        } else {
            statusBarScrim.isHidden = false
        }
    }

    private func updateStatusBarScrimHeight() {
        let height = view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        guard statusBarScrimHeight.constant != height else { return }
        statusBarScrimHeight.constant = height
    }

    private func updateGeometryIfNeeded() {
        guard let newIdentity = currentGeometryIdentity(), newIdentity != geometryIdentity else { return }
        if geometryIdentity != nil {
            captureGeometryScrollAnchorIfNeeded()
        }
        geometryIdentity = newIdentity
        geometryGeneration &+= 1
        performanceMetrics.recordGeometryChange()
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
        Self.performanceSignposter.emitEvent("Timeline geometry changed")
#endif
        invalidateScrolloverGeometry()
        cancelIncompatibleImagePrefetch()
        reconfigureVisibleCells(needsLayout: true)
        schedulePreparedLayoutWindow(for: newIdentity)
        // The store keeps serving the superseded heights while the replacement
        // set is measured, so rotation and Dynamic Type never block a frame on a
        // full re-measurement of every loaded row.
        rowHeights.beginGeneration(newIdentity)
        if let deferred = deferredSnapshot {
            // First resolved geometry: publish the rows that were held back,
            // through the same gate that measures their heights first.
            deferredSnapshot = nil
            applySnapshotWhenHeightsReady(deferred)
        } else {
            scheduleRowHeightMeasurement(reloadWhenComplete: true)
        }
    }

    private func scheduleRowHeightMeasurement(reloadWhenComplete: Bool) {
        guard let identity = geometryIdentity else { return }
        let missing = rowHeights.missingIDs(in: orderedIDs)
        guard !missing.isEmpty else {
            if reloadWhenComplete { reloadPreservingAnchor() }
            return
        }
        rowHeightGeneration &+= 1
        let generation = rowHeightGeneration
        let inputs = rowHeightInputs(for: missing)
        rowHeightTask?.cancel()
        rowHeightTask = Task { @MainActor [weak self] in
            let measured = await IOSUIKitArticleRowHeightMeasurement.heights(for: inputs)
            guard let self, !Task.isCancelled, self.rowHeightGeneration == generation else { return }
            self.rowHeightTask = nil
            self.rowHeights.store(measured, for: identity)
            _ = self.rowHeights.retireSupersededHeights(ifComplete: self.orderedIDs)
            if reloadWhenComplete { self.reloadPreservingAnchor() }
        }
    }

    private func rowHeightInputs(for ids: [Int64]) -> [(id: Int64, input: IOSUIKitArticleLayoutInput)] {
        ids.compactMap { id in
            guard let item = renderedItem(for: id) else { return nil }
            return (id, preparedLayoutInput(for: item))
        }
    }

    /// A reload with exact heights rewrites every row position at once, so the
    /// visible article is re-anchored explicitly instead of being left wherever
    /// the new content size happens to put it.
    private func reloadPreservingAnchor() {
        let anchor = pendingGeometryScrollAnchor ?? currentScrollAnchor()
        pendingGeometryScrollAnchor = nil
        dataSource.applySnapshotUsingReloadData(dataSource.snapshot(), completion: nil)
        guard let anchor, let row = orderedIDs.firstIndex(of: anchor.articleID) else { return }
        tableView.layoutIfNeeded()
        let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        tableView.setContentOffset(
            CGPoint(x: tableView.contentOffset.x, y: rect.minY - anchor.viewportOffset),
            animated: false
        )
    }

    private func captureGeometryScrollAnchorIfNeeded() {
        guard pendingGeometryScrollAnchor == nil else { return }
        pendingGeometryScrollAnchor = currentScrollAnchor()
    }

    private func currentScrollAnchor() -> ScrollAnchor? {
        guard let visibleRows = tableView.indexPathsForVisibleRows,
              let indexPath = visibleRows.min(by: { lhs, rhs in
                  tableView.rectForRow(at: lhs).minY < tableView.rectForRow(at: rhs).minY
              }),
              indexPath.row < orderedIDs.count
        else { return nil }
        return ScrollAnchor(
            articleID: orderedIDs[indexPath.row],
            viewportOffset: tableView.rectForRow(at: indexPath).minY - tableView.contentOffset.y
        )
    }

    /// Rows are never published before their exact heights exist. Applying a
    /// snapshot whose heights are unknown would make the table measure text
    /// synchronously while laying out.
    /// Built from `orderedIDs`, which the controller already maintains as the
    /// authoritative order, rather than from the data source's current state.
    /// The two diverge whenever a snapshot is still held back, and reading the
    /// data source then yields an empty snapshot with no section at all.
    private func currentSnapshot() -> NSDiffableDataSourceSnapshot<Section, Int64> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Int64>()
        snapshot.appendSections([.main])
        snapshot.appendItems(orderedIDs)
        return snapshot
    }

    private func applySnapshotWhenHeightsReady(_ snapshot: NSDiffableDataSourceSnapshot<Section, Int64>) {
        // Every newer structural state supersedes every older pending
        // publication, including when the new snapshot can be applied
        // immediately. Without this, an older height-measurement task can finish
        // later and republish identifiers that have already been removed from
        // itemsByID, causing the diffable cell provider to return nil and UIKit
        // to abort.
        structuralApplyGeneration &+= 1
        let generation = structuralApplyGeneration
        pendingStructuralApply?.cancel()
        pendingStructuralApply = nil

        guard let identity = geometryIdentity else {
            deferredSnapshot = snapshot
            return
        }
        let missing = rowHeights.missingIDs(in: snapshot.itemIdentifiers)
        guard !missing.isEmpty else {
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }
        let inputs = rowHeightInputs(for: missing)
        pendingStructuralApply = Task { @MainActor [weak self] in
            let measured = await IOSUIKitArticleRowHeightMeasurement.heights(for: inputs)
            guard let self,
                  !Task.isCancelled,
                  self.structuralApplyGeneration == generation
            else { return }
            self.pendingStructuralApply = nil
            self.rowHeights.store(measured, for: identity)
            self.dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return UITableView.automaticDimension }
        if let height = rowHeights.height(for: id) { return height }
        // Last resort: a prepared height is missing. Worth counting rather than
        // silently absorbing, because this is the one path that can put Core Text
        // on the main actor during layout.
        guard let item = renderedItem(for: id) else { return UITableView.automaticDimension }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let metrics = preparedLayoutCoordinator.measureSynchronously(preparedLayoutInput(for: item), priority: .visible)
        performanceMetrics.recordDeterministicHeightFallback(durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt)
#if DEBUG
        synchronousRowHeightFallbackCountForTesting &+= 1
#endif
        if let identity = geometryIdentity { rowHeights.store([id: metrics.cellSize.height], for: identity) }
        return metrics.cellSize.height
    }

    func update(
        structuralState: IOSUIKitArticleTimelineStructuralState,
        presentationBridge newPresentationBridge: IOSUIKitArticleTimelinePresentationBridge,
        feedIconPresentationBridge newFeedIconPresentationBridge: IOSUIKitArticleTimelinePresentationBridge,
        mode newMode: ArticlePresentationMode,
        previewLines newPreviewLines: ArticlePreviewLines,
        showRelativePublicationTime newShowRelativePublicationTime: Bool = false,
        iconVariant newIconVariant: FeedIconVariant,
        feedIconRequestRevision newFeedIconRequestRevision: UInt64,
        scrollResetRevision newScrollResetRevision: UInt64,
        markReadOnScrolloverEnabled newMarkReadOnScrolloverEnabled: Bool,
        swipeConfiguration newSwipeConfiguration: IOSArticleSwipeConfiguration = .defaultConfiguration,
        audioActionStates newAudioActionStates: [Int64: IOSArticleAudioActionState] = [:],
        showsRefreshControl newShowsRefreshControl: Bool,
        naturalTopContentInset newNaturalTopContentInset: CGFloat = 0,
        usesNativeTopEdgeEffect newUsesNativeTopEdgeEffect: Bool = true
    ) {
        loadViewIfNeeded()
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
        IOSUIKitTimelinePerformanceDiagnostics.currentController = self
#endif

        let structuralChanged = structuralRevision != structuralState.revision
        let layoutInputsChanged = mode != newMode
            || previewLines != newPreviewLines
            || showRelativePublicationTime != newShowRelativePublicationTime
        let iconVariantChanged = iconVariant != newIconVariant
        let feedIconRequestChanged = feedIconRequestRevision != nil && feedIconRequestRevision != newFeedIconRequestRevision
        let resetChanged = scrollResetRevision != nil && scrollResetRevision != newScrollResetRevision
        let clampedNaturalTopContentInset = max(0, newNaturalTopContentInset)
        let naturalTopInsetChanged = abs(naturalTopContentInset - clampedNaturalTopContentInset) > 0.5
        let wasAtNaturalTop = structuralRevision == nil
            || abs(tableView.contentOffset.y + tableView.adjustedContentInset.top) <= 0.5
        let topEdgePolicyChanged = usesNativeTopEdgeEffect != newUsesNativeTopEdgeEffect

        mode = newMode
        previewLines = newPreviewLines
        showRelativePublicationTime = newShowRelativePublicationTime
        iconVariant = newIconVariant
        feedIconRequestRevision = newFeedIconRequestRevision
        scrollResetRevision = newScrollResetRevision
        markReadOnScrolloverEnabled = newMarkReadOnScrolloverEnabled
        swipeConfiguration = newSwipeConfiguration
        audioActionStates = newAudioActionStates
        showsRefreshControl = newShowsRefreshControl
        naturalTopContentInset = clampedNaturalTopContentInset
        usesNativeTopEdgeEffect = newUsesNativeTopEdgeEffect
        tableView.refreshControl = showsRefreshControl ? refreshControl : nil
        if naturalTopInsetChanged {
            // The detached portrait capsule should clear the first article only at
            // the natural beginning of the list. contentInset scrolls away with
            // the content, unlike a permanent safe-area reservation.
            invalidateScrolloverGeometry()
            tableView.contentInset.top = naturalTopContentInset
            if wasAtNaturalTop {
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: -tableView.adjustedContentInset.top),
                    animated: false
                )
            }
        }
        if topEdgePolicyChanged {
            applyTopEdgeEffectPolicy()
        }
        if presentationBridge !== newPresentationBridge {
            presentationBridge?.unsubscribeArticles(self)
            presentationBridge = newPresentationBridge
            newPresentationBridge.subscribeArticles(self)
        }
        if feedIconPresentationBridge !== newFeedIconPresentationBridge {
            feedIconPresentationBridge?.unsubscribeFeedIcons(self)
            feedIconPresentationBridge = newFeedIconPresentationBridge
            newFeedIconPresentationBridge.subscribeFeedIcons(self)
        }

        var structuralUpdate: IOSUIKitArticleTimelineStructuralChange?
        if structuralChanged {
            structuralReconciliationCount &+= 1
            performanceMetrics.recordStructuralReconciliation()
            let canApplyIncrementally = structuralRevision == structuralState.revision &- 1
            if canApplyIncrementally, case let .append(appendedItems) = structuralState.change {
                let appended = appendedItems.filter { itemsByID[$0.article.id] == nil }
                let appendedIDs = appended.map(\.article.id)
                orderedIDs.append(contentsOf: appendedIDs)
                for item in appended {
                    itemsByID[item.article.id] = item
                    presentationByID[item.article.id] = newPresentationBridge.articleState(for: item.article.id, fallback: item.article)
                    if item.content.imageURL != nil { imageArticleIDs.insert(item.article.id) }
                }
                scrolloverGeometryTracker.appendSnapshot(appendedIDs)
                applySnapshotWhenHeightsReady(currentSnapshot())
                structuralUpdate = .append(appended)
            } else if canApplyIncrementally, case let .remove(removedIDs) = structuralState.change {
                let removed = removedIDs.filter { itemsByID[$0] != nil }
                if !removed.isEmpty {
                    let removedSet = Set(removed)
                    orderedIDs.removeAll { removedSet.contains($0) }
                    for id in removed {
                        itemsByID[id] = nil
                        presentationByID[id] = nil
                        imageArticleIDs.remove(id)
                        prefetchTasks.removeValue(forKey: id)?.task.cancel()
                    }
                    scrolloverGeometryTracker.removeSnapshot(removed)
                    invalidateScrolloverGeometry()
                    rowHeights.remove(removed)
                    applySnapshotWhenHeightsReady(currentSnapshot())
                    structuralUpdate = .remove(removed)
                }
            } else {
                let items = structuralState.storage.items
                let newIDs = items.map(\.article.id)
                orderedIDs = newIDs
                itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.article.id, $0) })
                imageArticleIDs = Set(items.compactMap { $0.content.imageURL == nil ? nil : $0.article.id })
                presentationByID = Dictionary(uniqueKeysWithValues: items.map {
                    ($0.article.id, newPresentationBridge.articleState(for: $0.article.id, fallback: $0.article))
                })
                scrolloverGeometryTracker.updateSnapshot(newIDs)
                invalidateScrolloverGeometry()
                applySnapshotWhenHeightsReady(currentSnapshot())
                structuralUpdate = .replace
            }
            structuralRevision = structuralState.revision
            structuralSnapshotApplicationCount &+= 1
            performanceMetrics.recordSnapshotApply()
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
            Self.performanceSignposter.emitEvent("Timeline snapshot applied")
#endif
        }
        // Append and removal own only their changed IDs. Reconfiguring every
        // visible cell here used to restart image bindings and duplicate layout
        // work even though neither operation changes unaffected row geometry.
        if iconVariantChanged {
            reconfigureVisibleCells(needsLayout: false)
        }

        if case .replace? = structuralUpdate {
            cancelAllPrefetch()
            schedulePreparedLayoutWindow(for: geometryIdentity)
            performanceMetrics.recordLayoutInvalidation()
#if DEBUG
            layoutInvalidationCountForTesting &+= 1
#endif
        } else if case let .append(appended)? = structuralUpdate {
            // Keep the existing visible/nearby window and prepare only the new
            // immutable inputs. UIKit prefetch will promote rows as they approach.
            preparedLayoutCoordinator.prepare(
                appended.prefix(IOSUIKitArticleLayoutPreparationCoordinator.nearbyWindowLimit)
                    .compactMap { renderedItem(for: $0.article.id) }
                    .map { preparedLayoutInput(for: $0) },
                priority: .nearby
            )
        }
        if layoutInputsChanged { updateGeometryIfNeeded() }
        if feedIconRequestChanged { requestFeedIconsForVisibleCells() }
        if resetChanged {
            // Semantic scope/filter/sort resets intentionally own the scroll
            // position. Never let a pending geometry-only anchor restore the
            // previous article after that explicit reset.
            pendingGeometryScrollAnchor = nil
            invalidateScrolloverGeometry()
            let naturalTop = CGPoint(x: 0, y: -tableView.adjustedContentInset.top)
            tableView.setContentOffset(naturalTop, animated: false)
#if DEBUG
            scrollResetApplicationCountForTesting &+= 1
            lastScrollResetOffsetForTesting = naturalTop
#endif
        }
    }

    private func renderedItem(for id: Int64) -> IOSUIKitArticleTimelineItem? {
        guard let item = itemsByID[id] else { return nil }
        let presentation = presentationByID[id] ?? presentationBridge?.articleState(for: id, fallback: item.article) ?? .init(isRead: item.article.isRead, isStarred: item.article.isStarred, revision: 0)
        return .init(article: item.article, content: item.content, isRead: presentation.isRead, isStarred: presentation.isStarred, feedIconImage: feedIconPresentationBridge?.feedIcon(for: item.article.feedId, variant: iconVariant))
    }

    private func configure(_ cell: IOSUIKitArticleCell, item: IOSUIKitArticleTimelineItem) {
        let layoutInput = preparedLayoutInput(for: item)
        let layoutMetrics: IOSUIKitArticleLayoutMetrics
        if let prepared = preparedLayoutCoordinator.metrics(for: layoutInput, priority: .visible) {
            performanceMetrics.recordDeterministicHeightRequest(prepared: true)
            layoutMetrics = prepared
        } else {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            layoutMetrics = preparedLayoutCoordinator.measureSynchronously(layoutInput, priority: .visible)
            performanceMetrics.recordDeterministicHeightFallback(durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt)
        }
        cell.performanceMetrics = performanceMetrics
        cell.setArticleImageArrivalAnimationsEnabled(!scrolloverPhase.isScrolling)
        performanceMetrics.recordConfigure()
        cell.configure(
            item: item,
            mode: mode,
            previewLines: previewLines,
            showRelativePublicationTime: showRelativePublicationTime,
            displayScale: view.traitCollection.displayScale,
            preparedLayoutMetrics: layoutMetrics
        )
        onRequestFeedIcon?(item.content.article.feedId, iconVariant, view.traitCollection.displayScale)
    }

    func applyPresentationBridgeState(_ bridge: IOSUIKitArticleTimelinePresentationBridge) {
        for id in orderedIDs where itemsByID[id] != nil {
            presentationByID[id] = bridge.articleState(for: id, fallback: itemsByID[id]!.article)
        }
    }

    func applyArticlePresentation(_ delta: IOSUIKitArticlePresentationDelta) {
        guard let current = presentationByID[delta.articleID], delta.state.revision >= current.revision else { return }
        articlePresentationApplicationCount &+= 1
        presentationByID[delta.articleID] = delta.state
        if delta.rearmScrollover {
            scrolloverGeometryTracker.rearm([delta.articleID])
            scrolloverRearmCount &+= 1
        }
        guard let indexPath = dataSource.indexPath(for: delta.articleID),
              let cell = tableView.cellForRow(at: indexPath) as? IOSUIKitArticleCell else { return }
        cell.updateStatus(isRead: delta.state.isRead, isStarred: delta.state.isStarred)
    }

    func applyFeedIconPresentation(_ delta: IOSUIKitFeedIconPresentationDelta) {
        guard delta.key.variant == iconVariant else { return }
        feedIconPresentationApplicationCount &+= 1
        applyFeedIconPresentation(delta, to: materializedVisibleArticleCells())
    }

    func applyFeedIconPresentation(_ delta: IOSUIKitFeedIconPresentationDelta, to cells: [IOSUIKitArticleCell]) {
        for cell in cells {
            guard let id = cell.representedArticleID,
                  let item = itemsByID[id], item.article.feedId == delta.key.feedID else { continue }
            cell.updateFeedIcon(image: delta.image, title: item.content.article.feedTitle)
        }
    }

    func clearFeedIconPresentation() {
        feedIconPresentationApplicationCount &+= 1
        clearFeedIconPresentation(to: materializedVisibleArticleCells())
    }

    func clearFeedIconPresentation(to cells: [IOSUIKitArticleCell]) {
        for cell in cells {
            guard let id = cell.representedArticleID, let item = itemsByID[id] else { continue }
            cell.updateFeedIcon(image: nil, title: item.content.article.feedTitle)
        }
    }

    /// Returns only cells UIKit has already materialized. Avoid
    /// `tableView.visibleCells` from update/presentation paths: on iOS 27 that
    /// accessor may synchronously create cells while a diffable snapshot is
    /// transitioning. During the intentional short window where `itemsByID`
    /// already reflects the new structural state but the table still presents
    /// the old snapshot, forced cell creation can ask the provider for an ID
    /// that was just removed and UIKit asserts when the provider returns nil.
    private func materializedVisibleArticleCells() -> [IOSUIKitArticleCell] {
        (tableView.indexPathsForVisibleRows ?? []).compactMap {
            tableView.cellForRow(at: $0) as? IOSUIKitArticleCell
        }
    }

    private func requestFeedIconsForVisibleCells() {
        for cell in materializedVisibleArticleCells() {
            guard let id = cell.representedArticleID,
                  let item = itemsByID[id]
            else { continue }
            onRequestFeedIcon?(item.content.article.feedId, iconVariant, view.traitCollection.displayScale)
        }
    }

    private func reconfigureVisibleCells(needsLayout: Bool) {
#if DEBUG
        visibleCellReconfigurationPassCountForTesting &+= 1
#endif
        for cell in materializedVisibleArticleCells() {
            guard let id = cell.representedArticleID, let item = renderedItem(for: id) else { continue }
            configure(cell, item: item)
            if needsLayout { cell.setNeedsLayout() }
        }
    }

    @objc private func refreshTriggered() {
        guard showsRefreshControl, let onRefresh else {
            refreshControl.endRefreshing()
            return
        }
        Task { @MainActor [weak self] in
            await onRefresh()
            self?.refreshControl.endRefreshing()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return }
        onArticleTap?(item.article)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        recordResolvedScrolloverFrame(for: cell)
        if let articleCell = cell as? IOSUIKitArticleCell {
            reconcilePresentationForDisplay(articleCell)
        }
        prepareVisibleLayoutMetrics()
        guard !orderedIDs.isEmpty, indexPath.row >= max(0, orderedIDs.count - 5) else { return }
        onApproachingEnd?()
    }

    func reconcilePresentationForDisplay(_ cell: IOSUIKitArticleCell) {
        guard let articleID = cell.representedArticleID,
              let item = itemsByID[articleID] else { return }
        let articleState = presentationBridge?.articleState(for: articleID, fallback: item.article)
        cell.updateStatus(
            isRead: articleState?.isRead ?? item.article.isRead,
            isStarred: articleState?.isStarred ?? item.article.isStarred
        )
        cell.updateFeedIcon(
            image: feedIconPresentationBridge?.feedIcon(for: item.article.feedId, variant: iconVariant),
            title: item.content.article.feedTitle
        )
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Keep the resolved frame briefly so either lifecycle/scroll callback order
        // can still prove a crossing using the same content-coordinate geometry.
        recordResolvedScrolloverFrame(for: cell)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
        Self.performanceSignposter.emitEvent("Timeline interaction began")
#endif
        onMeaningfulInteraction?()
        setScrolloverPhase(.interacting)
        sampleScrolloverGeometry()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrolloverPhase.isScrolling else { return }
        sampleScrolloverGeometry()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { sampleScrolloverGeometry() }
        setScrolloverPhase(decelerate ? .decelerating : .idle)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        sampleScrolloverGeometry()
        setScrolloverPhase(.idle)
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        invalidateScrolloverGeometry()
    }

    private func setScrolloverPhase(_ phase: IOSScrolloverPresentationPhase) {
        guard scrolloverPhase != phase else { return }
        scrolloverPhase = phase
        IOSArticleImagePresentationScheduler.shared.setScrolling(phase.isScrolling)
        let animationsEnabled = !phase.isScrolling
        for case let cell as IOSUIKitArticleCell in tableView.visibleCells {
            cell.setArticleImageArrivalAnimationsEnabled(animationsEnabled)
        }
        // Every phase boundary restarts the ballistic baseline.
        scrolloverGeometryTracker.setPhase(phase)
        onScrolloverPhase?(phase)
    }

    private func invalidateScrolloverGeometry() {
        scrolloverLayoutGeneration &+= 1
        resolvedScrolloverFrames.removeAll()
        scrolloverGeometryTracker.invalidateGeometry()
    }

    private func recordResolvedScrolloverFrame(for cell: UITableViewCell) {
        guard let articleCell = cell as? IOSUIKitArticleCell,
              let articleID = articleCell.representedArticleID else { return }
        resolvedScrolloverFrames.record(
            articleID: articleID,
            frame: articleCell.frame
        )
    }

    private func refreshResolvedVisibleScrolloverFrames() {
        for case let cell as IOSUIKitArticleCell in tableView.visibleCells {
            recordResolvedScrolloverFrame(for: cell)
        }
    }

    private func sampleScrolloverGeometry() {
        guard markReadOnScrolloverEnabled, tableView.bounds.height > 0 else { return }

        let effectiveTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let effectiveBottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        // `visibleCells` are UIKit-resolved geometry. The retained source covers a
        // cell whose didEndDisplaying arrives on either side of this scroll callback.
        refreshResolvedVisibleScrolloverFrames()

        let sample = IOSUIKitScrolloverGeometrySample(
            contentOffsetY: tableView.contentOffset.y,
            effectiveTop: effectiveTop,
            effectiveBottom: effectiveBottom,
            contentHeight: tableView.contentSize.height,
            rowFrames: resolvedScrolloverFrames.frames,
            layoutGeneration: scrolloverLayoutGeneration
        )
        let result = scrolloverGeometryTracker.receive(sample, enabled: true)
        if let direction = result.direction { onScrolloverDirection?(direction) }
        if !result.batch.articleIDs.isEmpty { onScrolloverBatch?(result.batch) }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        swipeActionsConfiguration(for: .leading, indexPath: indexPath)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        swipeActionsConfiguration(for: .trailing, indexPath: indexPath)
    }

    private func swipeActionsConfiguration(
        for side: IOSArticleSwipeSide,
        indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let item = renderedItem(for: id)
        else { return nil }

        // Product settings are inner-to-outer. UIKit assigns Full Swipe to its
        // first action, so feed UIKit outer-to-inner and keep the semantic
        // storage independent of UIKit's control ordering.
        let semanticActions = swipeConfiguration.actions(for: side)
        let configuredFullSwipe = semanticActions.last
        let renderedActions = semanticActions
            .reversed()
            .compactMap { semanticAction -> (IOSArticleSwipeAction, UIContextualAction)? in
                guard let action = makeSwipeAction(
                    semanticAction,
                    articleID: id,
                    item: item
                ) else { return nil }
                return (semanticAction, action)
            }

        guard !renderedActions.isEmpty else { return nil }
        let configuration = UISwipeActionsConfiguration(
            actions: renderedActions.map(\.1)
        )
        // A conditional outer action (for example Comments) may be unavailable
        // for this row. Never promote the inner action into Full Swipe merely
        // because UIKit sees it first after filtering.
        configuration.performsFirstActionWithFullSwipe =
            renderedActions.first?.0 == configuredFullSwipe
        return configuration
    }

    private func makeSwipeAction(
        _ semanticAction: IOSArticleSwipeAction,
        articleID: Int64,
        item: IOSUIKitArticleTimelineItem
    ) -> UIContextualAction? {
        switch semanticAction {
        case .readUnread:
            let newValue = !item.isRead
            let action = UIContextualAction(
                style: .normal,
                title: newValue
                    ? String(localized: "Swipe Read")
                    : String(localized: "Swipe Unread")
            ) { [weak self] _, _, completion in
                self?.setRead(id: articleID, value: newValue)
                completion(true)
            }
            action.image = UIImage(
                systemName: newValue ? "envelope.open" : "envelope"
            )
            action.backgroundColor = .tintColor
            return action

        case .starUnstar:
            let newValue = !item.isStarred
            let action = UIContextualAction(
                style: .normal,
                title: newValue
                    ? String(localized: "Swipe Star")
                    : String(localized: "Swipe Unstar")
            ) { [weak self] _, _, completion in
                self?.setStarred(id: articleID, value: newValue)
                completion(true)
            }
            action.image = UIImage(
                systemName: newValue ? "star" : "star.slash"
            )
            action.backgroundColor = .systemOrange
            return action

        case .comments:
            guard item.content.hasComments else { return nil }
            return makeContextSwipeAction(
                article: item.article,
                contextAction: .comments,
                title: String(localized: "Swipe Comments"),
                systemImage: "bubble.left",
                backgroundColor: .systemTeal
            )

        case .openOriginal:
            return makeContextSwipeAction(
                article: item.article,
                contextAction: .original,
                title: String(localized: "Swipe Original"),
                systemImage: "safari",
                backgroundColor: .systemBlue
            )

        case .openMiniflux:
            return makeContextSwipeAction(
                article: item.article,
                contextAction: .miniflux,
                title: String(localized: "Swipe Miniflux"),
                systemImage: "arrow.up.forward.app",
                backgroundColor: .systemIndigo
            )

        case .share:
            return makeContextSwipeAction(
                article: item.article,
                contextAction: .share,
                title: String(localized: "Swipe Share"),
                systemImage: "square.and.arrow.up",
                backgroundColor: .systemBlue
            )

        case .saveToService:
            return makeContextSwipeAction(
                article: item.article,
                contextAction: .saveToService,
                title: String(localized: "Swipe Save"),
                systemImage: "tray.and.arrow.down",
                backgroundColor: .systemPurple
            )

        case .downloadAudio:
            guard !IOSArticleAudioPresentation.downloadableEnclosures(
                audioActionStates[articleID]
            ).isEmpty else {
                return nil
            }
            let action = UIContextualAction(
                style: .normal,
                title: String(localized: "Swipe Download Audio")
            ) { [weak self] _, _, completion in
                self?.onArticleMediaAction?(
                    item.article,
                    .configuredDownloadAudio
                )
                completion(true)
            }
            action.image = UIImage(systemName: "arrow.down.circle")
            action.backgroundColor = .systemGreen
            return action
        }
    }

    private func makeContextSwipeAction(
        article: ArticleSummary,
        contextAction: IOSArticleContextAction,
        title: String,
        systemImage: String,
        backgroundColor: UIColor
    ) -> UIContextualAction {
        let action = UIContextualAction(
            style: .normal,
            title: title
        ) { [weak self] _, _, completion in
            self?.onArticleAction?(article, contextAction)
            completion(true)
        }
        action.image = UIImage(systemName: systemImage)
        action.backgroundColor = backgroundColor
        return action
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return nil }
        return UIContextMenuConfiguration(identifier: NSNumber(value: id), previewProvider: nil) { [weak self] _ in
            guard let self, let current = self.renderedItem(for: id) else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: current.isStarred ? String(localized: "Unstar") : String(localized: "Star"), image: UIImage(systemName: current.isStarred ? "star.slash" : "star")) { [weak self] _ in
                    self?.setStarred(id: id, value: !current.isStarred)
                },
                UIAction(title: current.isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read"), image: UIImage(systemName: current.isRead ? "envelope" : "envelope.open")) { [weak self] _ in
                    self?.setRead(id: id, value: !current.isRead)
                },
                UIMenu(options: .displayInline, children: self.contextNavigationActions(for: item)),
                self.contextAudioMenu(for: item),
                UIMenu(options: .displayInline, children: [
                    UIAction(title: String(localized: "Save to Third-Party Service"), image: UIImage(systemName: "tray.and.arrow.down")) { [weak self] _ in
                        self?.onArticleAction?(item.article, .saveToService)
                    }
                ])
            ]
            actions.removeAll { element in
                if let menu = element as? UIMenu { return menu.children.isEmpty }
                return false
            }
            return UIMenu(children: actions)
        }
    }

    func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        contextMenuTargetedPreview(for: configuration)
    }

    func tableView(_ tableView: UITableView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        contextMenuTargetedPreview(for: configuration)
    }

    private func contextMenuTargetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let identifier = configuration.identifier as? NSNumber,
              let indexPath = dataSource.indexPath(for: identifier.int64Value),
              let cell = tableView.cellForRow(at: indexPath)
        else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .systemBackground
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 16)
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    private func contextAudioMenu(
        for item: IOSUIKitArticleTimelineItem
    ) -> UIMenu {
        guard let state = audioActionStates[item.article.id],
              !state.audioEnclosures.isEmpty else {
            return UIMenu(options: .displayInline, children: [])
        }

        var children: [UIMenuElement] = [
            UIAction(
                title: state.isInListeningList
                    ? String(localized: "Remove from Listening List")
                    : String(localized: "Add to Listening List"),
                image: UIImage(
                    systemName: state.isInListeningList
                        ? "minus.circle"
                        : "plus.circle"
                )
            ) { [weak self] _ in
                self?.onArticleMediaAction?(
                    item.article,
                    .setListeningList(!state.isInListeningList)
                )
            }
        ]

        if state.audioEnclosures.count == 1,
           let enclosure = state.audioEnclosures.first {
            children.append(contentsOf: contextEnclosureActions(
                article: item.article,
                enclosure: enclosure,
                index: 0,
                state: state
            ))
        } else {
            for (index, enclosure) in state.audioEnclosures.enumerated() {
                children.append(
                    UIMenu(
                        title: IOSArticleAudioPresentation.enclosureLabel(
                            enclosure,
                            index: index
                        ),
                        image: UIImage(systemName: "waveform"),
                        children: contextEnclosureActions(
                            article: item.article,
                            enclosure: enclosure,
                            index: index,
                            state: state
                        )
                    )
                )
            }
        }

        return UIMenu(
            title: String(localized: "Audio"),
            image: UIImage(systemName: "headphones"),
            children: children
        )
    }

    private func contextEnclosureActions(
        article: ArticleSummary,
        enclosure: Enclosure,
        index: Int,
        state: IOSArticleAudioActionState
    ) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Play"),
                image: UIImage(systemName: "play.fill")
            ) { [weak self] _ in
                self?.onArticleMediaAction?(
                    article,
                    .play(enclosureID: enclosure.id)
                )
            }
        ]

        let download = state.downloads[enclosure.id]
        switch IOSArticleAudioPresentation.downloadAction(download) {
        case .download:
            actions.append(
                UIAction(
                    title: String(localized: "Download"),
                    image: UIImage(systemName: "arrow.down.circle")
                ) { [weak self] _ in
                    self?.onArticleMediaAction?(
                        article,
                        .requestDownload(enclosureID: enclosure.id)
                    )
                }
            )
        case .retry:
            actions.append(
                UIAction(
                    title: String(localized: "Retry Download"),
                    image: UIImage(systemName: "arrow.clockwise")
                ) { [weak self] _ in
                    self?.onArticleMediaAction?(
                        article,
                        .retryDownload(enclosureID: enclosure.id)
                    )
                }
            )
        case .delete:
            actions.append(
                UIAction(
                    title: String(localized: "Delete Download"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.onArticleMediaAction?(
                        article,
                        .deleteDownload(enclosureID: enclosure.id)
                    )
                }
            )
        case .pending:
            actions.append(
                UIAction(
                    title: String(localized: "Cancel Download"),
                    image: UIImage(systemName: "xmark.circle")
                ) { [weak self] _ in
                    self?.onArticleMediaAction?(
                        article,
                        .cancelDownload(enclosureID: enclosure.id)
                    )
                }
            )
        case .pendingDeletion:
            actions.append(
                UIAction(
                    title: String(localized: "Deletion Pending"),
                    image: UIImage(systemName: "clock"),
                    attributes: .disabled
                ) { _ in }
            )
        }

        return actions
    }

    private func contextNavigationActions(for item: IOSUIKitArticleTimelineItem) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Open Original"), image: UIImage(systemName: "safari")) { [weak self] _ in self?.onArticleAction?(item.article, .original) },
            UIAction(title: String(localized: "Open in Reader"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.onArticleAction?(item.article, .reader) },
            UIAction(title: String(localized: "Open in Miniflux"), image: UIImage(systemName: "arrow.up.forward.app")) { [weak self] _ in self?.onArticleAction?(item.article, .miniflux) },
        ]
        if item.content.hasComments {
            actions.append(UIAction(title: String(localized: "Open Comments"), image: UIImage(systemName: "bubble.left")) { [weak self] _ in self?.onArticleAction?(item.article, .comments) })
        }
        actions.append(contentsOf: [
            UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.onArticleAction?(item.article, .copyLink) },
            UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.onArticleAction?(item.article, .share) },
        ])
        return actions
    }

    private func setRead(id: Int64, value: Bool) {
        guard let item = renderedItem(for: id) else { return }
        onSetRead?(item.article, value)
    }

    private func setStarred(id: Int64, value: Bool) {
        guard let item = renderedItem(for: id) else { return }
        onSetStarred?(item.article, value)
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        let layoutInputs = indexPaths.compactMap { indexPath -> IOSUIKitArticleLayoutInput? in
            guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return nil }
            return preparedLayoutInput(for: item)
        }
#if DEBUG
        layoutPrefetchInputCountForTesting += layoutInputs.count
#endif
        preparedLayoutCoordinator.prepare(layoutInputs, priority: .prefetch)

        guard mode.showsArticleImage,
              let direction = articleImagePrefetchDirection(for: indexPaths)
        else { return }

        let visibleIDs = (tableView.indexPathsForVisibleRows ?? [])
            .sorted { $0.row < $1.row }
            .compactMap(dataSource.itemIdentifier(for:))
        let candidateIDs = IOSArticleImagePrefetchPolicy.candidateIDs(
            orderedIDs: orderedIDs,
            visibleIDs: visibleIDs,
            imageIDs: imageArticleIDs,
            direction: direction,
            limit: Self.maximumOffscreenArticleImagePrefetchCount
        )
        reconcileArticleImagePrefetch(candidateIDs)
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { continue }
            prefetchTasks.removeValue(forKey: id)?.task.cancel()
        }
    }

    private func articleImagePrefetchDirection(for indexPaths: [IndexPath]) -> IOSArticleScrollDirection? {
        guard !indexPaths.isEmpty,
              let firstVisible = tableView.indexPathsForVisibleRows?.map(\.row).min(),
              let lastVisible = tableView.indexPathsForVisibleRows?.map(\.row).max()
        else { return nil }

        let rows = indexPaths.map(\.row)
        if rows.allSatisfy({ $0 > lastVisible }) { return .forward }
        if rows.allSatisfy({ $0 < firstVisible }) { return .backward }

        let forwardDistance = max(0, (rows.max() ?? lastVisible) - lastVisible)
        let backwardDistance = max(0, firstVisible - (rows.min() ?? firstVisible))
        guard forwardDistance != 0 || backwardDistance != 0 else { return nil }
        return forwardDistance >= backwardDistance ? .forward : .backward
    }

    private func reconcileArticleImagePrefetch(_ candidateIDs: [Int64]) {
        let selected: [(id: Int64, request: ArticleImageRequest)] = candidateIDs.compactMap { id in
            guard let item = renderedItem(for: id), let request = imageRequest(for: item) else { return nil }
            return (id, request)
        }
        let selectedIDs = Set(selected.map(\.id))

        for id in prefetchTasks.keys where !selectedIDs.contains(id) {
            prefetchTasks.removeValue(forKey: id)?.task.cancel()
        }

        for candidate in selected {
            if let existing = prefetchTasks[candidate.id], existing.request == candidate.request { continue }
            prefetchTasks.removeValue(forKey: candidate.id)?.task.cancel()
            let request = candidate.request
            let id = candidate.id
            let task = Task { [weak self] in
                defer {
                    if self?.prefetchTasks[id]?.request == request {
                        self?.prefetchTasks[id] = nil
                    }
                }
                _ = try? await ArticleImagePipeline.shared.prefetch(request)
            }
            prefetchTasks[id] = (request, task)
        }
    }

    private func imageRequest(for item: IOSUIKitArticleTimelineItem) -> ArticleImageRequest? {
        guard mode.showsArticleImage,
              let url = item.content.imageURL
        else { return nil }
        let geometry = IOSUIKitArticleGeometry(
            mode: mode,
            containerWidth: tableView.bounds.width
        )
        let targetSize = geometry.imageSize(hasImage: true)
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        return ArticleImageRequest(
            url: url,
            targetSize: targetSize,
            displayScale: view.traitCollection.displayScale
        )
    }

    private func cancelAllPrefetch() {
#if DEBUG
        fullPrefetchCancellationCountForTesting &+= 1
#endif
        for prefetch in prefetchTasks.values { prefetch.task.cancel() }
        prefetchTasks.removeAll(keepingCapacity: true)
    }

    private func cancelIncompatibleImagePrefetch() {
        let incompatibleIDs = prefetchTasks.compactMap { id, prefetch in
            guard let item = renderedItem(for: id), imageRequest(for: item) == prefetch.request else { return id }
            return nil
        }
        for id in incompatibleIDs {
            prefetchTasks.removeValue(forKey: id)?.task.cancel()
        }
    }

    deinit {
        preparedWindowTask?.cancel()
        for prefetch in prefetchTasks.values { prefetch.task.cancel() }
    }

    func detachPresentationBridges() {
        presentationBridge?.unsubscribeArticles(self)
        feedIconPresentationBridge?.unsubscribeFeedIcons(self)
        presentationBridge = nil
        feedIconPresentationBridge = nil
    }

    func resetPerformanceMetrics() {
        performanceMetrics.reset()
        preparedLayoutCoordinator.resetInstrumentation()
    }
    func performanceSnapshot() -> IOSUIKitTimelinePerformanceSnapshot { performanceMetrics.snapshot(preparation: preparedLayoutCoordinator.snapshot()) }

    private func preparedLayoutInput(for item: IOSUIKitArticleTimelineItem) -> IOSUIKitArticleLayoutInput {
        .init(
            item: item,
            mode: mode,
            previewLines: previewLines,
            showsRelativePublicationTime: showRelativePublicationTime,
            containerWidth: tableView.bounds.width,
            displayScale: view.traitCollection.displayScale,
            contentSizeCategory: view.traitCollection.preferredContentSizeCategory,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
    }

    private func currentGeometryIdentity() -> IOSUIKitTimelineGeometryIdentity? {
        guard tableView.bounds.width > 0 else { return nil }
        return .init(
            mode: mode,
            previewLines: previewLines,
            showsRelativePublicationTime: showRelativePublicationTime,
            containerWidth: tableView.bounds.width,
            displayScale: view.traitCollection.displayScale,
            contentSizeCategory: view.traitCollection.preferredContentSizeCategory,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
    }

    private func schedulePreparedLayoutWindow(for identity: IOSUIKitTimelineGeometryIdentity?) {
        guard let identity else { return }
        if scheduledPreparedWindowGeneration != nil {
            performanceMetrics.recordPreparedWindowGenerationSuperseded()
        }
        preparedWindowGeneration &+= 1
        let generation = preparedWindowGeneration
        scheduledPreparedWindowGeneration = generation
        preparedWindowTask?.cancel()
        preparedWindowTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled,
                  self.preparedWindowGeneration == generation,
                  self.geometryIdentity == identity
            else {
                if self.scheduledPreparedWindowGeneration == generation {
                    self.scheduledPreparedWindowGeneration = nil
                }
                return
            }
            self.scheduledPreparedWindowGeneration = nil
            self.performanceMetrics.recordPreparedWindowReplacement()
            self.replacePreparedLayoutWindow()
        }
    }

    private func replacePreparedLayoutWindow() {
        guard tableView.bounds.width > 0 else { return }
        let visibleIndexes = (tableView.indexPathsForVisibleRows ?? []).map(\.row).sorted()
        let visibleIDs = visibleIndexes.compactMap { dataSource.itemIdentifier(for: .init(row: $0, section: 0)) }
        let nextIndex = min(orderedIDs.count, (visibleIndexes.last ?? -1) + 1)
        let nearbyIDs = orderedIDs.dropFirst(nextIndex).prefix(IOSUIKitArticleLayoutPreparationCoordinator.nearbyWindowLimit)
        let ids = Array(visibleIDs + nearbyIDs.filter { !visibleIDs.contains($0) })
        preparedLayoutCoordinator.replaceWindow(with: ids.compactMap { renderedItem(for: $0).map(preparedLayoutInput(for:)) }, visibleCount: visibleIDs.count)
    }

    private func prepareVisibleLayoutMetrics() {
        let ids = (tableView.indexPathsForVisibleRows ?? []).sorted { $0.row < $1.row }.compactMap(dataSource.itemIdentifier(for:))
        preparedLayoutCoordinator.prepare(ids.compactMap { renderedItem(for: $0).map(preparedLayoutInput(for:)) }, priority: .visible)
    }
}

#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
@MainActor
enum IOSUIKitTimelinePerformanceDiagnostics {
    weak static var currentController: IOSUIKitArticleTimelineController?

    static func resetAndPrint() async {
        guard let controller = currentController else {
            print("[Timeline Performance] No active Timeline controller")
            return
        }
        controller.resetPerformanceMetrics()
        await ArticleImagePipeline.shared.resetMetrics()
        print("[Timeline Performance] Metrics reset")
    }

    static func printSnapshot() async {
        guard let controller = currentController else {
            print("[Timeline Performance] No active Timeline controller")
            return
        }
        let timeline = controller.performanceSnapshot()
        let image = await ArticleImagePipeline.shared.metrics()
        let cacheHitRate = timeline.heightCacheHits + timeline.heightCacheMisses > 0 ? Double(timeline.heightCacheHits) / Double(timeline.heightCacheHits + timeline.heightCacheMisses) : nil
        let solverRate = timeline.preferredLayoutAttributesFittingCalls > 0 ? Double(timeline.systemLayoutSizeFittingCalls) / Double(timeline.preferredLayoutAttributesFittingCalls) : nil
        let averageSolveTime = timeline.systemLayoutSizeFittingCalls > 0 ? Double(timeline.systemLayoutSizeFittingTotalNanoseconds) / Double(timeline.systemLayoutSizeFittingCalls) : nil
        let imageHitRate = image.visibleMemoryCacheHits + image.visibleMemoryCacheMisses > 0 ? Double(image.visibleMemoryCacheHits) / Double(image.visibleMemoryCacheHits + image.visibleMemoryCacheMisses) : nil
        print("""
        [Timeline Performance]
        timeline preferredLayoutAttributesFittingCalls=\(timeline.preferredLayoutAttributesFittingCalls) systemLayoutSizeFittingCalls=\(timeline.systemLayoutSizeFittingCalls) configureCount=\(timeline.configureCount) reuseCount=\(timeline.reuseCount) layoutVariantSwitchCount=\(timeline.layoutVariantSwitchCount) imageBindingCount=\(timeline.imageBindingCount) structuralReconciliationCount=\(timeline.structuralReconciliationCount) snapshotApplyCount=\(timeline.snapshotApplyCount) layoutInvalidationCount=\(timeline.layoutInvalidationCount)
        geometry identityChanges=\(timeline.geometryIdentityChanges) layoutInvalidations=\(timeline.geometryLayoutInvalidationCount) preparedWindowReplacements=\(timeline.preparedWindowReplacementCount) preparedWindowGenerationsSuperseded=\(timeline.preparedWindowGenerationsSuperseded)
        deterministicHeight requests=\(timeline.deterministicHeightRequests) preparedHits=\(timeline.deterministicHeightPreparedHits) synchronousFallbacks=\(timeline.deterministicHeightSynchronousFallbacks) synchronousFallbackTotalNanoseconds=\(timeline.deterministicHeightSynchronousFallbackTotalNanoseconds) synchronousFallbackMaxNanoseconds=\(timeline.deterministicHeightSynchronousFallbackMaxNanoseconds)
        preparedLayout requests=\(timeline.preparedLayoutRequests) cacheHits=\(timeline.preparedLayoutCacheHits) cacheMisses=\(timeline.preparedLayoutCacheMisses) measurementsStarted=\(timeline.preparedLayoutMeasurementsStarted) measurementsCompleted=\(timeline.preparedLayoutMeasurementsCompleted) discardedResults=\(timeline.preparedLayoutDiscardedResults) cancellations=\(timeline.preparedLayoutCancellations) maximumConcurrency=\(timeline.preparedLayoutMaximumConcurrency) visibleRequests=\(timeline.visibleLayoutMetricRequests) visibleCacheHits=\(timeline.visibleLayoutMetricCacheHits) visibleCacheMisses=\(timeline.visibleLayoutMetricCacheMisses) prefetchRequests=\(timeline.prefetchLayoutMetricRequests) prefetchCacheHits=\(timeline.prefetchLayoutMetricCacheHits) prefetchCacheMisses=\(timeline.prefetchLayoutMetricCacheMisses)
        image memoryCacheHits=\(image.memoryCacheHits) memoryCacheMisses=\(image.memoryCacheMisses) visibleMemoryCacheHits=\(image.visibleMemoryCacheHits) visibleMemoryCacheMisses=\(image.visibleMemoryCacheMisses) prefetchMemoryCacheHits=\(image.prefetchMemoryCacheHits) prefetchMemoryCacheMisses=\(image.prefetchMemoryCacheMisses) memoryCacheInsertions=\(image.memoryCacheInsertions) memoryCacheEvictions=\(image.memoryCacheEvictions) memoryCacheCostLimit=\(image.memoryCacheCostLimit) inFlightDedupHits=\(image.inFlightDedupHits) startedOperations=\(image.startedOperations) completedOperations=\(image.completedOperations) retiredOperations=\(image.retiredOperations) maximumActiveOperations=\(image.maximumActiveOperations) visibleStarts=\(image.visibleStarts) prefetchStarts=\(image.prefetchStarts) activeOperations=\(image.activeOperations) queuedVisibleRequests=\(image.queuedVisibleRequests) queuedPrefetchRequests=\(image.queuedPrefetchRequests)
        derived heightCacheHitRate=\(cacheHitRate.map { String(format: "%.3f", $0) } ?? "n/a") solverRate=\(solverRate.map { String(format: "%.3f", $0) } ?? "n/a") averageSolveTime=\(averageSolveTime.map { String(format: "%.0f", $0) } ?? "n/a") visibleImageMemoryCacheHitRate=\(imageHitRate.map { String(format: "%.3f", $0) } ?? "n/a")
        """)
    }
}
#endif

enum IOSUIKitArticleCellLayoutVariant: Hashable {
    case compact
    case visualTextOnly
    case visualPortrait
    case visualLandscape
    /// `Visual compact`: metadata spans the row above; title and publication
    /// row share the content row with the trailing image; preview follows below.
    case visualSideTitle
    /// The same arrangement on a wide container, except the preview also joins
    /// the text column beside the image instead of running underneath it.
    case visualSideTitleWide
    /// `Visual compact` for an article without an image: same order, full width.
    case visualSideTitleTextOnly

    /// Whether the cell shows its image view at all. Derived rather than listed
    /// at each call site, so a new variant cannot silently default to "shown".
    var showsImageSlot: Bool {
        switch self {
        case .compact, .visualTextOnly, .visualSideTitleTextOnly: return false
        case .visualPortrait, .visualLandscape, .visualSideTitle, .visualSideTitleWide: return true
        }
    }
}

struct IOSUIKitTimelinePerformanceSnapshot: Equatable {
    let preferredLayoutAttributesFittingCalls: UInt64
    let heightCacheHits: UInt64
    let heightCacheMisses: UInt64
    let systemLayoutSizeFittingCalls: UInt64
    let systemLayoutSizeFittingTotalNanoseconds: UInt64
    let systemLayoutSizeFittingMaxNanoseconds: UInt64
    let systemLayoutSizeFittingP50ApproxNanoseconds: UInt64
    let systemLayoutSizeFittingP95ApproxNanoseconds: UInt64
    let configureCount: UInt64
    let reuseCount: UInt64
    let layoutVariantSwitchCount: UInt64
    let imageBindingCount: UInt64
    let structuralReconciliationCount: UInt64
    let snapshotApplyCount: UInt64
    let layoutInvalidationCount: UInt64
    let geometryIdentityChanges: UInt64
    let geometryLayoutInvalidationCount: UInt64
    let preparedWindowReplacementCount: UInt64
    let preparedWindowGenerationsSuperseded: UInt64
    let preparedLayoutRequests: UInt64
    let preparedLayoutCacheHits: UInt64
    let preparedLayoutCacheMisses: UInt64
    let preparedLayoutMeasurementsStarted: UInt64
    let preparedLayoutMeasurementsCompleted: UInt64
    let preparedLayoutDiscardedResults: UInt64
    let preparedLayoutCancellations: UInt64
    let preparedLayoutMaximumConcurrency: UInt64
    let visibleLayoutMetricRequests: UInt64
    let visibleLayoutMetricCacheHits: UInt64
    let visibleLayoutMetricCacheMisses: UInt64
    let prefetchLayoutMetricRequests: UInt64
    let prefetchLayoutMetricCacheHits: UInt64
    let prefetchLayoutMetricCacheMisses: UInt64
    let deterministicHeightRequests: UInt64
    let deterministicHeightPreparedHits: UInt64
    let deterministicHeightSynchronousFallbacks: UInt64
    let deterministicHeightSynchronousFallbackTotalNanoseconds: UInt64
    let deterministicHeightSynchronousFallbackMaxNanoseconds: UInt64
}

@MainActor
final class IOSUIKitTimelinePerformanceMetrics {
    // Logarithmic nanosecond buckets provide bounded percentile estimates.
    private static let durationBucketCount = 64
    private var durationBuckets = Array(repeating: UInt64(0), count: durationBucketCount)
    private var preferredLayoutAttributesFittingCalls: UInt64 = 0
    private var heightCacheHits: UInt64 = 0
    private var heightCacheMisses: UInt64 = 0
    private var systemLayoutSizeFittingCalls: UInt64 = 0
    private var systemLayoutSizeFittingTotalNanoseconds: UInt64 = 0
    private var systemLayoutSizeFittingMaxNanoseconds: UInt64 = 0
    private var configureCount: UInt64 = 0
    private var reuseCount: UInt64 = 0
    private var layoutVariantSwitchCount: UInt64 = 0
    private var imageBindingCount: UInt64 = 0
    private var structuralReconciliationCount: UInt64 = 0
    private var snapshotApplyCount: UInt64 = 0
    private var layoutInvalidationCount: UInt64 = 0
    private var geometryIdentityChanges: UInt64 = 0
    private var geometryLayoutInvalidationCount: UInt64 = 0
    private var preparedWindowReplacementCount: UInt64 = 0
    private var preparedWindowGenerationsSuperseded: UInt64 = 0
    private var deterministicHeightRequests: UInt64 = 0
    private var deterministicHeightPreparedHits: UInt64 = 0
    private var deterministicHeightSynchronousFallbacks: UInt64 = 0
    private var deterministicHeightSynchronousFallbackTotalNanoseconds: UInt64 = 0
    private var deterministicHeightSynchronousFallbackMaxNanoseconds: UInt64 = 0

    func reset() {
        durationBuckets = Array(repeating: 0, count: Self.durationBucketCount)
        preferredLayoutAttributesFittingCalls = 0; heightCacheHits = 0; heightCacheMisses = 0
        systemLayoutSizeFittingCalls = 0; systemLayoutSizeFittingTotalNanoseconds = 0; systemLayoutSizeFittingMaxNanoseconds = 0
        configureCount = 0; reuseCount = 0; layoutVariantSwitchCount = 0; imageBindingCount = 0
        structuralReconciliationCount = 0; snapshotApplyCount = 0; layoutInvalidationCount = 0
        geometryIdentityChanges = 0; geometryLayoutInvalidationCount = 0
        preparedWindowReplacementCount = 0; preparedWindowGenerationsSuperseded = 0
        deterministicHeightRequests = 0; deterministicHeightPreparedHits = 0; deterministicHeightSynchronousFallbacks = 0
        deterministicHeightSynchronousFallbackTotalNanoseconds = 0; deterministicHeightSynchronousFallbackMaxNanoseconds = 0
    }
    func recordFittingCall() { preferredLayoutAttributesFittingCalls &+= 1 }
    func recordCacheHit() { heightCacheHits &+= 1 }
    func recordCacheMiss() { heightCacheMisses &+= 1 }
    func recordConfigure() { configureCount &+= 1 }
    func recordReuse() { reuseCount &+= 1 }
    func recordVariantSwitch() { layoutVariantSwitchCount &+= 1 }
    func recordImageBinding() { imageBindingCount &+= 1 }
    func recordStructuralReconciliation() { structuralReconciliationCount &+= 1 }
    func recordSnapshotApply() { snapshotApplyCount &+= 1 }
    func recordLayoutInvalidation() { layoutInvalidationCount &+= 1 }
    func recordGeometryChange() {
        geometryIdentityChanges &+= 1
        geometryLayoutInvalidationCount &+= 1
        layoutInvalidationCount &+= 1
    }
    func recordPreparedWindowReplacement() { preparedWindowReplacementCount &+= 1 }
    func recordPreparedWindowGenerationSuperseded() { preparedWindowGenerationsSuperseded &+= 1 }
    func recordDeterministicHeightRequest(prepared: Bool) {
        deterministicHeightRequests &+= 1
        if prepared { deterministicHeightPreparedHits &+= 1 }
    }
    func recordDeterministicHeightFallback(durationNanoseconds: UInt64) {
        deterministicHeightRequests &+= 1
        deterministicHeightSynchronousFallbacks &+= 1
        deterministicHeightSynchronousFallbackTotalNanoseconds &+= durationNanoseconds
        deterministicHeightSynchronousFallbackMaxNanoseconds = max(deterministicHeightSynchronousFallbackMaxNanoseconds, durationNanoseconds)
    }
    func recordSolve(durationNanoseconds: UInt64) {
        systemLayoutSizeFittingCalls &+= 1
        systemLayoutSizeFittingTotalNanoseconds &+= durationNanoseconds
        systemLayoutSizeFittingMaxNanoseconds = max(systemLayoutSizeFittingMaxNanoseconds, durationNanoseconds)
        durationBuckets[min(durationNanoseconds == 0 ? 0 : 63 - durationNanoseconds.leadingZeroBitCount, Self.durationBucketCount - 1)] &+= 1
    }
    func snapshot(preparation: IOSUIKitArticleLayoutPreparationSnapshot = .init(requests: 0, cacheHits: 0, cacheMisses: 0, measurementsStarted: 0, measurementsCompleted: 0, discardedResults: 0, cancellations: 0, maximumConcurrentMeasurements: 0, visibleRequests: 0, visibleCacheHits: 0, visibleCacheMisses: 0, prefetchRequests: 0, prefetchCacheHits: 0, prefetchCacheMisses: 0)) -> IOSUIKitTimelinePerformanceSnapshot {
        .init(preferredLayoutAttributesFittingCalls: preferredLayoutAttributesFittingCalls, heightCacheHits: heightCacheHits, heightCacheMisses: heightCacheMisses, systemLayoutSizeFittingCalls: systemLayoutSizeFittingCalls, systemLayoutSizeFittingTotalNanoseconds: systemLayoutSizeFittingTotalNanoseconds, systemLayoutSizeFittingMaxNanoseconds: systemLayoutSizeFittingMaxNanoseconds, systemLayoutSizeFittingP50ApproxNanoseconds: percentile(0.5), systemLayoutSizeFittingP95ApproxNanoseconds: percentile(0.95), configureCount: configureCount, reuseCount: reuseCount, layoutVariantSwitchCount: layoutVariantSwitchCount, imageBindingCount: imageBindingCount, structuralReconciliationCount: structuralReconciliationCount, snapshotApplyCount: snapshotApplyCount, layoutInvalidationCount: layoutInvalidationCount, geometryIdentityChanges: geometryIdentityChanges, geometryLayoutInvalidationCount: geometryLayoutInvalidationCount, preparedWindowReplacementCount: preparedWindowReplacementCount, preparedWindowGenerationsSuperseded: preparedWindowGenerationsSuperseded, preparedLayoutRequests: preparation.requests, preparedLayoutCacheHits: preparation.cacheHits, preparedLayoutCacheMisses: preparation.cacheMisses, preparedLayoutMeasurementsStarted: preparation.measurementsStarted, preparedLayoutMeasurementsCompleted: preparation.measurementsCompleted, preparedLayoutDiscardedResults: preparation.discardedResults, preparedLayoutCancellations: preparation.cancellations, preparedLayoutMaximumConcurrency: preparation.maximumConcurrentMeasurements, visibleLayoutMetricRequests: preparation.visibleRequests, visibleLayoutMetricCacheHits: preparation.visibleCacheHits, visibleLayoutMetricCacheMisses: preparation.visibleCacheMisses, prefetchLayoutMetricRequests: preparation.prefetchRequests, prefetchLayoutMetricCacheHits: preparation.prefetchCacheHits, prefetchLayoutMetricCacheMisses: preparation.prefetchCacheMisses, deterministicHeightRequests: deterministicHeightRequests, deterministicHeightPreparedHits: deterministicHeightPreparedHits, deterministicHeightSynchronousFallbacks: deterministicHeightSynchronousFallbacks, deterministicHeightSynchronousFallbackTotalNanoseconds: deterministicHeightSynchronousFallbackTotalNanoseconds, deterministicHeightSynchronousFallbackMaxNanoseconds: deterministicHeightSynchronousFallbackMaxNanoseconds)
    }
    private func percentile(_ percentile: Double) -> UInt64 {
        let target = UInt64((Double(systemLayoutSizeFittingCalls) * percentile).rounded(.up))
        guard target > 0 else { return 0 }
        var seen: UInt64 = 0
        for (index, count) in durationBuckets.enumerated() {
            seen &+= count
            if seen >= target { return UInt64(1) << index }
        }
        return systemLayoutSizeFittingMaxNanoseconds
    }
}

@MainActor
final class IOSArticleImagePresentationScheduler {
    struct Metrics: Equatable {
        let queued: Int
        let maximumQueued: Int
        let presented: Int
        let discarded: Int
        let averageDelayMilliseconds: Double
        let maximumDelayMilliseconds: Double
    }

    static let shared = IOSArticleImagePresentationScheduler()

    private struct PendingPresentation {
        let enqueuedAt: CFTimeInterval
        let isStillValid: () -> Bool
        let present: () -> Void
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: IOSArticleImagePresentationScheduler?

        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.displayLinkDidFire()
        }
    }

    private var queue: [PendingPresentation] = []
    private var isScrolling = false
    private var displayLink: CADisplayLink?
    private let displayLinkTarget = DisplayLinkTarget()
    private var maximumQueued = 0
    private var presented = 0
    private var discarded = 0
    private var totalDelay: CFTimeInterval = 0
    private var maximumDelay: CFTimeInterval = 0

    private init() {
        displayLinkTarget.owner = self
    }

    func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        if scrolling {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
            drainImmediately()
        }
    }

    func enqueue(
        isStillValid: @escaping () -> Bool,
        present: @escaping () -> Void
    ) {
        guard isScrolling else {
            guard isStillValid() else {
                discarded += 1
                return
            }
            present()
            presented += 1
            return
        }

        queue.append(.init(
            enqueuedAt: CACurrentMediaTime(),
            isStillValid: isStillValid,
            present: present
        ))
        maximumQueued = max(maximumQueued, queue.count)
        startDisplayLinkIfNeeded()
    }

    func metrics() -> Metrics {
        .init(
            queued: queue.count,
            maximumQueued: maximumQueued,
            presented: presented,
            discarded: discarded,
            averageDelayMilliseconds: presented > 0 ? (totalDelay / Double(presented)) * 1_000 : 0,
            maximumDelayMilliseconds: maximumDelay * 1_000
        )
    }

    func resetMetrics() {
        maximumQueued = queue.count
        presented = 0
        discarded = 0
        totalDelay = 0
        maximumDelay = 0
    }

    private func displayLinkDidFire() {
        guard isScrolling else { return }
        presentNextValid()
        if queue.isEmpty {
            stopDisplayLink()
        }
    }

    private func presentNextValid() {
        while !queue.isEmpty {
            let pending = queue.removeFirst()
            guard pending.isStillValid() else {
                discarded += 1
                continue
            }
            let delay = CACurrentMediaTime() - pending.enqueuedAt
            pending.present()
            presented += 1
            totalDelay += delay
            maximumDelay = max(maximumDelay, delay)
            return
        }
    }

    private func drainImmediately() {
        while !queue.isEmpty {
            let pending = queue.removeFirst()
            guard pending.isStillValid() else {
                discarded += 1
                continue
            }
            let delay = CACurrentMediaTime() - pending.enqueuedAt
            pending.present()
            presented += 1
            totalDelay += delay
            maximumDelay = max(maximumDelay, delay)
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard isScrolling, !queue.isEmpty, displayLink == nil else { return }
        let link = CADisplayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

@MainActor
final class IOSUIKitArticleCell: UITableViewCell {
    static func reuseIdentifier(for variant: IOSUIKitArticleCellLayoutVariant) -> String {
        switch variant {
        case .compact: return "IOSUIKitArticleCell.compact"
        case .visualTextOnly: return "IOSUIKitArticleCell.visualTextOnly"
        case .visualPortrait: return "IOSUIKitArticleCell.visualPortrait"
        case .visualLandscape: return "IOSUIKitArticleCell.visualLandscape"
        case .visualSideTitle: return "IOSUIKitArticleCell.visualSideTitle"
        case .visualSideTitleWide: return "IOSUIKitArticleCell.visualSideTitleWide"
        case .visualSideTitleTextOnly: return "IOSUIKitArticleCell.visualSideTitleTextOnly"
        }
    }

    // A plain container, not a `UIStackView`. Setting `isHidden` on an
    // arranged subview makes the stack add and remove constraints, and
    // `previewLabel.isHidden` is set on every `configure`.
    private let textContainer = UIView()
    private let titleLabel = UILabel()
    private let starImageView = UIImageView(image: UIImage(systemName: "star.fill"))
    private let metadataRow = UIView()
    private let unreadIndicator = UIView()
    private let feedIconContainer = UIView()
    private let feedIconImageView = UIImageView()
    private let feedIconFallbackLabel = UILabel()
    private let feedTitleLabel = UILabel()
    private let publicationTimeIconView = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
    private let dateLabel = UILabel()
    private let landscapeReadingTimeContainer = UIView()
    private let landscapeReadingTimeIconView = UIImageView(image: UIImage(systemName: "doc.text"))
    private let landscapeReadingTimeLabel = UILabel()
    private let commentsContainer = UIView()
    private let commentsImageView = UIImageView(image: UIImage(systemName: "bubble.left"))
    private let previewLabel = UILabel()
    private let articleImageView = UIImageView()
    private let imagePlaceholder = UIImageView(image: UIImage(systemName: "photo"))

    private var textOnlyConstraints: [NSLayoutConstraint] = []
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var activeLayoutConstraints: [NSLayoutConstraint] = []
    private var portraitImageAspectConstraint: NSLayoutConstraint!
    private var portraitImageWidthConstraint: NSLayoutConstraint!
    private var sideTitleConstraints: [NSLayoutConstraint] = []
    private var defaultStackConstraints: [NSLayoutConstraint] = []
    private var sideTitleWideConstraints: [NSLayoutConstraint] = []
    private var sideTitleTextOnlyConstraints: [NSLayoutConstraint] = []
    private var previewBottomDefaultConstraint: NSLayoutConstraint!
    private var previewTrailingDefaultConstraint: NSLayoutConstraint!
    /// Preview top in the side-title variant: it must clear the image as well as
    /// the date, and its spacing collapses with the preview itself.
    private var sideTitlePreviewBelowDateConstraint: NSLayoutConstraint!
    private var sideTitlePreviewBelowImageConstraint: NSLayoutConstraint!
    private var landscapeImageWidthConstraint: NSLayoutConstraint!
    private var landscapeImageHeightConstraint: NSLayoutConstraint!
    private var commentsWidthConstraint: NSLayoutConstraint!
    private var commentsToStarSpacingConstraint: NSLayoutConstraint!
    private var metadataFeedTitleDefaultTrailingConstraint: NSLayoutConstraint!
    private var metadataFeedTitlePortraitTrailingConstraint: NSLayoutConstraint!
    private var publicationTimeIconWidthConstraint: NSLayoutConstraint!
    private var publicationTimeIconHeightConstraint: NSLayoutConstraint!
    private var publicationTimeIconTextSpacingConstraint: NSLayoutConstraint!
    private var dateWidthConstraint: NSLayoutConstraint!
    private var defaultDateTopConstraint: NSLayoutConstraint!
    private var defaultDateTrailingConstraint: NSLayoutConstraint!
    private var landscapeDateTrailingConstraint: NSLayoutConstraint!
    private var compactDateTrailingConstraint: NSLayoutConstraint!
    private var portraitDateTrailingConstraint: NSLayoutConstraint!
    private var sideTitleDateTrailingConstraint: NSLayoutConstraint!
    private var sideTitleWideDateTrailingConstraint: NSLayoutConstraint!
    private var sideTitleTextOnlyDateTrailingConstraint: NSLayoutConstraint!
    private var compactReadingContainerTrailingConstraint: NSLayoutConstraint!
    private var portraitReadingContainerTrailingConstraint: NSLayoutConstraint!
    private var sideTitleReadingContainerTrailingConstraint: NSLayoutConstraint!
    private var sideTitleWideReadingContainerTrailingConstraint: NSLayoutConstraint!
    private var sideTitleTextOnlyReadingContainerTrailingConstraint: NSLayoutConstraint!
    private var landscapeReadingContainerWidthConstraint: NSLayoutConstraint!
    private var landscapeReadingIconWidthConstraint: NSLayoutConstraint!
    private var landscapeReadingIconHeightConstraint: NSLayoutConstraint!
    private var landscapeReadingLabelWidthConstraint: NSLayoutConstraint!
    /// One step more contrast than `secondaryLabel` without reaching full
    /// `label`, which would compete with the headline. Resolved per trait
    /// collection so it still inverts in dark mode.
    /// A fixed alpha would cap what "Increase Contrast" can give back: the
    /// resolved base already carries the high-contrast variant, but multiplying
    /// it down again takes part of that away. Under high contrast the supporting
    /// text therefore runs at full strength.
    private static let supportingTextColor = UIColor { traits in
        let alpha: CGFloat = traits.accessibilityContrast == .high ? 1 : 0.8
        return UIColor.label.resolvedColor(with: traits).withAlphaComponent(alpha)
    }
    /// Read articles dim by the same proportion as the headline, so the whole
    /// row recedes together instead of only its title.
    private static let supportingReadTextColor = UIColor { traits in
        let alpha: CGFloat = traits.accessibilityContrast == .high ? 0.75 : 0.5
        return UIColor.label.resolvedColor(with: traits).withAlphaComponent(alpha)
    }
    private var previewTopConstraint: NSLayoutConstraint!
    private var previewCollapseConstraint: NSLayoutConstraint!
    /// Driven from the prepared metrics, so the cell cannot disagree with the
    /// engine about how large a scaled glyph slot is.
    private var accessoryConstraints: [NSLayoutConstraint] = []
    private var metadataMinimumHeight: NSLayoutConstraint!
    private var unreadWidth: NSLayoutConstraint!
    private var unreadHeight: NSLayoutConstraint!
    private var feedIconWidth: NSLayoutConstraint!
    private var feedIconHeight: NSLayoutConstraint!
    private var starWidth: NSLayoutConstraint!
    private var starHeight: NSLayoutConstraint!
    private var commentsHeightConstraint: NSLayoutConstraint!
    private var currentLayoutVariant: IOSUIKitArticleCellLayoutVariant?
    private var imageTask: Task<Void, Never>?
    private var representedImageRequest: ArticleImageRequest?
    private var articleImagePipeline = ArticleImagePipeline.shared
    private var imageBindingGeneration: UInt64 = 0
    private var currentTitle = ""
    private var currentFeedTitle = ""
    private var currentPublishedDate = ""
    private var currentShowsRelativePublicationTime = false
    private var currentReadingTime: String?
    private var currentIsRead = false
    private var currentIsStarred = false
    private var currentHasComments = false
    /// Late image arrivals normally fade in. The timeline disables that
    /// transition while the table is actively moving so image pixels still
    /// appear immediately without adding overlapping Core Animation work.
    private var articleImageArrivalAnimationsEnabled = true
    private(set) var preparedLayoutMetrics: IOSUIKitArticleLayoutMetrics?

    weak var performanceMetrics: IOSUIKitTimelinePerformanceMetrics?
    /// Narrow decoded-scale test seam; there is no production renderer switch.
    var articleImageRasterScale: (CGFloat) -> CGFloat = { $0 }
    private(set) var representedArticleID: Int64?
    private(set) var layoutVariantRevision: UInt64 = 0
    private(set) var measurementSolveCount = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .systemBackground
        contentView.backgroundColor = .systemBackground
        contentView.isOpaque = true
        contentView.preservesSuperviewLayoutMargins = false
        selectionStyle = .default

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        // The engine owns the row height, so a cell can carry slack its natural
        // content does not fill — in the side-title variant whenever the image is
        // taller than the title-and-date column. Without a firm hugging priority
        // Auto Layout absorbs that slack into these labels, which pushes the date
        // away from the headline it belongs to. Let it land in the gap above the
        // preview instead, which is where the engine put it.
        titleLabel.setContentHuggingPriority(UILayoutPriority(999), for: .vertical)
        dateLabel.setContentHuggingPriority(UILayoutPriority(999), for: .vertical)
        starImageView.tintColor = .systemYellow
        starImageView.alpha = 0
        starImageView.isAccessibilityElement = false
        metadataRow.translatesAutoresizingMaskIntoConstraints = false
        metadataMinimumHeight = metadataRow.heightAnchor.constraint(greaterThanOrEqualToConstant: IOSUIKitArticleGeometry.feedIconSize)
        metadataMinimumHeight.isActive = true

        unreadIndicator.translatesAutoresizingMaskIntoConstraints = false
        unreadIndicator.backgroundColor = .tintColor
        unreadWidth = unreadIndicator.widthAnchor.constraint(equalToConstant: IOSUIKitArticleGeometry.unreadSize)
        unreadHeight = unreadIndicator.heightAnchor.constraint(equalToConstant: IOSUIKitArticleGeometry.unreadSize)
        NSLayoutConstraint.activate([unreadWidth, unreadHeight])

        feedIconContainer.translatesAutoresizingMaskIntoConstraints = false
        feedIconWidth = feedIconContainer.widthAnchor.constraint(equalToConstant: IOSFeedIconImagePreparation.displaySidePoints)
        feedIconHeight = feedIconContainer.heightAnchor.constraint(equalToConstant: IOSFeedIconImagePreparation.displaySidePoints)
        NSLayoutConstraint.activate([feedIconWidth, feedIconHeight])
        feedIconImageView.translatesAutoresizingMaskIntoConstraints = false
        feedIconImageView.contentMode = .scaleAspectFit
        feedIconFallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedIconFallbackLabel.font = .preferredFont(forTextStyle: .caption2).bold()
        feedIconFallbackLabel.adjustsFontForContentSizeCategory = true
        feedIconFallbackLabel.textAlignment = .center
        feedIconFallbackLabel.textColor = .white
        feedIconContainer.addSubview(feedIconImageView)
        feedIconContainer.addSubview(feedIconFallbackLabel)
        NSLayoutConstraint.activate([
            feedIconImageView.leadingAnchor.constraint(equalTo: feedIconContainer.leadingAnchor),
            feedIconImageView.trailingAnchor.constraint(equalTo: feedIconContainer.trailingAnchor),
            feedIconImageView.topAnchor.constraint(equalTo: feedIconContainer.topAnchor),
            feedIconImageView.bottomAnchor.constraint(equalTo: feedIconContainer.bottomAnchor),
            feedIconFallbackLabel.leadingAnchor.constraint(equalTo: feedIconContainer.leadingAnchor),
            feedIconFallbackLabel.trailingAnchor.constraint(equalTo: feedIconContainer.trailingAnchor),
            feedIconFallbackLabel.topAnchor.constraint(equalTo: feedIconContainer.topAnchor),
            feedIconFallbackLabel.bottomAnchor.constraint(equalTo: feedIconContainer.bottomAnchor),
        ])

        feedTitleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        feedTitleLabel.adjustsFontForContentSizeCategory = true
        feedTitleLabel.textColor = Self.supportingTextColor
        feedTitleLabel.lineBreakMode = .byTruncatingTail
        feedTitleLabel.numberOfLines = 1
        feedTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        commentsContainer.translatesAutoresizingMaskIntoConstraints = false
        commentsImageView.translatesAutoresizingMaskIntoConstraints = false
        commentsImageView.tintColor = Self.supportingTextColor
        commentsContainer.addSubview(commentsImageView)
        NSLayoutConstraint.activate([
            commentsImageView.centerXAnchor.constraint(equalTo: commentsContainer.centerXAnchor),
            commentsImageView.centerYAnchor.constraint(equalTo: commentsContainer.centerYAnchor),
        ])

        starImageView.translatesAutoresizingMaskIntoConstraints = false
        publicationTimeIconView.translatesAutoresizingMaskIntoConstraints = false
        publicationTimeIconView.tintColor = Self.supportingTextColor
        publicationTimeIconView.contentMode = .scaleAspectFit
        publicationTimeIconView.isHidden = true
        publicationTimeIconWidthConstraint = publicationTimeIconView.widthAnchor.constraint(equalToConstant: 0)
        publicationTimeIconHeightConstraint = publicationTimeIconView.heightAnchor.constraint(equalToConstant: 0)

        dateLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = Self.supportingTextColor
        dateLabel.numberOfLines = 1
        dateLabel.lineBreakMode = .byTruncatingTail
        // The deterministic engine owns the exact publication width. This keeps
        // the optional reading-time group immediately adjacent instead of letting
        // the date label expand across all remaining horizontal space.
        dateWidthConstraint = dateLabel.widthAnchor.constraint(equalToConstant: 0)

        landscapeReadingTimeContainer.translatesAutoresizingMaskIntoConstraints = false
        landscapeReadingTimeContainer.isHidden = true
        landscapeReadingTimeIconView.translatesAutoresizingMaskIntoConstraints = false
        landscapeReadingTimeIconView.tintColor = Self.supportingTextColor
        landscapeReadingTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        landscapeReadingTimeLabel.font = .preferredFont(forTextStyle: .caption1)
        landscapeReadingTimeLabel.adjustsFontForContentSizeCategory = true
        landscapeReadingTimeLabel.textColor = Self.supportingTextColor
        landscapeReadingTimeLabel.numberOfLines = 1
        landscapeReadingTimeContainer.addSubview(landscapeReadingTimeIconView)
        landscapeReadingTimeContainer.addSubview(landscapeReadingTimeLabel)
        landscapeReadingContainerWidthConstraint = landscapeReadingTimeContainer.widthAnchor.constraint(equalToConstant: 0)
        landscapeReadingIconWidthConstraint = landscapeReadingTimeIconView.widthAnchor.constraint(equalToConstant: 0)
        landscapeReadingIconHeightConstraint = landscapeReadingTimeIconView.heightAnchor.constraint(equalToConstant: 0)
        landscapeReadingLabelWidthConstraint = landscapeReadingTimeLabel.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            landscapeReadingContainerWidthConstraint,
            landscapeReadingTimeIconView.leadingAnchor.constraint(equalTo: landscapeReadingTimeContainer.leadingAnchor),
            landscapeReadingTimeIconView.centerYAnchor.constraint(equalTo: landscapeReadingTimeContainer.centerYAnchor),
            landscapeReadingIconWidthConstraint,
            landscapeReadingIconHeightConstraint,
            landscapeReadingTimeLabel.leadingAnchor.constraint(
                equalTo: landscapeReadingTimeIconView.trailingAnchor,
                constant: IOSUIKitArticleGeometry.landscapeReadingTimeIconTextSpacing
            ),
            landscapeReadingTimeLabel.trailingAnchor.constraint(equalTo: landscapeReadingTimeContainer.trailingAnchor),
            landscapeReadingTimeLabel.topAnchor.constraint(equalTo: landscapeReadingTimeContainer.topAnchor),
            landscapeReadingTimeLabel.bottomAnchor.constraint(equalTo: landscapeReadingTimeContainer.bottomAnchor),
            landscapeReadingLabelWidthConstraint,
        ])

        metadataRow.addSubview(unreadIndicator)
        metadataRow.addSubview(feedIconContainer)
        metadataRow.addSubview(feedTitleLabel)
        metadataRow.addSubview(commentsContainer)
        metadataRow.addSubview(starImageView)
        commentsWidthConstraint = commentsContainer.widthAnchor.constraint(equalToConstant: 0)
        commentsHeightConstraint = commentsContainer.heightAnchor.constraint(equalToConstant: IOSUIKitArticleGeometry.commentSlotSize)
        starWidth = starImageView.widthAnchor.constraint(equalToConstant: IOSUIKitArticleGeometry.starSlotSize)
        starHeight = starImageView.heightAnchor.constraint(equalToConstant: IOSUIKitArticleGeometry.starSlotSize)
        commentsToStarSpacingConstraint = commentsContainer.trailingAnchor.constraint(equalTo: starImageView.leadingAnchor)
        metadataFeedTitleDefaultTrailingConstraint = feedTitleLabel.trailingAnchor.constraint(
            equalTo: commentsContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.metadataTitleSpacing
        )
        metadataFeedTitlePortraitTrailingConstraint = feedTitleLabel.trailingAnchor.constraint(equalTo: metadataRow.trailingAnchor)
        NSLayoutConstraint.activate([
            // Leading edge: feed icon, then the feed name.
            feedIconContainer.leadingAnchor.constraint(equalTo: metadataRow.leadingAnchor),
            feedIconContainer.centerYAnchor.constraint(equalTo: metadataRow.centerYAnchor),
            // Trailing edge, outermost first: unread dot, then star.
            unreadIndicator.trailingAnchor.constraint(equalTo: metadataRow.trailingAnchor),
            unreadIndicator.centerYAnchor.constraint(equalTo: metadataRow.centerYAnchor),
            feedTitleLabel.leadingAnchor.constraint(equalTo: feedIconContainer.trailingAnchor, constant: IOSUIKitArticleGeometry.metadataLeadingSpacing),
            metadataFeedTitleDefaultTrailingConstraint,
            feedTitleLabel.topAnchor.constraint(equalTo: metadataRow.topAnchor),
            feedTitleLabel.bottomAnchor.constraint(equalTo: metadataRow.bottomAnchor),
            commentsContainer.centerYAnchor.constraint(equalTo: metadataRow.centerYAnchor),
            commentsWidthConstraint,
            commentsHeightConstraint,
            commentsToStarSpacingConstraint,
            starImageView.trailingAnchor.constraint(
                equalTo: unreadIndicator.leadingAnchor,
                constant: -IOSUIKitArticleGeometry.metadataAccessorySpacing
            ),
            starImageView.centerYAnchor.constraint(equalTo: metadataRow.centerYAnchor),
            starWidth,
            starHeight,
        ])

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = Self.supportingTextColor
        previewLabel.numberOfLines = 3

        for label in [titleLabel, dateLabel, previewLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            textContainer.addSubview(label)
        }
        textContainer.addSubview(metadataRow)
        textContainer.addSubview(publicationTimeIconView)
        textContainer.addSubview(landscapeReadingTimeContainer)
        previewTopConstraint = previewLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing)
        // Collapsing by priority keeps the constraint graph untouched. Removing
        // or deactivating it instead would mutate the graph on every reuse
        // between an article with and without a preview.
        previewCollapseConstraint = previewLabel.heightAnchor.constraint(equalToConstant: 0)
        previewCollapseConstraint.priority = .defaultHigh
        previewCollapseConstraint.isActive = true
        // The side-title
        // variant reorders the text block and narrows part of it, so the
        // vertical order and the trailing edges are owned by the variant groups.
        // Only the leading edge and the container's bottom are shared.
        previewBottomDefaultConstraint = previewLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        previewTrailingDefaultConstraint = previewLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor)

        defaultDateTopConstraint = dateLabel.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: IOSUIKitArticleGeometry.textSpacing
        )
        defaultDateTrailingConstraint = dateLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor)
        defaultStackConstraints = [
            previewBottomDefaultConstraint,
            previewTrailingDefaultConstraint,
            metadataRow.topAnchor.constraint(equalTo: textContainer.topAnchor),
            metadataRow.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            titleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            defaultDateTopConstraint,
            defaultDateTrailingConstraint,
            previewTopConstraint,
        ]

        publicationTimeIconTextSpacingConstraint = dateLabel.leadingAnchor.constraint(
            equalTo: publicationTimeIconView.trailingAnchor,
            constant: 0
        )
        var stackedConstraints: [NSLayoutConstraint] = [
            publicationTimeIconView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            publicationTimeIconView.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            publicationTimeIconWidthConstraint,
            publicationTimeIconHeightConstraint,
            publicationTimeIconTextSpacingConstraint,
            dateWidthConstraint,
        ]
        for child in [titleLabel, metadataRow, previewLabel] as [UIView] {
            stackedConstraints.append(child.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor))
        }
        NSLayoutConstraint.activate(stackedConstraints)

        articleImageView.translatesAutoresizingMaskIntoConstraints = false
        articleImageView.isHidden = true
        imagePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        imagePlaceholder.tintColor = Self.supportingTextColor
        imagePlaceholder.contentMode = .center
        articleImageView.addSubview(imagePlaceholder)
        NSLayoutConstraint.activate([
            imagePlaceholder.centerXAnchor.constraint(equalTo: articleImageView.centerXAnchor),
            imagePlaceholder.centerYAnchor.constraint(equalTo: articleImageView.centerYAnchor),
        ])

        contentView.addSubview(textContainer)
        contentView.addSubview(articleImageView)
        preparePermanentLayoutConstraints()
        setArticleImagePresentation(loaded: false)
        setFeedIconPresentation(loaded: false)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the article")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func preparePermanentLayoutConstraints() {
        let margins = contentView.layoutMarginsGuide
        portraitImageAspectConstraint = articleImageView.heightAnchor.constraint(
            equalTo: articleImageView.widthAnchor,
            multiplier: 1 / ArticlePresentationLayout.portraitImageAspectRatio
        )
        portraitImageWidthConstraint = articleImageView.widthAnchor.constraint(equalToConstant: 1)
        landscapeImageWidthConstraint = articleImageView.widthAnchor.constraint(equalToConstant: 1)
        landscapeImageHeightConstraint = articleImageView.heightAnchor.constraint(equalToConstant: 1)
        compactDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )
        compactReadingContainerTrailingConstraint = landscapeReadingTimeContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: textContainer.trailingAnchor
        )
        let compactStackConstraints = defaultStackConstraints.filter {
            $0 !== defaultDateTrailingConstraint
        }
        textOnlyConstraints = compactStackConstraints + [
            compactDateTrailingConstraint,
            compactReadingContainerTrailingConstraint,
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),

            textContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(equalTo: margins.topAnchor),
            textContainer.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ]
        // Standard Visual portrait:
        //
        //   ┌─────────────────────┐
        //   │   HERO IMAGE 100%   │
        //   └─────────────────────┘
        //   ● icon  Feed name              ★ 💬
        //   Headline
        //   Date · ▤ 4 min
        //   Preview …
        //
        // Full-width image followed by the normal metadata/title/date stack.
        portraitDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )
        portraitReadingContainerTrailingConstraint = landscapeReadingTimeContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: textContainer.trailingAnchor
        )
        portraitConstraints = [
            articleImageView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            articleImageView.topAnchor.constraint(equalTo: margins.topAnchor),
            portraitImageWidthConstraint,
            portraitImageAspectConstraint,

            textContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(
                equalTo: articleImageView.bottomAnchor,
                constant: IOSUIKitArticleGeometry.portraitSpacing
            ),
            textContainer.bottomAnchor.constraint(equalTo: margins.bottomAnchor),

            metadataRow.topAnchor.constraint(equalTo: textContainer.topAnchor),
            metadataRow.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(
                equalTo: metadataRow.bottomAnchor,
                constant: IOSUIKitArticleGeometry.textSpacing
            ),
            titleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            dateLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: IOSUIKitArticleGeometry.textSpacing
            ),
            portraitDateTrailingConstraint,
            portraitReadingContainerTrailingConstraint,
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),

            previewTopConstraint,
            previewTrailingDefaultConstraint,
            previewBottomDefaultConstraint,
        ]

        landscapeDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )

        let landscapeStackConstraints = defaultStackConstraints.filter {
            $0 !== defaultDateTrailingConstraint
        }
        landscapeConstraints = landscapeStackConstraints + [
            landscapeDateTrailingConstraint,

            articleImageView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            articleImageView.topAnchor.constraint(equalTo: margins.topAnchor),
            landscapeImageWidthConstraint,
            landscapeImageHeightConstraint,
            articleImageView.bottomAnchor.constraint(lessThanOrEqualTo: margins.bottomAnchor),
            textContainer.leadingAnchor.constraint(equalTo: articleImageView.trailingAnchor, constant: 14),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(equalTo: margins.topAnchor),
            textContainer.bottomAnchor.constraint(lessThanOrEqualTo: margins.bottomAnchor),

            landscapeReadingTimeContainer.trailingAnchor.constraint(lessThanOrEqualTo: textContainer.trailingAnchor),
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),
        ]

        // Order, top to bottom:
        //
        //   ● icon  Feed name              ★ 💬     full width
        //   Headline …                    ┌─────┐
        //   Date · ▤ 4 min               │ IMG │
        //                                 └─────┘
        //   Preview …                               full width
        //
        // The metadata bar keeps the full width because the feed name is the
        // element that suffers first: in the narrow column it would fall from
        // 275 pt to 147 pt, and the accessories around it grow with Dynamic Type
        // while the column does not.
        //
        // The image is trailing so every headline starts at the same edge,
        // including rows that have no image at all (`visualTextOnly`).
        //
        // The image reuses the landscape size constraints; only one variant
        // group is ever active, so they cannot collide.
        sideTitlePreviewBelowDateConstraint = previewLabel.topAnchor.constraint(
            greaterThanOrEqualTo: dateLabel.bottomAnchor,
            constant: IOSUIKitArticleGeometry.textSpacing
        )
        sideTitlePreviewBelowImageConstraint = previewLabel.topAnchor.constraint(
            greaterThanOrEqualTo: articleImageView.bottomAnchor,
            constant: IOSUIKitArticleGeometry.textSpacing
        )
        // Pulls the preview up to the date when the text column is the taller of
        // the two. Together with the two required constraints above this is the
        // max() the engine computes.
        let previewPrefersDate = previewLabel.topAnchor.constraint(
            equalTo: dateLabel.bottomAnchor,
            constant: IOSUIKitArticleGeometry.textSpacing
        )
        previewPrefersDate.priority = .defaultLow
        let titleTrailingToImage = titleLabel.trailingAnchor.constraint(
            equalTo: articleImageView.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.sideTitleSpacing
        )
        sideTitleDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )
        sideTitleReadingContainerTrailingConstraint = landscapeReadingTimeContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: articleImageView.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.sideTitleSpacing
        )
        sideTitleConstraints = [
            textContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(equalTo: margins.topAnchor),
            textContainer.bottomAnchor.constraint(equalTo: margins.bottomAnchor),

            metadataRow.topAnchor.constraint(equalTo: textContainer.topAnchor),
            metadataRow.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            titleTrailingToImage,
            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            sideTitleDateTrailingConstraint,
            sideTitleReadingContainerTrailingConstraint,
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),

            articleImageView.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            articleImageView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            landscapeImageWidthConstraint,
            landscapeImageHeightConstraint,

            sideTitlePreviewBelowDateConstraint,
            sideTitlePreviewBelowImageConstraint,
            previewPrefersDate,
            previewBottomDefaultConstraint,
            previewTrailingDefaultConstraint,
        ]

        // Wide container: the
        // preview joins the column beside the image rather than running under it.
        //
        //   ● icon  Feed name              ★ 💬     full width
        //   Headline …                    ┌─────┐
        //   Date                          │ IMG │
        //   Preview …                     └─────┘
        //
        // The image can now be the lowest element in the row, so the container's
        // bottom is only an upper bound for both — the engine fixes the height.
        sideTitleWideDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )
        sideTitleWideReadingContainerTrailingConstraint = landscapeReadingTimeContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: articleImageView.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.sideTitleSpacing
        )
        sideTitleWideConstraints = [
            textContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(equalTo: margins.topAnchor),
            textContainer.bottomAnchor.constraint(equalTo: margins.bottomAnchor),

            metadataRow.topAnchor.constraint(equalTo: textContainer.topAnchor),
            metadataRow.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            titleLabel.trailingAnchor.constraint(
                equalTo: articleImageView.leadingAnchor,
                constant: -IOSUIKitArticleGeometry.sideTitleSpacing
            ),
            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            sideTitleWideDateTrailingConstraint,
            sideTitleWideReadingContainerTrailingConstraint,
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),
            previewTopConstraint,
            previewLabel.trailingAnchor.constraint(
                equalTo: articleImageView.leadingAnchor,
                constant: -IOSUIKitArticleGeometry.sideTitleSpacing
            ),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: textContainer.bottomAnchor),

            articleImageView.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            articleImageView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            articleImageView.bottomAnchor.constraint(lessThanOrEqualTo: textContainer.bottomAnchor),
            landscapeImageWidthConstraint,
            landscapeImageHeightConstraint,
        ]

        // `Visual compact` without an image: the same order — metadata bar,
        // then title, date, preview — at full width, with no image slot.
        sideTitleTextOnlyDateTrailingConstraint = dateLabel.trailingAnchor.constraint(
            equalTo: landscapeReadingTimeContainer.leadingAnchor,
            constant: -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
        )
        sideTitleTextOnlyReadingContainerTrailingConstraint = landscapeReadingTimeContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: textContainer.trailingAnchor
        )
        sideTitleTextOnlyConstraints = [
            textContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textContainer.topAnchor.constraint(equalTo: margins.topAnchor),
            textContainer.bottomAnchor.constraint(equalTo: margins.bottomAnchor),

            metadataRow.topAnchor.constraint(equalTo: textContainer.topAnchor),
            metadataRow.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: metadataRow.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            titleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: IOSUIKitArticleGeometry.textSpacing),
            sideTitleTextOnlyDateTrailingConstraint,
            sideTitleTextOnlyReadingContainerTrailingConstraint,
            landscapeReadingTimeContainer.topAnchor.constraint(equalTo: dateLabel.topAnchor),
            landscapeReadingTimeContainer.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),

            previewTopConstraint,
            previewBottomDefaultConstraint,
            previewTrailingDefaultConstraint,
        ]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        performanceMetrics?.recordReuse()
        invalidateImageBinding()
        representedImageRequest = nil
        representedArticleID = nil
        preparedLayoutMetrics = nil
        clearArticleImagePresentation()
    }

    func configure(
        item: IOSUIKitArticleTimelineItem,
        mode: ArticlePresentationMode,
        previewLines: ArticlePreviewLines,
        showRelativePublicationTime: Bool = false,
        displayScale: CGFloat,
        preparedLayoutMetrics: IOSUIKitArticleLayoutMetrics
    ) {
        let articleChanged = representedArticleID != item.article.id
        representedArticleID = item.article.id
        // Keep independently constrained content in the cell's semantic direction.
        // This is explicit because forced RTL test/preview environments do not
        // reliably propagate through UITableViewCell.contentView on every OS.
        metadataRow.semanticContentAttribute = semanticContentAttribute
        textContainer.semanticContentAttribute = semanticContentAttribute
        self.preparedLayoutMetrics = preparedLayoutMetrics
        currentTitle = item.content.article.title
        currentFeedTitle = item.content.article.feedTitle
        currentShowsRelativePublicationTime = showRelativePublicationTime
        currentPublishedDate = showRelativePublicationTime ? item.content.publishedAge : item.content.publishedDate
        currentReadingTime = item.content.readingTime
        titleLabel.text = currentTitle
        feedTitleLabel.text = currentFeedTitle
        dateLabel.text = item.content.readingTime == nil
            ? currentPublishedDate
            : "\(currentPublishedDate) ·"
        landscapeReadingTimeLabel.text = item.content.readingTime
        let hasPreview = !item.content.article.preview.isEmpty
        previewLabel.text = item.content.article.preview
        previewLabel.isHidden = !hasPreview
        previewLabel.numberOfLines = previewLines.rawValue
        // Constants and priorities only — the constraint graph stays identical
        // across every reuse, whatever the article contains.
        previewTopConstraint.constant = hasPreview ? IOSUIKitArticleGeometry.textSpacing : 0
        // Same collapse for the
        // side-title variant's pair, or a preview-less row keeps a gap below the
        // image that the engine did not budget for.
        let previewSpacing = hasPreview ? IOSUIKitArticleGeometry.textSpacing : 0
        sideTitlePreviewBelowDateConstraint.constant = previewSpacing
        sideTitlePreviewBelowImageConstraint.constant = previewSpacing
        previewCollapseConstraint.priority = hasPreview ? UILayoutPriority(1) : .defaultHigh
        let hasComments = item.content.hasComments
        currentHasComments = hasComments
        commentsContainer.isHidden = !hasComments
        commentsWidthConstraint.constant = hasComments ? (preparedLayoutMetrics.commentsFrame?.width ?? IOSUIKitArticleGeometry.commentSlotSize) : 0
        commentsToStarSpacingConstraint.constant = hasComments ? -IOSUIKitArticleGeometry.metadataAccessorySpacing : 0
        let hasImage = mode.showsArticleImage && item.content.imageURL != nil
        let imageSize = hasImage ? (preparedLayoutMetrics.imageFrame?.size ?? .zero) : .zero
        applyLayout(preparedLayoutMetrics)

        updateFeedIcon(image: item.feedIconImage, title: item.content.article.feedTitle)
        updateStatus(isRead: item.isRead, isStarred: item.isStarred)
        configureArticleImage(
            url: item.content.imageURL,
            targetSize: imageSize,
            displayScale: displayScale,
            articleChanged: articleChanged
        )
        contentView.setNeedsLayout()
    }

    /// Slot sizes come from the prepared metrics rather than from constants, so
    /// the scaled glyphs and the engine's frames cannot drift apart.
    private func applyAccessoryMetrics(_ layout: IOSUIKitArticleLayoutMetrics) {
        let unread = layout.unreadFrame.width
        if unreadWidth.constant != unread {
            unreadWidth.constant = unread
            unreadHeight.constant = unread
        }
        // Guarded on its own value, not on the size: at the default text size the
        // computed width equals the constant the constraint was created with, so
        // folding this into the branch above left the radius at 0 and the dot
        // rendered as a square.
        let unreadRadius = unread / 2
        if unreadIndicator.layer.cornerRadius != unreadRadius {
            unreadIndicator.layer.cornerRadius = unreadRadius
        }
        let icon = layout.feedIconFrame.width
        if feedIconWidth.constant != icon {
            feedIconWidth.constant = icon
            feedIconHeight.constant = icon
            metadataMinimumHeight.constant = icon
        }
        let star = layout.starFrame.width
        if starWidth.constant != star {
            starWidth.constant = star
            starHeight.constant = star
        }
        let comments = layout.commentsFrame?.width ?? IOSUIKitArticleGeometry.commentSlotSize
        if commentsHeightConstraint.constant != comments {
            commentsHeightConstraint.constant = comments
        }

        if let publicationIcon = layout.publicationTimeIconFrame {
            publicationTimeIconWidthConstraint.constant = publicationIcon.width
            publicationTimeIconHeightConstraint.constant = publicationIcon.height
        } else {
            publicationTimeIconWidthConstraint.constant = 0
            publicationTimeIconHeightConstraint.constant = 0
        }
        dateWidthConstraint.constant = layout.dateFrame.width

        if let container = layout.landscapeReadingTimeContainerFrame,
           let icon = layout.landscapeReadingTimeIconFrame,
           let text = layout.landscapeReadingTimeFrame {
            landscapeReadingContainerWidthConstraint.constant = container.width
            landscapeReadingIconWidthConstraint.constant = icon.width
            landscapeReadingIconHeightConstraint.constant = icon.height
            landscapeReadingLabelWidthConstraint.constant = text.width
        } else {
            landscapeReadingContainerWidthConstraint.constant = 0
            landscapeReadingIconWidthConstraint.constant = 0
            landscapeReadingIconHeightConstraint.constant = 0
            landscapeReadingLabelWidthConstraint.constant = 0
        }
    }

    private func applyLayout(_ layout: IOSUIKitArticleLayoutMetrics) {
        applyAccessoryMetrics(layout)
        let variant = layout.variant
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: layout.verticalInset,
            leading: layout.horizontalInset,
            bottom: layout.verticalInset,
            trailing: layout.horizontalInset
        )

        let usesDateRowReadingTime = currentReadingTime != nil
        publicationTimeIconView.isHidden = !currentShowsRelativePublicationTime
        publicationTimeIconTextSpacingConstraint.constant = currentShowsRelativePublicationTime
            ? IOSUIKitArticleGeometry.landscapeReadingTimeIconTextSpacing
            : 0
        metadataFeedTitleDefaultTrailingConstraint.isActive = true
        metadataFeedTitlePortraitTrailingConstraint.isActive = false
        landscapeReadingTimeContainer.isHidden = !usesDateRowReadingTime
        let dateReadingSpacing = usesDateRowReadingTime
            ? -IOSUIKitArticleGeometry.landscapeDateReadingTimeSpacing
            : 0
        landscapeDateTrailingConstraint.constant = dateReadingSpacing
        compactDateTrailingConstraint.constant = dateReadingSpacing
        portraitDateTrailingConstraint.constant = dateReadingSpacing
        sideTitleDateTrailingConstraint.constant = dateReadingSpacing
        sideTitleWideDateTrailingConstraint.constant = dateReadingSpacing
        sideTitleTextOnlyDateTrailingConstraint.constant = dateReadingSpacing
        unreadIndicator.isHidden = false
        starImageView.isHidden = false
        commentsContainer.isHidden = !currentHasComments

        if let imageSize = layout.imageFrame?.size {
            if variant == .visualPortrait {
                portraitImageWidthConstraint.constant = imageSize.width
            } else if variant == .visualLandscape || variant == .visualSideTitle || variant == .visualSideTitleWide {
                landscapeImageWidthConstraint.constant = imageSize.width
                landscapeImageHeightConstraint.constant = imageSize.height
            }
        }

        guard currentLayoutVariant != variant else {
            articleImageView.isHidden = !variant.showsImageSlot
            return
        }

        NSLayoutConstraint.deactivate(activeLayoutConstraints)
        dateLabel.isHidden = false

        switch variant {
        case .compact, .visualTextOnly:
            activeLayoutConstraints = textOnlyConstraints
        case .visualPortrait:
            activeLayoutConstraints = portraitConstraints
        case .visualLandscape:
            activeLayoutConstraints = landscapeConstraints
        case .visualSideTitle:
            activeLayoutConstraints = sideTitleConstraints
        case .visualSideTitleWide:
            activeLayoutConstraints = sideTitleWideConstraints
        case .visualSideTitleTextOnly:
            activeLayoutConstraints = sideTitleTextOnlyConstraints
        }
        NSLayoutConstraint.activate(activeLayoutConstraints)
        currentLayoutVariant = variant
        layoutVariantRevision &+= 1
        performanceMetrics?.recordVariantSwitch()
        articleImageView.isHidden = !variant.showsImageSlot
    }

    func updateStatus(isRead: Bool, isStarred: Bool) {
        currentIsRead = isRead
        currentIsStarred = isStarred
        titleLabel.textColor = isRead ? .secondaryLabel : .label
        // Colour only — never anything that could move a frame.
        let supporting = isRead ? Self.supportingReadTextColor : Self.supportingTextColor
        feedTitleLabel.textColor = supporting
        publicationTimeIconView.tintColor = supporting
        dateLabel.textColor = supporting
        landscapeReadingTimeIconView.tintColor = supporting
        landscapeReadingTimeLabel.textColor = supporting
        previewLabel.textColor = supporting
        commentsImageView.tintColor = supporting
        let unreadOpacity = ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: isRead)
        unreadIndicator.alpha = unreadOpacity
        // The fixed trailing/rail slot remains allocated when the star is not visible.
        starImageView.alpha = isStarred ? 1 : 0
        updateAccessibility()
    }

    func updateFeedIcon(image: UIImage?, title: String) {
        if let image {
            feedIconImageView.image = image
            feedIconImageView.isHidden = false
            feedIconFallbackLabel.isHidden = true
            feedIconContainer.backgroundColor = .clear
            setFeedIconPresentation(loaded: true)
        } else {
            feedIconImageView.image = nil
            feedIconImageView.isHidden = true
            feedIconFallbackLabel.isHidden = false
            feedIconFallbackLabel.text = title.prefix(1).uppercased()
            feedIconContainer.backgroundColor = .tintColor
            setFeedIconPresentation(loaded: false)
        }
    }

    // Internal test seam: pixels must remain a presentation-only update.
    func applyArticleImagePixelsForTesting(_ image: UIImage?) {
        articleImageView.image = image
        imagePlaceholder.isHidden = image != nil
        setArticleImagePresentation(loaded: image != nil)
    }

    var articleImageSlotFrameForTesting: CGRect { articleImageView.frame }
#if DEBUG
    private(set) var articleImageFadeCountForTesting = 0
    var articleImageIsFadingForTesting: Bool {
        articleImageView.layer.animation(forKey: Self.articleImageFadeKey) != nil
    }
#endif
    var articleImageForTesting: UIImage? { articleImageView.image }
    var articleImageSlotIsHiddenForTesting: Bool { articleImageView.isHidden }
#if DEBUG
    var articleImageRasterForTesting: CGImage? { articleImageView.image?.cgImage }
    func setArticleImagePipelineForTesting(_ pipeline: ArticleImagePipeline) { articleImagePipeline = pipeline }
#endif
    func setArticleImageArrivalAnimationsEnabled(_ enabled: Bool) {
        articleImageArrivalAnimationsEnabled = enabled
    }
    var articleImagePresentationForTesting: (placeholderHidden: Bool, contentMode: UIView.ContentMode, clipsToBounds: Bool, cornerRadius: CGFloat) {
        (imagePlaceholder.isHidden, articleImageView.contentMode, articleImageView.clipsToBounds, articleImageView.layer.cornerRadius)
    }
    var feedIconPresentationForTesting: (imageHidden: Bool, fallbackHidden: Bool, clipsToBounds: Bool, cornerRadius: CGFloat) {
        (feedIconImageView.isHidden, feedIconFallbackLabel.isHidden, feedIconContainer.clipsToBounds, feedIconContainer.layer.cornerRadius)
    }

    struct LayoutDiagnostics: Equatable {
        let contentBounds: CGRect
        let margins: NSDirectionalEdgeInsets
        let variant: IOSUIKitArticleCellLayoutVariant?
        let imageFrame: CGRect
        let textStackFrame: CGRect
        let titleFrame: CGRect
        let starFrame: CGRect
        let metadataFrame: CGRect
        let unreadFrame: CGRect
        let feedIconFrame: CGRect
        let feedTitleFrame: CGRect
        let commentsFrame: CGRect?
        let dateFrame: CGRect
        let publicationTimeIconFrame: CGRect?
        let landscapeReadingTimeContainerFrame: CGRect?
        let landscapeReadingTimeIconFrame: CGRect?
        let landscapeReadingTimeFrame: CGRect?
        let previewFrame: CGRect?
    }

    var layoutDiagnosticsForTesting: LayoutDiagnostics {
        func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: contentView) }
        return .init(
            contentBounds: contentView.bounds,
            margins: contentView.directionalLayoutMargins,
            variant: currentLayoutVariant,
            imageFrame: frame(articleImageView),
            textStackFrame: frame(textContainer),
            titleFrame: frame(titleLabel),
            starFrame: frame(starImageView),
            metadataFrame: frame(metadataRow),
            unreadFrame: frame(unreadIndicator),
            feedIconFrame: frame(feedIconContainer),
            feedTitleFrame: frame(feedTitleLabel),
            commentsFrame: currentHasComments ? frame(commentsContainer) : nil,
            dateFrame: frame(dateLabel),
            publicationTimeIconFrame: currentShowsRelativePublicationTime ? frame(publicationTimeIconView) : nil,
            landscapeReadingTimeContainerFrame: currentReadingTime != nil
                ? frame(landscapeReadingTimeContainer)
                : nil,
            landscapeReadingTimeIconFrame: currentReadingTime != nil
                ? frame(landscapeReadingTimeIconView)
                : nil,
            landscapeReadingTimeFrame: currentReadingTime != nil
                ? frame(landscapeReadingTimeLabel)
                : nil,
            previewFrame: previewLabel.isHidden ? nil : frame(previewLabel)
        )
    }

    var portraitAspectConstraintDiagnosticsForTesting: (multiplier: CGFloat, constant: CGFloat, priority: UILayoutPriority, imageFrame: CGRect, contentBounds: CGRect, margins: NSDirectionalEdgeInsets, displayScale: CGFloat) {
        (portraitImageAspectConstraint.multiplier, portraitImageAspectConstraint.constant, portraitImageAspectConstraint.priority, articleImageView.frame, contentView.bounds, contentView.directionalLayoutMargins, traitCollection.displayScale)
    }
    var layoutVariantForTesting: IOSUIKitArticleCellLayoutVariant? { currentLayoutVariant }
    var feedIconImageForTesting: UIImage? { feedIconImageView.image }
    var feedTitlePresentationForTesting: (lineCount: Int, lineBreakMode: NSLineBreakMode) {
        (feedTitleLabel.numberOfLines, feedTitleLabel.lineBreakMode)
    }

    private func configureArticleImage(
        url: URL?,
        targetSize: CGSize,
        displayScale: CGFloat,
        articleChanged: Bool
    ) {
        guard let url, targetSize.width > 0, targetSize.height > 0 else {
            guard representedImageRequest != nil else { return }
            performanceMetrics?.recordImageBinding()
            invalidateImageBinding()
            representedImageRequest = nil
            articleImageView.image = nil
            imagePlaceholder.isHidden = false
            setArticleImagePresentation(loaded: false)
            return
        }

        let request = ArticleImageRequest(
            url: url,
            targetSize: targetSize,
            displayScale: displayScale,
            rasterScale: articleImageRasterScale(displayScale)
        )
        guard articleChanged || representedImageRequest != request else { return }
        performanceMetrics?.recordImageBinding()
        invalidateImageBinding()
        let bindingGeneration = imageBindingGeneration
        guard let articleID = representedArticleID else { return }
        representedImageRequest = request
        if let cachedImage = articleImagePipeline.cachedImage(for: request) {
            // Cache residency removes decode/raster work, but swapping several
            // distinct large rasters into visible cells in one display frame can
            // still hitch. Route warm-cache presentation through the same
            // frame-paced scheduler as cold async completions while scrolling.
            clearArticleImagePresentation()
            scheduleArticleImagePresentation(
                cachedImage,
                request: request,
                articleID: articleID,
                bindingGeneration: bindingGeneration,
                allowsAnimation: false
            )
            return
        }

        clearArticleImagePresentation()
        let pipeline = articleImagePipeline
        imageTask = Task { @MainActor [weak self, pipeline] in
            do {
                let loadedImage = try await pipeline.image(for: request, cacheWasChecked: true)
                guard !Task.isCancelled,
                      let self,
                      self.imageBindingGeneration == bindingGeneration,
                      self.representedArticleID == articleID,
                      self.representedImageRequest == request
                else { return }
                self.scheduleArticleImagePresentation(
                    loadedImage,
                    request: request,
                    articleID: articleID,
                    bindingGeneration: bindingGeneration,
                    allowsAnimation: true
                )
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.imageBindingGeneration == bindingGeneration,
                      self.representedArticleID == articleID,
                      self.representedImageRequest == request
                else { return }
                self.clearArticleImagePresentation()
            }
        }
    }

    private func scheduleArticleImagePresentation(
        _ image: CGImage,
        request: ArticleImageRequest,
        articleID: Int64,
        bindingGeneration: UInt64,
        allowsAnimation: Bool
    ) {
        IOSArticleImagePresentationScheduler.shared.enqueue(
            isStillValid: { [weak self] in
                guard let self else { return false }
                return self.imageBindingGeneration == bindingGeneration
                    && self.representedArticleID == articleID
                    && self.representedImageRequest == request
            },
            present: { [weak self] in
                guard let self else { return }
                self.presentArticleImage(
                    image,
                    animated: allowsAnimation && self.articleImageArrivalAnimationsEnabled
                )
            }
        )
    }

    private static let articleImageFadeDuration: CFTimeInterval = 0.2
    private static let articleImageFadeKey = "flux.articleImageFade"

    private func presentArticleImage(_ image: CGImage, animated: Bool) {
        if animated {
#if DEBUG
            articleImageFadeCountForTesting &+= 1
#endif
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.articleImageFadeDuration
            articleImageView.layer.add(fade, forKey: Self.articleImageFadeKey)
        }
        // Use the physical display scale for UIImage semantics. Fixed
        // image-view constraints remain authoritative for the slot.
        articleImageView.image = UIImage(cgImage: image, scale: traitCollection.displayScale, orientation: .up)
        articleImageView.isOpaque = false
        imagePlaceholder.isHidden = true
        setArticleImagePresentation(loaded: true)
    }

    private func clearArticleImagePresentation() {
        articleImageView.layer.removeAnimation(forKey: Self.articleImageFadeKey)
        articleImageView.image = nil
        // The placeholder state has rounded corners of its own and must blend.
        articleImageView.isOpaque = false
        imagePlaceholder.isHidden = false
        setArticleImagePresentation(loaded: false)
    }

    private func setArticleImagePresentation(loaded: Bool) {
        articleImageView.contentMode = .scaleAspectFill
        articleImageView.clipsToBounds = loaded
        articleImageView.layer.cornerRadius = IOSUIKitArticleGeometry.articleImageCornerRadius
        articleImageView.backgroundColor = loaded ? .clear : .tertiarySystemFill
    }

    private func setFeedIconPresentation(loaded: Bool) {
        feedIconImageView.contentMode = loaded ? .scaleToFill : .scaleAspectFit
        // Core Animation resolves a rounded background analytically, but a
        // rounded mask over a sublayer needs an offscreen pass. The fallback
        // letter is centred inside the circle and never overflows it, so the
        // container keeps its rounded background without masking — matching the
        // cold article-image placeholder next to it.
        feedIconContainer.clipsToBounds = false
        feedIconContainer.layer.cornerRadius = loaded ? 0 : feedIconWidth.constant / 2
    }

    private func invalidateImageBinding() {
        imageBindingGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
    }

    private func updateAccessibility() {
        let reading = currentReadingTime.map { ", \(String(localized: "Reading time")) \($0)" } ?? ""
        accessibilityLabel = "\(currentTitle), \(currentFeedTitle), \(currentPublishedDate)\(reading), \(currentIsRead ? String(localized: "Read") : String(localized: "Unread"))\(currentIsStarred ? String(localized: ", starred") : "")"
        accessibilityValue = currentIsRead
            ? (currentIsStarred ? String(localized: "Read, starred") : String(localized: "Read"))
            : (currentIsStarred ? String(localized: "Unread, starred") : String(localized: "Unread"))
    }
}

struct ArticleListView: View {
    @Environment(\.colorScheme) private var colorScheme
    var store: NewsreaderStore
    var naturalTopContentInset: CGFloat = 0
    var usesNativeTopEdgeEffect = true
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void

    var body: some View {
        let emptyState = IOSArticleListEmptyState.resolve(
            isSyncing: store.isSyncing,
            isLoading: store.isLoading,
            errorMessage: store.errorMessage,
            hasArticles: store.hasLoadedArticles
        )
        let iconVariant = IOSFeedIconPresentation.variant(isDark: colorScheme == .dark)

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
                IOSUIKitArticleTimelineView(
                    structuralState: store.timelineStructuralState,
                    presentationBridge: store.timelinePresentationBridge,
                    feedIconPresentationBridge: store.timelinePresentationBridge,
                    mode: store.articlePresentationMode,
                    previewLines: store.articlePreviewLines,
                    showRelativePublicationTime: store.showRelativePublicationTime,
                    iconVariant: iconVariant,
                    feedIconRequestRevision: store.feedIconRequestRevision,
                    scrollResetRevision: store.scrollResetRevision,
                    markReadOnScrolloverEnabled: store.markReadOnScrolloverEnabled,
                    swipeConfiguration: store.articleSwipeConfiguration,
                    audioActionStates: store.articleAudioActionStates,
                    showsRefreshControl: true,
                    naturalTopContentInset: naturalTopContentInset,
                    usesNativeTopEdgeEffect: usesNativeTopEdgeEffect,
                    onArticleTap: onArticleTap,
                    onArticleAction: onArticleAction,
                    onArticleMediaAction: onArticleMediaAction,
                    onSetRead: { article, read in store.setRead(article, read: read) },
                    onSetStarred: { article, starred in store.setStarred(article, starred: starred) },
                    onRequestFeedIcon: { feedID, variant, displayScale in store.requestFeedIcon(feedID, variant: variant, displayScale: displayScale) },
                    onRefresh: { await store.syncManually() },
                    onApproachingEnd: { store.loadNextTimelinePage() },
                    onMeaningfulInteraction: { store.markMeaningfulInteraction() },
                    onScrolloverBatch: { store.flushScrollover($0) },
                    onScrolloverDirection: { store.receiveScrolloverDirection($0) },
                    onScrolloverPhase: { store.setScrolloverPresentationPhase($0) }
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
        }
        .background(.background)
        .overlay(alignment: .bottom) {
            ArticleListBottomOverlay(store: store)
        }
        // Mark-as-read is a completed action/event. Scrollover publishes this
        // revision only once after the motion has settled and its successful
        // mutations are drained, so fast scrolling never becomes a haptic stream.
        .sensoryFeedback(.success, trigger: store.readCompletionFeedbackRevision)
        .sensoryFeedback(.success, trigger: store.starCompletionFeedbackRevision)
        // Undo is intentionally distinct and lighter: it communicates the
        // reversal of the read-state change without reusing the completion pulse.
        .sensoryFeedback(.selection, trigger: store.undoCompletionFeedbackRevision)
    }

}

private struct ArticleListBottomOverlay: View {
    var store: NewsreaderStore

    var body: some View {
        Group {
            if store.scrolloverUndoVisible {
                ScrolloverUndoPresentation(store: store)
            } else if store.hasPendingNewDataForCurrentScope {
                Button("New articles available") { store.adoptVisibleSnapshot() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
            }
        }
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
