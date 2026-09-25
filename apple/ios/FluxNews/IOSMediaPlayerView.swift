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

    static func activeIndex(
        positionMs: UInt64,
        chapters: [MediaChapter]
    ) -> Int? {
        chapters.indices.last { index in
            let chapter = chapters[index]
            let end = chapter.endMs
                ?? chapters.dropFirst(index + 1).first?.startMs
            return positionMs >= chapter.startMs
                && (end == nil || positionMs < end!)
        }
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
        Button {
            ratePickerPresented = true
        } label: {
            Label(
                rateLabel(playbackState.playbackRate),
                systemImage: "speedometer"
            )
        }
        .accessibilityLabel(String(localized: "Playback speed"))
        .disabled(isPreviewingInactiveItem)
        .popover(
            isPresented: $ratePickerPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            VStack(spacing: 18) {
                Text("Playback speed")
                    .font(.headline)

                HStack(spacing: 20) {
                    Button {
                        adjustPlaybackRate(by: -0.1)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(playbackState.playbackRate <= 0.5)

                    Text(rateLabel(playbackState.playbackRate))
                        .font(.title2.monospacedDigit())
                        .frame(minWidth: 72)

                    Button {
                        adjustPlaybackRate(by: 0.1)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(playbackState.playbackRate >= 3.0)
                }

                HStack(spacing: 8) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(rateLabel(rate)) {
                            playbackCoordinator.setPlaybackRate(rate)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 320)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.height(220)])
        }
    }

    private var chapterMenu: some View {
        Button {
            chapterListSnapshot = playbackState.chapters
            chapterInitialIndex = IOSMediaChapterListPresentation.activeIndex(
                positionMs: playbackState.positionMs,
                chapters: playbackState.chapters
            )
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
                ScrollViewReader { proxy in
                    List {
                        ForEach(
                            Array(chapterListSnapshot.enumerated()),
                            id: \.offset
                        ) { index, chapter in
                            let isActive = IOSMediaChapterListPresentation
                                .activeIndex(
                                    positionMs: playbackState.positionMs,
                                    chapters: chapterListSnapshot
                                ) == index
                            Button {
                                playbackCoordinator.seek(toMs: chapter.startMs)
                                chapterListPresented = false
                            } label: {
                                HStack(
                                    alignment: .firstTextBaseline,
                                    spacing: 12
                                ) {
                                    Image(
                                        systemName: isActive
                                            ? "play.fill"
                                            : "circle.fill"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(
                                        isActive
                                            ? Color.accentColor
                                            : Color.clear
                                    )
                                    .frame(width: 12)

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
                                    .fontWeight(
                                        isActive ? .semibold : .regular
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
                                .padding(.vertical, 3)
                                .background(
                                    isActive
                                        ? Color.accentColor.opacity(0.10)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if let chapterInitialIndex {
                            DispatchQueue.main.async {
                                proxy.scrollTo(
                                    chapterInitialIndex,
                                    anchor: .center
                                )
                            }
                        }
                    }
                }
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

    private var sleepTimerButton: some View {
        Button {
            sleepTimerPresented = true
        } label: {
            Label(
                sleepTimer.isEnabled
                    ? sleepTimerLabel
                    : String(localized: "Sleep Timer"),
                systemImage: sleepTimer.isEnabled
                    ? "moon.zzz.fill"
                    : "moon.zzz"
            )
        }
        .popover(
            isPresented: $sleepTimerPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(
                    "Sleep Timer",
                    isOn: Binding(
                        get: { sleepTimer.isEnabled },
                        set: sleepTimer.setEnabled
                    )
                )

                Picker(
                    "Duration",
                    selection: Binding(
                        get: { sleepTimer.intervalMinutes },
                        set: sleepTimer.setInterval
                    )
                ) {
                    ForEach(
                        IOSMediaSleepTimer.intervalsMinutes,
                        id: \.self
                    ) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .disabled(!sleepTimer.isEnabled)

                if let remaining = sleepTimer.remainingSeconds {
                    Text("Stops in \(sleepTimerRemainingLabel(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(minWidth: 300)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.height(260)])
        }
    }

    private var downloadMenu: some View {
        Menu {
            ForEach(downloadEnclosures) { entry in
                let action = IOSListeningListPresentation.downloadAction(
                    download: entry.download,
                    runtime: transferState.runtime(
                        for: entry.enclosure.id
                    )
                )
                Button {
                    onDownloadAction(entry.enclosure.id, action)
                } label: {
                    downloadLabel(
                        action,
                        enclosureID: entry.enclosure.id
                    )
                }
                .disabled(
                    action == .cancelling
                        || action == .pendingDeletion
                )
            }
        } label: {
            Label("Downloads", systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func downloadLabel(
        _ action: IOSListeningListPresentation.DownloadAction,
        enclosureID: Int64
    ) -> some View {
        switch action {
        case .download:
            Label("Download", systemImage: "arrow.down.circle")
        case .pending:
            Label("Cancel Download", systemImage: "xmark.circle")
        case .downloading:
            if let fraction = transferState.runtime(
                for: enclosureID
            )?.fraction {
                Label(
                    "\(Int((fraction * 100).rounded()))% downloaded",
                    systemImage: "xmark.circle"
                )
            } else {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .cancelling:
            Label("Cancelling Download", systemImage: "clock")
        case .delete:
            Label("Delete Download", systemImage: "trash")
        case .pendingDeletion:
            Label("Deletion Pending", systemImage: "clock")
        case .retry:
            Label("Retry Download", systemImage: "arrow.clockwise")
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
            return "preview:\(previewEnclosure?.enclosure.id ?? -1)"
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
        let source: MediaArtworkSource?
        if isPreviewingInactiveItem,
           let enclosureID = previewEnclosure?.enclosure.id {
            source = await playbackCoordinator.previewArtworkSource(
                enclosureID: enclosureID
            )
        } else {
            source = playbackState.artworkSource
        }
        guard let source else {
            artworkIsLoading = false
            return
        }

        artworkIsLoading = true
        let data = await playbackCoordinator.artwork(source: source)
        guard !Task.isCancelled else { return }
        artworkImage = data.flatMap(UIImage.init(data:))
        artworkIsLoading = false
    }

    private func adjustPlaybackRate(by delta: Double) {
        playbackCoordinator.setPlaybackRate(
            playbackState.playbackRate + delta
        )
    }

    private var sleepTimerLabel: String {
        guard let remaining = sleepTimer.remainingSeconds else {
            return String(localized: "Sleep Timer")
        }
        return "Sleep \(sleepTimerRemainingLabel(remaining))"
    }

    private func sleepTimerRemainingLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0
            ? "\(minutes)m"
            : "\(minutes)m \(remainder)s"
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
