import SwiftUI
import UIKit

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

struct IOSScrolloverBatch: Equatable {
    let articleIDs: [Int64]
}

enum IOSArticleRowViewportRegion: Equatable {
    case above
    case visible
    case below

    static func resolve(frame: CGRect, viewportHeight: CGFloat) -> Self {
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

/// Historical SwiftUI/List sensor retained temporarily for its existing regression tests.
/// Production Timeline scrollover is driven by IOSUIKitScrolloverGeometryTracker below.
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

/// One coherent UIKit geometry sample. All values use UICollectionView content coordinates.
struct IOSUIKitScrolloverGeometrySample: Equatable {
    let contentOffsetY: CGFloat
    let effectiveTop: CGFloat
    let effectiveBottom: CGFloat
    let contentHeight: CGFloat
    let rowFrames: [Int64: CGRect]
    let layoutGeneration: UInt64
}

struct IOSUIKitScrolloverGeometryResult: Equatable {
    let direction: IOSArticleScrollDirection?
    let batch: IOSScrolloverBatch
}

/// Non-observable, bounded geometry detector owned by the UIKit Timeline.
/// It only emits IDs that were actually observed in the viewport during a user-driven
/// interaction and then crossed the effective upper viewport boundary while moving forward.
final class IOSUIKitScrolloverGeometryTracker {
    private static let bottomTolerance: CGFloat = 0.5
    private static let maximumRetainedGeometryCount = 96

    private var orderedIDs: [Int64] = []
    private var positions: [Int64: Int] = [:]
    private var emittedIDs = Set<Int64>()
    private var observedVisibleIDs = Set<Int64>()
    private var retainedFrames: [Int64: CGRect] = [:]
    private var previousSample: IOSUIKitScrolloverGeometrySample?
    private var phase: IOSScrolloverPresentationPhase = .idle
    private var wasAtBottom = false

    var retainedGeometryCount: Int { retainedFrames.count }

    func updateSnapshot(_ ids: [Int64]) {
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        emittedIDs.removeAll()
        observedVisibleIDs.removeAll()
        invalidateGeometry()
    }

    func setPhase(_ newPhase: IOSScrolloverPresentationPhase) {
        phase = newPhase
        if newPhase == .idle {
            observedVisibleIDs.removeAll(keepingCapacity: true)
            invalidateGeometry()
        }
    }

    func invalidateGeometry() {
        retainedFrames.removeAll(keepingCapacity: true)
        previousSample = nil
        wasAtBottom = false
    }

    func rearm(_ ids: some Sequence<Int64>) {
        for id in ids { emittedIDs.remove(id) }
    }

    func receive(_ sample: IOSUIKitScrolloverGeometrySample, enabled: Bool) -> IOSUIKitScrolloverGeometryResult {
        guard phase.isScrolling else {
            previousSample = sample
            wasAtBottom = isAtBottom(sample)
            return .init(direction: nil, batch: .init(articleIDs: []))
        }

        guard let previous = previousSample,
              previous.layoutGeneration == sample.layoutGeneration else {
            rebaseline(with: sample, enabled: enabled)
            return .init(direction: nil, batch: .init(articleIDs: []))
        }

        guard !hasMaterialLayoutChange(from: previous, to: sample) else {
            rebaseline(with: sample, enabled: enabled)
            return .init(direction: nil, batch: .init(articleIDs: []))
        }

        let delta = sample.contentOffsetY - previous.contentOffsetY
        let direction: IOSArticleScrollDirection?
        if delta > 0 { direction = .forward }
        else if delta < 0 { direction = .backward }
        else { direction = nil }

        let visibleIDs = visibleIDs(in: sample)

        var candidates = Set<Int64>()
        if enabled, direction == .forward {
            for id in observedVisibleIDs where !emittedIDs.contains(id) {
                guard let frame = sample.rowFrames[id] ?? retainedFrames[id] else { continue }
                if previous.effectiveTop < frame.maxY,
                   sample.effectiveTop >= frame.maxY {
                    candidates.insert(id)
                }
            }

            let atBottom = isAtBottom(sample)
            if !wasAtBottom, atBottom {
                candidates.formUnion(visibleIDs.intersection(observedVisibleIDs))
            }
            wasAtBottom = atBottom
        } else {
            wasAtBottom = isAtBottom(sample)
        }

        retainBoundedGeometry(sample.rowFrames, viewportTop: sample.effectiveTop)
        if enabled {
            observedVisibleIDs.formUnion(visibleIDs)
        } else {
            observedVisibleIDs.removeAll(keepingCapacity: true)
        }
        observedVisibleIDs.formIntersection(Set(retainedFrames.keys).union(visibleIDs))
        previousSample = sample

        let ids = candidates
            .filter { emittedIDs.insert($0).inserted }
            .sorted { positions[$0, default: .max] < positions[$1, default: .max] }
        return .init(direction: direction, batch: .init(articleIDs: ids))
    }

    private func rebaseline(with sample: IOSUIKitScrolloverGeometrySample, enabled: Bool) {
        let visible = visibleIDs(in: sample)
        observedVisibleIDs.removeAll(keepingCapacity: true)
        if enabled { observedVisibleIDs.formUnion(visible) }
        retainBoundedGeometry(sample.rowFrames, viewportTop: sample.effectiveTop)
        observedVisibleIDs.formIntersection(Set(retainedFrames.keys).union(visible))
        previousSample = sample
        wasAtBottom = isAtBottom(sample)
    }

    private func visibleIDs(in sample: IOSUIKitScrolloverGeometrySample) -> Set<Int64> {
        Set(sample.rowFrames.compactMap { id, frame in
            guard frame.maxY > sample.effectiveTop, frame.minY < sample.effectiveBottom else { return nil }
            return id
        })
    }

    private func isAtBottom(_ sample: IOSUIKitScrolloverGeometrySample) -> Bool {
        sample.effectiveBottom >= sample.contentHeight - Self.bottomTolerance
    }

    private func hasMaterialLayoutChange(
        from previous: IOSUIKitScrolloverGeometrySample,
        to sample: IOSUIKitScrolloverGeometrySample
    ) -> Bool {
        for (id, oldFrame) in previous.rowFrames {
            guard let newFrame = sample.rowFrames[id], oldFrame != newFrame else { continue }
            return true
        }
        return false
    }

    private func retainBoundedGeometry(_ frames: [Int64: CGRect], viewportTop: CGFloat) {
        retainedFrames.merge(frames) { _, new in new }
        guard retainedFrames.count > Self.maximumRetainedGeometryCount else { return }
        let retained = retainedFrames
            .sorted { abs($0.value.midY - viewportTop) < abs($1.value.midY - viewportTop) }
            .prefix(Self.maximumRetainedGeometryCount)
        retainedFrames = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
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
    private weak var controller: IOSUIKitArticleTimelineController?
    private var articleStates: [Int64: IOSUIKitArticlePresentationState] = [:]
    private var feedIcons: [IOSFeedIconKey: IOSUIKitFeedIconPresentationDelta] = [:]

    func attach(_ controller: IOSUIKitArticleTimelineController, appliesArticleState: Bool = true) {
        self.controller = controller
        if appliesArticleState { controller.applyPresentationBridgeState(self) }
    }

    func replaceArticleStates(_ states: [Int64: IOSUIKitArticlePresentationState]) {
        articleStates = states
    }

    func publishArticle(_ delta: IOSUIKitArticlePresentationDelta) {
        guard delta.state.revision >= articleStates[delta.articleID]?.revision ?? 0 else { return }
        articleStates[delta.articleID] = delta.state
        controller?.applyArticlePresentation(delta)
    }

    func publishFeedIcon(_ delta: IOSUIKitFeedIconPresentationDelta) {
        guard delta.revision >= feedIcons[delta.key]?.revision ?? 0 else { return }
        feedIcons[delta.key] = delta
        controller?.applyFeedIconPresentation(delta)
    }

    func articleState(for id: Int64, fallback: ArticleSummary) -> IOSUIKitArticlePresentationState {
        articleStates[id] ?? .init(isRead: fallback.isRead, isStarred: fallback.isStarred, revision: 0)
    }

    func feedIcon(for feedID: Int64, variant: FeedIconVariant) -> UIImage? {
        feedIcons[.init(feedID: feedID, variant: variant)]?.image
    }
}

struct IOSUIKitArticleTimelineStructuralState {
    let items: [IOSUIKitArticleTimelineStructuralItem]
    let revision: UInt64
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
    let iconVariant: FeedIconVariant
    let scrollResetRevision: UInt64
    let markReadOnScrolloverEnabled: Bool
    let showsRefreshControl: Bool
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    let onSetRead: (ArticleSummary, Bool) -> Void
    let onSetStarred: (ArticleSummary, Bool) -> Void
    let onRequestFeedIcon: (Int64, FeedIconVariant) -> Void
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

    private func update(_ controller: IOSUIKitArticleTimelineController) {
        controller.onArticleTap = onArticleTap
        controller.onArticleAction = onArticleAction
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
            iconVariant: iconVariant,
            scrollResetRevision: scrollResetRevision,
            markReadOnScrolloverEnabled: markReadOnScrolloverEnabled,
            showsRefreshControl: showsRefreshControl
        )
    }
}

@MainActor
final class IOSUIKitArticleTimelineController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private enum Section: Hashable { case main }

    var onArticleTap: ((ArticleSummary) -> Void)?
    var onArticleAction: ((ArticleSummary, IOSArticleContextAction) -> Void)?
    var onSetRead: ((ArticleSummary, Bool) -> Void)?
    var onSetStarred: ((ArticleSummary, Bool) -> Void)?
    var onRequestFeedIcon: ((Int64, FeedIconVariant) -> Void)?
    var onRefresh: (() async -> Void)?
    var onApproachingEnd: (() -> Void)?
    var onMeaningfulInteraction: (() -> Void)?
    var onScrolloverBatch: ((IOSScrolloverBatch) -> Void)?
    var onScrolloverDirection: ((IOSArticleScrollDirection) -> Void)?
    var onScrolloverPhase: ((IOSScrolloverPresentationPhase) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Int64>!
    private var orderedIDs: [Int64] = []
    private var itemsByID: [Int64: IOSUIKitArticleTimelineStructuralItem] = [:]
    private var presentationByID: [Int64: IOSUIKitArticlePresentationState] = [:]
    private weak var presentationBridge: IOSUIKitArticleTimelinePresentationBridge?
    private weak var feedIconPresentationBridge: IOSUIKitArticleTimelinePresentationBridge?
    private var structuralRevision: UInt64?
    private var mode: ArticlePresentationMode = .visual
    private var previewLines: ArticlePreviewLines = .standard
    private var iconVariant: FeedIconVariant = .normal
    private var scrollResetRevision: UInt64?
    private var markReadOnScrolloverEnabled = false
    private var showsRefreshControl = true
    private var scrolloverPhase: IOSScrolloverPresentationPhase = .idle
    private var scrolloverLayoutGeneration: UInt64 = 0
    private var lastLayoutWidth: CGFloat = 0
    private var prefetchTasks: [Int64: Task<Void, Never>] = [:]
    private let refreshControl = UIRefreshControl()
    private let scrolloverGeometryTracker = IOSUIKitScrolloverGeometryTracker()
    private let articleHeightCache = IOSUIKitArticleCellHeightCache(capacity: 512)
    private(set) var structuralReconciliationCount = 0
    private(set) var structuralSnapshotApplicationCount = 0
    private(set) var articlePresentationApplicationCount = 0
    private(set) var feedIconPresentationApplicationCount = 0
    private(set) var scrolloverRearmCount = 0

    private static func makeListLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeListLayout()
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(IOSUIKitArticleCell.self, forCellWithReuseIdentifier: IOSUIKitArticleCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.articleHeightCache.removeAll()
            self.invalidateScrolloverGeometry()
            self.collectionView.setCollectionViewLayout(Self.makeListLayout(), animated: false)
        }
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource<Section, Int64>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let self,
                  let cell = collectionView.dequeueReusableCell(withReuseIdentifier: IOSUIKitArticleCell.reuseIdentifier, for: indexPath) as? IOSUIKitArticleCell,
                  let item = self.renderedItem(for: id)
            else { return nil }
            self.configure(cell, item: item)
            return cell
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        cancelAllPrefetch()
        invalidateScrolloverGeometry()
        for case let cell as IOSUIKitArticleCell in collectionView.visibleCells {
            guard let id = cell.representedArticleID, let item = renderedItem(for: id) else { continue }
            configure(cell, item: item)
            cell.setNeedsLayout()
        }
        collectionView.setCollectionViewLayout(Self.makeListLayout(), animated: false)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        articleHeightCache.removeAll()
    }

    func update(
        structuralState: IOSUIKitArticleTimelineStructuralState,
        presentationBridge newPresentationBridge: IOSUIKitArticleTimelinePresentationBridge,
        feedIconPresentationBridge newFeedIconPresentationBridge: IOSUIKitArticleTimelinePresentationBridge,
        mode newMode: ArticlePresentationMode,
        previewLines newPreviewLines: ArticlePreviewLines,
        iconVariant newIconVariant: FeedIconVariant,
        scrollResetRevision newScrollResetRevision: UInt64,
        markReadOnScrolloverEnabled newMarkReadOnScrolloverEnabled: Bool,
        showsRefreshControl newShowsRefreshControl: Bool
    ) {
        loadViewIfNeeded()

        let structuralChanged = structuralRevision != structuralState.revision
        let layoutInputsChanged = mode != newMode || previewLines != newPreviewLines
        let iconVariantChanged = iconVariant != newIconVariant
        let resetChanged = scrollResetRevision != nil && scrollResetRevision != newScrollResetRevision

        mode = newMode
        previewLines = newPreviewLines
        iconVariant = newIconVariant
        scrollResetRevision = newScrollResetRevision
        markReadOnScrolloverEnabled = newMarkReadOnScrolloverEnabled
        showsRefreshControl = newShowsRefreshControl
        collectionView.refreshControl = showsRefreshControl ? refreshControl : nil
        if presentationBridge !== newPresentationBridge {
            presentationBridge = newPresentationBridge
            newPresentationBridge.attach(self)
        }
        if feedIconPresentationBridge !== newFeedIconPresentationBridge {
            feedIconPresentationBridge = newFeedIconPresentationBridge
            newFeedIconPresentationBridge.attach(self, appliesArticleState: false)
        }

        if structuralChanged {
            structuralReconciliationCount &+= 1
            let newIDs = structuralState.items.map(\.article.id)
            orderedIDs = newIDs
            itemsByID = Dictionary(uniqueKeysWithValues: structuralState.items.map { ($0.article.id, $0) })
            presentationByID = Dictionary(uniqueKeysWithValues: structuralState.items.map {
                ($0.article.id, newPresentationBridge.articleState(for: $0.article.id, fallback: $0.article))
            })
            structuralRevision = structuralState.revision
            scrolloverGeometryTracker.updateSnapshot(newIDs)
            invalidateScrolloverGeometry()
            var snapshot = NSDiffableDataSourceSnapshot<Section, Int64>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIDs)
            dataSource.apply(snapshot, animatingDifferences: false)
            structuralSnapshotApplicationCount &+= 1
        }
        if layoutInputsChanged { invalidateScrolloverGeometry() }

        var needsLayoutInvalidation = layoutInputsChanged
        if structuralChanged || layoutInputsChanged || iconVariantChanged {
            for case let cell as IOSUIKitArticleCell in collectionView.visibleCells {
                guard let id = cell.representedArticleID, let item = renderedItem(for: id) else { continue }
                configure(cell, item: item)
            }
            needsLayoutInvalidation = structuralChanged || layoutInputsChanged
        }

        if needsLayoutInvalidation {
            cancelAllPrefetch()
            collectionView.collectionViewLayout.invalidateLayout()
        }
        if resetChanged {
            invalidateScrolloverGeometry()
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
    }

    private func renderedItem(for id: Int64) -> IOSUIKitArticleTimelineItem? {
        guard let item = itemsByID[id] else { return nil }
        let presentation = presentationByID[id] ?? presentationBridge?.articleState(for: id, fallback: item.article) ?? .init(isRead: item.article.isRead, isStarred: item.article.isStarred, revision: 0)
        return .init(article: item.article, content: item.content, isRead: presentation.isRead, isStarred: presentation.isStarred, feedIconImage: feedIconPresentationBridge?.feedIcon(for: item.article.feedId, variant: iconVariant))
    }

    private func configure(_ cell: IOSUIKitArticleCell, item: IOSUIKitArticleTimelineItem) {
        let metrics = IOSUIKitArticleCell.Metrics(mode: mode, containerWidth: collectionView.bounds.width)
        cell.heightCache = articleHeightCache
        cell.configure(
            item: item,
            mode: mode,
            previewLines: previewLines,
            metrics: metrics,
            displayScale: view.traitCollection.displayScale
        )
        onRequestFeedIcon?(item.content.article.feedId, iconVariant)
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
              let cell = collectionView.cellForItem(at: indexPath) as? IOSUIKitArticleCell else { return }
        cell.updateStatus(isRead: delta.state.isRead, isStarred: delta.state.isStarred)
    }

    func applyFeedIconPresentation(_ delta: IOSUIKitFeedIconPresentationDelta) {
        guard delta.key.variant == iconVariant else { return }
        feedIconPresentationApplicationCount &+= 1
        for case let cell as IOSUIKitArticleCell in collectionView.visibleCells {
            guard let id = cell.representedArticleID,
                  let item = itemsByID[id], item.article.feedId == delta.key.feedID else { continue }
            cell.updateFeedIcon(image: delta.image, title: item.content.article.feedTitle)
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

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer { collectionView.deselectItem(at: indexPath, animated: true) }
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return }
        onArticleTap?(item.article)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !orderedIDs.isEmpty, indexPath.item >= max(0, orderedIDs.count - 5) else { return }
        onApproachingEnd?()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
        scrolloverGeometryTracker.setPhase(phase)
        onScrolloverPhase?(phase)
    }

    private func invalidateScrolloverGeometry() {
        scrolloverLayoutGeneration &+= 1
        scrolloverGeometryTracker.invalidateGeometry()
    }

    private func sampleScrolloverGeometry() {
        guard markReadOnScrolloverEnabled, collectionView.bounds.height > 0 else { return }

        let effectiveTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let effectiveBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        let viewportHeight = max(1, effectiveBottom - effectiveTop)
        let sensingRect = CGRect(
            x: collectionView.bounds.minX,
            y: max(0, effectiveTop - viewportHeight),
            width: collectionView.bounds.width,
            height: viewportHeight * 3
        )
        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: sensingRect) ?? []
        var rowFrames: [Int64: CGRect] = [:]
        rowFrames.reserveCapacity(attributes.count)
        for attribute in attributes where attribute.representedElementCategory == .cell {
            guard let id = dataSource.itemIdentifier(for: attribute.indexPath) else { continue }
            rowFrames[id] = attribute.frame
        }

        let sample = IOSUIKitScrolloverGeometrySample(
            contentOffsetY: collectionView.contentOffset.y,
            effectiveTop: effectiveTop,
            effectiveBottom: effectiveBottom,
            contentHeight: collectionView.contentSize.height,
            rowFrames: rowFrames,
            layoutGeneration: scrolloverLayoutGeneration
        )
        let result = scrolloverGeometryTracker.receive(sample, enabled: true)
        if let direction = result.direction { onScrolloverDirection?(direction) }
        if !result.batch.articleIDs.isEmpty { onScrolloverBatch?(result.batch) }
    }

