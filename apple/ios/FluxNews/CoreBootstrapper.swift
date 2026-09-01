import Foundation
import OSLog
import Combine

@MainActor
final class CoreBootstrapper: ObservableObject {
    enum State: Equatable {
        case starting
        case unconfigured
        case ready(String)
        case error(String)

        var title: String {
            switch self {
            case .starting: "Starting"
            case .unconfigured: "Unconfigured"
            case .ready: "Ready"
            case .error: "Error"
            }
        }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var legacyResult = LegacyStateDiscovery.probe()
    private(set) var core: Flux?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews", category: "core")

    func start() async {
        guard core == nil else { return }
        state = .starting
        legacyResult = LegacyStateDiscovery.probe()

        do {
            let paths = try CorePaths()
            guard let baseURL = ProcessInfo.processInfo.environment["FLUX_DEV_BASE_URL"],
                  let apiKey = ProcessInfo.processInfo.environment["FLUX_DEV_API_KEY"],
                  !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !apiKey.isEmpty else {
                state = .unconfigured
                return
            }

            let configuredCore = try Flux.initialize(config: InitializationConfig(
                persistentData: paths.persistentData.path,
                cache: paths.cache.path,
                media: paths.media.path,
                baseUrl: baseURL,
                apiKey: apiKey,
                customHeaders: []
            ))
            core = configuredCore

            let health = try configuredCore.runtimeHealth()
            state = .ready(String(describing: health.health))
            logger.info("Core initialized; runtime health check completed")
        } catch {
            state = .error(Self.safeMessage(for: error))
            logger.error("Core initialization or smoke test failed: \(Self.safeMessage(for: error), privacy: .public)")
        }
    }

    var pathsDescription: String {
        guard let paths = try? CorePaths() else { return "Unavailable" }
        return "Application Support: \(paths.persistentData.path)\nCaches: \(paths.cache.path)\nMedia: \(paths.media.path)"
    }

    private static func safeMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "The Core operation failed." : message
    }
}

private struct CorePaths {
    let persistentData: URL
    let cache: URL
    let media: URL

    init() throws {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let namespace = (Bundle.main.object(forInfoDictionaryKey: "FluxStorageNamespace") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "FluxNewsNativeDev"
        persistentData = applicationSupport.appendingPathComponent("\(namespace)/Core", isDirectory: true)
        cache = caches.appendingPathComponent("\(namespace)/CoreCache", isDirectory: true)
        media = applicationSupport.appendingPathComponent("\(namespace)/Media", isDirectory: true)

        for directory in [persistentData, cache, media] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
