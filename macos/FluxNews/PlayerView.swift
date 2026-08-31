import AppKit
import SwiftUI

enum PlayerPresentation {
    static func navigationSymbol(showingPlayer: Bool) -> String {
        showingPlayer ? "list.bullet" : "waveform"
    }

    static func navigationDisabled(showingPlayer: Bool, hasLoadedMedia: Bool) -> Bool {
        !showingPlayer && !hasLoadedMedia
    }

    static func seekTarget(positionMs: UInt64, deltaMs: Int64, durationMs: UInt64?) -> UInt64 {
        let target: UInt64
        if deltaMs < 0 {
            let distance = UInt64(deltaMs.magnitude)
            target = positionMs > distance ? positionMs - distance : 0
        } else {
            let result = positionMs.addingReportingOverflow(UInt64(deltaMs))
            target = result.overflow ? UInt64.max : result.partialValue
        }
        return durationMs.map { min(target, $0) } ?? target
    }

    static func formatDuration(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func activeChapterIndex(positionMs: UInt64, chapters: [MediaChapter]) -> Int? {
        chapters.indices.last { index in
            let chapter = chapters[index]
            let end = chapter.endMs ?? chapters.dropFirst(index + 1).first?.startMs
            return positionMs >= chapter.startMs && (end == nil || positionMs < end!)
        }
    }
}

struct PlayerView: View {
    let store: BrowserStore
    @ObservedObject var state: MediaPlaybackPresentationState
    let coordinator: MediaPlaybackCoordinator?
    @ObservedObject private var sleepTimer: MediaSleepTimer
    @State private var isScrubbing = false
    @State private var scrubPositionMs = 0.0
    @State private var readerDocument: ReaderDocument?
    @State private var isLoadingReaderDocument = false
    @State private var readerError: String?
    @State private var readerRequest = 0

