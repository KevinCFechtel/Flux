import SwiftUI
import UIKit

/// iOS 18 visibility reports need not include every intermediate row. The ordered
/// snapshot fills those gaps without using row geometry or exposure timing.
struct IOSScrolloverOrderTracker {
    private var orderedIDs: [Int64] = []
    private var positions: [Int64: Int] = [:]
    private var previousLeadingArticleID: Int64?
    private var emittedIDs = Set<Int64>()
    private var isUserScrolling = false

    mutating func updateSnapshot(_ ids: [Int64]) {
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        // A changed ordering can be a sync/filter/layout snapshot, not a scroll.
        previousLeadingArticleID = nil
        emittedIDs.removeAll()
        isUserScrolling = false
    }

    mutating func setUserScrolling(_ value: Bool) { isUserScrolling = value }

    mutating func reset() {
        previousLeadingArticleID = nil
        emittedIDs.removeAll()
        isUserScrolling = false
    }

    mutating func releaseEmittedIDs() { emittedIDs.removeAll() }

    mutating func receiveVisibleIDs(_ visibleIDs: [Int64], enabled: Bool) -> [Int64] {
        guard let leadingID = visibleIDs.min(by: { positions[$0, default: .max] < positions[$1, default: .max] }),
              let leadingPosition = positions[leadingID] else { return [] }
        defer { previousLeadingArticleID = leadingID }

        guard isUserScrolling, enabled, let previousLeadingArticleID,
              let previousPosition = positions[previousLeadingArticleID] else { return [] }
        guard leadingPosition > previousPosition else { return [] }

        let candidates = orderedIDs[previousPosition..<leadingPosition].filter { emittedIDs.insert($0).inserted }
        return candidates
    }
}

enum IOSArticleMutation: Equatable {
    case read(Bool)
    case starred(Bool)
}

enum IOSSwipeDirection: Equatable {
    case right
    case left

    var sign: CGFloat { self == .right ? 1 : -1 }
}

enum IOSArticleSwipeAction: Hashable {
    case read
    case unread
    case star
    case unstar

    var mutation: IOSArticleMutation {
        switch self {
        case .read: .read(true)
        case .unread: .read(false)
        case .star: .starred(true)
        case .unstar: .starred(false)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .read: "Mark as Read"
        case .unread: "Mark as Unread"
        case .star: "Star"
        case .unstar: "Unstar"
        }
    }

    var systemImage: String {
        switch self {
        case .read: "envelope.open"
        case .unread: "envelope"
        case .star: "star"
        case .unstar: "star.slash"
        }
    }

    var tint: Color {
        switch self {
        case .read, .unread: .accentColor
        case .star, .unstar: .orange
        }
    }
}

struct IOSArticleSwipeSideConfiguration: Equatable {
    // Visual order is inner-to-outer. The outer action is the Full Swipe action.
    let actions: [IOSArticleSwipeAction]

    var fullSwipeAction: IOSArticleSwipeAction? { actions.last }

}

struct IOSArticleSwipeConfiguration: Equatable {
    let leading: IOSArticleSwipeSideConfiguration
    let trailing: IOSArticleSwipeSideConfiguration

    static func `default`(for article: ArticleSummary) -> Self {
        Self(
            leading: IOSArticleSwipeSideConfiguration(actions: [article.isRead ? .unread : .read]),
            trailing: IOSArticleSwipeSideConfiguration(actions: [article.isStarred ? .unstar : .star])
        )
    }
}

enum IOSArticleSwipeEndState: Equatable {
    case closed
    case revealed(IOSSwipeDirection)
    case fullSwipe(IOSArticleSwipeAction)
}

enum IOSArticleSwipeState: Equatable {
    case closed
    case dragging(IOSSwipeDirection)
    case fullSwipeArmed(IOSSwipeDirection)
}

enum IOSArticleSwipeInteraction {
    static func fullSwipeDistance(actionWidth: CGFloat) -> CGFloat {
        actionWidth * 2.5
    }

