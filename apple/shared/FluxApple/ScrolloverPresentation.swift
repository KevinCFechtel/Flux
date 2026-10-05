import CoreGraphics
import Foundation

struct ScrolloverExposureTracker {
    private struct Exposure {
        var wasVisible = false
        var processedFrame: CGRect
        var currentFrame: CGRect
    }

    private var exposures: [Int64: Exposure] = [:]
    private var emittedIDs = Set<Int64>()

    mutating func reset() {
        exposures.removeAll()
        emittedIDs.removeAll()
    }

    mutating func rebase(frames: [Int64: CGRect], unread: Set<Int64>) {
        exposures = exposures.filter { unread.contains($0.key) }
        emittedIDs = emittedIDs.intersection(unread)
        for (id, frame) in frames where unread.contains(id) {
            var exposure = exposures[id] ?? Exposure(processedFrame: frame, currentFrame: frame)
            exposure.processedFrame = frame
            exposure.currentFrame = frame
            exposures[id] = exposure
        }
    }

    mutating func observe(frames: [Int64: CGRect], viewport: CGRect, unread: Set<Int64>, now _: TimeInterval) {
        for (id, frame) in frames where unread.contains(id) {
            var exposure = exposures[id] ?? Exposure(processedFrame: frame, currentFrame: frame)
            if frame.intersects(viewport) {
                exposure.wasVisible = true
            }
            exposure.currentFrame = frame
            exposures[id] = exposure
        }
        exposures = exposures.filter { unread.contains($0.key) }
        emittedIDs = emittedIDs.intersection(unread)
    }

    mutating func process(frames: [Int64: CGRect], viewport: CGRect, unread: Set<Int64>, now: TimeInterval, offsetDelta: CGFloat, userInitiated: Bool) -> [Int64] {
        guard userInitiated else {
            reset()
            observe(frames: frames, viewport: viewport, unread: unread, now: now)
            return []
        }

        if offsetDelta <= 0 {
            observe(frames: frames, viewport: viewport, unread: unread, now: now)
            for id in Array(exposures.keys) {
                if var exposure = exposures[id], let frame = frames[id] {
                    exposure.processedFrame = frame
                    exposure.currentFrame = frame
                    exposures[id] = exposure
                }
            }
            return []
        }

        // A normal forward scroll marks an unread article once it has actually
        // been visible and then leaves the viewport through its top edge.
        // There is deliberately no dwell-time or visibility-percentage gate:
        // those timing-dependent gates made slow desktop scrolling unreliable.
        let ids = exposures.compactMap { id, exposure -> Int64? in
            guard !emittedIDs.contains(id),
                  exposure.wasVisible,
                  unread.contains(id),
                  let frame = frames[id] else { return nil }
            let crossedTop = exposure.processedFrame.maxY > viewport.minY
                && frame.maxY <= viewport.minY
            return crossedTop ? id : nil
        }.sorted()
        emittedIDs.formUnion(ids)

        observe(frames: frames, viewport: viewport, unread: unread, now: now)
        for id in Array(exposures.keys) {
            if var exposure = exposures[id] {
                exposure.processedFrame = exposure.currentFrame
                exposures[id] = exposure
            }
        }
        return ids
    }
}

enum SnapshotRefreshPolicy {
    enum Action: Equatable { case replace, preserve, signalNewData }
    static func action(manual: Bool, dataChanged: Bool, hasMeaningfullyInteracted: Bool) -> Action {
        if manual || (dataChanged && !hasMeaningfullyInteracted) { return .replace }
        return dataChanged ? .signalNewData : .preserve
    }
}

struct PendingNewData: Equatable {
    private(set) var byFeed: [Int64: Int] = [:]
    var hasPending: Bool { byFeed.values.contains { $0 > 0 } }
    mutating func accumulate(_ additions: [(feedID: Int64, count: UInt32)]) { for a in additions where a.count > 0 { let (n, overflow) = (byFeed[a.feedID] ?? 0).addingReportingOverflow(Int(a.count)); byFeed[a.feedID] = overflow ? .max : n } }
    mutating func adoptAll() { byFeed.removeAll() }
    mutating func adoptFeed(_ id: Int64) { byFeed.removeValue(forKey: id) }
    mutating func adoptFeeds(in ids: Set<Int64>) { byFeed = byFeed.filter { !ids.contains($0.key) } }
    mutating func removeAbsentFeeds(_ ids: Set<Int64>) { byFeed = byFeed.filter { ids.contains($0.key) } }
}

enum PendingNewDataAggregation { static func count(feedIDs: [Int64], pendingByFeed: [Int64: Int]) -> Int { feedIDs.reduce(0) { $0 > Int.max - max(0, pendingByFeed[$1] ?? 0) ? .max : $0 + max(0, pendingByFeed[$1] ?? 0) } } }

struct ScrolloverUndoBatch {
    private var session = 0; private var batchSession: Int?; private(set) var articleIDs: [Int64] = []
    var showsUndo: Bool { articleIDs.count >= 2 }
    mutating func beginScroll() { session += 1 }
    mutating func append(_ ids: [Int64]) -> [Int64] { let unique = ids.reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }; guard !unique.isEmpty else { return articleIDs }; if batchSession != session { articleIDs = unique; batchSession = session } else { for id in unique where !articleIDs.contains(id) { articleIDs.append(id) } }; return articleIDs }
    mutating func clear() { articleIDs = []; batchSession = nil }
}
