import Foundation
import SwiftUI
import UIKit

struct IOSMediaPlayerDownloadEnclosure: Identifiable {
    let enclosure: Enclosure
    let download: MediaDownload?
    var id: Int64 { enclosure.id }
}

enum IOSMediaPlayerLayoutMode: Equatable {
    case stacked
    case sideBySide
}

enum IOSMediaPlayerPreviewPresentation {
    static func isPreviewingInactiveItem(
        item: ListeningListItem?,
        loadedEnclosureID: Int64?
    ) -> Bool {
        guard let item else { return false }
        guard let loadedEnclosureID else { return true }
        return !item.audioEnclosures.contains(
            where: { $0.enclosure.id == loadedEnclosureID }
        )
    }

    static func preferredEnclosure(
        item: ListeningListItem?
    ) -> ListeningListEnclosure? {
        guard let item else { return nil }
        return IOSListeningListPresentation.selectedEnclosure(item)
            ?? item.audioEnclosures.first
    }

    static func positionMs(
        item: ListeningListItem?,
        loadedEnclosureID: Int64?,
        runtimePositionMs: UInt64
    ) -> UInt64 {
        guard isPreviewingInactiveItem(
            item: item,
            loadedEnclosureID: loadedEnclosureID
        ) else {
            return runtimePositionMs
        }
        return preferredEnclosure(item: item)?.playbackState?.positionMs ?? 0
    }
}

enum IOSMediaChapterListPresentation {
    static func title(_ chapter: MediaChapter, index: Int) -> String {
        MediaChapterPresentation.usesGeneratedTitle(chapter.title)
            ? String(localized: "Chapter \(index + 1)")
            : chapter.title
    }

    static func positionLabel(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02llu:%02llu", minutes, seconds)
    }
}

enum IOSMediaPlayerLayoutPolicy {
    static func mode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> IOSMediaPlayerLayoutMode {
        if horizontalSizeClass == .regular || verticalSizeClass == .compact {
            return .sideBySide
        }
        return .stacked
    }
}