    static func shouldTriggerArmedFeedback(from oldState: IOSArticleSwipeState, to newState: IOSArticleSwipeState) -> Bool {
        guard oldState != newState else { return false }
        if case .fullSwipeArmed = newState { return true }
        return false
    }

    static func effectiveOffset(startOffset: CGFloat, rawTranslation: CGFloat) -> CGFloat {
        startOffset + rawTranslation
    }

    static func state(
        effectiveOffset: CGFloat,
        configuration: IOSArticleSwipeConfiguration,
        fullSwipeDistance: CGFloat
    ) -> IOSArticleSwipeState {
        guard effectiveOffset != 0 else { return .closed }
        let direction: IOSSwipeDirection = effectiveOffset > 0 ? .right : .left
        let side = side(for: direction, configuration: configuration)
        guard !side.actions.isEmpty else { return .closed }
        return abs(effectiveOffset) >= fullSwipeDistance ? .fullSwipeArmed(direction) : .dragging(direction)
    }

    static func visibleOffset(
        effectiveOffset: CGFloat,
        configuration: IOSArticleSwipeConfiguration,
        swipeActionWidth: CGFloat
    ) -> CGFloat {
        guard effectiveOffset != 0 else { return 0 }
        let direction: IOSSwipeDirection = effectiveOffset > 0 ? .right : .left
        let side = side(for: direction, configuration: configuration)
        guard !side.actions.isEmpty else { return 0 }
        let revealDistance = swipeActionWidth * CGFloat(side.actions.count)
        return min(revealDistance, max(-revealDistance, effectiveOffset))
    }

    static func endState(
        effectiveOffset: CGFloat,
        configuration: IOSArticleSwipeConfiguration,
        revealThreshold: CGFloat,
        fullSwipeDistance: CGFloat
    ) -> IOSArticleSwipeEndState {
        guard effectiveOffset != 0 else { return .closed }
        let direction: IOSSwipeDirection = effectiveOffset > 0 ? .right : .left
        let side = side(for: direction, configuration: configuration)
        guard !side.actions.isEmpty else { return .closed }
        if state(effectiveOffset: effectiveOffset, configuration: configuration, fullSwipeDistance: fullSwipeDistance) == .fullSwipeArmed(direction), let action = side.fullSwipeAction {
            return .fullSwipe(action)
        }
        return abs(effectiveOffset) >= revealThreshold ? .revealed(direction) : .closed
    }

    private static func side(for direction: IOSSwipeDirection, configuration: IOSArticleSwipeConfiguration) -> IOSArticleSwipeSideConfiguration {
        direction == .right ? configuration.leading : configuration.trailing
    }
}

@available(iOS 18.0, *)
private struct IOSHorizontalArticleSwipeGesture: UIGestureRecognizerRepresentable {
    @Binding var offset: CGFloat
    let canBegin: (IOSSwipeDirection, CGFloat) -> Bool
    let state: (CGFloat) -> IOSArticleSwipeState
    let visibleOffset: (CGFloat) -> CGFloat
    let onStateChanged: (IOSArticleSwipeState) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: Self.CoordinateSpaceConverter) -> Coordinator { Coordinator(self) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.parent = self
        recognizer.delegate = context.coordinator
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handlePan(recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSHorizontalArticleSwipeGesture
        private var startOffset: CGFloat = 0

        init(_ parent: IOSHorizontalArticleSwipeGesture) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) >= 24, abs(velocity.x) > abs(velocity.y) * 1.25 else { return false }
            return parent.canBegin(velocity.x >= 0 ? .right : .left, parent.offset)
        }

        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                startOffset = parent.offset
                parent.onStateChanged(.closed)
            case .changed:
                let effectiveOffset = IOSArticleSwipeInteraction.effectiveOffset(startOffset: startOffset, rawTranslation: translation.x)
                parent.onStateChanged(parent.state(effectiveOffset))
                parent.offset = parent.visibleOffset(effectiveOffset)
            case .ended:
                parent.onEnded(IOSArticleSwipeInteraction.effectiveOffset(startOffset: startOffset, rawTranslation: translation.x))
                reset()
            case .cancelled, .failed:
                parent.offset = startOffset
                parent.onStateChanged(.closed)
                reset()
            default:
                break
            }
        }

        private func reset() { startOffset = 0 }
    }
}

