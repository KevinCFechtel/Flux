import QuartzCore
import UIKit

// TEMPORARY PERFORMANCE DIAGNOSTIC — MUST NOT SHIP.
//
// The committed video measurement (`docs/tools/scroll-frame-analysis.swift`)
// proves how many display frames were dropped, because a pixel-identical frame
// in a 60 fps recording of a 60 Hz device is exactly one dropped frame. It
// cannot attribute a drop: a frame is lost either because the main thread
// missed the vsync, or because the render server could not composite in time.
//
// These two diagnostics close that gap without Instruments:
//
//   * `IOSUIKitTimelineScrollEdgeEffectDiagnostic` switches the iOS 26 scroll
//     edge effect at runtime, so one build and one session can record both the
//     shipping arm and an arm without continuous backdrop sampling.
//   * `IOSUIKitTimelineFrameHeadroomRecorder` records, per display frame, how
//     long the main thread stayed busy and how many vsyncs it skipped outright.
//
// Combining them answers the question the video alone cannot: of the measured
// drop rate, how much is app-controlled main-thread work, and how much is a
// fixed GPU cost that the remaining app-side work has to make room for.

/// Runtime arm for the iOS 26 scroll edge effect over the Timeline.
///
/// The Timeline deliberately scrolls under both the navigation bar and the
/// bottom bar (`ArticleListView`'s `.ignoresSafeArea`). The edge effect
/// therefore resamples freshly scrolled content every frame across the largest
/// possible area — a constant per-frame GPU term that is independent of scroll
/// velocity and list depth.
@MainActor
enum IOSUIKitTimelineScrollEdgeEffectDiagnostic {
    enum Arm: String, CaseIterable, Identifiable {
        /// Shipping behaviour: the system resolves the effect for both edges.
        case system
        /// Hard cutoff with a dividing line instead of a progressive blur.
        case hard
        /// No edge effect at all. Diagnostic only; not a proposed appearance.
        case hidden

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System (shipping)"
            case .hard: return "Hard cutoff"
            case .hidden: return "Disabled"
            }
        }
    }

    private static let defaultsKey = "flux.diagnostic.timelineScrollEdgeEffectArm"

    /// The Timeline's scroll view. Held weakly so the diagnostic never affects
    /// controller lifetime.
    private static weak var scrollView: UIScrollView?

    private(set) static var arm: Arm = UserDefaults.standard.string(forKey: defaultsKey)
        .flatMap(Arm.init(rawValue:)) ?? .system

    /// Registers the Timeline's scroll view and applies the current arm.
    static func adopt(_ newScrollView: UIScrollView) {
        scrollView = newScrollView
        apply(to: newScrollView)
    }

    static func setArm(_ newArm: Arm) {
        guard newArm != arm else { return }
        arm = newArm
        UserDefaults.standard.set(newArm.rawValue, forKey: defaultsKey)
        guard let scrollView else { return }
        apply(to: scrollView)
    }

    private static func apply(to scrollView: UIScrollView) {
        guard #available(iOS 26.0, *) else { return }
        switch arm {
        case .system:
            scrollView.topEdgeEffect.isHidden = false
            scrollView.bottomEdgeEffect.isHidden = false
            scrollView.topEdgeEffect.style = .automatic
            scrollView.bottomEdgeEffect.style = .automatic
        case .hard:
            scrollView.topEdgeEffect.isHidden = false
            scrollView.bottomEdgeEffect.isHidden = false
            scrollView.topEdgeEffect.style = .hard
            scrollView.bottomEdgeEffect.style = .hard
        case .hidden:
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
        }
    }
}

/// Runtime arm for the Scrollover Undo pill's background.
///
/// The pill floats over the scrolling Timeline and ships with
/// `.regularMaterial`, which resamples the content behind it every frame. It is
/// visible only while Scrollover is enabled and actively marking articles read,
/// so it is a render-server cost that appears exactly in the configuration the
/// user reports as less smooth. This arm separates that cost from the
/// Scrollover geometry sampler, which is main-thread work.
enum IOSUIKitTimelineScrolloverOverlayDiagnostic {
    static let defaultsKey = "flux.diagnostic.scrolloverUndoOverlayArm"

    enum Arm: String, CaseIterable, Identifiable {
        /// Shipping behaviour: a continuously sampling material blur.
        case material
        /// Solid fill; no backdrop sampling. Diagnostic only.
        case opaque

        var id: String { rawValue }

