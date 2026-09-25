import Foundation

enum MediaPlaybackPresentationStatus: Equatable {
    case stopped
    case paused
    case playing
}

enum MediaTransferRuntimePhase: Equatable {
    case starting
    case transferring
    case cancelling
}

struct MediaTransferRuntime: Equatable {
    let enclosureID: Int64
    let bytesReceived: Int64
    let expectedBytes: Int64?
    let phase: MediaTransferRuntimePhase

    var fraction: Double? {
        guard bytesReceived >= 0, let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(bytesReceived) / Double(expectedBytes), 0), 1)
    }
}
