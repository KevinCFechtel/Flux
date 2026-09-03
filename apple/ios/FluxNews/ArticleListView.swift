import SwiftUI
import UIKit

enum IOSScrolloverOffset {
    // Canonical positions increase as the list moves forward/downward.
    static func canonicalPosition(contentOffsetY: CGFloat) -> CGFloat { contentOffsetY }
    static func canonicalPosition(contentMinY: CGFloat) -> CGFloat { -contentMinY }
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
    private var frameGeneration = 0
    private var lastProcessedFrameGeneration = 0
    private var unread = Set<Int64>()
    private var enabled = true
    private var userScrolling = false
    private var tracker = ScrolloverExposureTracker()
    private var processingScheduled = false

    func updateViewport(_ viewport: CGRect) {
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        tracker.reset()
    }

    func updateEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { tracker.reset() }
    }

    func beginUserScroll() {
        guard !userScrolling else { return }
        userScrolling = true
        lastProcessedOffset = canonicalPosition
        lastProcessedFrameGeneration = frameGeneration
    }

    func endUserScroll() {
        userScrolling = false
    }

    func reset() {
        tracker.reset()
        userScrolling = false
        processingScheduled = false
    }

    func receiveFrames(_ frames: [Int64: CGRect], unread: Set<Int64>) {
        let framesChanged = self.frames != frames
        self.frames = frames
        self.unread = unread
        if framesChanged { frameGeneration &+= 1 }
        if userScrolling {
            if framesChanged { scheduleProcessing() }
        } else if enabled && !viewport.isEmpty {
            tracker.rebase(frames: frames, unread: unread)
            tracker.observe(frames: frames, viewport: viewport, unread: unread, now: Date.timeIntervalSinceReferenceDate)
            lastProcessedFrameGeneration = frameGeneration
        }
    }

    func receiveContentOffsetY(_ contentOffsetY: CGFloat, unread: Set<Int64>) {
        receiveCanonicalPosition(IOSScrolloverOffset.canonicalPosition(contentOffsetY: contentOffsetY), unread: unread)
    }

    func receiveLegacyContentMinY(_ contentMinY: CGFloat, unread: Set<Int64>) {
        receiveCanonicalPosition(IOSScrolloverOffset.canonicalPosition(contentMinY: contentMinY), unread: unread)
    }

    private func receiveCanonicalPosition(_ canonicalPosition: CGFloat, unread: Set<Int64>) {
        self.canonicalPosition = canonicalPosition
        self.unread = unread
        if userScrolling { scheduleProcessing() }
    }

    func observeIdle(now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard enabled, !userScrolling, !viewport.isEmpty else { return }
        tracker.observe(frames: frames, viewport: viewport, unread: unread, now: now)
    }

    private func scheduleProcessing() {
        guard !processingScheduled else { return }
        processingScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            processingScheduled = false
            guard userScrolling else { return }
            // Preserve movement until SwiftUI has published the matching row geometry.
            guard frameGeneration != lastProcessedFrameGeneration else { return }
            let delta = IOSScrolloverOffset.forwardDelta(current: canonicalPosition, previous: lastProcessedOffset)
            guard abs(delta) > 0.5 else { return }
            let ids = IOSScrolloverFrameProcessor.process(frames: frames, viewport: viewport, unread: unread, canonicalPosition: canonicalPosition, lastProcessedOffset: &lastProcessedOffset, tracker: &tracker, enabled: enabled, userInitiated: true)
            lastProcessedFrameGeneration = frameGeneration
            if !ids.isEmpty { onCandidate(ids) }
        }
    }
}

private struct IOSScrolloverInteractionModifier: ViewModifier {
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onContentOffsetY: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
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
        } else {
            content.simultaneousGesture(
                DragGesture()
                    .onChanged { _ in onBegin() }
                    .onEnded { _ in onEnd() }
            )
        }
    }
}

private struct IOSLegacyArticleOffsetPreferenceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ArticleOffsetKey.self,
                        value: geometry.frame(in: .named("ArticleScrollSpace")).minY)
                }
            }
        }
    }
}

enum IOSSwipeDirection: Equatable {
    case right
    case left
}

struct IOSSwipeArbitration: Equatable {
    enum Axis { case undecided, vertical, horizontal }
    private(set) var axis: Axis = .undecided
    private(set) var direction: IOSSwipeDirection?

    mutating func update(translation: CGSize, threshold: CGFloat = 12) {
        guard axis == .undecided else { return }
        guard max(abs(translation.width), abs(translation.height)) >= threshold else { return }
        if abs(translation.width) > abs(translation.height) {
            axis = .horizontal
            direction = translation.width >= 0 ? .right : .left
        } else {
            axis = .vertical
        }
    }

    mutating func reset() { axis = .undecided; direction = nil }
}

private struct IOSHorizontalSwipeRecognizer: UIViewRepresentable {
    @Binding var offset: CGFloat
    let actionWidth: CGFloat
    let onEnded: (IOSSwipeDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSHorizontalSwipeRecognizer
        private var startOffset: CGFloat = 0
        private var direction: IOSSwipeDirection?
        private var arbitration = IOSSwipeArbitration()

        init(_ parent: IOSHorizontalSwipeRecognizer) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                startOffset = parent.offset
                arbitration.reset()
            case .changed:
                arbitration.update(translation: CGSize(width: translation.x, height: translation.y))
                guard arbitration.axis == .horizontal, let lockedDirection = arbitration.direction else { return }
                direction = lockedDirection
                let horizontalTranslation = lockedDirection == .right ? max(0, translation.x) : min(0, translation.x)
                let proposed = startOffset + horizontalTranslation
                parent.offset = min(parent.actionWidth, max(-parent.actionWidth, proposed))
            case .ended, .cancelled, .failed:
                guard let direction else { reset(); return }
                let shouldReveal = abs(parent.offset) >= parent.actionWidth * 0.5
                parent.offset = shouldReveal ? (direction == .right ? parent.actionWidth : -parent.actionWidth) : 0
                if shouldReveal { parent.onEnded(direction) }
                reset()
            default: break
            }
        }

        private func reset() { startOffset = 0; direction = nil; arbitration.reset() }
    }
}

