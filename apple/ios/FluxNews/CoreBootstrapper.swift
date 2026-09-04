import Combine
import Foundation
import OSLog

@MainActor
final class CoreBootstrapper: ObservableObject {
    enum State: Equatable {
        case starting
        case accountRequired
        case ready(String)
        case recoverableError(String)

        var title: String {
            switch self {
            case .starting: "Starting"
            case .accountRequired: "Account required"
            case .ready: "Ready"
            case .recoverableError: "Recoverable startup error"
            }
        }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var credentials: IOSMinifluxCredentials?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isConfiguring = false
    @Published private(set) var core: Flux?
    @Published private(set) var coreRevision: UInt64 = 0
    let credentialStore: IOSCredentialStoreProtocol
    var onCoreChanged: ((Flux?) -> Void)?

    private let coreFactory: (IOSMinifluxCredentials) throws -> Flux
    private let accountValidator: (IOSMinifluxCredentials) throws -> AccountValidationResult
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews", category: "core")

    init(
        credentialStore: IOSCredentialStoreProtocol = IOSKeychainCredentialStore(),
        coreFactory: @escaping (IOSMinifluxCredentials) throws -> Flux = CoreBootstrapper.makeCore,
        accountValidator: @escaping (IOSMinifluxCredentials) throws -> AccountValidationResult = CoreBootstrapper.validateAccount
    ) {
        self.credentialStore = credentialStore
        self.coreFactory = coreFactory
        self.accountValidator = accountValidator
    }

    func start() async {
        guard case .starting = state else { return }
        do {
            guard let stored = try credentialStore.load() else {
                state = .accountRequired
                return
            }
            credentials = stored
            try activate(stored, persist: false)
        } catch {
            state = .recoverableError(Self.safeMessage(for: error))
            logger.error("Core startup failed: \(Self.safeMessage(for: error), privacy: .public)")
        }
    }

    func retry() async {
        state = .starting
        await start()
    }

    func configure(server: String, apiKey: String, headers: [IOSCustomHTTPHeader]) async {
        guard !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        validationMessage = nil
        let proposed = IOSMinifluxCredentials(server: server.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey, customHeaders: headers)
        guard !proposed.server.isEmpty, !proposed.apiKey.isEmpty else {
            validationMessage = "Enter both a Miniflux server URL and API key."
            return
        }
        let validator = accountValidator
        let validation = await Task.detached(priority: .userInitiated) {
            Result { try validator(proposed) }
        }.value
        switch validation {
        case let .failure(error): validationMessage = IOSAccountValidationPresentation.message(for: IOSAccountValidationPresentation.failure(for: error))
        case let .success(result):
            let normalized = IOSMinifluxCredentials(server: result.installationBase, apiKey: proposed.apiKey, customHeaders: proposed.customHeaders)
            do {
                let previous = credentials
                try credentialStore.save(normalized)
                do {
                    try activate(normalized, persist: false)
                } catch {
                    if let previous { try? credentialStore.save(previous) } else { try? credentialStore.remove() }
                    throw error
                }
            } catch { validationMessage = "The account could not be activated. Your previous account is still active." }
        }
    }

    func removeAccount() async {
        guard let activeCore = core else {
            try? credentialStore.remove()
            credentials = nil
            state = .accountRequired
            return
        }
        do {
            try await Task.detached { try activeCore.removeAccountState() }.value
            try credentialStore.remove()
            deactivate()
            state = .accountRequired
        } catch { validationMessage = "The account could not be removed." }
    }

    var pathsDescription: String {
        guard let paths = try? CorePaths() else { return "Unavailable" }
        return "Application Support: \(paths.persistentData.path)\nCaches: \(paths.cache.path)\nMedia: \(paths.media.path)"
    }

    private func activate(_ account: IOSMinifluxCredentials, persist: Bool) throws {
        if persist { try credentialStore.save(account) }
        let configuredCore = try coreFactory(account)
        core = configuredCore
        credentials = account
        coreRevision &+= 1
        state = .ready("Initialized")
        onCoreChanged?(configuredCore)
    }

    func deactivate() {
        core = nil
        coreRevision &+= 1
        credentials = nil
        onCoreChanged?(nil)
    }

    private nonisolated static func makeCore(_ account: IOSMinifluxCredentials) throws -> Flux {
        let paths = try CorePaths()
        return try Flux.initialize(config: InitializationConfig(
            persistentData: paths.persistentData.path,
            cache: paths.cache.path,
            media: paths.media.path,
            baseUrl: account.server,
            apiKey: account.apiKey,
            customHeaders: account.customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }
        ))
    }

    private nonisolated static func validateAccount(_ account: IOSMinifluxCredentials) throws -> AccountValidationResult {
        try validateMinifluxAccount(
            serverUrl: account.server,
            apiKey: account.apiKey,
            customHeaders: account.customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }
        )
    }

    private static func safeMessage(for error: Error) -> String {
        if let validation = error as? AccountValidationError { return IOSAccountValidationPresentation.message(for: IOSAccountValidationPresentation.failure(for: validation)) }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Flux could not start. Check the account configuration and try again." : message
    }
}

private struct CorePaths {
    let persistentData: URL
    let cache: URL
    let media: URL

    init() throws {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw CocoaError(.fileNoSuchFile) }
        let namespace = (Bundle.main.object(forInfoDictionaryKey: "FluxStorageNamespace") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "FluxNewsNativeDev"
        persistentData = applicationSupport.appendingPathComponent("\(namespace)/Core", isDirectory: true)
        cache = caches.appendingPathComponent("\(namespace)/CoreCache", isDirectory: true)
        media = applicationSupport.appendingPathComponent("\(namespace)/Media", isDirectory: true)
        for directory in [persistentData, cache, media] { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
}
