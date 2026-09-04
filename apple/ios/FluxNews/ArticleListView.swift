import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

enum IOSScrolloverOffset {
    // Canonical positions increase as the list moves forward/downward.
    static func canonicalPosition(contentOffsetY: CGFloat) -> CGFloat { contentOffsetY }
    static func forwardDelta(current: CGFloat, previous: CGFloat) -> CGFloat { current - previous }
}

enum IOSScrolloverProcessingGate {
    static func shouldProcess(enabled: Bool) -> Bool { enabled }
}

enum IOSScrolloverFrameProcessor {
    static func process(
        frames: [Int64: CGRect],
        viewport: CGRect,
        unread: Set<Int64>,
        canonicalPosition: CGFloat,
        lastProcessedOffset: inout CGFloat,
        tracker: inout ScrolloverExposureTracker,
        enabled: Bool,
        userInitiated: Bool
    ) -> [Int64] {
        guard enabled, userInitiated else { return [] }
        let delta = IOSScrolloverOffset.forwardDelta(current: canonicalPosition, previous: lastProcessedOffset)
        guard abs(delta) > 0.5 else { return [] }
        lastProcessedOffset = canonicalPosition
        return tracker.process(frames: frames, viewport: viewport, unread: unread, now: Date.timeIntervalSinceReferenceDate, offsetDelta: delta, userInitiated: true)
    }
}

@MainActor
final class IOSScrolloverRuntimeAdapter {
    var onCandidate: ([Int64]) -> Void = { _ in }

    private var frames: [Int64: CGRect] = [:]
    private var viewport = CGRect.zero
    private var canonicalPosition: CGFloat = 0
    private var lastProcessedOffset: CGFloat = 0
    private var unread = Set<Int64>()
    private var enabled = true
    private var userScrolling = false
    private var tracker = ScrolloverExposureTracker()
#if DEBUG
    private static let diagnosticLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews", category: "scrollover-diagnostic")
    private var diagnosticIndices: [Int64: Int] = [:]
    private var diagnosticIDs = Set<Int64>()
#endif

    func updateViewport(_ viewport: CGRect) {
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        // GeometryReader size changes occur during an active scroll; frames remain
        // in ArticleScrollSpace, so their exposure history is still meaningful.
        if !userScrolling {
            tracker.rebase(frames: frames, unread: unread)
        }
        diagnostic("viewport update viewport=\(rect(viewport)) rebase=\(!userScrolling)")
    }

    func updateEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { tracker.reset() }
    }

    func beginUserScroll() {
        guard !userScrolling else { return }
        userScrolling = true
        lastProcessedOffset = canonicalPosition
        diagnostic("begin offset=\(canonicalPosition) baseline=\(lastProcessedOffset) userScrolling=true")
    }

    func endUserScroll() {
        userScrolling = false
        diagnostic("end offset=\(canonicalPosition) userScrolling=false")
    }

    func reset() {
        tracker.reset()
        userScrolling = false
        diagnostic("reset")
    }

    func receiveFrames(_ frames: [Int64: CGRect], unread: Set<Int64>) {
        self.frames = frames
        self.unread = unread
        guard enabled, !viewport.isEmpty else { return }
        if !userScrolling {
            tracker.rebase(frames: frames, unread: unread)
            diagnostic("frames rebase count=\(frames.count) viewport=\(rect(viewport))")
        }
        tracker.observe(frames: frames, viewport: viewport, unread: unread, now: Date.timeIntervalSinceReferenceDate)
        diagnosticExposures(event: "observe", delta: nil)
    }

    func receiveContentOffsetY(_ contentOffsetY: CGFloat, unread: Set<Int64>) {
        receiveCanonicalPosition(IOSScrolloverOffset.canonicalPosition(contentOffsetY: contentOffsetY), unread: unread)
    }

    private func receiveCanonicalPosition(_ canonicalPosition: CGFloat, unread: Set<Int64>) {
        self.canonicalPosition = canonicalPosition
        self.unread = unread
        diagnostic("offset position=\(canonicalPosition) baseline=\(lastProcessedOffset) userScrolling=\(userScrolling)")
        processScrollDelta()
    }

    func observeIdle(now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard enabled, !userScrolling, !viewport.isEmpty else { return }
        tracker.observe(frames: frames, viewport: viewport, unread: unread, now: now)
        diagnosticExposures(event: "idle-observe", delta: nil)
    }

    private func processScrollDelta() {
        guard userScrolling else { return }
        let delta = IOSScrolloverOffset.forwardDelta(current: canonicalPosition, previous: lastProcessedOffset)
        diagnosticExposures(event: "process-before", delta: delta)
        if delta <= 0 || delta > viewport.height * 0.85 {
            diagnostic("process reset delta=\(delta) limit=\(viewport.height * 0.85)")
        }
        let ids = IOSScrolloverFrameProcessor.process(frames: frames, viewport: viewport, unread: unread, canonicalPosition: canonicalPosition, lastProcessedOffset: &lastProcessedOffset, tracker: &tracker, enabled: enabled, userInitiated: true)
        diagnosticExposures(event: "process-after emitted=\(ids)", delta: delta)
        if !ids.isEmpty { onCandidate(ids) }
    }

    func recordScrollPhase(previous: String, current: String) {
        diagnostic("phase \(previous)->\(current) offset=\(canonicalPosition) userScrolling=\(userScrolling)")
    }