private struct IOSArticleSwipeAccessibilityModifier: ViewModifier {
    let actions: [IOSArticleSwipeAction]
    let perform: (IOSArticleSwipeAction) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        switch actions.count {
        case 0:
            content
        case 1:
            content.accessibilityAction(named: actions[0].accessibilityLabel) { perform(actions[0]) }
        case 2:
            content
                .accessibilityAction(named: actions[0].accessibilityLabel) { perform(actions[0]) }
                .accessibilityAction(named: actions[1].accessibilityLabel) { perform(actions[1]) }
        case 3:
            content
                .accessibilityAction(named: actions[0].accessibilityLabel) { perform(actions[0]) }
                .accessibilityAction(named: actions[1].accessibilityLabel) { perform(actions[1]) }
                .accessibilityAction(named: actions[2].accessibilityLabel) { perform(actions[2]) }
        default:
            content
                .accessibilityAction(named: actions[0].accessibilityLabel) { perform(actions[0]) }
                .accessibilityAction(named: actions[1].accessibilityLabel) { perform(actions[1]) }
                .accessibilityAction(named: actions[2].accessibilityLabel) { perform(actions[2]) }
                .accessibilityAction(named: actions[3].accessibilityLabel) { perform(actions[3]) }
        }
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

struct ArticleListView: View {
    @Environment(\.colorScheme) private var colorScheme
    var store: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    @State private var scrolloverTracker = IOSScrolloverOrderTracker()
    // 15% admits a target that is only barely visible, so tall cards still give
    // the ordered tracker a reliable leading target. It is not a read threshold.
    private let scrolloverVisibilityThreshold: CGFloat = 0.15