    func collectionView(_ collectionView: UICollectionView, leadingSwipeActionsConfigurationForItemAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return nil }
        let newValue = !item.isRead
        let action = UIContextualAction(style: .normal, title: newValue ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")) { [weak self] _, _, completion in
            self?.setRead(id: id, value: newValue)
            completion(true)
        }
        action.image = UIImage(systemName: newValue ? "envelope.open" : "envelope")
        action.backgroundColor = .tintColor
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func collectionView(_ collectionView: UICollectionView, trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = renderedItem(for: id) else { return nil }
        let newValue = !item.isStarred
        let action = UIContextualAction(style: .normal, title: newValue ? String(localized: "Star") : String(localized: "Unstar")) { [weak self] _, _, completion in
            self?.setStarred(id: id, value: newValue)
            completion(true)
        }
        action.image = UIImage(systemName: newValue ? "star" : "star.slash")
        action.backgroundColor = .systemOrange
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
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

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard mode.showsArticleImage else { return }
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), prefetchTasks[id] == nil,
                  let item = renderedItem(for: id), let request = imageRequest(for: item)
            else { continue }
            prefetchTasks[id] = Task { [weak self] in
                _ = try? await ArticleImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                self?.prefetchTasks[id] = nil
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { continue }
            prefetchTasks.removeValue(forKey: id)?.cancel()
        }
    }

    private func imageRequest(for item: IOSUIKitArticleTimelineItem) -> ArticleImageRequest? {
        guard mode.showsArticleImage, let url = item.content.imageURL else { return nil }
        let metrics = IOSUIKitArticleCell.Metrics(mode: mode, containerWidth: collectionView.bounds.width)
        let targetSize = metrics.imageSize(hasImage: true)
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        return ArticleImageRequest(url: url, targetSize: targetSize, displayScale: view.traitCollection.displayScale)
    }

    private func cancelAllPrefetch() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll(keepingCapacity: true)
    }

    deinit {
        for task in prefetchTasks.values { task.cancel() }
    }
}