#if DEBUG
    func updateDiagnosticArticles(_ articles: [ArticleSummary]) {
        diagnosticIndices = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
        diagnosticIDs = Set(articles.lazy.filter { !$0.isRead }.prefix(6).map(\.id))
        diagnostic("tracking ids=\(diagnosticIDs.sorted())")
    }

    private func diagnosticExposures(event: String, delta: CGFloat?) {
        let now = Date.timeIntervalSinceReferenceDate
        let exposures = Dictionary(uniqueKeysWithValues: tracker.diagnosticExposures().map { ($0.id, $0) })
        for id in diagnosticIDs.sorted() {
            guard let exposure = exposures[id] else {
                diagnostic("id=\(id) index=\(diagnosticIndices[id] ?? -1) event=\(event) exposure=missing frame=\(rect(frames[id]))")
                continue
            }
            let frame = frames[id]
            let visibleHeight = frame?.intersection(viewport).height ?? 0
            let visibleFraction = visibleHeight / max(1, frame?.height ?? 1)
            let crossed = frame.map { exposure.processedFrame.maxY > viewport.minY && $0.maxY <= viewport.minY } ?? (exposure.currentFrame.midY < viewport.midY)
            let visibleFor = exposure.visibleSince.map { now - $0 } ?? 0
            diagnostic("id=\(id) index=\(diagnosticIndices[id] ?? -1) event=\(event) delta=\(delta ?? 0) visible=\(visibleFraction) visibleFor=\(visibleFor) qualified=\(exposure.qualified) crossed=\(crossed) frame=\(rect(frame)) processed=\(rect(exposure.processedFrame)) current=\(rect(exposure.currentFrame)) viewport=\(rect(viewport))")
        }
    }

    private func diagnostic(_ message: String) {
        Self.diagnosticLog.debug("\(message, privacy: .public)")
    }

    private func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(x:\(rect.origin.x),y:\(rect.origin.y),w:\(rect.width),h:\(rect.height))"
    }
#else
    func updateDiagnosticArticles(_ articles: [ArticleSummary]) {}
    private func diagnostic(_ message: String) {}
    private func diagnosticExposures(event: String, delta: CGFloat?) {}
    private func rect(_ rect: CGRect) -> String { "" }
#endif
}

private struct IOSScrolloverInteractionModifier: ViewModifier {
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onContentOffsetY: (CGFloat) -> Void
    let onPhase: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { previous, phase in
                onPhase(String(describing: previous), String(describing: phase))
                switch phase {
                case .interacting: onBegin()
                case .idle: onEnd()
                default: break
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newOffset in
                onContentOffsetY(newOffset)
            }
    }
}

enum IOSArticleMutation: Equatable {
    case read(Bool)
    case starred(Bool)
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