        var label: String {
            switch self {
            case .material: return "Material (shipping)"
            case .opaque: return "Opaque"
            }
        }
    }

    static var arm: Arm {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Arm.init(rawValue:)) ?? .material
    }
}

struct IOSUIKitTimelineFrameHeadroomSnapshot: Equatable {
    /// Display frames in which the main thread ran at least once.
    let sampledFrames: UInt64
    /// Vsyncs for which the display link callback never ran, because the main
    /// thread was still busy. Each one is a main-thread-caused dropped frame.
    let skippedVSyncs: UInt64
    /// Frames whose main-thread work never yielded before the next vsync.
    let unyieldedFrames: UInt64
    let expectedFrameNanoseconds: UInt64
    let totalBusyNanoseconds: UInt64
    let maximumBusyNanoseconds: UInt64
    /// Counts aligned with `IOSUIKitTimelineFrameHeadroomRecorder.busyBucketUpperBoundsMilliseconds`,
    /// plus one trailing overflow bucket.
    let busyBuckets: [UInt64]
    /// Scroll callbacks in which `contentSize.height` changed. With estimated
    /// self-sizing, every newly measured row rewrites the content height; the
    /// scroll destination is derived from it, so a change during deceleration is
    /// a position discontinuity rather than a timing problem.
    let contentHeightChanges: UInt64
    let maximumContentHeightJump: Double
    let totalContentHeightDrift: Double
    /// Samples taken while UIKit — not the finger — owned the scroll.
    let deceleratingSamples: UInt64
    /// Deceleration frames whose movement sped up or reversed. A decaying curve
    /// never does either, so each one is a position discontinuity.
    let deceleratingDiscontinuities: UInt64
    let maximumDeceleratingExcess: Double

    var averageBusyNanoseconds: UInt64 {
        sampledFrames == 0 ? 0 : totalBusyNanoseconds / sampledFrames
    }

    /// Share of sampled frames whose main-thread work alone exceeded the frame
    /// budget. This is the app-controlled part of the deficit.
    var mainThreadOverBudgetRate: Double? {
        guard sampledFrames > 0, expectedFrameNanoseconds > 0 else { return nil }
        let bounds = IOSUIKitTimelineFrameHeadroomRecorder.busyBucketUpperBoundsMilliseconds
        let budgetMilliseconds = Double(expectedFrameNanoseconds) / 1_000_000
        var overBudget: UInt64 = 0
        for (index, count) in busyBuckets.enumerated() {
            let lowerBound = index == 0 ? 0 : bounds[index - 1]
            if lowerBound >= budgetMilliseconds { overBudget &+= count }
        }
        return Double(overBudget) / Double(sampledFrames)
    }
}

/// Measures main-thread frame occupancy while the Timeline scrolls.
///
/// A `CADisplayLink` fires once per vsync. Its `timestamp` is the vsync it
/// belongs to, so a gap of more than one frame period between consecutive
/// callbacks means the main thread was still busy and the callback was skipped
/// entirely. Occupancy is measured from the callback to the run loop's
/// `beforeWaiting` activity, observed after Core Animation's own commit
/// observer, so it includes layout, display and the CATransaction commit.
@MainActor
final class IOSUIKitTimelineFrameHeadroomRecorder {
    static let busyBucketUpperBoundsMilliseconds: [Double] = [2, 4, 6, 8, 10, 12, 14, 16.7, 20, 25, 33, 50]

    private var displayLink: CADisplayLink?
    private var runLoopObserver: CFRunLoopObserver?
    private var previousTimestamp: CFTimeInterval?
    private var busyFrameStart: CFTimeInterval?
    private var expectedFrameSeconds: CFTimeInterval = 1.0 / 60
    private var sampledFrames: UInt64 = 0
    private var skippedVSyncs: UInt64 = 0
    private var unyieldedFrames: UInt64 = 0
    private var totalBusyNanoseconds: UInt64 = 0
    private var maximumBusyNanoseconds: UInt64 = 0
    private var busyBuckets = [UInt64](repeating: 0, count: busyBucketUpperBoundsMilliseconds.count + 1)
    private var previousContentHeight: Double?
    private var previousOffset: Double?
    private var previousOffsetDelta: Double?
    private var deceleratingSamples: UInt64 = 0
    private var deceleratingDiscontinuities: UInt64 = 0
    private var maximumDeceleratingExcess: Double = 0
    private var contentHeightChanges: UInt64 = 0
    private var maximumContentHeightJump: Double = 0
    private var totalContentHeightDrift: Double = 0

