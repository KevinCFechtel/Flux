import XCTest
@testable import FluxNews

@MainActor
private final class FakeIOSPlaybackCoreAccess: IOSMediaPlaybackCoreAccessing {
    var preparation: PlaybackPreparation
    var chaptersValue: [MediaChapter] = []
    var checkpoints: [(Int64, UInt64, UInt64?)] = []
    var completed: [(Int64, UInt64?)] = []
    var restarted: [Int64] = []
    var observedDurations: [(Int64, UInt64)] = []

    init(
        status: PlaybackStatus = .notStarted,
        positionMs: UInt64 = 0,
        durationMs: UInt64? = 120_000
    ) {
        let enclosure = Enclosure(
            id: 7,
            articleId: 70,
            url: "https://example.test/audio.mp3",
            mimeType: "audio/mpeg",
            sizeBytes: nil,
            remoteMediaProgressionSeconds: 0,
            mediaKind: .audio
        )
        preparation = PlaybackPreparation(
            enclosure: enclosure,
            articleTitle: "Episode",
            feedTitle: "Feed",
            playbackState: PlaybackState(
                enclosureId: 7,
                positionMs: positionMs,
                durationMs: durationMs,
                status: status,
                updatedAt: nil
            ),
            localFile: nil,
            durationMs: durationMs,
            artworkSource: nil
        )
    }

    func attach(to core: Flux) {}
    func detach() {}

    func preparePlayback(enclosureID: Int64) async throws -> PlaybackPreparation {
        preparation
    }

    func chapters(enclosureID: Int64) async throws -> [MediaChapter] {
        chaptersValue
    }

    func checkpoint(
        enclosureID: Int64,
        positionMs: UInt64,
        durationMs: UInt64?
    ) async {
        checkpoints.append((enclosureID, positionMs, durationMs))
    }

    func completed(enclosureID: Int64, durationMs: UInt64?) async throws {
        completed.append((enclosureID, durationMs))
    }

    func restart(enclosureID: Int64) async throws {
        restarted.append(enclosureID)
        preparation = PlaybackPreparation(
            enclosure: preparation.enclosure,
            articleTitle: preparation.articleTitle,
            feedTitle: preparation.feedTitle,
            playbackState: PlaybackState(
                enclosureId: enclosureID,
                positionMs: 0,
                durationMs: preparation.durationMs,
                status: .notStarted,
                updatedAt: nil
            ),
            localFile: preparation.localFile,
            durationMs: preparation.durationMs,
            artworkSource: preparation.artworkSource
        )
    }

    func observeDuration(enclosureID: Int64, durationMs: UInt64) async {
        observedDurations.append((enclosureID, durationMs))
    }
}

@MainActor
private final class FakeIOSPlaybackEngine: IOSNativePlaybackEngine {
    var currentPositionMs: UInt64 = 0
    var durationMs: UInt64? = 120_000
    var isPlaying = false
    var rate: Double = 1.0

    var onEnded: (@MainActor () -> Void)?
    var onDuration: (@MainActor (UInt64) -> Void)?
    var onPosition: (@MainActor (UInt64) -> Void)?
    var onPlaybackStateChanged: (@MainActor (Bool) -> Void)?
    var onLoadingChanged: (@MainActor (Bool) -> Void)?
    var onBufferingChanged: (@MainActor (Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private(set) var loadedURL: URL?
    private(set) var loadedStartMs: UInt64?
    private(set) var unloadCount = 0

    func load(url: URL, startAtMs: UInt64) {
        loadedURL = url
        loadedStartMs = startAtMs
        currentPositionMs = startAtMs
    }

    func play() {
        isPlaying = true
        onPlaybackStateChanged?(true)
    }

    func pause() {
        isPlaying = false
        onPlaybackStateChanged?(false)
    }

    func unload() {
        unloadCount += 1
        isPlaying = false
    }

    func seek(toMs: UInt64) {
        currentPositionMs = toMs
        onPosition?(toMs)
    }

    func finish() {
        isPlaying = false
        onEnded?()
    }

    func emitDuration(_ value: UInt64) {
        durationMs = value
        onDuration?(value)
    }
}

@MainActor
private final class FakeIOSAudioSession: IOSMediaAudioSessionManaging {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEndedShouldResume: ((Bool) -> Void)?
    var onOldDeviceUnavailable: (() -> Void)?

    private(set) var activateCount = 0
    private(set) var deactivateCount = 0

    func activate() throws {
        activateCount += 1
    }

    func deactivateIfIdle() throws {
        deactivateCount += 1
    }

    func interrupt() {
        onInterruptionBegan?()
    }

    func endInterruption(shouldResume: Bool) {
        onInterruptionEndedShouldResume?(shouldResume)
    }

    func routeLost() {
        onOldDeviceUnavailable?()
    }
}

@MainActor
final class IOSMediaPlaybackCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        core: FakeIOSPlaybackCoreAccess,
        engine: FakeIOSPlaybackEngine,
        audio: FakeIOSAudioSession,
        checkpointInterval: TimeInterval = 20
    ) -> IOSMediaPlaybackCoordinator {
        IOSMediaPlaybackCoordinator(
            coreAccess: core,
            presentationState: IOSMediaPlaybackPresentationState(),
            engine: engine,
            audioSession: audio,
            checkpointInterval: checkpointInterval
        )
    }

