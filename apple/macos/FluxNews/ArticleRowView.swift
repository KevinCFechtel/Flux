import AppKit
import SwiftUI

// Visual/Compact use the original adjacent hover buttons. Visual Compact
// keeps its trailing-thumbnail overlay and pointer dwell behavior.
enum ArticleHoverActionsLayout {
    // Only Visual Compact uses these overlay sizes and the dwell delay.
    static let controlSize: CGFloat = 28
    static let controlSpacing: CGFloat = 2
    static let verticalPadding: CGFloat = 3
    static let minimumOverlayHeight = 3 * controlSize + 2 * controlSpacing + 2 * verticalPadding
    // Avoid revealing actions on rows briefly crossed while scrolling.
    static let hoverRevealDelayNanoseconds: UInt64 = 400_000_000

    enum Anchor: Equatable {
        case adjacentText
        case trailingThumbnail
    }

    static func anchor(for mode: ArticlePresentationMode) -> Anchor {
        switch mode {
        case .visual, .compact: .adjacentText
        case .visualCompact: .trailingThumbnail
        }
    }
}

struct ArticleItem: View {
    let article: ArticleSummary
    let mode: ArticlePresentationMode
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var focusedControl: FocusedControl?
    @State private var hovered = false
    @State private var hoverActionsReady = false
    @State private var hoverRevealTask: Task<Void, Never>?
    @State private var temporalReferenceDate = Date()

    private enum FocusedControl: Hashable {
        case thumbnail, metadata, headline, preview, read, star, more
    }

    // Pointer dwell is delayed; keyboard focus and VoiceOver stay immediate.
    private var actionsVisible: Bool {
        hoverActionsReady || focusedControl != nil || voiceOverEnabled
    }

    @ViewBuilder
    var body: some View {
        switch mode {
        case .visual:
            visual
        case .visualCompact:
            visualCompact
        case .compact:
            compact
        }
    }