    // SwiftUI assigns Full Swipe to the first declared action, while displaying
    // its actions from the swipe edge inward. Reverse the visual order here.
    var nativeDeclarationOrder: [IOSArticleSwipeAction] { actions.reversed() }
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
    @ObservedObject var store: NewsreaderStore
    let onArticleTap: (ArticleSummary) -> Void
    let onArticleAction: (ArticleSummary, IOSArticleContextAction) -> Void
    @State private var scrolloverAdapter = IOSScrolloverRuntimeAdapter()
    @State private var unreadArticleIDs = Set<Int64>()
    @State private var sensoryFeedbackTrigger = 0
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let topAnchorID = "article-list-top"

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
                    ScrollViewReader { scrollProxy in
                    GeometryReader { proxy in
                        let horizontalInset: CGFloat = proxy.size.width > 700 ? 28 : 16
                        let articleSpacing: CGFloat =
                          ArticlePresentationLayout.usesLandscapeVisual(
                            mode: store.articlePresentationMode,
                            availableWidth: proxy.size.width - horizontalInset * 2) ? 20 : 26
                          ScrollView {
                             Color.clear.frame(height: 0).id(topAnchorID)
                             LazyVStack(spacing: articleSpacing) {
                                ForEach(store.articles, id: \.id) { article in
                                       ArticlePresentationView(article: article, mode: store.articlePresentationMode, previewLines: store.articlePreviewLines, availableWidth: proxy.size.width - horizontalInset * 2, feedIconData: store.feedIcons[IOSFeedIconKey(feedID: article.feedId, variant: IOSFeedIconPresentation.variant(isDark: colorScheme == .dark))], iconVariant: IOSFeedIconPresentation.variant(isDark: colorScheme == .dark), onRequestFeedIcon: { store.requestFeedIcon(article.feedId, variant: IOSFeedIconPresentation.variant(isDark: colorScheme == .dark)) }, onTap: { onArticleTap(article) }, onAction: { onArticleAction(article, $0) }, onSetRead: { article, read in store.setRead(article, read: read) }, onSetStarred: { article, starred in store.setStarred(article, starred: starred) })
                                         .equatable()
                                        .background { GeometryReader { row in Color.clear.preference(key: ArticleFrameKey.self, value: [article.id: row.frame(in: .named("ArticleScrollSpace"))]) } }
                                }
                             }
                             .padding(.horizontal, horizontalInset)
                             .padding(.vertical, 12)
                          }
                         .refreshable { await store.syncManually() }
                        .coordinateSpace(name: "ArticleScrollSpace")
                        .scrollIndicators(.hidden)
                          .onAppear {
                              scrolloverAdapter.updateViewport(CGRect(origin: .zero, size: proxy.size))
                              scrolloverAdapter.onCandidate = { ids in store.flushScrollover(ids) }
                              refreshUnreadArticleIDs()
                          }
                         .onChange(of: proxy.size) { _, size in scrolloverAdapter.updateViewport(CGRect(origin: .zero, size: size)) }
                           .onPreferenceChange(ArticleFrameKey.self) { values in
                                scrolloverAdapter.updateEnabled(store.markReadOnScrolloverEnabled)
                                scrolloverAdapter.receiveFrames(values, unread: unreadArticleIDs)
                         }
                             .modifier(IOSScrolloverInteractionModifier(onBegin: {
                                 scrolloverAdapter.beginUserScroll()
                                 store.beginScrolloverPresentationScroll()
                                 store.markMeaningfulInteraction()
                                 store.beginScrolloverUndoBatch()
                            }, onEnd: {
                                 scrolloverAdapter.endUserScroll()
                                 store.finishScrolloverPresentationScroll()
                                 store.finishScrolloverUndoBatch()
                             }, onContentOffsetY: { newOffset in
                                 scrolloverAdapter.updateEnabled(store.markReadOnScrolloverEnabled)
                                 scrolloverAdapter.receiveContentOffsetY(newOffset, unread: unreadArticleIDs)
                            }, onPhase: { previous, current in
                                scrolloverAdapter.recordScrollPhase(previous: previous, current: current)
                            }))
          .onReceive(timer) { _ in scrolloverAdapter.observeIdle() }
                           .onChange(of: store.articles) { _, _ in refreshUnreadArticleIDs() }
                            .onChange(of: store.markReadOnScrolloverEnabled) { _, enabled in scrolloverAdapter.updateEnabled(enabled) }
                            .onChange(of: store.snapshotRevision) { _, _ in scrolloverAdapter.reset() }
                            .onChange(of: store.scrollResetRevision) { _, _ in
                                scrollProxy.scrollTo(topAnchorID, anchor: .top)
                            }
                           .onChange(of: store.scrolloverUndoVisible) { _, visible in
                               if visible { sensoryFeedbackTrigger += 1 }
                           }
                           .sensoryFeedback(.success, trigger: sensoryFeedbackTrigger)
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
            if store.scrolloverUndoVisible {
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
             } else if store.hasPendingNewData || store.hasUnscopedNewDataSignal {
                Button("New articles available") { store.adoptVisibleSnapshot() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
            }
        }
    }

    private func refreshUnreadArticleIDs() {
        unreadArticleIDs = Set(store.articles.lazy.filter { !$0.isRead }.map(\.id))
        scrolloverAdapter.updateDiagnosticArticles(store.articles)
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
        .swipeActions(edge: .leading, allowsFullSwipe: swipeConfiguration.leading.fullSwipeAction != nil) {
            ForEach(swipeConfiguration.leading.nativeDeclarationOrder, id: \.self, content: swipeActionButton)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: swipeConfiguration.trailing.fullSwipeAction != nil) {
            ForEach(swipeConfiguration.trailing.nativeDeclarationOrder, id: \.self, content: swipeActionButton)
        }
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

    private func swipeActionButton(_ action: IOSArticleSwipeAction) -> some View {
        Button { performSwipeAction(action) } label: {
            Label(action.accessibilityLabel, systemImage: action.systemImage)
        }
        .tint(action.tint)
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
                AsyncImage(url: imageURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: portraitContentWidth, height: ArticlePresentationLayout.portraitImageHeight(contentWidth: portraitContentWidth))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                .accessibilityHidden(true)
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
                AsyncImage(url: imageURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: imageWidth, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: imageWidth))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                .accessibilityHidden(true)
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

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
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
        if ArticlePresentationLayout.showsInternalUnreadIndicator(isRead: article.isRead) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }
}

private struct ArticleFrameKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
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
