import Combine
import Foundation

@MainActor
final class IOSListeningListStore: ObservableObject {
    @Published private(set) var items: [ListeningListItem] = []
    @Published private(set) var feeds: [ListeningListFeed] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var sort: ListeningListSort = .recentlyAdded
    @Published var feedID: Int64?

    private var core: Flux?
    private var coreSessionExecutionCoordinator = IOSCoreSessionExecutionCoordinator()
    private var generation: UInt64 = 0

    var count: UInt64 { UInt64(items.count) }

    func attach(
        to core: Flux,
        coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator
    ) {
        generation &+= 1
        self.core = core
        self.coreSessionExecutionCoordinator = coreSessionExecutionCoordinator
        reload()
    }

    func detach() {
        generation &+= 1
        core = nil
        items = []
        feeds = []
        feedID = nil
        isLoading = false
        errorMessage = nil
    }

    func reload() {
        guard let core else { return }
        generation &+= 1
        let request = generation
        let requestedFeedID = feedID
        let requestedSort = sort
        let coordinator = coreSessionExecutionCoordinator
        isLoading = true
        errorMessage = nil

        Task { [weak self, core, coordinator] in
            guard let result = await coordinator.responsiveResult(
                for: core,
                {
                    let feeds = try core.listeningListFeeds()
                    let validatedFeedID = requestedFeedID.flatMap { id in
                        feeds.contains(where: { $0.feedId == id }) ? id : nil
                    }
                    let items = try core.listeningList(
                        feedId: validatedFeedID,
                        sort: requestedSort
                    )
                    return (feeds, validatedFeedID, items)
                }
            ) else { return }

            guard let self, self.generation == request else { return }
            self.isLoading = false
            switch result {
            case let .success((feeds, validatedFeedID, items)):
                self.feeds = feeds
                self.feedID = validatedFeedID
                self.items = items
                self.errorMessage = nil
            case let .failure(error):
                self.errorMessage = IOSErrorPresentation.message(
                    for: error,
                    context: .contentLoad
                )
            }
        }
    }

    func setSort(_ sort: ListeningListSort) {
        guard self.sort != sort else { return }
        self.sort = sort
        reload()
    }

    func setFeedID(_ feedID: Int64?) {
        guard self.feedID != feedID else { return }
        self.feedID = feedID
        reload()
    }
}

enum IOSListeningListPresentation {
    struct Progress: Equatable {
        let positionMs: UInt64
        let durationMs: UInt64?
        let status: PlaybackStatus

        var fraction: Double? {
            guard let durationMs, durationMs > 0 else { return nil }
            return min(
                max(Double(positionMs) / Double(durationMs), 0),
                1
            )
        }
    }

    static func textOrFallback(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback
            : value
    }

    static func selectedEnclosure(
        _ item: ListeningListItem
    ) -> ListeningListEnclosure? {
        if let activeID = item.activeEnclosureId,
           let active = item.audioEnclosures.first(
            where: { $0.enclosure.id == activeID }
           ) {
            return active
        }
        return item.audioEnclosures.count == 1
            ? item.audioEnclosures[0]
            : nil
    }

    static func progress(
        _ item: ListeningListItem,
        runtime: IOSMediaPlaybackPresentationState
    ) -> Progress? {
        guard let selected = selectedEnclosure(item) else { return nil }
        let isRuntimeItem = runtime.loadedEnclosure?.id == selected.enclosure.id
        let playback = selected.playbackState

        let status: PlaybackStatus = if isRuntimeItem {
            switch runtime.status {
            case .playing:
                .inProgress
            case .paused, .stopped:
                playback?.status ?? .notStarted
            }
        } else {
            playback?.status ?? .notStarted
        }

        let rawPosition = isRuntimeItem
            ? runtime.positionMs
            : playback?.positionMs ?? 0
        let rawDuration = isRuntimeItem
            ? runtime.durationMs ?? selected.durationMs ?? playback?.durationMs
            : selected.durationMs ?? playback?.durationMs
        let duration = rawDuration.flatMap { $0 > 0 ? $0 : nil }
        let position = duration.map { min(rawPosition, $0) } ?? rawPosition

        guard status != .notStarted || position > 0 else { return nil }
        return .init(
            positionMs: position,
            durationMs: duration,
            status: status
        )
    }

    static func downloadSummary(
        _ item: ListeningListItem
    ) -> (downloaded: Int, total: Int, pending: Int) {
        let states = item.audioEnclosures.compactMap(\.download?.state)
        return (
            states.filter { $0 == .downloaded }.count,
            item.audioEnclosures.count,
            states.filter {
                $0 == .requested || $0 == .deleteRequested
            }.count
        )
    }
}