struct ArticleListView: View {
    @ObservedObject var store: NewsreaderStore
    @State private var scrolloverAdapter = IOSScrolloverRuntimeAdapter()
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

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
                                    ArticlePresentationView(article: article, mode: store.articlePresentationMode, previewLines: store.articlePreviewLines, availableWidth: proxy.size.width - horizontalInset * 2, store: store)
                                        .background { GeometryReader { row in Color.clear.preference(key: ArticleFrameKey.self, value: [article.id: row.frame(in: .named("ArticleScrollSpace"))]) } }
                                }
                             }
                             .padding(.horizontal, horizontalInset)
                             .padding(.vertical, 12)
                             .modifier(IOSLegacyArticleOffsetPreferenceModifier())
                         }
                         .refreshable { await store.syncManually() }
                        .coordinateSpace(name: "ArticleScrollSpace")
                        .scrollIndicators(.hidden)
                         .onAppear {
                             scrolloverAdapter.updateViewport(CGRect(origin: .zero, size: proxy.size))
                             scrolloverAdapter.onCandidate = { ids in store.flushScrollover(ids) }
                         }
                         .onChange(of: proxy.size) { _, size in scrolloverAdapter.updateViewport(CGRect(origin: .zero, size: size)) }
                           .onPreferenceChange(ArticleFrameKey.self) { values in
                               scrolloverAdapter.updateEnabled(store.markReadOnScrolloverEnabled)
                               scrolloverAdapter.receiveFrames(values, unread: unreadIDs)
                         }
                            .onPreferenceChange(ArticleOffsetKey.self) { newOffset in
                                if #available(iOS 18.0, *) {
                                    // iOS 18 uses onScrollGeometryChange as its only offset source.
                                } else {
                                    scrolloverAdapter.updateEnabled(store.markReadOnScrolloverEnabled)
                                    scrolloverAdapter.receiveLegacyContentMinY(newOffset, unread: unreadIDs)
                                }
                         }
                           .modifier(IOSScrolloverInteractionModifier(onBegin: {
                               scrolloverAdapter.beginUserScroll()
                               store.markMeaningfulInteraction()
                               store.beginScrolloverUndoBatch()
                           }, onEnd: {
                               scrolloverAdapter.endUserScroll()
                               store.finishScrolloverUndoBatch()
                            }, onContentOffsetY: { newOffset in
                                scrolloverAdapter.updateEnabled(store.markReadOnScrolloverEnabled)
                                scrolloverAdapter.receiveContentOffsetY(newOffset, unread: unreadIDs)
                           }))
         .onReceive(timer) { _ in scrolloverAdapter.observeIdle() }
                          .onChange(of: store.markReadOnScrolloverEnabled) { _, enabled in scrolloverAdapter.updateEnabled(enabled) }
                          .onChange(of: store.snapshotRevision) { _, _ in scrolloverAdapter.reset() }
                    }
                }
        }
        .background(Color(uiColor: .systemGroupedBackground))
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

    private var unreadIDs: Set<Int64> { Set(store.articles.filter { !$0.isRead }.map(\.id)) }
}

private struct ArticlePresentationView: View {
    let article: ArticleSummary
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    @ObservedObject var store: NewsreaderStore
    @State private var horizontalOffset: CGFloat = 0

    private let actionWidth: CGFloat = 76

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Button { store.setRead(article, read: !article.isRead); closeActions() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: article.isRead ? "envelope" : "envelope.open")
                        Text(article.isRead ? "Unread" : "Read")
                    }
                }
                .frame(width: actionWidth)
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity)
                .background(Color.accentColor)
                Spacer(minLength: 0)
                Button { store.setStarred(article, starred: !article.isStarred); closeActions() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: article.isStarred ? "star.slash" : "star")
                        Text(article.isStarred ? "Unstar" : "Star")
                    }
                }
                .frame(width: actionWidth)
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity)
                .background(Color.orange)
            }
            Group {
                switch mode {
                case .visual: visual
                case .compact: compact
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .frame(width: articleWidth, alignment: .leading)
            .background(Color(uiColor: .systemGroupedBackground))
            .offset(x: horizontalOffset)
            .background {
                IOSHorizontalSwipeRecognizer(offset: $horizontalOffset, actionWidth: actionWidth) { direction in
                    switch direction {
                    case .right: store.setRead(article, read: !article.isRead)
                    case .left: store.setStarred(article, starred: !article.isStarred)
                    }
                }
            }
        }
        .frame(width: articleWidth, alignment: .leading)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Article opening will be added in a later release.")
    }

    private func closeActions() {
        horizontalOffset = 0
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
            HStack(spacing: 6) {
                if ArticlePresentationLayout.showsInternalUnreadIndicator(isRead: article.isRead) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                FeedIconView(feedID: article.feedId, title: article.feedTitle, store: store)
                Text(article.feedTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("•")
                Text(date)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.secondary)
            .font(.caption)
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
}

private struct ArticleFrameKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}

private struct ArticleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FeedIconView: View {
    let feedID: Int64
    let title: String
    @ObservedObject var store: NewsreaderStore

    var body: some View {
        Group {
            if let data = store.feedIcons[feedID], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(title.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.gradient, in: Circle())
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("Feed \(title)")
        .task { store.requestFeedIcon(feedID) }
    }
}
