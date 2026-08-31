import AppKit
import Combine
import Foundation
import MediaPlayer

struct NowPlayingProjection: Equatable {
    let title: String
    let sourceTitle: String
    let durationSeconds: Double?
    let elapsedSeconds: Double
    let effectivePlaybackRate: Double
    let defaultPlaybackRate: Double
    let playbackState: MediaPlaybackPresentationStatus
    let assetURL: URL?
    let artworkData: Data?

    @MainActor
    static func make(state: MediaPlaybackPresentationState, artworkData: Data? = nil) -> NowPlayingProjection? {
        guard let enclosure = state.loadedEnclosure else { return nil }
        return make(title: state.mediaTitle, sourceTitle: state.feedTitle, enclosureURL: enclosure.url, durationMs: state.durationMs, positionMs: state.positionMs, status: state.status, playbackRate: state.playbackRate, errorMessage: state.errorMessage, artworkData: artworkData)
    }

    static func make(title: String, sourceTitle: String, enclosureURL: String, durationMs: UInt64?, positionMs: UInt64, status: MediaPlaybackPresentationStatus, playbackRate: Double, errorMessage: String?, artworkData: Data? = nil) -> NowPlayingProjection {
        let duration = durationMs.flatMap { milliseconds in
            let seconds = Double(milliseconds) / 1_000
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        let rawElapsed = Double(positionMs) / 1_000
        let elapsed = rawElapsed.isFinite && rawElapsed >= 0
            ? min(rawElapsed, duration ?? rawElapsed)
            : 0
        let configuredRate = playbackRate.isFinite ? min(3.0, max(0.5, playbackRate)) : 1.0
        let isPlaying = status == .playing && errorMessage == nil
        let assetURL = URL(string: enclosureURL).flatMap { url in
            url.scheme == "http" || url.scheme == "https" ? url : nil
        }
        return NowPlayingProjection(
            title: title.isEmpty ? "FluxNews Audio" : title,
            sourceTitle: sourceTitle.isEmpty ? "FluxNews" : sourceTitle,
            durationSeconds: duration,
            elapsedSeconds: elapsed,
            effectivePlaybackRate: isPlaying ? configuredRate : 0,
            defaultPlaybackRate: configuredRate,
            playbackState: isPlaying ? .playing : status,
            assetURL: assetURL,
            artworkData: artworkData
        )
    }
}

enum MediaRemoteCommand: Equatable {
    case play
    case pause
    case toggle
    case skipBackward
    case skipForward
    case seek(seconds: Double)
}

@MainActor
final class MediaRemoteControlCoordinator {
    private let playbackCoordinator: MediaPlaybackCoordinator
    private let presentationState: MediaPlaybackPresentationState
    private let nowPlaying = MPNowPlayingInfoCenter.default()
    private var cancellables = Set<AnyCancellable>()
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var artworkGeneration = 0
    private var artworkReference: String?
    private var artworkData: Data?

    private(set) var registrationCount = 0

    init(playbackCoordinator: MediaPlaybackCoordinator, presentationState: MediaPlaybackPresentationState) {
        self.playbackCoordinator = playbackCoordinator
        self.presentationState = presentationState
        observePresentationState()
        start()
        publish()
    }

    func cleanup() {
        removeCommandTargets()
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .unknown
    }

    func start() {
        guard registrations.isEmpty else { return }
        registerCommands()
    }

    private func observePresentationState() {
        presentationState.$positionMs
            .sink { [weak self] _ in self?.publishElapsed() }
            .store(in: &cancellables)
        Publishers.MergeMany(
            presentationState.$loadedEnclosure.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$feedTitle.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$mediaTitle.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$artworkReference.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$status.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$durationMs.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$playbackRate.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$errorMessage.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.publish() }
        .store(in: &cancellables)
    }

