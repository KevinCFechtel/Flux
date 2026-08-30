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
    func unload()
    func seek(toMs: UInt64)
}

@MainActor
final class AVFoundationPlaybackEngine: NativePlaybackEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var durationObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private(set) var currentPositionMs: UInt64 = 0
    private(set) var durationMs: UInt64?
    private(set) var isPlaying = false
    var onEnded: (@MainActor () -> Void)?
    var onDuration: (@MainActor (UInt64) -> Void)?

    func load(url: URL, startAtMs: UInt64) {
        let item = AVPlayerItem(url: url)
        removeObservers()
        observedItem = item
        currentPositionMs = 0
        durationMs = nil
        isPlaying = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.observedItem === item else { return }
                self.isPlaying = false
                self.currentPositionMs = self.durationMs ?? self.currentPositionMs
                self.onEnded?()
            }
        }
        player.replaceCurrentItem(with: item)
        observeDuration(for: item)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.observedItem === item else { return }
                self.updatePosition(time)
            }
        }
        seek(toMs: startAtMs)
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); updatePosition(); isPlaying = false }
    func unload() {
        player.pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        currentPositionMs = 0
        durationMs = nil
        isPlaying = false
    }

    func seek(toMs: UInt64) {
        let seconds = CMTime(seconds: Double(toMs) / 1_000, preferredTimescale: 1_000)
        player.seek(to: seconds) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePosition() }
        }
    }

    private func observeDuration(for item: AVPlayerItem) {
        durationObservation = item.observe(\AVPlayerItem.duration, options: [.initial, .new]) { [weak self, weak observedItem = item] _, _ in
            guard let observedItem else { return }
            Task { @MainActor [weak self, weak observedItem] in
                guard let self, let observedItem, self.observedItem === observedItem else { return }
                self.updateDuration(observedItem.duration)
            }
        }
        updateDuration(item.duration)
    }

    private func updateDuration(_ time: CMTime) {
        guard let duration = Self.milliseconds(time, requiresPositive: true), durationMs != duration else { return }
        durationMs = duration
        onDuration?(duration)
    }

    private func updatePosition() { updatePosition(player.currentTime()) }

    private func updatePosition(_ time: CMTime) {
        guard let position = Self.milliseconds(time, requiresPositive: false) else { return }
        currentPositionMs = position
    }

    static func milliseconds(_ time: CMTime, requiresPositive: Bool) -> UInt64? {
        guard time.isValid, time.isNumeric else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0, (!requiresPositive || seconds > 0) else { return nil }
        let milliseconds = seconds * 1_000
        guard milliseconds <= Double(UInt64.max) else { return nil }
        return UInt64(milliseconds)
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        durationObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        observedItem = nil
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}

@MainActor
final class MediaPlaybackCoordinator {
    private let core: MediaPlaybackCore
    private let engine: NativePlaybackEngine
    private let nowPlaying = MPNowPlayingInfoCenter.default()
    private let checkpointInterval: TimeInterval
    private var checkpointTimer: Timer?
    private var activeEnclosureID: Int64?
    private var completionSent = false
    private var preparedDurationMs: UInt64?
    private var lastObservedDurationMs: UInt64?
    private var preparedStatus: PlaybackStatus = .notStarted

    init(core: MediaPlaybackCore, engine: NativePlaybackEngine? = nil, checkpointInterval: TimeInterval = 20) {
        self.core = core
        self.checkpointInterval = checkpointInterval
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
        lastObservedDurationMs = preparedDurationMs
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
    func stop() { engine.pause(); checkpoint(); stopCheckpointTimer(); engine.unload(); activeEnclosureID = nil; nowPlaying.playbackState = .stopped }
    func applicationDidResignActive() { checkpoint() }
    func applicationWillTerminate() { checkpoint(); stopCheckpointTimer(); engine.unload() }

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
    func isUsing(enclosureID: Int64) -> Bool { activeEnclosureID == enclosureID }

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
        guard lastObservedDurationMs != duration else { return }
        lastObservedDurationMs = duration
        preparedDurationMs = duration
        guard let activeEnclosureID else { return }
        do { try core.observeMediaDuration(enclosureId: activeEnclosureID, durationMs: duration) }
        catch { Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media duration observation failed: \(error.localizedDescription, privacy: .public)") }
        updateNowPlayingPlaybackState()
    }

    private func startCheckpointTimer() {
        guard checkpointTimer == nil else { return }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: checkpointInterval, repeats: true) { [weak self] _ in
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
