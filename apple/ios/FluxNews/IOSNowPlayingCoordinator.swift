import Combine
import Foundation
import MediaPlayer
import UIKit

protocol IOSNowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: IOSNowPlayingInfoPublishing {}

@MainActor
final class IOSNowPlayingCoordinator {
    private let playbackCoordinator: IOSMediaPlaybackCoordinator
    private let presentationState: IOSMediaPlaybackPresentationState
    private let nowPlaying: IOSNowPlayingInfoPublishing
    private var cancellables = Set<AnyCancellable>()
    private var artworkGeneration = 0
    private var artworkSource: MediaArtworkSource?
    private var artworkData: Data?
    private var publishedArtworkData: Data?
    private var publishedArtwork: MPMediaItemArtwork?
    private var hasPublishedArtwork = false

    init(
        playbackCoordinator: IOSMediaPlaybackCoordinator,
        presentationState: IOSMediaPlaybackPresentationState,
        nowPlaying: IOSNowPlayingInfoPublishing = MPNowPlayingInfoCenter.default()
    ) {
        self.playbackCoordinator = playbackCoordinator
        self.presentationState = presentationState
        self.nowPlaying = nowPlaying
        observePresentationState()
        publish()
    }

    func cleanup() {
        cancellables.removeAll()
        artworkGeneration += 1
        artworkSource = nil
        artworkData = nil
        publishedArtworkData = nil
        publishedArtwork = nil
        hasPublishedArtwork = false
        clear()
    }

    private func observePresentationState() {
        presentationState.$positionMs
            .sink { [weak self] _ in self?.publishElapsed() }
            .store(in: &cancellables)

        Publishers.MergeMany(
            presentationState.$loadedEnclosure.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$feedTitle.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$mediaTitle.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$artworkSource.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$status.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$durationMs.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$playbackRate.map { _ in () }.eraseToAnyPublisher(),
            presentationState.$errorMessage.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.publish() }
        .store(in: &cancellables)
    }

    private func projection() -> AppleNowPlayingProjection? {
        guard let enclosure = presentationState.loadedEnclosure else { return nil }
        return AppleNowPlayingProjection.make(
            title: presentationState.mediaTitle,
            sourceTitle: presentationState.feedTitle,
            enclosureURL: enclosure.url,
            durationMs: presentationState.durationMs,
            positionMs: presentationState.positionMs,
            status: presentationState.status,
            playbackRate: presentationState.playbackRate,
            errorMessage: presentationState.errorMessage,
            artworkData: artworkData
        )
    }

    private func publish() {
        requestArtworkIfNeeded()
        guard let projection = projection() else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: projection.title,
            MPMediaItemPropertyAlbumTitle: projection.sourceTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: projection.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: projection.effectivePlaybackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: projection.defaultPlaybackRate
        ]
        if let assetURL = projection.assetURL {
            info[MPNowPlayingInfoPropertyAssetURL] = assetURL
        }
        if let duration = projection.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if !hasPublishedArtwork || publishedArtworkData != projection.artworkData {
            publishedArtworkData = projection.artworkData
            hasPublishedArtwork = true
            if let data = projection.artworkData, let image = UIImage(data: data) {
                publishedArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                publishedArtwork = nil
            }
        }
        if let publishedArtwork {
            info[MPMediaItemPropertyArtwork] = publishedArtwork
        }

        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = projection.playbackState == .playing ? .playing : .paused
    }

    private func publishElapsed() {
        guard let projection = projection(), var info = nowPlaying.nowPlayingInfo else {
            publish()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = projection.elapsedSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = projection.effectivePlaybackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = projection.defaultPlaybackRate
        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = projection.playbackState == .playing ? .playing : .paused
    }

    private func clear() {
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .unknown
    }

    private func requestArtworkIfNeeded() {
        let source = presentationState.artworkSource
        guard source != artworkSource else { return }
        artworkSource = source
        artworkData = nil
        artworkGeneration += 1
        let generation = artworkGeneration
        guard let source else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.playbackCoordinator.artwork(source: source)
            guard self.artworkGeneration == generation,
                  self.presentationState.artworkSource == source else { return }
            self.artworkData = data
            self.publish()
        }
    }
}