    private func registerCommands() {
        registrationCount += 1

        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.stopCommand.isEnabled = false

        add(center.playCommand) { [weak self] _ in self?.dispatch(.play) ?? .commandFailed }
        add(center.pauseCommand) { [weak self] _ in self?.dispatch(.pause) ?? .commandFailed }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.dispatch(.toggle) ?? .commandFailed }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 30)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        add(center.skipBackwardCommand) { [weak self] _ in self?.dispatch(.skipBackward) ?? .commandFailed }
        add(center.skipForwardCommand) { [weak self] _ in self?.dispatch(.skipForward) ?? .commandFailed }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.dispatch(.seek(seconds: event.positionTime)) ?? .commandFailed
        }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        registrations.append((command, command.addTarget(handler: handler)))
    }

    private func removeCommandTargets() {
        for (command, token) in registrations { command.removeTarget(token) }
        registrations.removeAll()
    }

    func dispatch(_ command: MediaRemoteCommand) -> MPRemoteCommandHandlerStatus {
        switch command {
        case .play: return handlePlay()
        case .pause: return handlePause()
        case .toggle: return handleToggle()
        case .skipBackward: return handleSkip(seconds: -30)
        case .skipForward: return handleSkip(seconds: 30)
        case let .seek(seconds): return handleSeek(seconds: seconds)
        }
    }

    private func handlePlay() -> MPRemoteCommandHandlerStatus {
        guard let enclosureID = presentationState.loadedEnclosure?.id else { return .commandFailed }
        do {
            try playbackCoordinator.play(enclosureID: enclosureID)
            return .success
        } catch {
            return .commandFailed
        }
    }

    private func handlePause() -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else { return .commandFailed }
        playbackCoordinator.pause()
        return .success
    }

    private func handleToggle() -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else { return .commandFailed }
        if presentationState.status == .playing { playbackCoordinator.pause() }
        else { return handlePlay() }
        return .success
    }

    private func handleSkip(seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else { return .commandFailed }
        playbackCoordinator.skip(bySeconds: seconds)
        return .success
    }

    private func handleSeek(seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard seconds.isFinite, seconds >= 0, presentationState.loadedEnclosure != nil else { return .commandFailed }
        let bounded = presentationState.durationMs.map { min(seconds, Double($0) / 1_000) } ?? seconds
        guard bounded.isFinite else { return .commandFailed }
        playbackCoordinator.seek(toMs: UInt64(bounded * 1_000))
        return .success
    }

    private func publish() {
        guard let projection = NowPlayingProjection.make(state: presentationState, artworkData: artworkData) else {
            nowPlaying.nowPlayingInfo = nil
            nowPlaying.playbackState = .unknown
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: projection.title,
            MPMediaItemPropertyAlbumTitle: projection.sourceTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: projection.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: projection.effectivePlaybackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: projection.defaultPlaybackRate,
            MPNowPlayingInfoPropertyAssetURL: projection.assetURL as Any
        ]
        if let duration = projection.durationSeconds { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artworkData = projection.artworkData, let image = NSImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = projection.playbackState == .playing ? .playing : .paused
        requestArtworkIfNeeded()
    }

    private func publishElapsed() {
        guard let projection = NowPlayingProjection.make(state: presentationState, artworkData: artworkData), var info = nowPlaying.nowPlayingInfo else {
            publish()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = projection.elapsedSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = projection.effectivePlaybackRate
        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = projection.playbackState == .playing ? .playing : .paused
    }

    private func requestArtworkIfNeeded() {
        let reference = presentationState.artworkReference
        guard reference != artworkReference else { return }
        artworkReference = reference
        artworkData = nil
        artworkGeneration += 1
        let generation = artworkGeneration
        guard let reference else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = try? self.playbackCoordinator.artwork(reference: reference)
            guard self.artworkGeneration == generation, self.presentationState.artworkReference == reference else { return }
            self.artworkData = data ?? nil
            self.publish()
        }
    }
}