    func start() {
        installIfNeeded()
        previousTimestamp = nil
        busyFrameStart = nil
        displayLink?.isPaused = false
    }

    func stop() {
        displayLink?.isPaused = true
        previousTimestamp = nil
        busyFrameStart = nil
        previousContentHeight = nil
        previousOffset = nil
        previousOffsetDelta = nil
    }

    /// Call from `scrollViewDidScroll` while decelerating. UIKit owns the scroll
    /// then, and the offset must follow a monotonically decaying curve: it never
    /// speeds up and never reverses. Anything else is the content being moved by
    /// something other than the deceleration — measured directly on the offset
    /// instead of inferred from recorded pixels.
    func recordDeceleratingOffset(_ y: Double, isBouncing: Bool) {
        guard !isBouncing else {
            previousOffset = nil
            previousOffsetDelta = nil
            return
        }
        defer { previousOffset = y }
        guard let previousOffset else { return }
        let delta = y - previousOffset
        defer { previousOffsetDelta = delta }
        guard let previousOffsetDelta, abs(previousOffsetDelta) > 0.5 else { return }
        deceleratingSamples &+= 1

        let reversed = (delta > 0) != (previousOffsetDelta > 0) && abs(delta) > 0.5
        // A small tolerance absorbs the curve's own per-frame quantisation.
        let excess = abs(delta) - (abs(previousOffsetDelta) * 1.2 + 0.5)
        guard reversed || excess > 0 else { return }
        deceleratingDiscontinuities &+= 1
        maximumDeceleratingExcess = max(maximumDeceleratingExcess, reversed ? abs(delta) : excess)
    }

    /// Call from `scrollViewDidScroll`. A stable list has a stable content
    /// height; repeated changes mean the layout is still resolving estimates.
    func recordContentHeight(_ height: Double) {
        defer { previousContentHeight = height }
        guard let previousContentHeight, height != previousContentHeight else { return }
        let jump = abs(height - previousContentHeight)
        contentHeightChanges &+= 1
        maximumContentHeightJump = max(maximumContentHeightJump, jump)
        totalContentHeightDrift += jump
    }

    func reset() {
        sampledFrames = 0
        skippedVSyncs = 0
        unyieldedFrames = 0
        totalBusyNanoseconds = 0
        maximumBusyNanoseconds = 0
        busyBuckets = [UInt64](repeating: 0, count: Self.busyBucketUpperBoundsMilliseconds.count + 1)
        previousTimestamp = nil
        busyFrameStart = nil
        previousContentHeight = nil
        contentHeightChanges = 0
        maximumContentHeightJump = 0
        totalContentHeightDrift = 0
        previousOffset = nil
        previousOffsetDelta = nil
        deceleratingSamples = 0
        deceleratingDiscontinuities = 0
        maximumDeceleratingExcess = 0
    }

    func snapshot() -> IOSUIKitTimelineFrameHeadroomSnapshot {
        .init(
            sampledFrames: sampledFrames,
            skippedVSyncs: skippedVSyncs,
            unyieldedFrames: unyieldedFrames,
            expectedFrameNanoseconds: UInt64((expectedFrameSeconds * 1_000_000_000).rounded()),
            totalBusyNanoseconds: totalBusyNanoseconds,
            maximumBusyNanoseconds: maximumBusyNanoseconds,
            busyBuckets: busyBuckets,
            contentHeightChanges: contentHeightChanges,
            maximumContentHeightJump: maximumContentHeightJump,
            totalContentHeightDrift: totalContentHeightDrift,
            deceleratingSamples: deceleratingSamples,
            deceleratingDiscontinuities: deceleratingDiscontinuities,
            maximumDeceleratingExcess: maximumDeceleratingExcess
        )
    }