    init(store: BrowserStore, state: MediaPlaybackPresentationState, coordinator: MediaPlaybackCoordinator?) {
        self.store = store
        self.state = state
        self.coordinator = coordinator
        _sleepTimer = ObservedObject(wrappedValue: coordinator?.sleepTimer ?? MediaSleepTimer())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeline
                    controls
                    runtimeStatus
                    chapters
                    showNotes
                    advancedSettings
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: state.positionMs) { _, position in
            if !isScrubbing { scrubPositionMs = Double(position) }
        }
        .onAppear { loadReaderDocument() }
        .onChange(of: state.loadedEnclosure?.articleId) { _, _ in loadReaderDocument() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.feedTitle.isEmpty ? String(localized: "Unknown Feed") : state.feedTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(state.mediaTitle.isEmpty ? String(localized: "Untitled Media") : state.mediaTitle)
                .font(.headline)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let duration = state.durationMs, duration > 0 {
                Slider(value: sliderBinding, in: 0...Double(duration), onEditingChanged: finishScrubbing)
                    .accessibilityLabel("Playback timeline")
                    .accessibilityValue("")
                HStack {
                    Text(PlayerPresentation.formatDuration(currentPositionMs))
                    Spacer()
                    Text(PlayerPresentation.formatDuration(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Slider(value: .constant(0), in: 0...1)
                    .disabled(true)
                    .accessibilityLabel("Playback timeline unavailable")
                HStack {
                    Text(PlayerPresentation.formatDuration(currentPositionMs))
                    Spacer()
                    Text("--:--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            controlButton("gobackward.30", label: "Back 30 seconds") { seek(by: -30_000) }
            controlButton(state.status == .playing ? "pause.fill" : "play.fill", label: state.status == .playing ? "Pause" : "Play") { togglePlayback() }
                .disabled(state.isLoading || state.loadedEnclosure == nil)
            controlButton("stop.fill", label: "Stop") { coordinator?.stop() }
                .disabled(state.loadedEnclosure == nil)
            controlButton("goforward.30", label: "Forward 30 seconds") { seek(by: 30_000) }
            controlButton("arrow.counterclockwise", label: "Restart") { restart() }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var chapters: some View {
        if !state.chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chapters").font(.headline)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(state.chapters.enumerated()), id: \.offset) { index, chapter in
                                chapterRow(chapter, index: index)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: activeChapterIndex) { _, index in
                        guard let index else { return }
                        withAnimation { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
    }

    private func chapterRow(_ chapter: MediaChapter, index: Int) -> some View {
        let active = activeChapterIndex == index
        return Button {
            guard let coordinator, let enclosure = state.loadedEnclosure else { return }
            coordinator.seek(toMs: chapter.startMs)
            if state.status != .playing { try? coordinator.play(enclosureID: enclosure.id) }
        } label: {
            HStack(spacing: 8) {
                Text(PlayerPresentation.formatDuration(chapter.startMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(chapter.title.isEmpty ? String(localized: "Untitled Chapter") : chapter.title).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chapter.title.isEmpty ? String(localized: "Untitled Chapter") : chapter.title)
        .accessibilityValue(String(localized: "Starts at \(PlayerPresentation.formatDuration(chapter.startMs))") + (active ? String(localized: ", current chapter") : ""))
        .id(index)
    }

    @ViewBuilder private var showNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show Notes").font(.headline)
            if isLoadingReaderDocument {
                ProgressView("Loading Show Notes...").controlSize(.small)
            } else if let readerError {
                Label(readerError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let readerDocument {
                ReaderDocumentContent(document: readerDocument, openOriginal: openOriginal)
                    .textSelection(.enabled)
            } else {
                Text("Show Notes unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSettings: some View {
        DisclosureGroup("Advanced Settings") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Playback Speed")
                        Spacer()
                        Text(String(format: "%.1f×", state.playbackRate)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: speedBinding, in: 0.5...3.0, step: 0.1)
                        .accessibilityLabel("Playback Speed")
                        .accessibilityValue(String(format: "%.1f×", state.playbackRate))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Sleep Timer", isOn: Binding(get: { sleepTimer.isEnabled }, set: sleepTimer.setEnabled))
                    Picker("Duration", selection: Binding(get: { sleepTimer.intervalMinutes }, set: sleepTimer.setInterval)) {
                        ForEach(MediaSleepTimer.intervalsMinutes, id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .disabled(!sleepTimer.isEnabled)
                    if let remaining = sleepTimer.remainingSeconds {
                        Text("Stops in \(sleepTimerDescription(remaining))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var runtimeStatus: some View {
        if state.isLoading || state.isBuffering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state.isBuffering ? "Buffering..." : "Loading media...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if state.errorMessage != nil {
            Label("Playback failed. Try again.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentPositionMs: UInt64 {
        isScrubbing ? UInt64(max(0, scrubPositionMs)) : state.positionMs
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubPositionMs : Double(state.positionMs) },
            set: { scrubPositionMs = $0 }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { state.playbackRate }, set: { coordinator?.setPlaybackRate($0) })
    }

    private var activeChapterIndex: Int? {
        PlayerPresentation.activeChapterIndex(positionMs: state.positionMs, chapters: state.chapters)
    }

    private func sleepTimerDescription(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    private func loadReaderDocument() {
        readerRequest += 1
        let request = readerRequest
        guard let articleID = state.loadedEnclosure?.articleId else {
            readerDocument = nil
            isLoadingReaderDocument = false
            readerError = nil
            return
        }
        readerDocument = nil
        readerError = nil
        isLoadingReaderDocument = true
        store.loadReaderDocument(articleID: articleID) { result in
            guard request == readerRequest, state.loadedEnclosure?.articleId == articleID else { return }
            isLoadingReaderDocument = false
            switch result {
            case let .success(document): readerDocument = document
            case let .failure(error): readerError = NativeErrorPresentation.message(for: error)
            }
        }
    }

    private func openOriginal() {
        guard let articleID = state.loadedEnclosure?.articleId,
              let article = store.articles.first(where: { $0.id == articleID }) else { return }
        store.openOriginal(article)
    }

    private func finishScrubbing(_ editing: Bool) {
        if editing {
            scrubPositionMs = Double(state.positionMs)
            isScrubbing = true
        } else {
            isScrubbing = false
            coordinator?.seek(toMs: UInt64(max(0, scrubPositionMs)))
        }
    }

    private func togglePlayback() {
        guard let coordinator, let enclosure = state.loadedEnclosure else { return }
        if state.status == .playing {
            coordinator.pause()
        } else {
            try? coordinator.play(enclosureID: enclosure.id)
        }
    }

    private func seek(by deltaMs: Int64) {
        guard let coordinator else { return }
        coordinator.seek(toMs: PlayerPresentation.seekTarget(positionMs: state.positionMs, deltaMs: deltaMs, durationMs: state.durationMs))
    }

    private func restart() {
        guard let coordinator, let enclosure = state.loadedEnclosure else { return }
        try? coordinator.restart(enclosureID: enclosure.id)
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

}
