import Foundation
import OSLog

struct NativeTransferResult {
    let temporaryURL: URL
}

protocol MediaTransferEngine: Sendable {
    func download(from url: URL) async throws -> NativeTransferResult
}

@MainActor
protocol MediaTransferCore: AnyObject {
    func coreSettings() throws -> CoreSettings
    func downloadsRequiringTransfer() throws -> [MediaTransferWork]
    func downloadsRequiringDeletion() throws -> [MediaTransferWork]
    func downloadFinished(enclosureId: Int64, localFile: String, fileSizeBytes: UInt64) throws
    func downloadFailed(enclosureId: Int64, failureKind: DownloadFailureKind) throws
    func downloadDeleted(enclosureId: Int64) throws
}

enum MediaTransferNetworkConfiguration {
    static func configuration(for policy: DownloadNetworkPolicy) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = policy == .anyNetwork
        configuration.allowsConstrainedNetworkAccess = policy == .anyNetwork
        return configuration
    }
}

struct URLSessionMediaTransferEngine: MediaTransferEngine {
    let networkPolicy: DownloadNetworkPolicy

    init(networkPolicy: DownloadNetworkPolicy = .anyNetwork) {
        self.networkPolicy = networkPolicy
    }

    func download(from url: URL) async throws -> NativeTransferResult {
        let session = URLSession(configuration: MediaTransferNetworkConfiguration.configuration(for: networkPolicy))
        let (temporaryURL, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MediaTransferError.network
        }
        return NativeTransferResult(temporaryURL: temporaryURL)
    }
}

@MainActor
final class MediaTransferCoordinator {
    private let core: MediaTransferCore
    private let mediaRoot: URL
    private var engine: MediaTransferEngine
    private var networkPolicy: DownloadNetworkPolicy
    private let isMediaInUse: (Int64) -> Bool
    private var activeTasks = [Int64: Task<Void, Never>]()
    private var activeTaskTokens = [Int64: UUID]()

    init(core: MediaTransferCore, mediaRoot: URL = MediaPlaybackPaths.mediaRootURL, networkPolicy: DownloadNetworkPolicy = .anyNetwork, engine: MediaTransferEngine? = nil, isMediaInUse: @escaping (Int64) -> Bool = { _ in false }) {
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
            for id in Array(activeTasks.keys) where !requestedIDs.contains(id) {
                activeTasks[id]?.cancel()
                activeTasks[id] = nil
                activeTaskTokens[id] = nil
            }
            executeDeletions(try core.downloadsRequiringDeletion())
        } catch {
            Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media transfer reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel(enclosureID: Int64) {
        activeTasks[enclosureID]?.cancel()
        activeTasks[enclosureID] = nil
        activeTaskTokens[enclosureID] = nil
    }

    private func start(_ work: MediaTransferWork) {
        guard let url = URL(string: work.url), url.scheme == "http" || url.scheme == "https" else {
            reportFailure(enclosureID: work.enclosureId, kind: .invalidMedia)
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").info("media transfer started enclosure=\(work.enclosureId, privacy: .public)")
            let result: NativeTransferResult
            do {
                result = try await engine.download(from: url)
            } catch is CancellationError {
                finish(enclosureID: work.enclosureId, token: token)
                return
            } catch {
                finish(enclosureID: work.enclosureId, token: token)
                reportFailure(enclosureID: work.enclosureId, kind: Self.failureKind(for: error))
                return
            }

            let reference = "downloads/enclosure-\(work.enclosureId).media"
            let destination: URL
            do {
                destination = try safeDestination(reference)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: result.temporaryURL, to: destination)
            } catch {
                finish(enclosureID: work.enclosureId, token: token)
                reportFailure(enclosureID: work.enclosureId, kind: .storage)
                return
            }

            let size: UInt64
            do {
                let value = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                size = UInt64(value?.int64Value ?? 0)
            } catch {
                finish(enclosureID: work.enclosureId, token: token)
                reportFailure(enclosureID: work.enclosureId, kind: .storage)
                return
            }

            do {
                try core.downloadFinished(enclosureId: work.enclosureId, localFile: reference, fileSizeBytes: size)
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").info("media transfer completed enclosure=\(work.enclosureId, privacy: .public)")
            } catch {
                // Core owns stale-callback handling; a callback rejection is not a transfer failure.
                Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "media").error("media completion callback rejected enclosure=\(work.enclosureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            finish(enclosureID: work.enclosureId, token: token)
        }
        activeTaskTokens[work.enclosureId] = token
        activeTasks[work.enclosureId] = task
    }

    private func finish(enclosureID: Int64, token: UUID) {
        guard activeTaskTokens[enclosureID] == token else { return }
        activeTaskTokens[enclosureID] = nil
        activeTasks[enclosureID] = nil
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

    static func failureKind(for error: Error) -> DownloadFailureKind {
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

extension Flux: MediaTransferCore {}
