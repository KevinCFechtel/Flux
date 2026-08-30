import Foundation
import XCTest
@testable import FluxNews

@MainActor
private final class FakePlaybackCore: MediaPlaybackCore {
    var preparation: PlaybackPreparation
    var checkpoints = [(Int64, UInt64, UInt64?)]()
    var completions = [(Int64, UInt64?)]()
    var restartCount = 0
    var observedDurations = [(Int64, UInt64)]()

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
    func checkpointPlayback(enclosureId: Int64, positionMs: UInt64, durationMs: UInt64?) throws { checkpoints.append((enclosureId, positionMs, durationMs)) }
    func playbackCompleted(enclosureId: Int64, durationMs: UInt64?) throws { completions.append((enclosureId, durationMs)) }
    func restartPlayback(enclosureId: Int64) throws { restartCount += 1; preparation.playbackState = PlaybackState(enclosureId: 7, positionMs: 0, durationMs: 120_000, status: .inProgress, updatedAt: nil) }
    func observeMediaDuration(enclosureId: Int64, durationMs: UInt64) throws { observedDurations.append((enclosureId, durationMs)) }
    func mediaChapters(enclosureId: Int64) throws -> [MediaChapter] { [] }
    func mediaArtwork(reference: String) throws -> Data? { nil }
}

@MainActor
private final class FakePlaybackEngine: NativePlaybackEngine {
    var currentPositionMs: UInt64 = 0
    var durationMs: UInt64? = nil
    var isPlaying = false
    var onEnded: (@MainActor () -> Void)?
    var onDuration: (@MainActor (UInt64) -> Void)?
    var loadedStartMs: UInt64?
    var playCount = 0

    func load(url: URL, startAtMs: UInt64) { loadedStartMs = startAtMs; durationMs = 120_000; onDuration?(120_000) }
    func play() { isPlaying = true; playCount += 1 }
    func pause() { isPlaying = false }
    func seek(toMs: UInt64) { currentPositionMs = toMs }
    func finish() { isPlaying = false; onEnded?() }
}

@MainActor
final class MediaCoordinatorTests: XCTestCase {
    func testInProgressStartsAtCorePositionAndPauseCheckpoints() throws {
        let core = FakePlaybackCore(status: .inProgress, positionMs: 35_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        try coordinator.prepare(enclosureID: 7)
        XCTAssertEqual(engine.loadedStartMs, 35_000)
        try coordinator.play(enclosureID: 7)
        engine.currentPositionMs = 36_000
        coordinator.pause()

        XCTAssertEqual(core.checkpoints.map(\.1), [36_000])
    }

    func testCompletedDoesNotImplicitlyRestartAndExplicitRestartUsesCore() throws {
        let core = FakePlaybackCore(status: .completed, positionMs: 120_000)
        let engine = FakePlaybackEngine()
        let coordinator = MediaPlaybackCoordinator(core: core, engine: engine)

        try coordinator.prepare(enclosureID: 7)
        try coordinator.play(enclosureID: 7)
        XCTAssertEqual(engine.playCount, 0)

        try coordinator.restart(enclosureID: 7)
        XCTAssertEqual(core.restartCount, 1)
        XCTAssertEqual(engine.playCount, 1)
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
}
