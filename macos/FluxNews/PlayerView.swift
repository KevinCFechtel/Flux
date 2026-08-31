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
}

struct PlayerView: View {
    @ObservedObject var state: MediaPlaybackPresentationState
    let coordinator: MediaPlaybackCoordinator?
    @State private var isScrubbing = false
    @State private var scrubPositionMs = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeline
                    controls
                    runtimeStatus
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: state.positionMs) { _, position in
            if !isScrubbing { scrubPositionMs = Double(position) }
        }
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
