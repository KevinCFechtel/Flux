// Scroll frame-drop analysis for iOS screen recordings.
//
//   swiftc -O docs/tools/scroll-frame-analysis.swift -o /tmp/sfa
//   /tmp/sfa docs/ScreenRecording1.MP4              # summary
//   /tmp/sfa docs/ScreenRecording1.MP4 --csv        # per-frame CSV on stdout
//
// Requires a recording whose frame rate matches the device refresh rate
// (60 fps recording on a 60 Hz device). Under that condition a pixel-identical
// consecutive frame is exactly one dropped display frame.
//
// Method: each frame is reduced to a 640-entry row-luminance profile. The
// vertical scroll offset between consecutive frames is estimated by SAD
// cross-correlation; `mad` is the mean absolute profile difference and detects
// duplicated frames. Motion is classified from the median neighbour velocity so
// a dropped frame cannot suppress its own classification.

import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: sfa <recording.mp4> [--csv]\n".data(using: .utf8)!)
    exit(2)
}
let emitCSV = arguments.contains("--csv")
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))

// Profile resolution and the point conversion below assume a full-resolution
// portrait iPhone capture; both are derived from the track, not hard-coded.
let profileHeight = 640
let profileWidth = 64
let maximumShift = 120
let duplicateThreshold = 0.06
let motionThreshold = 300.0 // pt/s

let ready = DispatchSemaphore(value: 0)
var videoTrack: AVAssetTrack?
var naturalSize = CGSize.zero
var nominalFrameRate: Float = 0
Task {
    let tracks = try? await asset.loadTracks(withMediaType: .video)
    videoTrack = tracks?.first
    if let track = videoTrack {
        naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
    }
    ready.signal()
}
ready.wait()

guard let videoTrack, naturalSize.height > 0 else {
    FileHandle.standardError.write("no readable video track\n".data(using: .utf8)!)
    exit(1)
}

// One profile row corresponds to this many device pixels; iOS renders at 3x on
// the phones this timeline targets, so points are pixels / 3.
let pixelsPerProfileRow = naturalSize.height / CGFloat(profileHeight)
let pointsPerProfileRow = Double(pixelsPerProfileRow / 3)

let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: profileWidth,
    kCVPixelBufferHeightKey as String: profileHeight,
])
output.alwaysCopiesSampleData = false
reader.add(output)
reader.startReading()

struct Frame {
    let time: Double
    let shift: Double
    let difference: Double
}

func estimateShift(_ previous: [Double], _ current: [Double]) -> Double {
    let count = previous.count
    var bestShift = 0
    var bestScore = Double.greatestFiniteMagnitude
    for shift in -maximumShift...maximumShift {
        var score = 0.0
        var samples = 0
        var index = max(0, -shift)
        let end = min(count, count - shift)
        guard end - index >= count / 3 else { continue }
        while index < end {
            score += abs(previous[index + shift] - current[index])
            samples += 1
            index += 1
        }
        // A tiny bias towards the smaller shift breaks ties on flat content.
        let penalized = score / Double(samples) + Double(abs(shift)) * 1e-9
        if penalized < bestScore {
            bestScore = penalized
            bestShift = shift
        }
    }
    return Double(bestShift)
}

var frames: [Frame] = []
var previousProfile: [Double]?

while let sample = output.copyNextSampleBuffer() {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var profile = [Double](repeating: 0, count: height)
    for y in 0..<height {
        var sum = 0.0
        let row = base + y * stride
        for x in 0..<width {
            let pixel = row + x * 4
            sum += 0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
        }
        profile[y] = sum / Double(width)
    }
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

    if let previousProfile {
        var difference = 0.0
        for index in 0..<height { difference += abs(previousProfile[index] - profile[index]) }
        frames.append(Frame(
            time: time,
            shift: estimateShift(previousProfile, profile),
            difference: difference / Double(height)
        ))
    }
    previousProfile = profile
}

guard !frames.isEmpty else {
    FileHandle.standardError.write("no frames decoded\n".data(using: .utf8)!)
    exit(1)
}

if emitCSV {
    print("index,time,shift,pointsPerSecond,difference")
    for (index, frame) in frames.enumerated() {
        let velocity = abs(frame.shift) * pointsPerProfileRow * Double(nominalFrameRate)
        print(String(format: "%d,%.4f,%.1f,%.0f,%.4f", index, frame.time, frame.shift, velocity, frame.difference))
    }
    exit(0)
}

// Median neighbour velocity, excluding the frame itself.
func neighbourVelocity(_ index: Int) -> Double {
    var window: [Double] = []
    for other in max(0, index - 4)...min(frames.count - 1, index + 4) where other != index {
        window.append(abs(frames[other].shift) * pointsPerProfileRow * Double(nominalFrameRate))
    }
    window.sort()
    return window[window.count / 2]
}

let velocities = (0..<frames.count).map(neighbourVelocity)
let totalScroll = frames.reduce(0.0) { $0 + abs($1.shift) * pointsPerProfileRow }

print(String(format: "recording      %.2f s, %.0f x %.0f, %.2f fps, %d frames",
             frames.last!.time, naturalSize.width, naturalSize.height, nominalFrameRate, frames.count + 1))
print(String(format: "total scroll   %.0f pt", totalScroll))
print("")
print("threshold   motionFrames  dropped   rate   events   scrolled   1 drop per")

for threshold in [motionThreshold, 1000, 2000] {
    let motion = (0..<frames.count).filter { velocities[$0] > threshold }
    guard !motion.isEmpty else { continue }
    let dropped = motion.filter { frames[$0].difference < duplicateThreshold }
    var events = 0
    var previous = -9
    for index in dropped {
        if index != previous + 1 { events += 1 }
        previous = index
    }
    let scrolled = motion.reduce(0.0) { $0 + abs(frames[$1].shift) * pointsPerProfileRow }
    print(String(format: "> %4.0f pt/s   %10d  %7d  %4.1f%%  %6d  %8.0f pt  %8.0f pt",
                 threshold, motion.count, dropped.count,
                 100 * Double(dropped.count) / Double(motion.count),
                 events, scrolled, scrolled / Double(max(1, events))))
}

print("")
print("drop rate by instantaneous velocity")
for (low, high) in [(300.0, 700.0), (700.0, 1200.0), (1200.0, 1800.0), (1800.0, 2500.0), (2500.0, .infinity)] {
    let bucket = (0..<frames.count).filter { velocities[$0] >= low && velocities[$0] < high }
    guard !bucket.isEmpty else { continue }
    let dropped = bucket.filter { frames[$0].difference < duplicateThreshold }
    print(String(format: "  %5.0f - %5.0f pt/s   frames %4d   dropped %3d   %4.1f%%",
                 low, min(high, 99999), bucket.count, dropped.count,
                 100 * Double(dropped.count) / Double(bucket.count)))
}
