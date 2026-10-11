import Foundation

struct FeedSettingsTarget: Identifiable { let id: Int64; let title: String }

struct ArticleAudioActionState: Equatable {
    let articleID: Int64
    let enclosures: [Enclosure]
    let isInListeningList: Bool
    let downloads: [Int64: MediaDownload]
}

struct ListeningListProgress: Equatable {
    let positionMs: UInt64
    let durationMs: UInt64?
    let status: PlaybackStatus
}

enum ListeningListPresentation {
    static func textOrFallback(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    static func validatedFeedID(_ feedID: Int64?, feeds: [ListeningListFeed]) -> Int64? {
        guard let feedID else { return nil }
        return feeds.contains(where: { $0.feedId == feedID }) ? feedID : nil
    }

    static func preferredEnclosure(_ item: ListeningListItem) -> Enclosure? {
        if let activeID = item.activeEnclosureId,
           let active = item.audioEnclosures.first(where: { $0.enclosure.id == activeID }) {
            return active.enclosure
        }
        return item.audioEnclosures.count == 1 ? item.audioEnclosures[0].enclosure : nil
    }

    @MainActor static func progress(_ item: ListeningListItem, runtime: MediaPlaybackPresentationState? = nil) -> ListeningListProgress? {
        let selected = item.activeEnclosureId.flatMap { id in item.audioEnclosures.first(where: { $0.enclosure.id == id }) }
            ?? (item.audioEnclosures.count == 1 ? item.audioEnclosures[0] : nil)
        guard let selected else { return nil }
        let isRuntimeItem = runtime?.loadedEnclosure?.id == selected.enclosure.id
        let playback = selected.playbackState
        let status: PlaybackStatus
        if isRuntimeItem {
            switch runtime?.status {
            case .playing: status = .inProgress
            case .paused, .stopped, nil: status = playback?.status ?? .notStarted
            }
        } else {
            status = playback?.status ?? .notStarted
        }
        let rawPosition = isRuntimeItem ? runtime?.positionMs ?? playback?.positionMs ?? 0 : playback?.positionMs ?? 0
        let rawDuration = isRuntimeItem ? runtime?.durationMs ?? selected.durationMs ?? playback?.durationMs : selected.durationMs ?? playback?.durationMs
        let duration = rawDuration.flatMap { $0 > 0 ? $0 : nil }
        let position = duration.map { min(rawPosition, $0) } ?? rawPosition
        guard status != .notStarted || position > 0 else { return nil }
        return ListeningListProgress(positionMs: position, durationMs: duration, status: status)
    }

    static func downloadedCount(_ item: ListeningListItem) -> (downloaded: Int, total: Int, pending: Int) {
        let states = item.audioEnclosures.compactMap(\.download?.state)
        let downloaded = states.filter { $0 == .downloaded }.count
        let pending = states.filter { $0 == .requested || $0 == .deleteRequested }.count
        return (downloaded, item.audioEnclosures.count, pending)
    }
}

enum ArticleAudioActions {
    enum DownloadAction: Equatable { case download, pending, delete, downloading, pendingDeletion, retry }

    static func audioEnclosures(_ enclosures: [Enclosure]) -> [Enclosure] {
        enclosures.filter { $0.mediaKind == .audio }
    }

    static func shouldRender(_ state: ArticleAudioActionState?, transferStateAvailable: Bool) -> Bool {
        state != nil && transferStateAvailable && !(state?.enclosures.isEmpty ?? true)
    }

    static func requiresReplacement(currentID: Int64?, currentStatus: MediaPlaybackPresentationStatus, selectedID: Int64) -> Bool {
        currentID != selectedID && currentStatus == .playing
    }

    static func canRequestDownload(_ download: MediaDownload?) -> Bool {
        switch downloadAction(download) {
        case .download, .retry: return true
        case .pending, .delete, .downloading, .pendingDeletion: return false
        }
    }

    static func canDeleteDownload(_ download: MediaDownload?) -> Bool {
        downloadAction(download) == .delete
    }

    static func hasLocalDownload(_ item: ListeningListItem) -> Bool {
        item.audioEnclosures.contains { $0.download?.state == .downloaded }
    }

    static func downloadAction(_ download: MediaDownload?, runtime: MediaTransferRuntime? = nil) -> DownloadAction {
        switch download?.state {
        case .downloaded: return .delete
        case .requested: return runtime?.phase == .transferring ? .downloading : .pending
        case .deleteRequested: return .pendingDeletion
        case .failed: return .retry
        case .notDownloaded, nil: return .download
        }
    }

    static func enclosureLabel(_ enclosure: Enclosure, index: Int) -> String {
        let filename: String?
        if let url = URL(string: enclosure.url), let decoded = url.lastPathComponent.removingPercentEncoding {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            filename = trimmed.isEmpty || trimmed == "/" ? nil : trimmed
        } else {
            filename = nil
        }
        let name = filename ?? String(localized: "Audio \(index + 1)")
        let format = enclosure.mimeType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let size = enclosure.sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64(min($0, UInt64(Int64.max))), countStyle: .file) }
        let details = [format, size].compactMap { $0 }.filter { !$0.isEmpty }
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }
}

enum AddFeedOptionalBoolean: String, CaseIterable, Identifiable {
    case serverDefault, enabled, disabled

    var id: Self { self }
    var value: Bool? {
        switch self {
        case .serverDefault: nil
        case .enabled: true
        case .disabled: false
        }
    }
    var title: String {
        switch self {
        case .serverDefault: String(localized: "Use Miniflux default")
        case .enabled: String(localized: "Enabled")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct AddFeedForm {
    var url = ""
    var categoryID: Int64?
    var username = ""
    var password = ""
    var userAgent = ""
    var scraperRules = ""
    var rewriteRules = ""
    var blocklistRules = ""
    var keeplistRules = ""
    var crawler: AddFeedOptionalBoolean = .serverDefault
    var disabled: AddFeedOptionalBoolean = .serverDefault
    var ignoreHttpCache: AddFeedOptionalBoolean = .serverDefault
    var fetchViaProxy: AddFeedOptionalBoolean = .serverDefault

    func discoveryRequest() -> DiscoverSubscriptionsRequest {
        DiscoverSubscriptionsRequest(
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: optional(username),
            password: optional(password),
            userAgent: optional(userAgent),
            fetchViaProxy: fetchViaProxy.value
        )
    }
    func createRequest(feedURL: String) -> CreateFeedRequest {
        CreateFeedRequest(
            feedUrl: feedURL,
            categoryId: categoryID,
            username: optional(username),
            password: optional(password),
            crawler: crawler.value,
            userAgent: optional(userAgent),
            scraperRules: optional(scraperRules),
            rewriteRules: optional(rewriteRules),
            blocklistRules: optional(blocklistRules),
            keeplistRules: optional(keeplistRules),
            disabled: disabled.value,
            ignoreHttpCache: ignoreHttpCache.value,
            fetchViaProxy: fetchViaProxy.value
        )
    }
    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AddFeedDiscoveryOutcome: Equatable {
    case none
    case automatic(DiscoveredSubscription)
    case choose

    static func from(_ candidates: [DiscoveredSubscription]) -> Self {
        switch candidates.count {
        case 0: .none
        case 1: .automatic(candidates[0])
        default: .choose
        }
    }
}
