import Combine
import Foundation

enum IOSMediaPlaybackSource: Equatable, Hashable {
    case local
    case remote
}

@MainActor
final class IOSMediaPlaybackPresentationState: ObservableObject {
    @Published private(set) var loadedEnclosure: Enclosure?
    @Published private(set) var feedTitle = ""
    @Published private(set) var mediaTitle = ""
    @Published private(set) var artworkSource: MediaArtworkSource?
    @Published private(set) var chapters: [MediaChapter] = []
    @Published private(set) var status: MediaPlaybackPresentationStatus = .stopped
    @Published private(set) var positionMs: UInt64 = 0
    @Published private(set) var durationMs: UInt64?
    @Published private(set) var playbackSource: IOSMediaPlaybackSource?
    @Published private(set) var isLoading = false
    @Published private(set) var isBuffering = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackRate = 1.0

    func reset() {
        loadedEnclosure = nil
        feedTitle = ""
        mediaTitle = ""
        artworkSource = nil
        chapters = []
        status = .stopped
        positionMs = 0
        durationMs = nil
        playbackSource = nil
        isLoading = false
        isBuffering = false
        errorMessage = nil
        playbackRate = 1.0
    }

    func setLoadedMedia(
        enclosure: Enclosure,
        feedTitle: String,
        mediaTitle: String,
        artworkSource: MediaArtworkSource?,
        chapters: [MediaChapter],
        positionMs: UInt64,
        durationMs: UInt64?
    ) {
        loadedEnclosure = enclosure
        self.feedTitle = feedTitle
        self.mediaTitle = mediaTitle
        self.artworkSource = artworkSource
        self.chapters = chapters
        self.positionMs = positionMs
        self.durationMs = durationMs
        playbackSource = nil
        status = .paused
        isLoading = false
        isBuffering = false
        errorMessage = nil
    }

    func setStatus(_ status: MediaPlaybackPresentationStatus) {
        self.status = status
    }

    func setPosition(_ positionMs: UInt64) {
        self.positionMs = positionMs
    }

    func setDuration(_ durationMs: UInt64?) {
        self.durationMs = durationMs
    }

    func setPlaybackSource(_ playbackSource: IOSMediaPlaybackSource?) {
        self.playbackSource = playbackSource
    }

    func setLoading(_ isLoading: Bool) {
        self.isLoading = isLoading
    }

    func setBuffering(_ isBuffering: Bool) {
        self.isBuffering = isBuffering
    }

    func setErrorMessage(_ errorMessage: String?) {
        self.errorMessage = errorMessage
    }

    func setPlaybackRate(_ playbackRate: Double) {
        self.playbackRate = playbackRate
    }

    func setChapters(_ chapters: [MediaChapter]) {
        self.chapters = chapters
    }
}

@MainActor
final class IOSMediaTransferPresentationState: ObservableObject {
    @Published private(set) var transfers: [Int64: MediaTransferRuntime] = [:]

    func runtime(for enclosureID: Int64) -> MediaTransferRuntime? {
        transfers[enclosureID]
    }

    func set(_ runtime: MediaTransferRuntime) {
        transfers[runtime.enclosureID] = runtime
    }

    func remove(enclosureID: Int64) {
        transfers[enclosureID] = nil
    }

    func reset() {
        transfers.removeAll()
    }
}