enum IOSUIKitArticleCellLayoutVariant: Hashable {
    case compact
    case visualTextOnly
    case visualPortrait
    case visualLandscape
}

struct IOSUIKitArticleCellSizingContentKey: Hashable {
    let articleID: Int64
    let title: String
    let feedTitle: String
    let publishedDate: String
    let preview: String
    let imageURL: String?
    let hasComments: Bool

    init(item: IOSUIKitArticleTimelineItem) {
        articleID = item.article.id
        title = item.content.article.title
        feedTitle = item.content.article.feedTitle
        publishedDate = item.content.publishedDate
        preview = item.content.article.preview
        imageURL = item.content.imageURL?.absoluteString
        hasComments = item.content.hasComments
    }
}

struct IOSUIKitArticleCellMeasurementKey: Hashable {
    let content: IOSUIKitArticleCellSizingContentKey
    let availableWidthPixels: Int
    let displayScaleHundredths: Int
    let variant: IOSUIKitArticleCellLayoutVariant
    let previewLineCount: Int
    let contentSizeCategory: String
    let localeIdentifier: String
    let isRightToLeft: Bool
}

final class IOSUIKitArticleCellHeightCache {
    let capacity: Int
    private var values: [IOSUIKitArticleCellMeasurementKey: CGFloat] = [:]
    private var slots: [IOSUIKitArticleCellMeasurementKey] = []
    private var nextEvictionIndex = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
        slots.reserveCapacity(self.capacity)
    }

    var count: Int { values.count }

    func height(for key: IOSUIKitArticleCellMeasurementKey) -> CGFloat? {
        values[key]
    }

    func insert(_ height: CGFloat, for key: IOSUIKitArticleCellMeasurementKey) {
        if values.updateValue(height, forKey: key) != nil { return }
        if slots.count < capacity {
            slots.append(key)
            return
        }
        let evicted = slots[nextEvictionIndex]
        values.removeValue(forKey: evicted)
        slots[nextEvictionIndex] = key
        nextEvictionIndex = (nextEvictionIndex + 1) % capacity
    }

    func removeAll() {
        values.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        nextEvictionIndex = 0
    }
}