    private var visual: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAvailableThumbnail {
                Button { onSelect(); store.open(article) } label: {
                    ThumbnailSlot(
                        article: article,
                        store: store,
                        width: PopoverLayout.visualWidth - 24,
                        height: 206,
                        cornerRadius: 10
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Button { onSelect(); store.open(article) } label: {
                        semanticTextComposition
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    quickActions
                        .opacity(hovered ? 1 : 0)
                        .allowsHitTesting(hovered)
                }
                audioActions
            }
            .padding(12)
        }
        .articleInteractionStyle(
            selected: selected,
            hovered: hovered,
            onHoverChanged: updateHover,
            menu: { actionMenu }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onDisappear { store.retryUnavailableArticleThumbnail(article) }
    }

    private var visualCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadata

            HStack(alignment: .top, spacing: 12) {
                Button { onSelect(); store.open(article) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        headline(lineLimit: 3)
                        publicationRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .headline)

                if hasAvailableThumbnail {
                    Button { onSelect(); store.open(article) } label: {
                        ThumbnailSlot(
                            article: article,
                            store: store,
                            width: 112,
                            height: ArticleHoverActionsLayout.minimumOverlayHeight,
                            cornerRadius: 9
                        )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .thumbnail)
                }
            }
            // Give text-only items the same minimum height; the hover overlay
            // must never spill into the preview or adjacent article.
            .frame(minHeight: ArticleHoverActionsLayout.minimumOverlayHeight, alignment: .top)
            // The right-hand image sits immediately below the metadata/read
            // indicator. Anchor to it, never to the preview's variable height.
            // Without a thumbnail, the controls overlap the trailing headline.
            .overlay(alignment: .topTrailing) {
                hoverActions
            }

            if !article.preview.isEmpty {
                Text(article.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(store.articlePreviewLines.rawValue)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            audioActions
        }
        .padding(12)
        .articleInteractionStyle(
            selected: selected,
            hovered: hovered,
            onHoverChanged: updateHover,
            menu: { actionMenu }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onDisappear {
            updateHover(false)
            store.retryUnavailableArticleThumbnail(article)
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Button { onSelect(); store.open(article) } label: {
                    semanticTextComposition
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                quickActions
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
            audioActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(interactionBackground)
        .onHover(perform: updateHover)
        .contextMenu { actionMenu }
    }

    private var semanticTextComposition: some View {
        VStack(alignment: .leading, spacing: mode == .compact ? 3 : 5) {
            metadata
            headline(lineLimit: mode == .compact ? 2 : 3)
            publicationRow
            if !article.preview.isEmpty {
                Text(article.preview)
                    .font(mode == .compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(store.articlePreviewLines.rawValue)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(lineLimit: Int) -> some View {
        Text(
            ListeningListPresentation.textOrFallback(
                article.title,
                fallback: String(localized: "Untitled News")
            )
        )
        .font(.system(size: 14, weight: article.isRead ? .regular : .semibold))
        .foregroundStyle(article.isRead ? .secondary : .primary)
        .lineLimit(lineLimit)
        .multilineTextAlignment(.leading)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            FeedIconSlot(feedID: article.feedId, store: store, size: 22)
            Text(article.feedTitle)
                .lineLimit(1)
                .foregroundStyle(article.isRead ? .tertiary : .secondary)

            Spacer(minLength: 4)

            if hasAudio {
                Image(systemName: "headphones")
                    .accessibilityLabel("Audio available")
            }
            if !article.commentsUrl.isEmpty {
                Image(systemName: "bubble.left")
                    .accessibilityLabel("Comments available")
            }
            if article.isStarred {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            if !article.isRead {
                Circle()
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var publicationRow: some View {
        HStack(spacing: 4) {
            if store.showRelativePublicationTime {
                Image(systemName: "clock.arrow.circlepath")
                    .accessibilityHidden(true)
            }

            Text(publicationValue)

            if let readingTime {
                Text("·")
                Image(systemName: hasAudio ? "headphones" : "doc.text")
                    .accessibilityHidden(true)
                Text(readingTime)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var audioActions: some View {
        if ArticleAudioActions.shouldRender(audioState, transferStateAvailable: transferState != nil),
           let audioState,
           let transferState {
            AudioActionsView(
                state: audioState,
                transferState: transferState,
                onPlay: onPlayAudio,
                onDownload: onDownloadAudio,
                onDelete: onDeleteDownload,
                onAdd: onAddToListeningList
            )
        }
    }

    // Original adjacent vertical actions for Visual and Compact; these
    // reserve their width and appear immediately on row hover.
    private var quickActions: some View {
        VStack(spacing: 8) {
            if !store.isSearchActive {
                legacyQuickActionButton(
                    article.isRead ? "circle.fill" : "checkmark.circle",
                    label: readActionLabel
                ) {
                    store.setRead(article, !article.isRead)
                }
            }
            legacyQuickActionButton(
                article.isStarred ? "star.fill" : "star",
                label: starActionLabel
            ) {
                store.setStarred(article, !article.isStarred)
            }
            Menu { actionMenu } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("More")
            .accessibilityLabel("More")
        }
    }

    private func legacyQuickActionButton(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    // Visual Compact retains the new overlay controls and 400 ms dwell.
    @ViewBuilder
    private var hoverActionControls: some View {
        if !store.isSearchActive {
            iconButton(
                article.isRead ? "circle.fill" : "checkmark.circle",
                label: readActionLabel
            ) {
                store.setRead(article, !article.isRead)
            }
            .focused($focusedControl, equals: .read)
        }
        iconButton(
            article.isStarred ? "star.fill" : "star",
            label: starActionLabel
        ) {
            store.setStarred(article, !article.isStarred)
        }
        .focused($focusedControl, equals: .star)
        Menu { actionMenu } label: {
            Image(systemName: "ellipsis")
                .frame(width: ArticleHoverActionsLayout.controlSize, height: ArticleHoverActionsLayout.controlSize)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: ArticleHoverActionsLayout.controlSize, height: ArticleHoverActionsLayout.controlSize)
        .focused($focusedControl, equals: .more)
        .help("More")
        .accessibilityLabel("More")
    }

    private var hoverActions: some View {
        VStack(spacing: ArticleHoverActionsLayout.controlSpacing) {
            hoverActionControls
        }
        .padding(.horizontal, 5)
        .padding(.vertical, ArticleHoverActionsLayout.verticalPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .accessibilityHidden(!actionsVisible)
    }

    private var interactionBackground: Color {
        selected
            ? Color.accentColor.opacity(0.16)
            : hovered ? Color.primary.opacity(0.055) : .clear
    }

    @ViewBuilder
    private var actionMenu: some View {
        Button { store.open(article) } label: { Label("Open", systemImage: "safari") }
        Button { store.openDetail(article) } label: { Label("Open Detail View", systemImage: "doc.text") }
        Button { store.setStarred(article, !article.isStarred) } label: {
            Label(starActionLabel, systemImage: article.isStarred ? "star.slash" : "star")
        }
        if !store.isSearchActive {
            Button { store.setRead(article, !article.isRead) } label: {
                Label(readActionLabel, systemImage: article.isRead ? "circle.fill" : "checkmark.circle")
            }
            Button { store.saveToService(article) } label: {
                Label("Save to Third-Party Service", systemImage: "tray.and.arrow.down")
            }
            Divider()
            Button { store.copyLink(article) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button { store.share(article) } label: { Label("Share...", systemImage: "square.and.arrow.up") }
            Button { store.openOriginal(article) } label: { Label("Open Original", systemImage: "safari") }
            Button { store.openInMiniflux(article) } label: { Label("Open in Miniflux", systemImage: "arrow.up.forward.app") }
            Button { store.select(.feed(article.feedId)) } label: { Label("Show Feed", systemImage: "line.3.horizontal.decrease.circle") }
            if !article.commentsUrl.isEmpty {
                Button { store.openComments(article) } label: { Label("Open Comments", systemImage: "bubble.left") }
            }
        }
    }

    private func iconButton(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: ArticleHoverActionsLayout.controlSize, height: ArticleHoverActionsLayout.controlSize)
        }
        .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    private func updateHover(_ hovering: Bool) {
        // Visual and Compact use the original immediate hover behavior.
        // Only Visual Compact delays revealing its overlay controls.
        hovered = hovering
        if mode == .visualCompact {
            hoverRevealTask?.cancel()
            hoverRevealTask = nil
            if hovering {
                hoverActionsReady = false
                hoverRevealTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: ArticleHoverActionsLayout.hoverRevealDelayNanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, hovered else { return }
                    hoverActionsReady = true
                }
            } else {
                hoverActionsReady = false
            }
        }
        onHoverChanged(hovering)
    }

    private var hasAvailableThumbnail: Bool {
        mode.showsArticleImage
            && article.imageUrl != nil
            && !store.unavailableArticleThumbnails.contains(store.articleThumbnailKey(article))
    }

    private var hasAudio: Bool {
        !(audioState?.enclosures.isEmpty ?? true)
    }

    private var publicationValue: String {
        ArticleTemporalPresentation.publicationValue(
            article.publishedAt,
            showRelative: store.showRelativePublicationTime,
            relativeTo: temporalReferenceDate
        )
    }

    private var readingTime: String? {
        ArticleTemporalPresentation.readingTime(article.readingTimeMinutes)
    }

    private var readActionLabel: String {
        article.isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")
    }

    private var starActionLabel: String {
        article.isStarred ? String(localized: "Unstar") : String(localized: "Star")
    }
}

private extension View {
    func articleInteractionStyle<MenuContent: View>(
        selected: Bool,
        hovered: Bool,
        onHoverChanged: @escaping (Bool) -> Void,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? Color.accentColor.opacity(0.16)
                    : hovered ? Color.primary.opacity(0.055) : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onHover(perform: onHoverChanged)
            .contextMenu { menu() }
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
    @Environment(\.displayScale) private var displayScale
    let feedID: Int64
    @ObservedObject var store: BrowserStore
    var size: CGFloat = 16

    var body: some View {
        let dark = colorScheme == .dark
        let key = "\(feedID)-\(dark ? "dark" : "normal")"

        Group {
            if let image = store.feedIcons[key] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Text(fallbackLetter)
                        .font(.system(size: max(8, size * 0.52), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Feed icon")
        .onAppear {
            store.requestFeedIcon(
                feedID,
                darkAppearance: dark,
                displayScale: displayScale
            )
        }
        .onChange(of: colorScheme) { _, appearance in
            store.requestFeedIcon(
                feedID,
                darkAppearance: appearance == .dark,
                displayScale: displayScale
            )
        }
    }

    private var fallbackLetter: String {
        let title = store.feedTitle(feedID: feedID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.first.map { String($0).uppercased() } ?? "•"
    }
}
