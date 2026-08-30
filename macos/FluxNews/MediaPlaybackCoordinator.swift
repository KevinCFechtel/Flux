import AVFoundation
import Foundation
import MediaPlayer
import OSLog

enum MediaPlaybackPaths {
    static var mediaRootURL: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluxNews", isDirectory: true)
    }
}

@MainActor
protocol MediaPlaybackCore: AnyObject {
    func preparePlayback(enclosureId: Int64) throws -> PlaybackPreparation
    func checkpointPlayback(enclosureId: Int64, positionMs: UInt64, durationMs: UInt64?) throws
    func playbackCompleted(enclosureId: Int64, durationMs: UInt64?) throws
    func restartPlayback(enclosureId: Int64) throws
    func observeMediaDuration(enclosureId: Int64, durationMs: UInt64) throws
    func mediaChapters(enclosureId: Int64) throws -> [MediaChapter]
    func mediaArtwork(reference: String) throws -> Data?
}

@MainActor
protocol NativePlaybackEngine: AnyObject {
    var currentPositionMs: UInt64 { get }
    var durationMs: UInt64? { get }
    var isPlaying: Bool { get }
    var onEnded: (@MainActor () -> Void)? { get set }
    var onDuration: (@MainActor (UInt64) -> Void)? { get set }
    func load(url: URL, startAtMs: UInt64)
    func play()
    func pause()
    func seek(toMs: UInt64)
}