@MainActor
final class IOSUIKitArticleCell: UICollectionViewCell {
    static let reuseIdentifier = "IOSUIKitArticleCell"

    struct Metrics {
        let mode: ArticlePresentationMode
        let containerWidth: CGFloat
        let horizontalInset: CGFloat
        let outerVerticalPadding: CGFloat
        let availableWidth: CGFloat
        let isLandscapeVisual: Bool

        init(mode: ArticlePresentationMode, containerWidth: CGFloat) {
            self.mode = mode
            self.containerWidth = containerWidth
            switch mode {
            case .compact:
                horizontalInset = containerWidth > 700 ? 28 : 10
            case .visual:
                horizontalInset = containerWidth > 700 ? 28 : 16
            }
            availableWidth = max(0, containerWidth - horizontalInset * 2)
            isLandscapeVisual = ArticlePresentationLayout.usesLandscapeVisual(mode: mode, availableWidth: availableWidth)
            switch mode {
            case .compact:
                outerVerticalPadding = 11
            case .visual:
                outerVerticalPadding = isLandscapeVisual ? 13 : 15
            }
        }

        func imageSize(hasImage: Bool) -> CGSize {
            guard hasImage, mode.showsArticleImage else { return .zero }
            if isLandscapeVisual {
                let width = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
                return CGSize(width: width, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: width))
            }
            let width = ArticlePresentationLayout.visualPortraitContentWidth(availableWidth)
            return CGSize(width: width, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: width))
        }

        func layoutVariant(hasImage: Bool) -> IOSUIKitArticleCellLayoutVariant {
            switch mode {
            case .compact:
                return .compact
            case .visual:
                guard hasImage else { return .visualTextOnly }
                return isLandscapeVisual ? .visualLandscape : .visualPortrait
            }
        }
    }

    private let textStack = UIStackView()
    private let titleRow = UIStackView()
    private let titleLabel = UILabel()
    private let starImageView = UIImageView(image: UIImage(systemName: "star.fill"))
    private let metadataStack = UIStackView()
    private let metadataPrimaryStack = UIStackView()
    private let unreadIndicator = UIView()
    private let feedIconContainer = UIView()
    private let feedIconImageView = UIImageView()
    private let feedIconFallbackLabel = UILabel()
    private let feedTitleLabel = UILabel()
    private let metadataBulletLabel = UILabel()
    private let dateLabel = UILabel()
    private let commentsImageView = UIImageView(image: UIImage(systemName: "bubble.left"))
    private let previewLabel = UILabel()
    private let articleImageView = UIImageView()
    private let imagePlaceholder = UIImageView(image: UIImage(systemName: "photo"))

    private var textOnlyConstraints: [NSLayoutConstraint] = []
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var activeLayoutConstraints: [NSLayoutConstraint] = []
    private var portraitImageAspectConstraint: NSLayoutConstraint!
    private var landscapeImageWidthConstraint: NSLayoutConstraint!
    private var landscapeImageHeightConstraint: NSLayoutConstraint!
    private var currentLayoutVariant: IOSUIKitArticleCellLayoutVariant?
    private var imageTask: Task<Void, Never>?
    private var representedImageRequest: ArticleImageRequest?
    private var sizingContentKey: IOSUIKitArticleCellSizingContentKey?
    private var sizingMode: ArticlePresentationMode = .visual
    private var sizingPreviewLines: ArticlePreviewLines = .standard
    private var sizingDisplayScale: CGFloat = 2
    private var currentTitle = ""
    private var currentFeedTitle = ""
    private var currentPublishedDate = ""
    private var currentIsRead = false
    private var currentIsStarred = false

    weak var heightCache: IOSUIKitArticleCellHeightCache?
    private(set) var representedArticleID: Int64?
    private(set) var layoutVariantRevision: UInt64 = 0
    private(set) var measurementSolveCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.preservesSuperviewLayoutMargins = false

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 7
        textStack.alignment = .fill
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        starImageView.tintColor = .systemYellow
        starImageView.alpha = 0
        starImageView.isAccessibilityElement = false
        starImageView.setContentHuggingPriority(.required, for: .horizontal)
        starImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(starImageView)

        metadataStack.axis = .horizontal
        metadataStack.spacing = 5
        metadataStack.alignment = .center
        metadataPrimaryStack.axis = .horizontal
        metadataPrimaryStack.spacing = 6
        metadataPrimaryStack.alignment = .center

        unreadIndicator.translatesAutoresizingMaskIntoConstraints = false
        unreadIndicator.backgroundColor = .tintColor
        unreadIndicator.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            unreadIndicator.widthAnchor.constraint(equalToConstant: 6),
            unreadIndicator.heightAnchor.constraint(equalToConstant: 6),
        ])

        feedIconContainer.translatesAutoresizingMaskIntoConstraints = false
        feedIconContainer.clipsToBounds = true
        feedIconContainer.layer.cornerRadius = 11
        NSLayoutConstraint.activate([
            feedIconContainer.widthAnchor.constraint(equalToConstant: 22),
            feedIconContainer.heightAnchor.constraint(equalToConstant: 22),
        ])
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
        feedTitleLabel.textColor = .secondaryLabel
        feedTitleLabel.lineBreakMode = .byTruncatingTail
        feedTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commentsImageView.tintColor = .secondaryLabel
        commentsImageView.setContentHuggingPriority(.required, for: .horizontal)
        metadataPrimaryStack.addArrangedSubview(unreadIndicator)
        metadataPrimaryStack.addArrangedSubview(feedIconContainer)
        metadataPrimaryStack.addArrangedSubview(feedTitleLabel)
        metadataPrimaryStack.addArrangedSubview(commentsImageView)

        metadataBulletLabel.text = "•"
        metadataBulletLabel.textColor = .secondaryLabel
        metadataBulletLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        metadataBulletLabel.adjustsFontForContentSizeCategory = true
        dateLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        metadataStack.addArrangedSubview(metadataPrimaryStack)
        metadataStack.addArrangedSubview(metadataBulletLabel)
        metadataStack.addArrangedSubview(dateLabel)

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 3

        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(metadataStack)
        textStack.addArrangedSubview(previewLabel)

        articleImageView.translatesAutoresizingMaskIntoConstraints = false
        articleImageView.contentMode = .scaleAspectFill
        articleImageView.clipsToBounds = true
        articleImageView.layer.cornerRadius = 12
        articleImageView.backgroundColor = .tertiarySystemFill
        articleImageView.isHidden = true
        articleImageView.setContentHuggingPriority(.required, for: .vertical)
        articleImageView.setContentCompressionResistancePriority(.required, for: .vertical)
        articleImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imagePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        imagePlaceholder.tintColor = .secondaryLabel
        imagePlaceholder.contentMode = .center
        articleImageView.addSubview(imagePlaceholder)
        NSLayoutConstraint.activate([
            imagePlaceholder.centerXAnchor.constraint(equalTo: articleImageView.centerXAnchor),
            imagePlaceholder.centerYAnchor.constraint(equalTo: articleImageView.centerYAnchor),
        ])

        contentView.addSubview(textStack)
        contentView.addSubview(articleImageView)
        preparePermanentLayoutConstraints()

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
        landscapeImageWidthConstraint = articleImageView.widthAnchor.constraint(equalToConstant: 1)
        landscapeImageHeightConstraint = articleImageView.heightAnchor.constraint(equalToConstant: 1)

        textOnlyConstraints = [
            textStack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: margins.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ]
        portraitConstraints = [
            articleImageView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            articleImageView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            articleImageView.topAnchor.constraint(equalTo: margins.topAnchor),
            portraitImageAspectConstraint,
            textStack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: articleImageView.bottomAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ]
        landscapeConstraints = [
            articleImageView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            articleImageView.topAnchor.constraint(equalTo: margins.topAnchor),
            landscapeImageWidthConstraint,
            landscapeImageHeightConstraint,
            articleImageView.bottomAnchor.constraint(lessThanOrEqualTo: margins.bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: articleImageView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: margins.topAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: margins.bottomAnchor),
        ]
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        guard let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else { return layoutAttributes }
        guard let sizingContentKey else {
            return measuredAttributes(attributes, cacheKey: nil)
        }

        let metrics = Metrics(mode: sizingMode, containerWidth: layoutAttributes.size.width)
        let hasImage = sizingContentKey.imageURL != nil && sizingMode.showsArticleImage
        let variant = metrics.layoutVariant(hasImage: hasImage)
        applyLayout(metrics: metrics, variant: variant)
        let key = measurementKey(
            content: sizingContentKey,
            metrics: metrics,
            variant: variant,
            previewLines: sizingPreviewLines,
            displayScale: sizingDisplayScale
        )
        if let cachedHeight = heightCache?.height(for: key) {
            attributes.size.height = cachedHeight
            return attributes
        }
        return measuredAttributes(attributes, cacheKey: key)
    }

    private func measuredAttributes(
        _ attributes: UICollectionViewLayoutAttributes,
        cacheKey: IOSUIKitArticleCellMeasurementKey?
    ) -> UICollectionViewLayoutAttributes {
        let targetSize = CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height)
        let fittedSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = ceil(fittedSize.height)
        attributes.size.height = height
        measurementSolveCount += 1
        if let cacheKey { heightCache?.insert(height, for: cacheKey) }
        return attributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedImageRequest = nil
        representedArticleID = nil
        sizingContentKey = nil
        articleImageView.image = nil
        imagePlaceholder.isHidden = false
    }

    func configure(
        item: IOSUIKitArticleTimelineItem,
        mode: ArticlePresentationMode,
        previewLines: ArticlePreviewLines,
        metrics: Metrics,
        displayScale: CGFloat
    ) {
        representedArticleID = item.article.id
        sizingContentKey = IOSUIKitArticleCellSizingContentKey(item: item)
        sizingMode = mode
        sizingPreviewLines = previewLines
        sizingDisplayScale = displayScale
        currentTitle = item.content.article.title
        currentFeedTitle = item.content.article.feedTitle
        currentPublishedDate = item.content.publishedDate
        titleLabel.text = currentTitle
        feedTitleLabel.text = currentFeedTitle
        dateLabel.text = currentPublishedDate
        previewLabel.text = item.content.article.preview
        previewLabel.isHidden = item.content.article.preview.isEmpty
        previewLabel.numberOfLines = previewLines.rawValue
        commentsImageView.isHidden = !item.content.hasComments

        let hasImage = mode.showsArticleImage && item.content.imageURL != nil
        let imageSize = metrics.imageSize(hasImage: hasImage)
        applyLayout(metrics: metrics, variant: metrics.layoutVariant(hasImage: hasImage))

        updateFeedIcon(image: item.feedIconImage, title: item.content.article.feedTitle)
        updateStatus(isRead: item.isRead, isStarred: item.isStarred)
        configureArticleImage(url: item.content.imageURL, targetSize: imageSize, displayScale: displayScale)
        contentView.setNeedsLayout()
    }

    private func applyLayout(metrics: Metrics, variant: IOSUIKitArticleCellLayoutVariant) {
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: metrics.outerVerticalPadding,
            leading: metrics.horizontalInset,
            bottom: metrics.outerVerticalPadding,
            trailing: metrics.horizontalInset
        )

        let useColumnMetadata = metrics.availableWidth < 370
        metadataStack.axis = useColumnMetadata ? .vertical : .horizontal
        metadataStack.alignment = useColumnMetadata ? .leading : .center
        metadataStack.spacing = useColumnMetadata ? 3 : 5
        metadataBulletLabel.isHidden = useColumnMetadata

        if variant == .visualLandscape {
            let imageSize = metrics.imageSize(hasImage: true)
            landscapeImageWidthConstraint.constant = imageSize.width
            landscapeImageHeightConstraint.constant = imageSize.height
        }

        guard currentLayoutVariant != variant else {
            articleImageView.isHidden = variant == .compact || variant == .visualTextOnly
            return
        }

        NSLayoutConstraint.deactivate(activeLayoutConstraints)
        switch variant {
        case .compact, .visualTextOnly:
            activeLayoutConstraints = textOnlyConstraints
        case .visualPortrait:
            activeLayoutConstraints = portraitConstraints
        case .visualLandscape:
            activeLayoutConstraints = landscapeConstraints
        }
        NSLayoutConstraint.activate(activeLayoutConstraints)
        currentLayoutVariant = variant
        layoutVariantRevision &+= 1
        articleImageView.isHidden = variant == .compact || variant == .visualTextOnly
    }

    private func measurementKey(
        content: IOSUIKitArticleCellSizingContentKey,
        metrics: Metrics,
        variant: IOSUIKitArticleCellLayoutVariant,
        previewLines: ArticlePreviewLines,
        displayScale: CGFloat
    ) -> IOSUIKitArticleCellMeasurementKey {
        IOSUIKitArticleCellMeasurementKey(
            content: content,
            availableWidthPixels: Int((metrics.availableWidth * displayScale).rounded()),
            displayScaleHundredths: Int((displayScale * 100).rounded()),
            variant: variant,
            previewLineCount: previewLines.rawValue,
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            localeIdentifier: Locale.current.identifier,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
    }

    func updateStatus(isRead: Bool, isStarred: Bool) {
        currentIsRead = isRead
        currentIsStarred = isStarred
        titleLabel.textColor = isRead ? .secondaryLabel : .label
        unreadIndicator.alpha = ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: isRead)
        // Reserve the star's arranged-subview slot so status changes cannot change title width or row height.
        starImageView.alpha = isStarred ? 1 : 0
        updateAccessibility()
    }

    func updateFeedIcon(image: UIImage?, title: String) {
        if let image {
            feedIconImageView.image = image
            feedIconImageView.isHidden = false
            feedIconFallbackLabel.isHidden = true
            feedIconContainer.backgroundColor = .clear
        } else {
            feedIconImageView.image = nil
            feedIconImageView.isHidden = true
            feedIconFallbackLabel.isHidden = false
            feedIconFallbackLabel.text = title.prefix(1).uppercased()
            feedIconContainer.backgroundColor = .tintColor
        }
    }

    private func configureArticleImage(url: URL?, targetSize: CGSize, displayScale: CGFloat) {
        imageTask?.cancel()
        imageTask = nil
        representedImageRequest = nil
        guard let url, targetSize.width > 0, targetSize.height > 0 else {
            articleImageView.image = nil
            imagePlaceholder.isHidden = false
            return
        }

        let request = ArticleImageRequest(url: url, targetSize: targetSize, displayScale: displayScale)
        representedImageRequest = request
        if let cachedImage = ArticleImagePipeline.shared.cachedImage(for: request) {
            articleImageView.image = UIImage(cgImage: cachedImage, scale: displayScale, orientation: .up)
            imagePlaceholder.isHidden = true
            return
        }

        articleImageView.image = nil
        imagePlaceholder.isHidden = false
        imageTask = Task { @MainActor [weak self] in
            do {
                let loadedImage = try await ArticleImagePipeline.shared.image(for: request)
                guard !Task.isCancelled, let self, self.representedImageRequest == request else { return }
                self.articleImageView.image = UIImage(cgImage: loadedImage, scale: displayScale, orientation: .up)
                self.imagePlaceholder.isHidden = true
            } catch {
                guard let self, self.representedImageRequest == request else { return }
                self.articleImageView.image = nil
                self.imagePlaceholder.isHidden = false
            }
        }
    }

    private func updateAccessibility() {
        accessibilityLabel = "\(currentTitle), \(currentFeedTitle), \(currentPublishedDate), \(currentIsRead ? String(localized: "Read") : String(localized: "Unread"))\(currentIsStarred ? String(localized: ", starred") : "")"
        accessibilityValue = currentIsRead
            ? (currentIsStarred ? String(localized: "Read, starred") : String(localized: "Read"))
            : (currentIsStarred ? String(localized: "Unread, starred") : String(localized: "Unread"))
    }
}

