import Combine
import Foundation
import OSLog

@MainActor
final class CoreBootstrapper: ObservableObject {
    enum LocalStateRebuildState: Equatable {
        case idle
        case rebuilding
        case succeeded
        case failed
    }

    enum State: Equatable {
        case starting
        case accountRequired
        case ready(String)
        case recoverableError(String)

        var title: String {
            switch self {
            case .starting: String(localized: "Starting")
            case .accountRequired: String(localized: "Account required")
            case .ready: String(localized: "Ready")
            case .recoverableError: String(localized: "Recoverable startup error")
            }
        }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var credentials: IOSMinifluxCredentials?
    @Published private(set) var validationMessage: String?
    @Published private(set) var validationDiagnostic: AccountValidationDiagnostic?
    @Published private(set) var isConfiguring = false
    @Published private(set) var localStateRebuildState: LocalStateRebuildState = .idle
    @Published private(set) var core: Flux?
    @Published private(set) var coreRevision: UInt64 = 0
    let credentialStore: IOSCredentialStoreProtocol
    let coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator
    var onCoreChanged: ((Flux?) -> Void)?
    var prepareForCoreReplacement: (() async -> Void)?
    var onCoreReplacementAborted: (() -> Void)?
    var prepareForLocalStateRebuild: (() -> Void)?
    var onLocalStateRebuildFinished: ((Flux) -> Void)?

    private let coreFactory: @Sendable (IOSMinifluxCredentials) throws -> Flux
    private let accountValidator: @Sendable (IOSMinifluxCredentials) throws -> AccountValidationAttempt
    private let localStateRebuilder: @Sendable (Flux) throws -> SyncCompleted
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews", category: "core")
    private var bootstrapGeneration: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var startupTaskGeneration: UInt64?
    private nonisolated static let defaultCoreFactory: @Sendable (IOSMinifluxCredentials) throws -> Flux = { try makeCore($0) }
    private nonisolated static let defaultAccountValidator: @Sendable (IOSMinifluxCredentials) throws -> AccountValidationAttempt = { validateAccount($0) }
    private nonisolated static let defaultLocalStateRebuilder: @Sendable (Flux) throws -> SyncCompleted = { try $0.rebuildLocalState() }

    init(
        credentialStore: IOSCredentialStoreProtocol = IOSKeychainCredentialStore(),
        coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator? = nil,
        coreFactory: @escaping @Sendable (IOSMinifluxCredentials) throws -> Flux = CoreBootstrapper.defaultCoreFactory,
        accountValidator: @escaping @Sendable (IOSMinifluxCredentials) throws -> AccountValidationAttempt = CoreBootstrapper.defaultAccountValidator,
        localStateRebuilder: @escaping @Sendable (Flux) throws -> SyncCompleted = CoreBootstrapper.defaultLocalStateRebuilder
    ) {
        self.credentialStore = credentialStore
        self.coreSessionExecutionCoordinator =
            coreSessionExecutionCoordinator ?? IOSCoreSessionExecutionCoordinator()
        self.coreFactory = coreFactory
        self.accountValidator = accountValidator
        self.localStateRebuilder = localStateRebuilder
    }

    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }
        guard case .starting = state else { return }

