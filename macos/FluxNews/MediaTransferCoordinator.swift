import Foundation
import OSLog

struct NativeTransferResult {
    let temporaryURL: URL
}

protocol MediaTransferEngine: Sendable {
    func download(from url: URL) async throws -> NativeTransferResult
}

struct URLSessionMediaTransferEngine: MediaTransferEngine {
    let networkPolicy: DownloadNetworkPolicy

    init(networkPolicy: DownloadNetworkPolicy = .anyNetwork) {
        self.networkPolicy = networkPolicy
    }

    func download(from url: URL) async throws -> NativeTransferResult {
        let configuration = URLSessionConfiguration.default
        if networkPolicy == .unmeteredOnly {
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
        }
        let session = URLSession(configuration: configuration)
        let (temporaryURL, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MediaTransferError.network
        }
        return NativeTransferResult(temporaryURL: temporaryURL)
    }
}

@MainActor
final class MediaTransferCoordinator {
    private let core: Flux
    private let mediaRoot: URL
    private var engine: MediaTransferEngine
    private var networkPolicy: DownloadNetworkPolicy
    private let isMediaInUse: (Int64) -> Bool
    private var activeTasks = [Int64: Task<Void, Never>]()

    init(core: Flux, mediaRoot: URL = MediaPlaybackPaths.mediaRootURL, networkPolicy: DownloadNetworkPolicy = .anyNetwork, engine: MediaTransferEngine? = nil, isMediaInUse: @escaping (Int64) -> Bool = { _ in false }) {
        self.core = core
        self.mediaRoot = mediaRoot
        self.networkPolicy = networkPolicy
        self.engine = engine ?? URLSessionMediaTransferEngine(networkPolicy: networkPolicy)
        self.isMediaInUse = isMediaInUse
    }

    func reconcile() {
        do {
            let currentPolicy = try core.coreSettings().downloadNetworkPolicy
            if currentPolicy != networkPolicy {
                networkPolicy = currentPolicy
                engine = URLSessionMediaTransferEngine(networkPolicy: currentPolicy)
            }
            let requested = try core.downloadsRequiringTransfer()
            let requestedIDs = Set(requested.map(\.enclosureId))
            for work in requested where activeTasks[work.enclosureId] == nil { start(work) }
            for id in Array(activeTasks.keys) where !requestedIDs.contains(id) { activeTasks[id]?.cancel(); activeTasks[id] = nil }
            executeDeletions(try core.downloadsRequiringDeletion())
        } catch {
            Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media transfer reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel(enclosureID: Int64) { activeTasks[enclosureID]?.cancel(); activeTasks[enclosureID] = nil }

    private func start(_ work: MediaTransferWork) {
        guard let url = URL(string: work.url), url.scheme == "http" || url.scheme == "https" else {
            reportFailure(enclosureID: work.enclosureId, kind: .invalidMedia)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").info("media transfer started enclosure=\(work.enclosureId, privacy: .public)")
                let result = try await engine.download(from: url)
                try Task.checkCancellation()
                let reference = "downloads/enclosure-\(work.enclosureId).media"
                let destination = try safeDestination(reference)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: result.temporaryURL, to: destination)
                let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                try core.downloadFinished(enclosureId: work.enclosureId, localFile: reference, fileSizeBytes: UInt64(size?.int64Value ?? 0))
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").info("media transfer completed enclosure=\(work.enclosureId, privacy: .public)")
                activeTasks[work.enclosureId] = nil
            } catch is CancellationError {
                activeTasks[work.enclosureId] = nil
            } catch {
                activeTasks[work.enclosureId] = nil
                reportFailure(enclosureID: work.enclosureId, kind: Self.failureKind(for: error))
            }
        }
        activeTasks[work.enclosureId] = task
    }

    private func executeDeletions(_ workItems: [MediaTransferWork]) {
        for work in workItems {
            guard !isMediaInUse(work.enclosureId) else { continue }
            guard let reference = work.localFile, let path = try? safeDestination(reference) else { continue }
            do {
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                try core.downloadDeleted(enclosureId: work.enclosureId)
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").info("media deletion completed enclosure=\(work.enclosureId, privacy: .public)")
            } catch {
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media deletion failed enclosure=\(work.enclosureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func safeDestination(_ reference: String) throws -> URL {
        try MediaTransferFileLayout.destination(reference: reference, under: mediaRoot)
    }

    private func reportFailure(enclosureID: Int64, kind: DownloadFailureKind) {
        do { try core.downloadFailed(enclosureId: enclosureID, failureKind: kind) }
        catch { Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media failure callback failed enclosure=\(enclosureID, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    private static func failureKind(for error: Error) -> DownloadFailureKind {
        if let transferError = error as? MediaTransferError {
            return transferError == .network ? .network : .storage
        }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        return .unknown
    }
}

enum MediaTransferError: Error, Equatable { case network, storage, invalidMedia }

enum MediaTransferFileLayout {
    static func destination(reference: String, under root: URL) throws -> URL {
        guard !reference.hasPrefix("/"), !reference.contains("..") else { throw MediaTransferError.storage }
        let destination = root.appendingPathComponent(reference).standardizedFileURL
        guard destination.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw MediaTransferError.storage }
        return destination
    }
}