    func testPrepareRestoresInProgressPositionAndNewsMetadata() async throws {
        let core = FakeIOSPlaybackCoreAccess(
            status: .inProgress,
            positionMs: 35_000
        )
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        _ = try await coordinator.prepare(enclosureID: 7)

        XCTAssertEqual(engine.loadedStartMs, 35_000)
        XCTAssertEqual(engine.loadedURL?.absoluteString, "https://example.test/audio.mp3")
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
    }

    func testPauseCheckpointsAndKeepsPreparedMediaOwned() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        try await coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 42_000
        coordinator.pause()
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 42_000)
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
    }

    func testSceneDeactivationCheckpointsWithoutPausingBackgroundAudio() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        try await coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 18_000
        coordinator.sceneWillResignActive()
        await Task.yield()

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 18_000)
    }

    func testInterruptionPausesCheckpointsAndResumesOnlyWhenAllowed() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        try await coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 22_000
        audio.interrupt()
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 22_000)

        audio.endInterruption(shouldResume: true)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(audio.activateCount, 2)
    }

    func testRouteLossPausesAndCheckpoints() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        try await coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 11_000
        audio.routeLost()
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(core.checkpoints.last?.1, 11_000)
    }

    func testPlaybackRateClampsToContract() async throws {
        let core = FakeIOSPlaybackCoreAccess()
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let state = IOSMediaPlaybackPresentationState()
        let coordinator = IOSMediaPlaybackCoordinator(
            coreAccess: core,
            presentationState: state,
            engine: engine,
            audioSession: audio
        )
        _ = try await coordinator.prepare(enclosureID: 7)

        coordinator.setPlaybackRate(3.7)
        XCTAssertEqual(engine.rate, 3.0)
        XCTAssertEqual(state.playbackRate, 3.0)

        coordinator.setPlaybackRate(0.44)
        XCTAssertEqual(engine.rate, 0.5)
        XCTAssertEqual(state.playbackRate, 0.5)

        coordinator.setPlaybackRate(.nan)
        XCTAssertEqual(engine.rate, 0.5)
    }

    func testNaturalEndReportsCoreCompletionAndReleasesDeletionDeferral() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )
        var useChanges = 0
        coordinator.onPlaybackUseChanged = {
            useChanges += 1
        }

        _ = try await coordinator.prepare(enclosureID: 7)
        engine.currentPositionMs = 120_000
        engine.finish()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(core.completed.count, 1)
        XCTAssertEqual(core.completed.first?.0, 7)
        XCTAssertEqual(useChanges, 2)
    }

    func testDurationObservationIsDeduplicated() async throws {
        let core = FakeIOSPlaybackCoreAccess()
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let coordinator = makeCoordinator(
            core: core,
            engine: engine,
            audio: audio
        )

        _ = try await coordinator.prepare(enclosureID: 7)
        engine.emitDuration(130_000)
        engine.emitDuration(130_000)
        await Task.yield()

        XCTAssertEqual(core.observedDurations.count, 1)
        XCTAssertEqual(core.observedDurations.first?.1, 130_000)
    }

    func testSleepTimerPausesWithoutUnloadingPreparedMedia() async throws {
        let core = FakeIOSPlaybackCoreAccess(status: .inProgress)
        let engine = FakeIOSPlaybackEngine()
        let audio = FakeIOSAudioSession()
        let now = Date()
        let sleepTimer = IOSMediaSleepTimer(now: { now })
        let coordinator = IOSMediaPlaybackCoordinator(
            coreAccess: core,
            presentationState: IOSMediaPlaybackPresentationState(),
            engine: engine,
            audioSession: audio,
            sleepTimer: sleepTimer
        )

        try await coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 24_000
        sleepTimer.setEnabled(true)
        sleepTimer.evaluate(at: now.addingTimeInterval(31 * 60))
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.unloadCount, 0)
        XCTAssertTrue(coordinator.isUsing(enclosureID: 7))
        XCTAssertEqual(core.checkpoints.last?.1, 24_000)
    }

    func testAVPlayerMillisecondsRejectsInvalidValues() {
        XCTAssertNil(
            IOSAVPlayerPlaybackEngine.milliseconds(
                .invalid,
                requiresPositive: true
            )
        )
        XCTAssertNil(
            IOSAVPlayerPlaybackEngine.milliseconds(
                .indefinite,
                requiresPositive: true
            )
        )
        XCTAssertNil(
            IOSAVPlayerPlaybackEngine.milliseconds(
                .zero,
                requiresPositive: true
            )
        )
        XCTAssertEqual(
            IOSAVPlayerPlaybackEngine.milliseconds(
                CMTime(seconds: 1.5, preferredTimescale: 1_000),
                requiresPositive: true
            ),
            1_500
        )
    }
}