struct IOSMediaPlayerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var playbackState: IOSMediaPlaybackPresentationState
    @ObservedObject var transferState: IOSMediaTransferPresentationState
    @ObservedObject var sleepTimer: IOSMediaSleepTimer
    let playbackCoordinator: IOSMediaPlaybackCoordinator
    let item: ListeningListItem?
    let downloadEnclosures: [IOSMediaPlayerDownloadEnclosure]
    let onDownloadAction: (
        _ enclosureID: Int64,
        _ action: IOSListeningListPresentation.DownloadAction
    ) -> Void
    let feedIconFeedID: Int64?
    let feedIconTitle: String
    let feedIconState: (_ feedID: Int64, _ variant: FeedIconVariant) -> IOSFeedIconPresentationState
    let onRequestFeedIcon: (_ feedID: Int64, _ variant: FeedIconVariant) -> Void
    let showNotesDocument: ReaderDocument?
    let showNotesIsLoading: Bool
    let showNotesErrorMessage: String?
    let onSelectEnclosure: (Int64) -> Void
    let onShowNotes: () -> Void
    let onDismiss: () -> Void

    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var showNotesPresented = false
    @State private var chapterListPresented = false
    @State private var chapterListSnapshot: [MediaChapter] = []
    @State private var chapterInitialIndex: Int?
    @State private var ratePickerPresented = false
    @State private var sleepTimerPresented = false
    @State private var artworkImage: UIImage?
    @State private var artworkIsLoading = false

    private var layoutMode: IOSMediaPlayerLayoutMode {
        IOSMediaPlayerLayoutPolicy.mode(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    private var previewEnclosure: ListeningListEnclosure? {
        IOSMediaPlayerPreviewPresentation.preferredEnclosure(item: item)
    }

    private var isPreviewingInactiveItem: Bool {
        IOSMediaPlayerPreviewPresentation.isPreviewingInactiveItem(
            item: item,
            loadedEnclosureID: playbackState.loadedEnclosure?.id
        )
    }

    private var displayedTitle: String {
        if isPreviewingInactiveItem, let item {
            return IOSListeningListPresentation.textOrFallback(
                item.title,
                fallback: String(localized: "Audio")
            )
        }
        return playbackState.mediaTitle.isEmpty
            ? String(localized: "Audio")
            : playbackState.mediaTitle
    }

    private var displayedFeedTitle: String {
        if isPreviewingInactiveItem, let item {
            return IOSListeningListPresentation.textOrFallback(
                item.feedTitle,
                fallback: String(localized: "Unknown Feed")
            )
        }
        return playbackState.feedTitle
    }

    private var displayedPositionMs: UInt64 {
        IOSMediaPlayerPreviewPresentation.positionMs(
            item: item,
            loadedEnclosureID: playbackState.loadedEnclosure?.id,
            runtimePositionMs: playbackState.positionMs
        )
    }

    private var displayedDurationMs: UInt64? {
        if isPreviewingInactiveItem {
            return previewEnclosure?.durationMs
                ?? previewEnclosure?.playbackState?.durationMs
        }
        return playbackState.durationMs
    }

    private var displayedIsPlaying: Bool {
        !isPreviewingInactiveItem && playbackState.status == .playing
    }

    var body: some View {
        NavigationStack {
            Group {
                switch layoutMode {
                case .stacked:
                    ScrollView {
                        VStack(spacing: 24) {
                            artwork
                                .frame(maxWidth: 300)
                            controls
                        }
                        .frame(maxWidth: 560)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }

                case .sideBySide:
                    ScrollView {
                        HStack(alignment: .top, spacing: 32) {
                            artwork
                                .frame(maxWidth: 360)

                            controls
                                .frame(maxWidth: 520)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !isPreviewingInactiveItem,
                       let enclosureID = playbackState.loadedEnclosure?.id {
                        Button("Restart") {
                            Task {
                                try? await playbackCoordinator.restart(
                                    enclosureID: enclosureID
                                )
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showNotesPresented) {
                NavigationStack {
                    Group {
                        if showNotesIsLoading {
                            ProgressView("Loading article…")
                        } else if let showNotesErrorMessage {
                            ContentUnavailableView(
                                "Unable to load article",
                                systemImage: "exclamationmark.triangle",
                                description: Text(showNotesErrorMessage)
                            )
                        } else if let showNotesDocument {
                            ScrollView {
                                ReaderDocumentContent(
                                    document: showNotesDocument,
                                    openOriginal: nil
                                )
                            }
                        } else {
                            ProgressView("Loading article…")
                        }
                    }
                    .navigationTitle("Show Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showNotesPresented = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            seekPosition = Double(displayedPositionMs)
        }
        .task(id: artworkTaskKey) {
            await loadArtwork()
        }
    }

    private var controls: some View {
        VStack(spacing: 24) {
            header

            if let duration = displayedDurationMs, duration > 0 {
                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: {
                                isSeeking
                                    ? seekPosition
                                    : Double(displayedPositionMs)
                            },
                            set: { seekPosition = $0 }
                        ),
                        in: 0...Double(duration),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if editing {
                                seekPosition = Double(displayedPositionMs)
                            } else {
                                if !isPreviewingInactiveItem {
                                    playbackCoordinator.seek(
                                        toMs: UInt64(max(0, seekPosition))
                                    )
                                }
                            }
                        }
                    )

                    HStack {
                        Text(timeLabel(displayedPositionMs))
                        Spacer()
                        Text(timeLabel(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                Button {
                    if !isPreviewingInactiveItem {
                        playbackCoordinator.skip(bySeconds: -15)
                    }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "Back 15 seconds"))

                Button {
                    togglePlayback()
                } label: {
                    Image(
                        systemName: displayedIsPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 54))
                }
                .accessibilityLabel(
                    displayedIsPlaying
                        ? String(localized: "Pause")
                        : String(localized: "Play")
                )

                Button {
                    if !isPreviewingInactiveItem {
                        playbackCoordinator.stop()
                    }
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "Stop"))
                .disabled(isPreviewingInactiveItem)

                Button {
                    if !isPreviewingInactiveItem {
                        playbackCoordinator.skip(bySeconds: 30)
                    }
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "Forward 30 seconds"))
            }
            .buttonStyle(.plain)

            ViewThatFits(in: .horizontal) {
                playerActionRow
                playerActionColumn
            }

            if !isPreviewingInactiveItem
                && (playbackState.isLoading || playbackState.isBuffering) {
                ProgressView(
                    playbackState.isBuffering
                        ? "Buffering…"
                        : "Loading…"
                )
            }

            if !isPreviewingInactiveItem,
               let error = playbackState.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var playerActionRow: some View {
        HStack(spacing: 18) {
            rateMenu
            chapterMenu
            sleepTimerButton
            if !downloadEnclosures.isEmpty {
                downloadMenu
            }
            if let item, item.audioEnclosures.count > 1 {
                enclosureMenu(item)
            }
            showNotesButton
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private var playerActionColumn: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                rateMenu
                chapterMenu
                sleepTimerButton
                if !downloadEnclosures.isEmpty {
                    downloadMenu
                }
                if let item, item.audioEnclosures.count > 1 {
                    enclosureMenu(item)
                }
            }
            showNotesButton
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private var showNotesButton: some View {
        Button {
            onShowNotes()
            showNotesPresented = true
        } label: {
            Label("Show Notes", systemImage: "doc.text")
        }
    }

    private var artwork: some View {
        Group {
            if let artworkImage {
                Image(uiImage: artworkImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel(String(localized: "Media artwork"))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.secondary.opacity(0.12))
                    if artworkIsLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 54))
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(displayedTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if !displayedFeedTitle.isEmpty {
                HStack(spacing: 6) {
                    if let feedIconFeedID {
                        FeedIconView(
                            feedID: feedIconFeedID,
                            title: feedIconTitle,
                            state: feedIconState(
                                feedIconFeedID,
                                feedIconVariant
                            ),
                            onRequest: {
                                onRequestFeedIcon(
                                    feedIconFeedID,
                                    feedIconVariant
                                )
                            },
                            size: 18
                        )
                    }
                    Text(displayedFeedTitle)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var feedIconVariant: FeedIconVariant {
        IOSFeedIconPresentation.variant(
            isDark: colorScheme == .dark
        )
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                Button {
                    playbackCoordinator.setPlaybackRate(rate)
                } label: {
                    if playbackState.playbackRate == rate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Label(rateLabel(playbackState.playbackRate), systemImage: "speedometer")
        }
        .accessibilityLabel(String(localized: "Playback speed"))
        .disabled(isPreviewingInactiveItem)
    }

    private var chapterMenu: some View {
        Button {
            chapterListSnapshot = playbackState.chapters
            chapterListPresented = true
        } label: {
            Label("Chapters", systemImage: "list.bullet.rectangle")
        }
        .disabled(isPreviewingInactiveItem || playbackState.chapters.isEmpty)
        .popover(
            isPresented: $chapterListPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            NavigationStack {
                List {
                    ForEach(
                        Array(chapterListSnapshot.enumerated()),
                        id: \.offset
                    ) { index, chapter in
                        Button {
                            playbackCoordinator.seek(toMs: chapter.startMs)
                            chapterListPresented = false
                        } label: {
                            HStack(
                                alignment: .firstTextBaseline,
                                spacing: 12
                            ) {
                                Text(
                                    IOSMediaChapterListPresentation
                                        .positionLabel(chapter.startMs)
                                )
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .leading)

                                Text(
                                    IOSMediaChapterListPresentation.title(
                                        chapter,
                                        index: index
                                    )
                                )
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("Chapters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            chapterListPresented = false
                        }
                    }
                }
            }
            .frame(
                minWidth: 340,
                idealWidth: 440,
                maxWidth: 520,
                minHeight: 320,
                idealHeight: 480
            )
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func enclosureMenu(_ item: ListeningListItem) -> some View {
        Menu {
            ForEach(Array(item.audioEnclosures.enumerated()), id: \.element.enclosure.id) { index, enclosure in
                Button {
                    onSelectEnclosure(enclosure.enclosure.id)
                } label: {
                    Text(
                        IOSListeningListPresentation.enclosureLabel(
                            enclosure.enclosure,
                            index: index
                        )
                    )
                }
            }
        } label: {
            Label("Audio", systemImage: "waveform")
        }
        .accessibilityLabel(String(localized: "Choose audio"))
    }

    private var artworkTaskKey: String {
        if isPreviewingInactiveItem {
            return "preview:\(item?.articleId ?? -1)"
        }
        switch playbackState.artworkSource {
        case let .some(.localReference(reference)):
            return "local:\(reference)"
        case let .some(.remoteUrl(url)):
            return "remote:\(url)"
        case .none:
            return "none"
        }
    }

    @MainActor
    private func loadArtwork() async {
        artworkImage = nil
        guard !isPreviewingInactiveItem,
              let source = playbackState.artworkSource else {
            artworkIsLoading = false
            return
        }

        artworkIsLoading = true
        let data = await playbackCoordinator.artwork(source: source)
        guard !Task.isCancelled else { return }
        artworkImage = data.flatMap(UIImage.init(data:))
        artworkIsLoading = false
    }

    private func togglePlayback() {
        if isPreviewingInactiveItem {
            guard let enclosureID = previewEnclosure?.enclosure.id else { return }
            onSelectEnclosure(enclosureID)
            return
        }

        guard let enclosureID = playbackState.loadedEnclosure?.id else { return }
        if playbackState.status == .playing {
            playbackCoordinator.pause()
        } else {
            Task {
                try? await playbackCoordinator.play(
                    enclosureID: enclosureID
                )
            }
        }
    }

    private func timeLabel(_ milliseconds: UInt64) -> String {
        Duration.seconds(Double(milliseconds) / 1_000)
            .formatted(.time(pattern: .minuteSecond))
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == floor(rate)
            ? "\(Int(rate))×"
            : String(format: "%.2g×", rate)
    }
}
