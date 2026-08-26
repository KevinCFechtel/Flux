import CoreGraphics
import Foundation

/// Native-only visibility state machine. It emits exact IDs for the normal Core bulk mutation.
struct ScrolloverExposureTracker {
    private struct Exposure { var visibleSince: TimeInterval?; var qualified = false; var processedFrame: CGRect; var currentFrame: CGRect }
    private var exposures: [Int64: Exposure] = [:]
    mutating func reset() { exposures.removeAll() }
    mutating func rebase(frames: [Int64: CGRect], unread: Set<Int64>) { exposures = exposures.filter { unread.contains($0.key) }; for (id, frame) in frames where unread.contains(id) { guard var exposure = exposures[id] else { continue }; exposure.processedFrame = frame; exposure.currentFrame = frame; exposures[id] = exposure } }
    mutating func observe(frames: [Int64: CGRect], viewport: CGRect, unread: Set<Int64>, now: TimeInterval) { for (id, frame) in frames where unread.contains(id) { var exposure = exposures[id] ?? Exposure(processedFrame: frame, currentFrame: frame); let visible = frame.intersection(viewport).height / max(1, frame.height); if visible >= 0.6 { exposure.visibleSince = exposure.visibleSince ?? now; exposure.qualified = exposure.qualified || now - (exposure.visibleSince ?? now) >= 0.7 } else if !exposure.qualified { exposure.visibleSince = nil }; exposure.currentFrame = frame; exposures[id] = exposure }; exposures = exposures.filter { unread.contains($0.key) } }
    mutating func process(frames: [Int64: CGRect], viewport: CGRect, unread: Set<Int64>, now: TimeInterval, offsetDelta: CGFloat, userInitiated: Bool) -> [Int64] { guard userInitiated, offsetDelta > 0, offsetDelta <= viewport.height * 0.85 else { reset(); observe(frames: frames, viewport: viewport, unread: unread, now: now); return [] }; let ids = exposures.compactMap { id, exposure -> Int64? in let crossed = frames[id].map { exposure.processedFrame.maxY > viewport.minY && $0.maxY <= viewport.minY } ?? (exposure.currentFrame.midY < viewport.midY); return exposure.qualified && unread.contains(id) && crossed ? id : nil }.sorted(); for id in ids { exposures.removeValue(forKey: id) }; observe(frames: frames, viewport: viewport, unread: unread, now: now); for id in Array(exposures.keys) { if var exposure = exposures[id] { exposure.processedFrame = exposure.currentFrame; exposures[id] = exposure } }; return ids }
}

enum SnapshotRefreshPolicy {
    enum Action: Equatable {
        case replace
        case preserve
        case signalNewData
    }

    static func action(manual: Bool, dataChanged: Bool, popoverVisible: Bool, hasMeaningfullyInteracted: Bool) -> Action {
        if manual || (dataChanged && (!popoverVisible || !hasMeaningfullyInteracted)) { return .replace }
        return dataChanged ? .signalNewData : .preserve
    }
}

/// Runtime-only counts for local data not yet adopted by a visible Feed snapshot.
struct PendingNewData: Equatable {
    private(set) var byFeed: [Int64: Int] = [:]

    var hasPending: Bool { byFeed.values.contains(where: { $0 > 0 }) }

    mutating func accumulate(_ additions: [(feedID: Int64, count: UInt32)]) {
        for addition in additions where addition.count > 0 {
            let current = byFeed[addition.feedID] ?? 0
            let (next, overflow) = current.addingReportingOverflow(Int(addition.count))
            byFeed[addition.feedID] = overflow ? Int.max : next
        }
    }

    mutating func adoptAll() { byFeed.removeAll() }
    mutating func adoptFeed(_ feedID: Int64) { byFeed.removeValue(forKey: feedID) }
    mutating func adoptFeeds(in categoryFeedIDs: Set<Int64>) {
        byFeed = byFeed.filter { !categoryFeedIDs.contains($0.key) }
    }
    mutating func removeAbsentFeeds(_ feedIDs: Set<Int64>) {
        byFeed = byFeed.filter { feedIDs.contains($0.key) }
    }
}

enum StatusItemPresentation {
    static func title(unreadTotal: UInt64, hasPendingNewData: Bool) -> String {
        let unread = unreadTotal == 0 ? "" : unreadTotal > 999 ? "999+" : "\(unreadTotal)"
        return switch (hasPendingNewData, unread.isEmpty) {
        case (false, _): unread
        case (true, true): "•"
        case (true, false): "• \(unread)"
        }
    }

    static func accessibilityValue(unreadTotal: UInt64, hasPendingNewData: Bool) -> String {
        let unread = unreadTotal == 1 ? "1 unread article" : "\(unreadTotal) unread articles"
        return hasPendingNewData ? "\(unread), new data available" : unread
    }
}

/// Presentation-only policy for grouping tracker flushes from one scroll interaction.
struct ScrolloverUndoBatch {
    private var session = 0
    private var batchSession: Int?
    private(set) var articleIDs: [Int64] = []
    var showsUndo: Bool { articleIDs.count >= 2 }

    mutating func beginScroll() {
        session += 1
    }

    mutating func append(_ ids: [Int64]) -> [Int64] {
        let ids = ids.reduce(into: [Int64]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !ids.isEmpty else { return articleIDs }
        if batchSession != session {
            articleIDs = ids
            batchSession = session
        } else {
            for id in ids where !articleIDs.contains(id) { articleIDs.append(id) }
        }
        return articleIDs
    }

    mutating func clear() {
        articleIDs = []
        batchSession = nil
    }
}

struct FeedIconRequestState {
    private var inFlight = Set<String>()

    mutating func begin(_ key: String, cached: Bool) -> Bool {
        !cached && inFlight.insert(key).inserted
    }

    mutating func complete(_ key: String) {
        inFlight.remove(key)
    }

    func isInFlight(_ key: String) -> Bool {
        inFlight.contains(key)
    }
}

struct ArticleThumbnailRequestState {
    private var inFlight = Set<String>()

    mutating func begin(_ key: String, cached: Bool) -> Bool {
        !cached && inFlight.insert(key).inserted
    }

    mutating func complete(_ key: String) {
        inFlight.remove(key)
    }

    func isInFlight(_ key: String) -> Bool {
        inFlight.contains(key)
    }
}
