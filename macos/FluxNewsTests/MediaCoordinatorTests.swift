import Foundation
import AVFoundation
import XCTest
@testable import FluxNews

@MainActor
private final class FakePlaybackCore: MediaPlaybackCore {
    var preparation: PlaybackPreparation
    var checkpoints = [(Int64, UInt64, UInt64?)]()
    var completions = [(Int64, UInt64?)]()
    var restartCount = 0
    var observedDurations = [(Int64, UInt64)]()
    var chapters = [MediaChapter]()

    init(status: PlaybackStatus = .notStarted, positionMs: UInt64 = 0) {
        let enclosure = Enclosure(id: 7, articleId: 11, url: "https://example.test/audio.mp3", mimeType: "audio/mpeg", sizeBytes: nil, remoteMediaProgressionSeconds: 0, mediaKind: .audio)
        preparation = PlaybackPreparation(
            enclosure: enclosure,
            playbackState: PlaybackState(enclosureId: 7, positionMs: positionMs, durationMs: 120_000, status: status, updatedAt: nil),
            localFile: nil,
            durationMs: 120_000,
            artworkReference: nil
        )
    }

    func preparePlayback(enclosureId: Int64) throws -> PlaybackPreparation { preparation }
    func savedMedia() throws -> [SavedPlayableMediaItem] { [] }
    func checkpointPlayback(enclosureId: Int64, positionMs: UInt64, durationMs: UInt64?) throws { checkpoints.append((enclosureId, positionMs, durationMs)) }
    func playbackCompleted(enclosureId: Int64, durationMs: UInt64?) throws { completions.append((enclosureId, durationMs)) }
    func restartPlayback(enclosureId: Int64) throws { restartCount += 1; preparation.playbackState = PlaybackState(enclosureId: 7, positionMs: 0, durationMs: 120_000, status: .inProgress, updatedAt: nil) }
    func observeMediaDuration(enclosureId: Int64, durationMs: UInt64) throws { observedDurations.append((enclosureId, durationMs)) }
    func mediaChapters(enclosureId: Int64) throws -> [MediaChapter] { chapters }
    func mediaArtwork(reference: String) throws -> Data? { nil }
}