    var body: some View {
        Group {
            if store.isLoading && store.articles.isEmpty {
                ProgressView("Loading articles")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.articles.isEmpty {
                ContentUnavailableView("Unable to Load Articles", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if store.articles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "newspaper")
            } else {
                    GeometryReader { proxy in
                        let horizontalInset: CGFloat = proxy.size.width > 700 ? 28 : 16
                        let articleSpacing: CGFloat =
                          ArticlePresentationLayout.usesLandscapeVisual(
                            mode: store.articlePresentationMode,
                            availableWidth: proxy.size.width - horizontalInset * 2) ? 20 : 26
                               ScrollView {
                               LazyVStack(spacing: articleSpacing) {
                                 ForEach(store.articles, id: \.id) { article in
                                       let iconVariant = IOSFeedIconPresentation.variant(isDark: colorScheme == .dark)
                                       let feedIcon = store.feedIcons[IOSFeedIconKey(feedID: article.feedId, variant: iconVariant)]
                                       ArticlePresentationView(article: article, mode: store.articlePresentationMode, previewLines: store.articlePreviewLines, availableWidth: proxy.size.width - horizontalInset * 2, feedIconData: feedIcon, iconVariant: iconVariant, onRequestFeedIcon: { store.requestFeedIcon(article.feedId, variant: iconVariant) }, onTap: { onArticleTap(article) }, onAction: { onArticleAction(article, $0) }, onSetRead: { article, read in store.setRead(article, read: read) }, onSetStarred: { article, starred in store.setStarred(article, starred: starred) })
                                          .equatable()
                                 }
                              }
                              .scrollTargetLayout()
                              .padding(.horizontal, horizontalInset)
                              .padding(.vertical, 12)
                           }
                               .id(store.scrollResetRevision)
                               .refreshable { await store.syncManually() }
                            .scrollIndicators(.hidden)
                            .onAppear {
                                scrolloverTracker.updateSnapshot(store.articles.map(\.id))
                            }
                             .onScrollTargetVisibilityChange(idType: Int64.self, threshold: scrolloverVisibilityThreshold) { visibleIDs in
                                 let candidates = scrolloverTracker.receiveVisibleIDs(visibleIDs, enabled: store.markReadOnScrolloverEnabled)
                                 if !candidates.isEmpty { store.flushScrollover(candidates) }
                            }
                            .onScrollPhaseChange { _, phase in
                                switch phase {
                                 case .interacting:
                                   scrolloverTracker.setUserScrolling(true)
                                   store.markMeaningfulInteraction()
                                 case .idle:
                                   scrolloverTracker.setUserScrolling(false)
                                 default:
                                   break
                                }
                            }
                             .onChange(of: store.snapshotRevision) { _, _ in
                                 scrolloverTracker.updateSnapshot(store.articles.map(\.id))
                             }
                              .onChange(of: store.scrolloverRearmRevision) { _, _ in
                                  scrolloverTracker.releaseEmittedIDs()
                              }
                   }
                 }
        }
        .background(.background)
        .overlay(alignment: .top) {
            if store.isLoading && !store.articles.isEmpty {
                ProgressView()
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
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
            Text("\(store.scrolloverUndoIDs.count) articles marked as read")
            Button("Undo") { store.undoScrollover() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}

struct ArticlePresentationView: View, Equatable {
    let article: ArticleSummary
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    let feedIconData: Data?
    let iconVariant: FeedIconVariant
    let onRequestFeedIcon: () -> Void
    let onTap: () -> Void
    let onAction: (IOSArticleContextAction) -> Void
    let onSetRead: (ArticleSummary, Bool) -> Void
    let onSetStarred: (ArticleSummary, Bool) -> Void
    @State private var horizontalOffset: CGFloat = 0
    @State private var swipeState: IOSArticleSwipeState = .closed

    private let swipeActionWidth: CGFloat = 76
    private let swipeRevealThreshold: CGFloat = 38

    // The list observes its snapshot, but Undo-only publications must not redraw
    // rows whose article and presentation inputs have not changed.
    static func == (lhs: ArticlePresentationView, rhs: ArticlePresentationView) -> Bool {
        lhs.article == rhs.article &&
            lhs.mode == rhs.mode &&
            lhs.previewLines == rhs.previewLines &&
            lhs.availableWidth == rhs.availableWidth &&
            lhs.feedIconData == rhs.feedIconData &&
            lhs.iconVariant == rhs.iconVariant
    }

    var body: some View {
        ZStack {
            swipeActionBackground
            Group {
                switch mode {
                case .visual: visual
                case .compact: compact
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture(perform: onTap)
            .frame(width: articleWidth, alignment: .leading)
            .background(.background)
            .offset(x: horizontalOffset)
            .gesture(
                IOSHorizontalArticleSwipeGesture(
                    offset: $horizontalOffset,
                    canBegin: canBeginSwipe,
                    state: swipeStateForOffset,
                    visibleOffset: visibleSwipeOffset,
                    onStateChanged: updateSwipeState,
                    onEnded: finishSwipe
                )
            )
        }
        .frame(width: articleWidth, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the article")
        .modifier(IOSArticleSwipeAccessibilityModifier(actions: swipeConfiguration.leading.actions + swipeConfiguration.trailing.actions, perform: performSwipeAction))
        .contextMenu {
            Button { onAction(.starred) } label: {
                Label(article.isStarred ? "Unstar" : "Star", systemImage: article.isStarred ? "star.slash" : "star")
            }
            Button { onAction(.read) } label: {
                Label(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? "envelope" : "envelope.open")
            }
            Divider()
            Button { onAction(.original) } label: { Label("Open Original", systemImage: "safari") }
            Button { onAction(.reader) } label: { Label("Open in Reader", systemImage: "doc.text") }
            Button { onAction(.miniflux) } label: { Label("Open in Miniflux", systemImage: "arrow.up.forward.app") }
            if IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) != nil {
                Button { onAction(.comments) } label: { Label("Open Comments", systemImage: "bubble.left") }
            }
            Button { onAction(.copyLink) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button { onAction(.share) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Divider()
            Button { onAction(.saveToService) } label: { Label("Save to Third-Party Service", systemImage: "tray.and.arrow.down") }
        }
    }

    private var swipeConfiguration: IOSArticleSwipeConfiguration {
        .default(for: article)
    }

    private var fullSwipeDistance: CGFloat {
        IOSArticleSwipeInteraction.fullSwipeDistance(actionWidth: swipeActionWidth)
    }

    private func swipeSide(for direction: IOSSwipeDirection) -> IOSArticleSwipeSideConfiguration {
        direction == .right ? swipeConfiguration.leading : swipeConfiguration.trailing
    }

    private func canBeginSwipe(direction: IOSSwipeDirection, offset: CGFloat) -> Bool {
        offset != 0 || !swipeSide(for: direction).actions.isEmpty
    }

    private func visibleSwipeOffset(_ effectiveOffset: CGFloat) -> CGFloat {
        IOSArticleSwipeInteraction.visibleOffset(
            effectiveOffset: effectiveOffset,
            configuration: swipeConfiguration,
            swipeActionWidth: fullSwipeDistance
        )
    }

    private func swipeStateForOffset(_ effectiveOffset: CGFloat) -> IOSArticleSwipeState {
        IOSArticleSwipeInteraction.state(
            effectiveOffset: effectiveOffset,
            configuration: swipeConfiguration,
            fullSwipeDistance: fullSwipeDistance
        )
    }

    private func updateSwipeState(_ newState: IOSArticleSwipeState) {
        if IOSArticleSwipeInteraction.shouldTriggerArmedFeedback(from: swipeState, to: newState) {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.prepare()
            feedback.impactOccurred()
        }
        swipeState = newState
    }

    private func finishSwipe(effectiveOffset: CGFloat) {
        switch IOSArticleSwipeInteraction.endState(
            effectiveOffset: effectiveOffset,
            configuration: swipeConfiguration,
            revealThreshold: swipeRevealThreshold,
            fullSwipeDistance: fullSwipeDistance
        ) {
        case .closed:
            horizontalOffset = 0
        case let .revealed(direction):
            horizontalOffset = direction.sign * swipeActionWidth * CGFloat(swipeSide(for: direction).actions.count)
        case let .fullSwipe(action):
            horizontalOffset = 0
            performSwipeAction(action)
        }
    }

    private var swipeActionBackground: some View {
        HStack(spacing: 0) {
            swipeActionButtons(swipeConfiguration.leading.actions, direction: .right)
            Spacer(minLength: 0)
            swipeActionButtons(Array(swipeConfiguration.trailing.actions.reversed()), direction: .left)
        }
    }

    @ViewBuilder
    private func swipeActionButtons(_ actions: [IOSArticleSwipeAction], direction: IOSSwipeDirection) -> some View {
        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
            let isOuterAction = isOuterAction(index: index, actionCount: actions.count, direction: direction)
            let buttonWidth = actionWidth(actionCount: actions.count, isOuterAction: isOuterAction)
            Button {
                horizontalOffset = 0
                performSwipeAction(action)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: action.systemImage)
                    Text(action.accessibilityLabel)
                        .font(.caption2)
                }
                .frame(minWidth: buttonWidth, maxWidth: buttonWidth, maxHeight: .infinity)
                .foregroundStyle(.white)
                .background(action.tint)
                .scaleEffect(isOuterAction && isSwipeArmed(direction) ? 1.12 : 1)
                .animation(.easeOut(duration: 0.12), value: isSwipeArmed(direction))
            }
            .accessibilityLabel(action.accessibilityLabel)
        }
    }

    private func isOuterAction(index: Int, actionCount: Int, direction: IOSSwipeDirection) -> Bool {
        if direction == .right { return index == actionCount - 1 }
        return index == 0
    }

    private func actionWidth(actionCount: Int, isOuterAction: Bool) -> CGFloat {
        guard isOuterAction else { return swipeActionWidth }
        let progress = max(swipeActionWidth, abs(horizontalOffset))
        let innerWidth = swipeActionWidth * CGFloat(max(0, actionCount - 1))
        return max(swipeActionWidth, progress - innerWidth)
    }

    private func isSwipeArmed(_ direction: IOSSwipeDirection) -> Bool {
        swipeState == .fullSwipeArmed(direction)
    }

    private func performSwipeAction(_ action: IOSArticleSwipeAction) {
        switch action.mutation {
        case let .read(value): onSetRead(article, value)
        case let .starred(value): onSetStarred(article, value)
        }
    }

    @ViewBuilder
    private var visual: some View {
        if ArticlePresentationLayout.usesLandscapeVisual(mode: mode, availableWidth: availableWidth) {
            landscapeVisual
        } else {
            portraitVisual
        }
    }

    private var portraitVisual: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = article.imageUrl.flatMap(URL.init(string:)) {
                ArticleImageView(
                    url: imageURL,
                    targetSize: CGSize(width: portraitContentWidth, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: portraitContentWidth))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            articleText
                .frame(width: portraitContentWidth, alignment: .leading)
        }
        .frame(width: portraitContentWidth, alignment: .leading)
    }

    private var landscapeVisual: some View {
        HStack(alignment: .top, spacing: 14) {
            let imageWidth = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
            if let imageURL = article.imageUrl.flatMap(URL.init(string:)) {
                ArticleImageView(
                    url: imageURL,
                    targetSize: CGSize(width: imageWidth, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: imageWidth))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            articleText
                .frame(width: hasImage ? ArticlePresentationLayout.landscapeTextWidth(availableWidth: availableWidth, imageWidth: imageWidth, interColumnSpacing: 14) : contentWidth, alignment: .leading)
        }
        .frame(width: contentWidth, alignment: .leading)
        //.padding(12)
        //.background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            articleText
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }

    private var articleWidth: CGFloat {
        ArticlePresentationLayout.boundedArticleWidth(availableWidth)
    }

    private var contentWidth: CGFloat {
        ArticlePresentationLayout.articleContentWidth(articleWidth)
    }

    private var portraitContentWidth: CGFloat {
        ArticlePresentationLayout.visualPortraitContentWidth(articleWidth)
    }

    private var hasImage: Bool {
        article.imageUrl.flatMap(URL.init(string:)) != nil
    }

    private var articleText: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if article.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Starred")
                }
            }
            ViewThatFits(in: .horizontal) {
                metadataRow
                metadataColumn
            }
            if !article.preview.isEmpty {
                Text(article.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLines.rawValue)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var date: String {
        ISO8601DateFormatter().date(from: article.publishedAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? article.publishedAt
    }

    private var accessibilityLabel: String {
        let state = article.isRead ? "Read" : "Unread"
        let star = article.isStarred ? ", starred" : ""
        return "\(article.title), \(article.feedTitle), \(date), \(state)\(star)"
    }

    private var accessibilityValue: String {
        article.isRead ? (article.isStarred ? "Read, starred" : "Read") : (article.isStarred ? "Unread, starred" : "Unread")
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            unreadIndicator
            FeedIconView(feedID: article.feedId, title: article.feedTitle, data: feedIconData, onRequest: onRequestFeedIcon)
            Text(article.feedTitle).font(.subheadline.weight(.medium))
            Text("•")
            Text(date)
            commentsIndicator
        }
        .foregroundStyle(.secondary)
        .font(.caption)
        .lineLimit(1)
    }

    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                unreadIndicator
                FeedIconView(feedID: article.feedId, title: article.feedTitle, data: feedIconData, onRequest: onRequestFeedIcon)
                Text(article.feedTitle).font(.subheadline.weight(.medium))
                commentsIndicator
            }
            Text(date)
        }
        .foregroundStyle(.secondary)
        .font(.caption)
    }

    @ViewBuilder
    private var commentsIndicator: some View {
        if IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) != nil {
            Image(systemName: "bubble.left")
                .accessibilityLabel("Comments available")
        }
    }

    @ViewBuilder
    private var unreadIndicator: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(ArticlePresentationLayout.internalUnreadIndicatorOpacity(isRead: article.isRead))
            .accessibilityHidden(true)
    }
}

struct FeedIconView: View {
    let feedID: Int64
    let title: String
    let data: Data?
    let onRequest: () -> Void
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = data.flatMap(UIImage.init(data:)) {
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