@MainActor
final class AVFoundationPlaybackEngine: NativePlaybackEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private(set) var currentPositionMs: UInt64 = 0
    private(set) var durationMs: UInt64?
    private(set) var isPlaying = false
    var onEnded: (@MainActor () -> Void)?
    var onDuration: (@MainActor (UInt64) -> Void)?

    func load(url: URL, startAtMs: UInt64) {
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.currentPositionMs = self.durationMs ?? self.currentPositionMs
                self.onEnded?()
            }
        }
        player.replaceCurrentItem(with: item)
        durationMs = Self.milliseconds(item.duration)
        if let durationMs { onDuration?(durationMs) }
        seek(toMs: startAtMs)
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); updatePosition(); isPlaying = false }

    func seek(toMs: UInt64) {
        let seconds = CMTime(seconds: Double(toMs) / 1_000, preferredTimescale: 1_000)
        player.seek(to: seconds) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePosition() }
        }
    }

    private func updatePosition() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        currentPositionMs = UInt64(seconds * 1_000)
    }

    private static func milliseconds(_ time: CMTime) -> UInt64? {
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return UInt64(seconds * 1_000)
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

@MainActor
final class MediaPlaybackCoordinator {
    private let core: MediaPlaybackCore
    private let engine: NativePlaybackEngine
    private let nowPlaying = MPNowPlayingInfoCenter.default()
    private var checkpointTimer: Timer?
    private var activeEnclosureID: Int64?
    private var completionSent = false
    private var preparedDurationMs: UInt64?
    private var preparedStatus: PlaybackStatus = .notStarted

    init(core: MediaPlaybackCore, engine: NativePlaybackEngine? = nil) {
        self.core = core
        let engine = engine ?? AVFoundationPlaybackEngine()
        self.engine = engine
        engine.onEnded = { @MainActor [weak self] in self?.handleNaturalEnd() }
        engine.onDuration = { @MainActor [weak self] duration in self?.handleDuration(duration) }
    }

    func prepare(enclosureID: Int64) throws -> PlaybackPreparation {
        try stopCurrentIfNeeded()
        let preparation = try core.preparePlayback(enclosureId: enclosureID)
        activeEnclosureID = enclosureID
        completionSent = false
        preparedDurationMs = preparation.durationMs ?? preparation.playbackState.durationMs
        preparedStatus = preparation.playbackState.status
        let source: URL
        if let localFile = preparation.localFile,
           let localURL = Self.safeLocalURL(localFile, under: MediaPlaybackPaths.mediaRootURL),
           FileManager.default.isReadableFile(atPath: localURL.path) {
            source = localURL
        } else if let remoteURL = URL(string: preparation.enclosure.url), remoteURL.scheme == "http" || remoteURL.scheme == "https" {
            source = remoteURL
        } else {
            throw MediaPlaybackError.invalidMediaURL
        }
        let startAt = preparation.playbackState.status == .inProgress ? preparation.playbackState.positionMs : 0
        engine.load(url: source, startAtMs: startAt)
        updateNowPlaying(preparation: preparation)
        return preparation
    }

    func play(enclosureID: Int64) throws {
        if activeEnclosureID != enclosureID { _ = try prepare(enclosureID: enclosureID) }
        guard activeEnclosureID == enclosureID else { return }
        guard preparedStatus != .completed else { return }
        engine.play()
        startCheckpointTimer()
        updateNowPlayingPlaybackState()
    }

    func pause() { engine.pause(); checkpoint(); stopCheckpointTimer(); updateNowPlayingPlaybackState() }
    func stop() { engine.pause(); checkpoint(); stopCheckpointTimer(); activeEnclosureID = nil; nowPlaying.playbackState = .stopped }

    func seek(toMs: UInt64) {
        engine.seek(toMs: toMs)
        checkpoint()
        updateNowPlayingPlaybackState()
    }

    func restart(enclosureID: Int64) throws {
        try core.restartPlayback(enclosureId: enclosureID)
        _ = try prepare(enclosureID: enclosureID)
        try play(enclosureID: enclosureID)
    }

    func chapters() throws -> [MediaChapter] {
        guard let activeEnclosureID else { return [] }
        return try core.mediaChapters(enclosureId: activeEnclosureID)
    }

    func artwork(reference: String) throws -> Data? { try core.mediaArtwork(reference: reference) }
    func isUsing(enclosureID: Int64) -> Bool { activeEnclosureID == enclosureID && engine.isPlaying }

    private func stopCurrentIfNeeded() throws {
        guard activeEnclosureID != nil else { return }
        checkpoint()
        engine.pause()
        stopCheckpointTimer()
    }

    private func checkpoint() {
        guard let activeEnclosureID else { return }
        do {
            try core.checkpointPlayback(enclosureId: activeEnclosureID, positionMs: engine.currentPositionMs, durationMs: engine.durationMs ?? preparedDurationMs)
        } catch {
            Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleNaturalEnd() {
        guard let activeEnclosureID, !completionSent else { return }
        completionSent = true
        preparedStatus = .completed
        stopCheckpointTimer()
        do { try core.playbackCompleted(enclosureId: activeEnclosureID, durationMs: engine.durationMs ?? preparedDurationMs) }
        catch { Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media completion failed: \(error.localizedDescription, privacy: .public)") }
        updateNowPlayingPlaybackState()
    }

    private func handleDuration(_ duration: UInt64) {
        preparedDurationMs = duration
        guard let activeEnclosureID else { return }
        do { try core.observeMediaDuration(enclosureId: activeEnclosureID, durationMs: duration) }
        catch { Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media duration observation failed: \(error.localizedDescription, privacy: .public)") }
        updateNowPlayingPlaybackState()
    }

    private func startCheckpointTimer() {
        guard checkpointTimer == nil else { return }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engine.isPlaying else { return }
                self.checkpoint()
                self.updateNowPlayingPlaybackState()
            }
        }
    }

    private func stopCheckpointTimer() { checkpointTimer?.invalidate(); checkpointTimer = nil }

    private func updateNowPlaying(preparation: PlaybackPreparation) {
        var info = [String: Any]()
        info[MPMediaItemPropertyPlaybackDuration] = (preparation.durationMs ?? preparation.playbackState.durationMs).map { Double($0) / 1_000 }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(preparation.playbackState.positionMs) / 1_000
        info[MPNowPlayingInfoPropertyAssetURL] = URL(string: preparation.enclosure.url)
        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = .paused
    }

    private func updateNowPlayingPlaybackState() {
        nowPlaying.playbackState = engine.isPlaying ? .playing : .paused
        guard var info = nowPlaying.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(engine.currentPositionMs) / 1_000
        nowPlaying.nowPlayingInfo = info
    }

    private static func safeLocalURL(_ reference: String, under root: URL) -> URL? {
        guard !reference.hasPrefix("/"), !reference.contains("..") else { return nil }
        let url = root.appendingPathComponent(reference).standardizedFileURL
        return url.path == root.standardizedFileURL.path || url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }
}

enum MediaPlaybackError: LocalizedError {
    case invalidMediaURL
    var errorDescription: String? { "The media URL is not playable." }
}

extension Flux: MediaPlaybackCore {}
