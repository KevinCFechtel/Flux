import Foundation
import SwiftUI
import UIKit

enum IOSMediaPlayerLayoutMode: Equatable {
    case stacked
    case sideBySide
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

    @ObservedObject var playbackState: IOSMediaPlaybackPresentationState
    let playbackCoordinator: IOSMediaPlaybackCoordinator
    let item: ListeningListItem?
    let showNotesDocument: ReaderDocument?
    let showNotesIsLoading: Bool
    let showNotesErrorMessage: String?
    let onSelectEnclosure: (Int64) -> Void
    let onShowNotes: () -> Void
    let onDismiss: () -> Void

    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var showNotesPresented = false
    @State private var artworkImage: UIImage?
    @State private var artworkIsLoading = false

    private var layoutMode: IOSMediaPlayerLayoutMode {
        IOSMediaPlayerLayoutPolicy.mode(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
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
                    if let enclosureID = playbackState.loadedEnclosure?.id {
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
            seekPosition = Double(playbackState.positionMs)
        }
        .task(id: artworkTaskKey) {
            await loadArtwork()
        }
    }

    private var controls: some View {
        VStack(spacing: 24) {
            header

            if let duration = playbackState.durationMs, duration > 0 {
                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: {
                                isSeeking
                                    ? seekPosition
                                    : Double(playbackState.positionMs)
                            },
                            set: { seekPosition = $0 }
                        ),
                        in: 0...Double(duration),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if editing {
                                seekPosition = Double(playbackState.positionMs)
                            } else {
                                playbackCoordinator.seek(
                                    toMs: UInt64(max(0, seekPosition))
                                )
                            }
                        }
                    )

                    HStack {
                        Text(timeLabel(playbackState.positionMs))
                        Spacer()
                        Text(timeLabel(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 30) {
                Button {
                    playbackCoordinator.skip(bySeconds: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "Back 15 seconds"))

                Button {
                    togglePlayback()
                } label: {
                    Image(
                        systemName: playbackState.status == .playing
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 54))
                }
                .accessibilityLabel(
                    playbackState.status == .playing
                        ? String(localized: "Pause")
                        : String(localized: "Play")
                )

                Button {
                    playbackCoordinator.skip(bySeconds: 30)
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

            if playbackState.isLoading || playbackState.isBuffering {
                ProgressView(
                    playbackState.isBuffering
                        ? "Buffering…"
                        : "Loading…"
                )
            }

            if let error = playbackState.errorMessage {
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
            Text(
                playbackState.mediaTitle.isEmpty
                    ? String(localized: "Audio")
                    : playbackState.mediaTitle
            )
            .font(.title2.bold())
            .multilineTextAlignment(.center)

            if !playbackState.feedTitle.isEmpty {
                Text(playbackState.feedTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
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
    }

    private var chapterMenu: some View {
        Menu {
            if playbackState.chapters.isEmpty {
                Text("No Chapters")
            } else {
                ForEach(Array(playbackState.chapters.enumerated()), id: \.offset) { _, chapter in
                    Button {
                        playbackCoordinator.seek(toMs: chapter.startMs)
                    } label: {
                        Text(
                            chapter.title.isEmpty
                                ? timeLabel(chapter.startMs)
                                : chapter.title
                        )
                    }
                }
            }
        } label: {
            Label("Chapters", systemImage: "list.bullet.rectangle")
        }
        .disabled(playbackState.chapters.isEmpty)
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
        guard let source = playbackState.artworkSource else {
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
