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


enum MediaChapterPresentation {
    static func usesGeneratedTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        guard !normalized.isEmpty else { return true }

        for prefix in ["cp", "ch", "chp", "chap", "chapter"] {
            guard normalized.hasPrefix(prefix) else { continue }
            let suffix = normalized.dropFirst(prefix.count)
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }
}