    private func installIfNeeded() {
        if displayLink == nil {
            let link = CADisplayLink(target: IOSUIKitTimelineFrameHeadroomProxy(recorder: self), selector: #selector(IOSUIKitTimelineFrameHeadroomProxy.fire(_:)))
            link.isPaused = true
            // `.common` keeps the callback running during scroll tracking.
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        guard runLoopObserver == nil else { return }
        // A large order runs after Core Animation's commit observer, so the
        // measured interval contains the whole main-thread frame.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            .max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.frameDidYield() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let period = link.targetTimestamp - link.timestamp
        if period > 0 { expectedFrameSeconds = period }

        if let busyFrameStart {
            // The run loop never reached `beforeWaiting` before this vsync, so
            // the previous frame's main-thread work outlasted a whole period.
            unyieldedFrames &+= 1
            record(busy: now - busyFrameStart)
        }

        if let previousTimestamp {
            let elapsedPeriods = (link.timestamp - previousTimestamp) / expectedFrameSeconds
            let skipped = Int((elapsedPeriods - 1).rounded())
            if skipped > 0 { skippedVSyncs &+= UInt64(skipped) }
        }
        previousTimestamp = link.timestamp
        busyFrameStart = now
    }

    private func frameDidYield() {
        guard let busyFrameStart else { return }
        self.busyFrameStart = nil
        record(busy: CACurrentMediaTime() - busyFrameStart)
    }

    private func record(busy seconds: CFTimeInterval) {
        guard seconds >= 0 else { return }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        sampledFrames &+= 1
        totalBusyNanoseconds &+= nanoseconds
        maximumBusyNanoseconds = max(maximumBusyNanoseconds, nanoseconds)
        let milliseconds = seconds * 1000
        let index = Self.busyBucketUpperBoundsMilliseconds.firstIndex { milliseconds <= $0 }
            ?? Self.busyBucketUpperBoundsMilliseconds.count
        busyBuckets[index] &+= 1
    }
}

/// `CADisplayLink` retains its target; the proxy keeps that retain off the
/// recorder so pausing is the only lifetime concern.
private final class IOSUIKitTimelineFrameHeadroomProxy: NSObject {
    private weak var recorder: IOSUIKitTimelineFrameHeadroomRecorder?

    init(recorder: IOSUIKitTimelineFrameHeadroomRecorder) {
        self.recorder = recorder
    }

    @objc func fire(_ link: CADisplayLink) {
        MainActor.assumeIsolated { recorder?.displayLinkFired(link) }
    }
}

/// Process-wide access point, mirroring the existing Timeline diagnostics seam.
@MainActor
enum IOSUIKitTimelineFrameHeadroomDiagnostics {
    static let recorder = IOSUIKitTimelineFrameHeadroomRecorder()

    static func formattedSnapshot() -> String {
        let snapshot = recorder.snapshot()
        guard snapshot.sampledFrames > 0 else {
            return "No scroll frames sampled yet. Scroll the Timeline, then reopen this screen."
        }
        let budgetMilliseconds = Double(snapshot.expectedFrameNanoseconds) / 1_000_000
        var lines: [String] = []
        lines.append(String(format: "budget %.1f ms/frame", budgetMilliseconds))
        lines.append("frames \(snapshot.sampledFrames)")
        lines.append("skippedVSyncs \(snapshot.skippedVSyncs)")
        lines.append("unyielded \(snapshot.unyieldedFrames)")
        lines.append(String(format: "busy avg %.2f ms  max %.2f ms",
                            Double(snapshot.averageBusyNanoseconds) / 1_000_000,
                            Double(snapshot.maximumBusyNanoseconds) / 1_000_000))
        if let rate = snapshot.mainThreadOverBudgetRate {
            lines.append(String(format: "mainThreadOverBudget %.2f %%", rate * 100))
        }
        let skippedRate = Double(snapshot.skippedVSyncs) / Double(snapshot.sampledFrames + snapshot.skippedVSyncs)
        lines.append(String(format: "skippedVSyncRate %.2f %%", skippedRate * 100))

        let bounds = IOSUIKitTimelineFrameHeadroomRecorder.busyBucketUpperBoundsMilliseconds
        var histogram: [String] = []
        for (index, count) in snapshot.busyBuckets.enumerated() where count > 0 {
            let label = index == bounds.count
                ? String(format: ">%.1f", bounds[bounds.count - 1])
                : String(format: "≤%.1f", bounds[index])
            histogram.append("\(label)=\(count)")
        }
        lines.append("busyMs " + histogram.joined(separator: " "))
        lines.append(String(format: "contentHeight changes=%llu maxJump=%.0f pt drift=%.0f pt",
                            snapshot.contentHeightChanges,
                            snapshot.maximumContentHeightJump,
                            snapshot.totalContentHeightDrift))
        lines.append(String(format: "decel frames=%llu discontinuities=%llu maxExcess=%.1f pt",
                            snapshot.deceleratingSamples,
                            snapshot.deceleratingDiscontinuities,
                            snapshot.maximumDeceleratingExcess))
        return lines.joined(separator: "\n")
    }
}