@MainActor
private final class FakePlaybackEngine: NativePlaybackEngine {
    var currentPositionMs: UInt64 = 0
    var durationMs: UInt64? = nil
    var isPlaying = false
    var rate = 1.0
    var onEnded: (@MainActor () -> Void)?
    var onDuration: (@MainActor (UInt64) -> Void)?
    var onPosition: (@MainActor (UInt64) -> Void)?
    var onLoadingChanged: (@MainActor (Bool) -> Void)?
    var onBufferingChanged: (@MainActor (Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var loadedStartMs: UInt64?
    var playCount = 0
    var unloadCount = 0

    func load(url: URL, startAtMs: UInt64) { loadedStartMs = startAtMs; currentPositionMs = startAtMs; durationMs = 120_000; onLoadingChanged?(true); onPosition?(startAtMs) }
    func play() { isPlaying = true; playCount += 1 }
    func pause() { isPlaying = false }
    func unload() { unloadCount += 1; isPlaying = false; currentPositionMs = 0; durationMs = nil }
    func seek(toMs: UInt64) { currentPositionMs = toMs; onPosition?(toMs) }
    func finish() { isPlaying = false; onEnded?() }
    func emitDuration(_ duration: UInt64) { onDuration?(duration) }
    func emitReady() { onLoadingChanged?(false) }
}

@MainActor
private final class FakeTransferCore: MediaTransferCore {
    var policy: DownloadNetworkPolicy = .anyNetwork
    var transfers: [MediaTransferWork] = []
    var deletions: [MediaTransferWork] = []
    var states = [Int64: DownloadState]()
    var finished = [(Int64, String, UInt64)]()
    var failures = [(Int64, DownloadFailureKind)]()
    var deleted = [Int64]()
    var onFinished: (() -> Void)?
    var onFailure: (() -> Void)?

    func coreSettings() throws -> CoreSettings {
        CoreSettings(retention: .days30, deliveryMode: .live, backgroundSyncEnabled: false, detailCharacterLimit: 10_000, downloadNetworkPolicy: policy, downloadRetention: .forever, deleteAfterPlayback: false, autoDownloadListeningList: false, removeCompletedListeningList: false)
    }
    func downloadsRequiringTransfer() throws -> [MediaTransferWork] { transfers }
    func downloadsRequiringDeletion() throws -> [MediaTransferWork] { deletions }
    func downloadFinished(enclosureId: Int64, localFile: String, fileSizeBytes: UInt64) throws {
        finished.append((enclosureId, localFile, fileSizeBytes))
        if states[enclosureId] == .requested { states[enclosureId] = .downloaded }
        onFinished?()
    }
    func downloadFailed(enclosureId: Int64, failureKind: DownloadFailureKind) throws {
        failures.append((enclosureId, failureKind))
        if states[enclosureId] == .requested { states[enclosureId] = .failed }
        onFailure?()
    }
    func downloadDeleted(enclosureId: Int64) throws {
        deleted.append(enclosureId)
        if states[enclosureId] == .deleteRequested { states[enclosureId] = .notDownloaded }
    }
}

private actor FakeTransferEngine: MediaTransferEngine {
    enum Result {
        case immediate(NativeTransferResult)
        case failure(Error)
        case pending
    }

    var result: Result
    private(set) var callCount = 0
    private var progressCallbacks: [@Sendable (Int64, Int64?) -> Void] = []
    private var continuations = [CheckedContinuation<NativeTransferResult, Error>]()

    init(result: Result) { self.result = result }

    func download(from url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> NativeTransferResult {
        callCount += 1
        progressCallbacks.append(progress)
        switch result {
        case let .immediate(value): return value
        case let .failure(error): throw error
        case .pending:
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
    }

    func emitProgress(index: Int, bytesReceived: Int64, expectedBytes: Int64?) {
        progressCallbacks[index](bytesReceived, expectedBytes)
    }

    func resolveAll(_ result: Result) {
        let pending = continuations
        continuations = []
        for continuation in pending {
            switch result {
            case let .immediate(value): continuation.resume(returning: value)
            case let .failure(error): continuation.resume(throwing: error)
            case .pending: break
            }
        }
    }
}

private func transferWork(_ id: Int64 = 7, localFile: String? = nil) -> MediaTransferWork {
    MediaTransferWork(enclosureId: id, url: "https://example.test/episode.mp3", origin: .manual, localFile: localFile)
}

@MainActor
final class MediaCoordinatorTests: XCTestCase {
    func testArticleAudioActionsOnlyExposeCoreAudioEnclosures() {
        let audio = Enclosure(id: 1, articleId: 11, url: "https://example.test/Episode%201.mp3", mimeType: "audio/mpeg", sizeBytes: 100, remoteMediaProgressionSeconds: 0, mediaKind: .audio)
        let video = Enclosure(id: 2, articleId: 11, url: "https://example.test/video.mp4", mimeType: "video/mp4", sizeBytes: nil, remoteMediaProgressionSeconds: 0, mediaKind: .video)

        XCTAssertEqual(ArticleAudioActions.audioEnclosures([audio, video]), [audio])
        let label = ArticleAudioActions.enclosureLabel(audio, index: 0)
        XCTAssertTrue(label.hasPrefix("Episode 1.mp3 (audio/mpeg"))
        XCTAssertTrue(label.contains("100"))
        XCTAssertEqual(ArticleAudioActions.audioEnclosures([video]), [])
    }

    func testArticleAudioActionsReplacementOnlyAppliesToDifferentPlayingEnclosure() {
        XCTAssertTrue(ArticleAudioActions.requiresReplacement(currentID: 1, currentStatus: .playing, selectedID: 2))
        XCTAssertFalse(ArticleAudioActions.requiresReplacement(currentID: 1, currentStatus: .paused, selectedID: 2))
        XCTAssertFalse(ArticleAudioActions.requiresReplacement(currentID: 1, currentStatus: .stopped, selectedID: 2))
        XCTAssertFalse(ArticleAudioActions.requiresReplacement(currentID: 1, currentStatus: .playing, selectedID: 1))
    }

    func testArticleAudioActionsAvoidDuplicateDownloadRequests() {
        let enclosure = Enclosure(id: 1, articleId: 11, url: "https://example.test/audio.mp3", mimeType: "audio/mpeg", sizeBytes: nil, remoteMediaProgressionSeconds: 0, mediaKind: .audio)
        let state = ArticleAudioActionState(articleID: 11, enclosures: [enclosure], isInListeningList: true, downloads: [:])
        XCTAssertTrue(ArticleAudioActions.canRequestDownload(state.downloads[1]))
        for downloadState in [DownloadState.requested, .downloaded, .deleteRequested] {
            let download = MediaDownload(enclosureId: 1, state: downloadState, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil)
            XCTAssertFalse(ArticleAudioActions.canRequestDownload(download))
        }
        XCTAssertTrue(ArticleAudioActions.canRequestDownload(MediaDownload(enclosureId: 1, state: .failed, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: .network)))
    }

    func testArticleAudioActionsExposeCoherentDownloadManagementStates() {
        XCTAssertEqual(ArticleAudioActions.downloadAction(nil), .download)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .notDownloaded, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil)), .download)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .failed, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: .network)), .retry)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .requested, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil)), .pending)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .downloaded, origin: .manual, localFile: "/tmp/episode.mp3", fileSizeBytes: 10, downloadedAt: nil, failureKind: nil)), .delete)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .deleteRequested, origin: .manual, localFile: "/tmp/episode.mp3", fileSizeBytes: 10, downloadedAt: nil, failureKind: nil)), .pendingDeletion)
        let requested = MediaDownload(enclosureId: 1, state: .requested, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil)
        XCTAssertEqual(ArticleAudioActions.downloadAction(requested), .pending)
        XCTAssertEqual(ArticleAudioActions.downloadAction(requested, runtime: MediaTransferRuntime(enclosureID: 1, bytesReceived: 42, expectedBytes: 100, phase: .transferring)), .downloading)
        XCTAssertEqual(ArticleAudioActions.downloadAction(MediaDownload(enclosureId: 1, state: .downloaded, origin: .manual, localFile: nil, fileSizeBytes: nil, downloadedAt: nil, failureKind: nil), runtime: MediaTransferRuntime(enclosureID: 1, bytesReceived: 100, expectedBytes: 100, phase: .transferring)), .delete)
    }

    func testTransferRuntimeProgressValidatesAndClampsFractions() {
        XCTAssertEqual(MediaTransferRuntime(enclosureID: 1, bytesReceived: 42, expectedBytes: 100, phase: .transferring).fraction, 0.42)
        XCTAssertEqual(MediaTransferRuntime(enclosureID: 1, bytesReceived: 120, expectedBytes: 100, phase: .transferring).fraction, 1)
        XCTAssertNil(MediaTransferRuntime(enclosureID: 1, bytesReceived: 42, expectedBytes: nil, phase: .transferring).fraction)
        XCTAssertNil(MediaTransferRuntime(enclosureID: 1, bytesReceived: 42, expectedBytes: 0, phase: .transferring).fraction)
        XCTAssertNil(MediaTransferRuntime(enclosureID: 1, bytesReceived: -1, expectedBytes: 100, phase: .transferring).fraction)
    }

    func testPlaybackUseChangesReconcileDeferredCoreWork() throws {
        let core = FakePlaybackCore()
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
        var callbackCount = 0
        coordinator.onPlaybackUseChanged = { callbackCount += 1 }

        _ = try coordinator.prepare(enclosureID: 7)
        XCTAssertEqual(callbackCount, 1)
        try coordinator.play(enclosureID: 7)
        engine.finish()
        XCTAssertEqual(callbackCount, 2)
    }

    func testInProgressStartsAtCorePositionAndPauseCheckpoints() throws {
        let core = FakePlaybackCore(status: .inProgress, positionMs: 35_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        _ = try coordinator.prepare(enclosureID: 7)
        XCTAssertEqual(engine.loadedStartMs, 35_000)
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 36_000
        coordinator.pause()

        XCTAssertEqual(core.checkpoints.map(\.1), [36_000])
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
    }

    func testPeriodicCheckpointUsesPositionWhilePlaybackRuns() async throws {
        let core = FakePlaybackCore(status: .inProgress)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine, checkpointInterval: 0.01)
        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 42_000

        let deadline = Date().addingTimeInterval(1)
        while core.checkpoints.isEmpty && Date() < deadline { await Task.yield() }
        XCTAssertEqual(core.checkpoints.first?.1, 42_000)
    }

    func testDeactivationCheckpointsWithoutPausingPlayback() throws {
        let core = FakePlaybackCore(status: .inProgress)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 18_000

        coordinator.applicationDidResignActive()

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 18_000)
    }

    func testStopKeepsNativePlaybackItemLoaded() throws {
        let core = FakePlaybackCore(status: .inProgress)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
        try coordinator.play(enclosureID: 7)

        coordinator.stop()

        XCTAssertEqual(engine.unloadCount, 0)
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
        XCTAssertEqual(coordinator.presentationState.status, .stopped)
    }

    func testPlaybackRateIsClampedToContractAndAppliedToEngine() throws {
        let core = FakePlaybackCore()
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        _ = try coordinator.prepare(enclosureID: 7)
        for rate in [0.5, 1.0, 1.7, 3.0] {
            coordinator.setPlaybackRate(rate)
            XCTAssertEqual(engine.rate, rate)
            XCTAssertEqual(coordinator.presentationState.playbackRate, rate)
            XCTAssertFalse(engine.isPlaying)
        }
        coordinator.setPlaybackRate(3.7)
        XCTAssertEqual(engine.rate, 3.0)
        coordinator.setPlaybackRate(0.44)
        XCTAssertEqual(engine.rate, 0.5)
        coordinator.setPlaybackRate(.nan)
        XCTAssertEqual(engine.rate, 0.5)
        XCTAssertEqual(coordinator.presentationState.playbackRate, 0.5)
    }

    func testAsynchronousDurationIsObservedOnlyWhenItChanges() throws {
        let core = FakePlaybackCore()
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
        _ = try coordinator.prepare(enclosureID: 7)

        engine.emitDuration(130_000)
        engine.emitDuration(130_000)

        XCTAssertEqual(core.observedDurations.count, 1)
        XCTAssertEqual(core.observedDurations[0].0, 7)
        XCTAssertEqual(core.observedDurations[0].1, 130_000)
    }

    func testInvalidAVPlayerDurationsAreIgnored() {
        XCTAssertNil(AVFoundationPlaybackEngine.milliseconds(.invalid, requiresPositive: true))
        XCTAssertNil(AVFoundationPlaybackEngine.milliseconds(.indefinite, requiresPositive: true))
        XCTAssertNil(AVFoundationPlaybackEngine.milliseconds(CMTime.zero, requiresPositive: true))
        XCTAssertNil(AVFoundationPlaybackEngine.milliseconds(CMTime(seconds: -1, preferredTimescale: 1_000), requiresPositive: true))
        XCTAssertEqual(AVFoundationPlaybackEngine.milliseconds(CMTime(seconds: 12.5, preferredTimescale: 1_000), requiresPositive: true), 12_500)
    }

    func testCompletedDoesNotImplicitlyRestartAndExplicitRestartUsesCore() throws {
        let core = FakePlaybackCore(status: .completed, positionMs: 120_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        _ = try coordinator.prepare(enclosureID: 7)
        try coordinator.play(enclosureID: 7)
        XCTAssertEqual(engine.playCount, 0)

        try coordinator.restart(enclosureID: 7)
        XCTAssertEqual(core.restartCount, 1)
        XCTAssertEqual(engine.playCount, 1)
    }

    func testPlayerTimelineFormattingAndSeekBounds() {
        XCTAssertEqual(PlayerPresentation.navigationSymbol(showingPlayer: false), "waveform")
        XCTAssertEqual(PlayerPresentation.navigationSymbol(showingPlayer: true), "list.bullet")
        XCTAssertTrue(PlayerPresentation.navigationDisabled(showingPlayer: false, hasLoadedMedia: false))
        XCTAssertFalse(PlayerPresentation.navigationDisabled(showingPlayer: false, hasLoadedMedia: true))
        XCTAssertFalse(PlayerPresentation.navigationDisabled(showingPlayer: true, hasLoadedMedia: false))
        XCTAssertEqual(PlayerPresentation.formatDuration(0), "0:00")
        XCTAssertEqual(PlayerPresentation.formatDuration(65_000), "1:05")
        XCTAssertEqual(PlayerPresentation.formatDuration(3_725_000), "1:02:05")
        XCTAssertEqual(PlayerPresentation.seekTarget(positionMs: 10_000, deltaMs: -30_000, durationMs: 120_000), 0)
        XCTAssertEqual(PlayerPresentation.seekTarget(positionMs: 110_000, deltaMs: 30_000, durationMs: 120_000), 120_000)
        XCTAssertEqual(PlayerPresentation.seekTarget(positionMs: 10_000, deltaMs: 30_000, durationMs: nil), 40_000)
    }

    func testChaptersLoadAndActiveChapterUsesNextStartWhenEndIsMissing() throws {
        let core = FakePlaybackCore()
        core.chapters = [
            MediaChapter(enclosureId: 7, title: "Intro", startMs: 0, endMs: nil, source: .articleContent),
            MediaChapter(enclosureId: 7, title: "Interview", startMs: 60_000, endMs: nil, source: .articleContent)
        ]
        let coordinator = MediaPlaybackCoordinator(core: core, engine: FakePlaybackEngine())

        _ = try coordinator.prepare(enclosureID: 7)

        XCTAssertEqual(coordinator.presentationState.chapters.map(\.title), ["Intro", "Interview"])
        XCTAssertEqual(PlayerPresentation.activeChapterIndex(positionMs: 30_000, chapters: core.chapters), 0)
        XCTAssertEqual(PlayerPresentation.activeChapterIndex(positionMs: 60_000, chapters: core.chapters), 1)
        XCTAssertEqual(PlayerPresentation.activeChapterIndex(positionMs: 120_000, chapters: core.chapters), 1)
    }

    func testChapterEndBoundsActiveChapter() {
        let chapters = [
            MediaChapter(enclosureId: 7, title: "Intro", startMs: 0, endMs: 30_000, source: .embedded),
            MediaChapter(enclosureId: 7, title: "Main", startMs: 30_000, endMs: 90_000, source: .embedded)
        ]

        XCTAssertEqual(PlayerPresentation.activeChapterIndex(positionMs: 29_999, chapters: chapters), 0)
        XCTAssertEqual(PlayerPresentation.activeChapterIndex(positionMs: 30_000, chapters: chapters), 1)
        XCTAssertNil(PlayerPresentation.activeChapterIndex(positionMs: 90_000, chapters: chapters))
    }

    func testSleepTimerFiringPausesAndCheckpointsWithoutUnloading() throws {
        let core = FakePlaybackCore(status: .inProgress, positionMs: 12_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 24_000

        XCTAssertFalse(coordinator.sleepTimer.isEnabled)
        coordinator.sleepTimer.setEnabled(true)
        coordinator.sleepTimer.evaluate(at: Date().addingTimeInterval(31 * 60))

        XCTAssertFalse(coordinator.sleepTimer.isEnabled)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 24_000)
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
        XCTAssertEqual(coordinator.presentationState.status, .paused)
    }

    func testNowPlayingProjectionSanitizesMetadataAndPlaybackValues() {
        let projection = NowPlayingProjection.make(
            title: "",
            sourceTitle: "",
            enclosureURL: "file:///not-published",
            durationMs: 0,
            positionMs: 90_000,
            status: .playing,
            playbackRate: .infinity,
            errorMessage: "network error"
        )

        XCTAssertEqual(projection.title, "FluxNews Audio")
        XCTAssertEqual(projection.sourceTitle, "FluxNews")
        XCTAssertNil(projection.durationSeconds)
        XCTAssertEqual(projection.elapsedSeconds, 90)
        XCTAssertEqual(projection.effectivePlaybackRate, 0)
        XCTAssertEqual(projection.defaultPlaybackRate, 1)
        XCTAssertEqual(projection.playbackState, .playing)
        XCTAssertNil(projection.assetURL)
    }

    func testRemoteCommandsDelegateToPlaybackCoordinatorAndRegistrationIsIdempotent() throws {
        let core = FakePlaybackCore()
        let engine = FakePlaybackEngine()
        let playback = MediaPlaybackCoordinator(core: core, engine: engine)
        _ = try playback.prepare(enclosureID: 7)
        let remote = MediaRemoteControlCoordinator(playbackCoordinator: playback, presentationState: playback.presentationState)
        defer { remote.cleanup() }

        XCTAssertEqual(remote.registrationCount, 1)
        remote.start()
        XCTAssertEqual(remote.registrationCount, 1)
        XCTAssertEqual(remote.dispatch(.play), .success)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(remote.dispatch(.pause), .success)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(remote.dispatch(.seek(seconds: 45)), .success)
        XCTAssertEqual(engine.currentPositionMs, 45_000)
        XCTAssertEqual(remote.dispatch(.skipForward), .success)
        XCTAssertEqual(engine.currentPositionMs, 75_000)
        XCTAssertEqual(remote.dispatch(.skipBackward), .success)
        XCTAssertEqual(engine.currentPositionMs, 45_000)
    }

    func testSleepTimerIntervalChangeRestartsAndDisableClearsState() {
        let timer = MediaSleepTimer()
        timer.setEnabled(true)
        timer.setInterval(90)
        XCTAssertEqual(timer.intervalMinutes, 90)
        XCTAssertTrue(timer.isEnabled)
        XCTAssertEqual(timer.remainingSeconds, 90 * 60)
        timer.setEnabled(false)
        XCTAssertFalse(timer.isEnabled)
        XCTAssertNil(timer.remainingSeconds)
    }

    func testRestartPreservesPausedAndStoppedState() throws {
        for expectedStatus in [MediaPlaybackPresentationStatus.paused, .stopped] {
            let core = FakePlaybackCore(status: .inProgress, positionMs: 20_000)
            let engine = FakePlaybackEngine()
            let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)
            _ = try coordinator.prepare(enclosureID: 7)
            if expectedStatus == .stopped { coordinator.stop() } else { coordinator.pause() }

            try coordinator.restart(enclosureID: 7)

            XCTAssertEqual(coordinator.presentationState.status, expectedStatus)
            XCTAssertEqual(engine.playCount, 0)
            XCTAssertEqual(engine.currentPositionMs, 0)
        }
    }

    func testReadyPlaybackItemClearsLoadingState() throws {
        let core = FakePlaybackCore()
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        _ = try coordinator.prepare(enclosureID: 7)
        XCTAssertTrue(coordinator.presentationState.isLoading)
        engine.emitReady()
        XCTAssertFalse(coordinator.presentationState.isLoading)
    }

    func testNaturalEndCompletesOnceAndCheckpointDoesNotComplete() throws {
        let core = FakePlaybackCore(status: .inProgress, positionMs: 1_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 50_000
        coordinator.seek(toMs: 50_000)
        XCTAssertTrue(core.completions.isEmpty)
        engine.finish()
        engine.finish()

        XCTAssertEqual(core.completions.count, 1)
        XCTAssertEqual(core.completions[0].1, 120_000)
    }

    func testTransferReferencesStayInsideMediaRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/flux-media")
        XCTAssertEqual(try MediaTransferFileLayout.destination(reference: "downloads/enclosure-7.media", under: root).path, "/tmp/flux-media/downloads/enclosure-7.media")
        XCTAssertThrowsError(try MediaTransferFileLayout.destination(reference: "../outside", under: root))
        XCTAssertThrowsError(try MediaTransferFileLayout.destination(reference: "/tmp/outside", under: root))
    }

    func testReconcileStartsOneTransferForOneRequestedEnclosure() async throws {
        let core = FakeTransferCore()
        core.transfers = [transferWork()]
        core.states[7] = .requested
        let engine = FakeTransferEngine(result: .pending)
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: temporaryMediaRoot(), engine: engine)

        coordinator.reconcile()
        coordinator.reconcile()
        await settle()

        let calls = await engine.callCount
        XCTAssertEqual(calls, 1)
    }

    func testStaleTransferProgressCannotOverwriteReplacementTask() async throws {
        let core = FakeTransferCore()
        core.transfers = [transferWork()]
        let engine = FakeTransferEngine(result: .pending)
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: temporaryMediaRoot(), engine: engine)

        coordinator.reconcile()
        await settle()
        await engine.emitProgress(index: 0, bytesReceived: 10, expectedBytes: 100)
        await settle()
        XCTAssertEqual(coordinator.presentationState.runtime(for: 7)?.bytesReceived, 10)

        core.transfers = []
        coordinator.reconcile()
        core.transfers = [transferWork()]
        coordinator.reconcile()
        await settle()
        await engine.emitProgress(index: 0, bytesReceived: 90, expectedBytes: 100)
        await engine.emitProgress(index: 1, bytesReceived: 20, expectedBytes: 100)
        await settle()

        XCTAssertEqual(coordinator.presentationState.runtime(for: 7)?.bytesReceived, 20)
    }

    func testCancellationReconciliationCancelsWithoutFailureAndLateCompletionStaysStale() async throws {
        let core = FakeTransferCore()
        core.transfers = [transferWork()]
        core.states[7] = .requested
        let engine = FakeTransferEngine(result: .pending)
        let root = temporaryMediaRoot()
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: root, engine: engine)

        coordinator.reconcile()
        await Task.yield()
        core.transfers = []
        core.states[7] = .notDownloaded
        coordinator.reconcile()

        let temporary = root.appendingPathComponent("late.media")
        try Data("late".utf8).write(to: temporary)
        await engine.resolveAll(.immediate(NativeTransferResult(temporaryURL: temporary)))
        await settle()

        XCTAssertTrue(core.failures.isEmpty)
        XCTAssertEqual(core.states[7], .notDownloaded)
        XCTAssertEqual(core.finished.count, 1)
    }

    func testFreshCoordinatorReconstructsRequestedAndDeleteRequestedWork() async throws {
        let core = FakeTransferCore()
        core.transfers = [transferWork()]
        core.states[7] = .requested
        let engine = FakeTransferEngine(result: .pending)
        let root = temporaryMediaRoot()
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: root, engine: engine)

        coordinator.reconcile()
        await settle()
        let calls = await engine.callCount
        XCTAssertEqual(calls, 1)

        let local = root.appendingPathComponent("downloads/enclosure-7.media")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: local)
        core.transfers = []
        core.deletions = [transferWork(localFile: "downloads/enclosure-7.media")]
        core.states[7] = .deleteRequested
        let fresh = MediaTransferCoordinator(core: core, mediaRoot: root, engine: engine)
        fresh.reconcile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(core.deleted, [7])
        let late = root.appendingPathComponent("late.media")
        try Data("late".utf8).write(to: late)
        await engine.resolveAll(.immediate(NativeTransferResult(temporaryURL: late)))
        await settle()
    }

    func testSuccessfulTransferPlacesFileBeforeFinishedCallback() async throws {
        let root = temporaryMediaRoot()
        let temporary = root.appendingPathComponent("temporary.media")
        try Data("media".utf8).write(to: temporary)
        let core = FakeTransferCore()
        core.transfers = [transferWork()]
        core.states[7] = .requested
        let engine = FakeTransferEngine(result: .immediate(NativeTransferResult(temporaryURL: temporary)))
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: root, engine: engine)
        let finished = expectation(description: "download finished")
        core.onFinished = { finished.fulfill() }

        coordinator.reconcile()
        await fulfillment(of: [finished], timeout: 2)

        let destination = root.appendingPathComponent("downloads/enclosure-7.media")
        XCTAssertEqual(core.finished.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(core.finished[0].1, "downloads/enclosure-7.media")
        XCTAssertEqual(core.states[7], .downloaded)
        XCTAssertNil(coordinator.presentationState.runtime(for: 7))
    }

    func testNetworkAndStorageFailuresUseNarrowFailureKinds() async throws {
        let networkCore = FakeTransferCore()
        networkCore.transfers = [transferWork()]
        networkCore.states[7] = .requested
        let network = MediaTransferCoordinator(core: networkCore, mediaRoot: temporaryMediaRoot(), engine: FakeTransferEngine(result: .failure(MediaTransferError.network)))
        let networkFailure = expectation(description: "network failure")
        networkCore.onFailure = { networkFailure.fulfill() }
        network.reconcile()
        await fulfillment(of: [networkFailure], timeout: 2)

        let storageCore = FakeTransferCore()
        storageCore.transfers = [transferWork()]
        storageCore.states[7] = .requested
        let root = temporaryMediaRoot()
        let invalidRoot = root.appendingPathComponent("not-a-directory")
        try Data("not a directory".utf8).write(to: invalidRoot)
        let temporary = root.appendingPathComponent("storage-temporary.media")
        try Data("media".utf8).write(to: temporary)
        let storage = MediaTransferCoordinator(core: storageCore, mediaRoot: invalidRoot, engine: FakeTransferEngine(result: .immediate(NativeTransferResult(temporaryURL: temporary))))
        let storageFailure = expectation(description: "storage failure")
        storageCore.onFailure = { storageFailure.fulfill() }
        storage.reconcile()
        await fulfillment(of: [storageFailure], timeout: 2)

        XCTAssertEqual(networkCore.failures.map { $0.1 }, [.network])
        XCTAssertEqual(storageCore.failures.map { $0.1 }, [.storage])
    }

    func testDeletionIsIdempotentAndDeferredWhilePlaying() throws {
        let root = temporaryMediaRoot()
        let local = root.appendingPathComponent("downloads/enclosure-7.media")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: local)
        let core = FakeTransferCore()
        core.deletions = [transferWork(localFile: "downloads/enclosure-7.media")]
        core.states[7] = .deleteRequested
        var inUse = true
        let coordinator = MediaTransferCoordinator(core: core, mediaRoot: root, isMediaInUse: { _ in inUse })

        coordinator.reconcile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertTrue(core.deleted.isEmpty)

        inUse = false
        coordinator.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(core.deleted, [7])

        core.deletions = [transferWork(localFile: "downloads/enclosure-7.media")]
        coordinator.reconcile()
        XCTAssertEqual(core.deleted, [7, 7])
    }

    func testNetworkPolicyMapsAnyNetworkAndUnmeteredOnly() {
        let any = MediaTransferNetworkConfiguration.configuration(for: .anyNetwork)
        XCTAssertTrue(any.allowsExpensiveNetworkAccess)
        XCTAssertTrue(any.allowsConstrainedNetworkAccess)

        let unmetered = MediaTransferNetworkConfiguration.configuration(for: .unmeteredOnly)
        XCTAssertFalse(unmetered.allowsExpensiveNetworkAccess)
        XCTAssertFalse(unmetered.allowsConstrainedNetworkAccess)
    }

    private func temporaryMediaRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxNewsMedia-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