struct ArticleListView: View {
    @Environment(\.colorScheme) private var colorScheme
    var store: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void

    var body: some View {
        let emptyState = IOSArticleListEmptyState.resolve(
            isSyncing: store.isSyncing,
            isLoading: store.isLoading,
            errorMessage: store.errorMessage,
            hasArticles: !store.articles.isEmpty
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
                    iconVariant: iconVariant,
                    scrollResetRevision: store.scrollResetRevision,
                    markReadOnScrolloverEnabled: store.markReadOnScrolloverEnabled,
                    showsRefreshControl: true,
                    onArticleTap: onArticleTap,
                    onArticleAction: onArticleAction,
                    onSetRead: { article, read in store.setRead(article, read: read) },
                    onSetStarred: { article, starred in store.setStarred(article, starred: starred) },
                    onRequestFeedIcon: { feedID, variant in store.requestFeedIcon(feedID, variant: variant) },
                    onRefresh: { await store.syncManually() },
                    onApproachingEnd: nil,
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
        ArticleRowStateInteractions(
            content: content,
            fallbackRead: fallbackRead,
            fallbackStarred: fallbackStarred,
            rowState: rowState,
            mode: mode,
            previewLines: previewLines,
            availableWidth: availableWidth,
            feedIcon: feedIcon,
            onRequestFeedIcon: onRequestFeedIcon,
            onTap: onTap,
            onAction: onAction,
            onSetRead: onSetRead,
            onSetStarred: onSetStarred
        )
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
        ArticleRowSurface(
            content: content,
            fallbackRead: fallbackRead,
            fallbackStarred: fallbackStarred,
            rowState: rowState,
            mode: mode,
            previewLines: previewLines,
            availableWidth: availableWidth,
            feedIcon: feedIcon,
            onRequestFeedIcon: onRequestFeedIcon,
            onTap: onTap
        )
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
        ArticleRowContentBody(
            content: content,
            fallbackRead: fallbackRead,
            fallbackStarred: fallbackStarred,
            rowState: rowState,
            mode: mode,
            previewLines: previewLines,
            availableWidth: availableWidth,
            feedIcon: feedIcon,
            onRequestFeedIcon: onRequestFeedIcon
        )
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