        let generation = nextBootstrapGeneration()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartup(generation: generation)
        }
        startupTask = task
        startupTaskGeneration = generation
        await task.value

        if startupTaskGeneration == generation {
            startupTask = nil
            startupTaskGeneration = nil
        }
    }

    /// Idempotent readiness entry point for both normal app startup and later
    /// headless/background launch paths. Concurrent callers await the same
    /// in-flight bootstrap instead of constructing a second Core.
    @discardableResult
    func ensureStarted() async -> Flux? {
        if let core { return core }
        await start()
        return core
    }

    private func performStartup(generation: UInt64) async {
        do {
            guard let stored = try credentialStore.load() else {
                guard generation == bootstrapGeneration else { return }
                state = .accountRequired
                return
            }
            credentials = stored
            _ = try await activate(stored, persist: false, generation: generation)
        } catch IOSCredentialStoreError.temporarilyUnavailable {
            // Before the first unlock after reboot, Keychain access can be
            // unavailable to a background launch. Keep startup retryable rather
            // than presenting a broken-account error. A later app-active or
            // background readiness request will retry the same bootstrap path.
            guard generation == bootstrapGeneration else { return }
            state = .starting
            logger.info("Core startup deferred until protected credentials become available.")
        } catch {
            guard generation == bootstrapGeneration else { return }
            state = .recoverableError(Self.safeMessage(for: error))
            logger.error("Core startup failed: \(String(reflecting: error), privacy: .private)")
        }
    }

    func retry() async {
        _ = nextBootstrapGeneration()
        state = .starting
        await start()
    }

    func configure(server: String, apiKey: String, headers: [IOSCustomHTTPHeader]) async {
        guard !isConfiguring, localStateRebuildState != .rebuilding else { return }
        localStateRebuildState = .idle
        let generation = nextBootstrapGeneration()
        isConfiguring = true
        defer { isConfiguring = false }
        validationMessage = nil
        validationDiagnostic = nil
        let proposed = IOSMinifluxCredentials(server: server.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey, customHeaders: headers)
        guard !proposed.server.isEmpty, !proposed.apiKey.isEmpty else {
            validationMessage = String(localized: "Enter both a Miniflux server URL and API key.")
            return
        }
        let validator = accountValidator
        let validation = await AppleCoreExecution.shared.blockingResult {
            try validator(proposed)
        }
        guard generation == bootstrapGeneration else { return }
        switch validation {
        case let .failure(error): validationMessage = IOSAccountValidationPresentation.message(for: IOSAccountValidationPresentation.failure(for: error))
        case let .success(attempt):
            validationDiagnostic = attempt.diagnostic
            if let error = attempt.error {
                validationMessage = IOSAccountValidationPresentation.message(for: IOSAccountValidationPresentation.failure(for: error))
                return
            }
            guard let result = attempt.result else {
                validationMessage = String(localized: "The Miniflux server returned an unexpected response.")
                validationDiagnostic = nil
                return
            }
            let normalized = IOSMinifluxCredentials(server: result.installationBase, apiKey: proposed.apiKey, customHeaders: proposed.customHeaders)
            do {
                let previous = credentials
                try credentialStore.save(normalized)
                do {
                    guard try await activate(normalized, persist: false, generation: generation) else { return }
                } catch {
                    if let previous { try? credentialStore.save(previous) } else { try? credentialStore.remove() }
                    throw error
                }
            } catch { validationMessage = String(localized: "The account could not be activated. Your previous account is still active.") }
        }
    }

    func rebuildLocalState() async {
        guard localStateRebuildState != .rebuilding else { return }
        guard let activeCore = core else {
            localStateRebuildState = .failed
            return
        }

        let generation = nextBootstrapGeneration()
        localStateRebuildState = .rebuilding
        validationMessage = nil

        // Manual Sync owns presentation work outside the app-wide Core gate.
        // Quiesce that lifecycle first, then close admission for every other
        // foreground/background Core caller before invalidating projections.
        await prepareForCoreReplacement?()
        await coreSessionExecutionCoordinator.quiesce()
        guard generation == bootstrapGeneration else {
            localStateRebuildState = .idle
            return
        }

        prepareForLocalStateRebuild?()

        let rebuilder = localStateRebuilder
        guard let result = await coreSessionExecutionCoordinator.exclusiveBlockingResult(
            for: activeCore,
            { try rebuilder(activeCore) }
        ) else {
            guard generation == bootstrapGeneration else {
                localStateRebuildState = .idle
                return
            }
            coreSessionExecutionCoordinator.resume(activeCore)
            onLocalStateRebuildFinished?(activeCore)
            localStateRebuildState = .failed
            return
        }

        guard generation == bootstrapGeneration else {
            // A newer account/session lifecycle operation now owns the quiesced
            // Core. Do not reopen admission or reattach stale presentation.
            localStateRebuildState = .idle
            return
        }

        coreSessionExecutionCoordinator.resume(activeCore)
        onLocalStateRebuildFinished?(activeCore)

        switch result {
        case .success:
            localStateRebuildState = .succeeded
        case let .failure(error):
            localStateRebuildState = .failed
            logger.error(
                "Local state rebuild failed after destructive reset: \(String(reflecting: error), privacy: .private)"
            )
        }
    }

    func removeAccount() async {
        guard localStateRebuildState != .rebuilding else { return }
        let generation = nextBootstrapGeneration()
        guard let activeCore = core else {
            try? credentialStore.remove()
            credentials = nil
            state = .accountRequired
            return
        }

        await prepareForCoreReplacement?()
        await coreSessionExecutionCoordinator.quiesce()
        guard generation == bootstrapGeneration else {
            coreSessionExecutionCoordinator.resume(activeCore)
            return
        }

        do {
            try await AppleCoreExecution.shared.responsive {
                try activeCore.removeAccountState()
            }
            guard generation == bootstrapGeneration else {
                coreSessionExecutionCoordinator.resume(activeCore)
                return
            }
            try credentialStore.remove()
            deactivateAfterCoreQuiescence()
            localStateRebuildState = .idle
            state = .accountRequired
        } catch {
            guard generation == bootstrapGeneration else { return }
            coreSessionExecutionCoordinator.resume(activeCore)
            onCoreReplacementAborted?()
            validationMessage = String(localized: "The account could not be removed.")
        }
    }

    var pathsDescription: String {
        guard let paths = try? CorePaths(createDirectories: false) else { return String(localized: "Unavailable") }
        return "Application Support: \(paths.persistentData.path)\nCaches: \(paths.cache.path)\nMedia: \(paths.media.path)"
    }

    private func activate(_ account: IOSMinifluxCredentials, persist: Bool, generation: UInt64) async throws -> Bool {
        if persist { try credentialStore.save(account) }

        let previousCore = core
        let replacingExistingCore = previousCore != nil
        if let previousCore {
            await prepareForCoreReplacement?()
            await coreSessionExecutionCoordinator.quiesce()
            guard generation == bootstrapGeneration else {
                coreSessionExecutionCoordinator.resume(previousCore)
                return false
            }
        }

        let factory = coreFactory
        let result = await AppleCoreExecution.shared.responsiveResult {
            try factory(account)
        }
        guard generation == bootstrapGeneration else { return false }

        let configuredCore: Flux
        do {
            configuredCore = try result.get()
        } catch {
            if let previousCore {
                coreSessionExecutionCoordinator.resume(previousCore)
                onCoreReplacementAborted?()
            }
            throw error
        }

        if replacingExistingCore {
            coreSessionExecutionCoordinator.deactivate()
        }
        coreSessionExecutionCoordinator.activate(configuredCore)
        core = configuredCore
        credentials = account
        localStateRebuildState = .idle
        coreRevision &+= 1
        state = .ready(String(localized: "Initialized"))
        onCoreChanged?(configuredCore)
        return true
    }

    func deactivate() async {
        let generation = nextBootstrapGeneration()
        if let activeCore = core {
            await prepareForCoreReplacement?()
            await coreSessionExecutionCoordinator.quiesce()
            guard generation == bootstrapGeneration else {
                coreSessionExecutionCoordinator.resume(activeCore)
                return
            }
        }
        deactivateAfterCoreQuiescence()
    }

    private func deactivateAfterCoreQuiescence() {
        if core != nil {
            coreSessionExecutionCoordinator.deactivate()
        }
        core = nil
        coreRevision &+= 1
        credentials = nil
        onCoreChanged?(nil)
    }

    private func nextBootstrapGeneration() -> UInt64 {
        bootstrapGeneration &+= 1
        // The underlying stale task may still be unwinding on AppleCoreExecution,
        // but generation guards make its publication inert. Clearing only this
        // reference allows an explicit retry/reconfiguration to start a new
        // bootstrap without waiting for stale synchronous work.
        startupTask = nil
        startupTaskGeneration = nil
        return bootstrapGeneration
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

    private nonisolated static func validateAccount(_ account: IOSMinifluxCredentials) -> AccountValidationAttempt {
        validateMinifluxAccountWithDiagnostic(
            serverUrl: account.server,
            apiKey: account.apiKey,
            customHeaders: account.customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }
        )
    }

    private static func safeMessage(for error: Error) -> String {
        IOSErrorPresentation.message(for: error, context: .startup)
    }
}

private struct CorePaths {
    let persistentData: URL
    let cache: URL
    let media: URL

    init(createDirectories: Bool = true) throws {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw CocoaError(.fileNoSuchFile) }
        let namespace = (Bundle.main.object(forInfoDictionaryKey: "FluxStorageNamespace") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "FluxNewsNativeDev"
        persistentData = applicationSupport.appendingPathComponent("\(namespace)/Core", isDirectory: true)
        cache = caches.appendingPathComponent("\(namespace)/CoreCache", isDirectory: true)
        media = applicationSupport.appendingPathComponent("\(namespace)/Media", isDirectory: true)
        if createDirectories {
            for directory in [persistentData, cache, media] { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
    }
}
