import CarPlay
import Combine
import Foundation
import MediaPlayer
import UIKit

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
    private let remoteCommandCenter: MPRemoteCommandCenter
    private var cancellables = Set<AnyCancellable>()
    private var commandRegistrations: [(MPRemoteCommand, Any)] = []
    private var artworkGeneration = 0
    private var artworkSource: MediaArtworkSource?
    private var artworkData: Data?
    private var publishedArtworkData: Data?
    private var publishedArtwork: MPMediaItemArtwork?
    private var hasPublishedArtwork = false

    private(set) var remoteCommandRegistrationCount = 0

    init(
        playbackCoordinator: IOSMediaPlaybackCoordinator,
        presentationState: IOSMediaPlaybackPresentationState,
        nowPlaying: IOSNowPlayingInfoPublishing = MPNowPlayingInfoCenter.default(),
        remoteCommandCenter: MPRemoteCommandCenter = .shared()
    ) {
        self.playbackCoordinator = playbackCoordinator
        self.presentationState = presentationState
        self.nowPlaying = nowPlaying
        self.remoteCommandCenter = remoteCommandCenter
        observePresentationState()
        startRemoteCommands()
        publish()
    }

    func cleanup() {
        removeRemoteCommandTargets()
        cancellables.removeAll()
        artworkGeneration += 1
        artworkSource = nil
        artworkData = nil
        publishedArtworkData = nil
        publishedArtwork = nil
        hasPublishedArtwork = false
        clear()
    }

    func startRemoteCommands() {
        guard commandRegistrations.isEmpty else { return }
        registerRemoteCommands()
    }

    func dispatch(_ command: AppleMediaRemoteCommand) -> MPRemoteCommandHandlerStatus {
        switch command {
        case .play:
            return handlePlay()
        case .pause:
            return handlePause()
        case .toggle:
            return handleToggle()
        case .skipBackward:
            return handleSkip(seconds: -AppleMediaRemoteCommandPolicy.skipIntervalSeconds)
        case .skipForward:
            return handleSkip(seconds: AppleMediaRemoteCommandPolicy.skipIntervalSeconds)
        case let .seek(seconds):
            return handleSeek(seconds: seconds)
        }
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

    private func registerRemoteCommands() {
        remoteCommandRegistrationCount += 1

        remoteCommandCenter.nextTrackCommand.isEnabled = false
        remoteCommandCenter.previousTrackCommand.isEnabled = false
        remoteCommandCenter.stopCommand.isEnabled = false

        add(remoteCommandCenter.playCommand) { [weak self] _ in
            self?.dispatch(.play) ?? .commandFailed
        }
        add(remoteCommandCenter.pauseCommand) { [weak self] _ in
            self?.dispatch(.pause) ?? .commandFailed
        }
        add(remoteCommandCenter.togglePlayPauseCommand) { [weak self] _ in
            self?.dispatch(.toggle) ?? .commandFailed
        }

        let skipInterval = NSNumber(value: AppleMediaRemoteCommandPolicy.skipIntervalSeconds)
        remoteCommandCenter.skipBackwardCommand.preferredIntervals = [skipInterval]
        remoteCommandCenter.skipForwardCommand.preferredIntervals = [skipInterval]
        add(remoteCommandCenter.skipBackwardCommand) { [weak self] _ in
            self?.dispatch(.skipBackward) ?? .commandFailed
        }
        add(remoteCommandCenter.skipForwardCommand) { [weak self] _ in
            self?.dispatch(.skipForward) ?? .commandFailed
        }
        add(remoteCommandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.dispatch(.seek(seconds: event.positionTime)) ?? .commandFailed
        }
    }

    private func add(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        commandRegistrations.append((command, command.addTarget(handler: handler)))
    }

    private func removeRemoteCommandTargets() {
        for (command, token) in commandRegistrations {
            command.removeTarget(token)
        }
        commandRegistrations.removeAll()
    }

    private func handlePlay() -> MPRemoteCommandHandlerStatus {
        guard let enclosureID = presentationState.loadedEnclosure?.id else {
            return .commandFailed
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.playbackCoordinator.play(enclosureID: enclosureID)
        }
        return .success
    }

    private func handlePause() -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else {
            return .commandFailed
        }
        playbackCoordinator.pause()
        return .success
    }

    private func handleToggle() -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else {
            return .commandFailed
        }
        if presentationState.status == .playing {
            playbackCoordinator.pause()
            return .success
        }
        return handlePlay()
    }

    private func handleSkip(seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard presentationState.loadedEnclosure != nil else {
            return .commandFailed
        }
        playbackCoordinator.skip(bySeconds: seconds)
        return .success
    }

    private func handleSeek(seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard seconds.isFinite,
              seconds >= 0,
              presentationState.loadedEnclosure != nil else {
            return .commandFailed
        }
        let bounded = presentationState.durationMs.map {
            min(seconds, Double($0) / 1_000)
        } ?? seconds
        guard bounded.isFinite,
              bounded <= Double(UInt64.max) / 1_000 else {
            return .commandFailed
        }
        playbackCoordinator.seek(toMs: UInt64(bounded * 1_000))
        return .success
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

@MainActor
final class IOSCarPlayCoordinator {
    private weak var interfaceController: CPInterfaceController?
    private let mediaRuntime: IOSMediaRuntime
    private var loadGeneration: UInt64 = 0

    init(mediaRuntime: IOSMediaRuntime) {
        self.mediaRuntime = mediaRuntime
    }

    func connect(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        showLoadingRoot()
        reloadListeningList()
    }

    func disconnect() {
        loadGeneration &+= 1
        interfaceController = nil
    }

    func reloadListeningList() {
        guard let core = mediaRuntime.core else {
            showMessageRoot(
                title: String(localized: "Listening List"),
                message: String(localized: "Media is not available yet.")
            )
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        let executionCoordinator = mediaRuntime.coreSessionExecutionCoordinator

        Task { @MainActor [weak self, core, executionCoordinator] in
            guard let result = await executionCoordinator.responsiveResult(
                for: core,
                { try core.listeningList(feedId: nil, sort: .recentlyAdded) }
            ) else {
                return
            }
            guard let self,
                  self.loadGeneration == generation,
                  self.mediaRuntime.core === core else {
                return
            }

            switch result {
            case let .success(items):
                self.showListeningList(items)
            case .failure:
                self.showMessageRoot(
                    title: String(localized: "Listening List"),
                    message: String(localized: "The Listening List could not be loaded.")
                )
            }
        }
    }

    private func showLoadingRoot() {
        let item = CPListItem(
            text: String(localized: "Loading…"),
            detailText: nil
        )
        item.isEnabled = false
        setRoot(
            CPListTemplate(
                title: String(localized: "Listening List"),
                sections: [CPListSection(items: [item])]
            )
        )
    }

    private func showMessageRoot(title: String, message: String) {
        let item = CPListItem(text: message, detailText: nil)
        item.isEnabled = false
        setRoot(
            CPListTemplate(
                title: title,
                sections: [CPListSection(items: [item])]
            )
        )
    }

    private func showListeningList(_ items: [ListeningListItem]) {
        guard !items.isEmpty else {
            showMessageRoot(
                title: String(localized: "Listening List"),
                message: String(localized: "No audio items available.")
            )
            return
        }

        let limit = CPListTemplate.maximumItemCount
        let projected = items.prefix(limit).map(makeListItem)
        setRoot(
            CPListTemplate(
                title: String(localized: "Listening List"),
                sections: [CPListSection(items: Array(projected))]
            )
        )
    }

    private func makeListItem(_ item: ListeningListItem) -> CPListItem {
        let title = IOSListeningListPresentation.textOrFallback(
            item.title,
            fallback: String(localized: "Untitled")
        )
        let feedTitle = IOSListeningListPresentation.textOrFallback(
            item.feedTitle,
            fallback: String(localized: "Unknown Feed")
        )
        let listItem = CPListItem(text: title, detailText: feedTitle)

        guard let selected = IOSListeningListPresentation.selectedEnclosure(item) else {
            listItem.isEnabled = false
            if item.audioEnclosures.count > 1 {
                listItem.setDetailText(String(localized: "Multiple audio files"))
            }
            return listItem
        }

        let enclosureID = selected.enclosure.id
        listItem.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion()
                    return
                }
                do {
                    try await self.mediaRuntime.playbackCoordinator.play(
                        enclosureID: enclosureID
                    )
                    self.interfaceController?.pushTemplate(
                        CPNowPlayingTemplate.shared,
                        animated: true,
                        completion: nil
                    )
                } catch {
                    // Playback error remains projected by the shared media
                    // runtime/Now Playing path; CarPlay owns no parallel state.
                }
                completion()
            }
        }
        return listItem
    }

    private func setRoot(_ template: CPTemplate) {
        interfaceController?.setRootTemplate(
            template,
            animated: true,
            completion: nil
        )
    }
}

@MainActor
@objc(IOSCarPlaySceneDelegate)
final class IOSCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: IOSCarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let coordinator = IOSCarPlayCoordinator(
            mediaRuntime: IOSAppRuntime.shared.mediaRuntime
        )
        self.coordinator = coordinator
        coordinator.connect(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.disconnect()
        coordinator = nil
    }
}
