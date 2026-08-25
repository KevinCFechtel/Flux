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
