import XCTest
@testable import FluxNews

final class AccountLifecycleTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Value

        init(_ value: Value) { storedValue = value }

        func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&storedValue)
        }

        func value() -> Value {
            withValue { $0 }
        }
    }

    private final class FirstFactoryGate: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirstFactory = DispatchSemaphore(value: 0)
        private var firstFactoryStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var callCount = 0
        private var storedAccounts: [IOSMinifluxCredentials] = []

        func make(_ account: IOSMinifluxCredentials, first: Flux, subsequent: Flux) -> Flux {
            let shouldWait = withLock {
                callCount += 1
                storedAccounts.append(account)
                guard callCount == 1 else { return false }
                firstFactoryStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
                return true
            }
            if shouldWait { releaseFirstFactory.wait() }
            return shouldWait ? first : subsequent
        }

        func waitUntilFirstFactoryStarts() async {
            await withCheckedContinuation { continuation in
                let shouldResume = withLock {
                    if firstFactoryStarted { return true }
                    startWaiters.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }

        func releaseFirst() { releaseFirstFactory.signal() }

        private func withLock<Result>(_ body: () -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private func makeCore(for credentials: IOSMinifluxCredentials) throws -> Flux {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("data")
        let cache = root.appendingPathComponent("cache")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return try Flux.initialize(config: InitializationConfig(
            persistentData: data.path,
            cache: cache.path,
            media: media.path,
            baseUrl: credentials.server,
            apiKey: credentials.apiKey,
            customHeaders: credentials.customHeaders.map { HttpHeader(name: $0.name, value: $0.value) }
        ))
    }

    func testCredentialStoreRoundTripsHeadersAndDoesNotDescribeSecrets() throws {
        let store = IOSMemoryCredentialStore()
        let credentials = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "super-secret-key",
            customHeaders: [IOSCustomHTTPHeader(name: "X-Tenant", value: "secret-header")]
        )

        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
        XCTAssertFalse(credentials.description.contains(credentials.apiKey))
        XCTAssertFalse(credentials.description.contains("secret-header"))
        try store.remove()
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testStartupWithoutCredentialsRequiresAnAccount() async {
        let bootstrapper = CoreBootstrapper(credentialStore: IOSMemoryCredentialStore())

        await bootstrapper.start()

        XCTAssertEqual(bootstrapper.state, .accountRequired)
        XCTAssertNil(bootstrapper.core)
    }

    @MainActor
    func testStoredCredentialStartupFailureIsRecoverable() async throws {
        let store = IOSMemoryCredentialStore()
        try store.save(IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: []))
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { _ in
            throw NSError(domain: "FluxNewsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreachable"])
        })

        await bootstrapper.start()

        XCTAssertEqual(bootstrapper.state, .recoverableError("unreachable"))
        XCTAssertNotNil(bootstrapper.credentials)
    }

    @MainActor
    func testStoredCredentialsActivateWithHeaders() async throws {
        let credentials = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: [IOSCustomHTTPHeader(name: "X-Tenant", value: "tenant")]
        )
        let store = IOSMemoryCredentialStore()
        try store.save(credentials)
        let activated = LockedBox<IOSMinifluxCredentials?>(nil)
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            activated.withValue { $0 = account }
            return try self.makeCore(for: account)
        })

        await bootstrapper.start()

        XCTAssertTrue({ if case .ready = bootstrapper.state { return true }; return false }())
        XCTAssertEqual(activated.value(), credentials)
        XCTAssertEqual(bootstrapper.credentials, credentials)
    }

    @MainActor
    func testFailedAccountEditKeepsPreviousAccountAndRuntime() async throws {
        let previous = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(previous)
        let core = try makeCore(for: previous)
        let validatorInput = LockedBox<IOSMinifluxCredentials?>(nil)
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { _ in core }, accountValidator: { account in
            validatorInput.withValue { $0 = account }
            throw AccountValidationError.Unauthorized
        })
        await bootstrapper.start()

        await bootstrapper.configure(server: "https://new.example", apiKey: "new-key", headers: [IOSCustomHTTPHeader(name: "X-Tenant", value: "new")])

        XCTAssertEqual(validatorInput.value()?.customHeaders.first?.value, "new")
        XCTAssertEqual(try store.load(), previous)
        XCTAssertIdentical(bootstrapper.core, core)
        XCTAssertEqual(bootstrapper.credentials, previous)
    }

    @MainActor
    func testSuccessfulAccountEditReplacesCoreAndPersistsNormalizedHeaders() async throws {
        let old = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let replacement = IOSMinifluxCredentials(server: "https://new.example", apiKey: "new-key", customHeaders: [IOSCustomHTTPHeader(name: "X-Tenant", value: "new")])
        let store = IOSMemoryCredentialStore()
        try store.save(old)
        let oldCore = try makeCore(for: old)
        let newCore = try makeCore(for: replacement)
        let factoryInputs = LockedBox<[IOSMinifluxCredentials]>([])
        var changes: [Flux?] = []
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            let isInitialActivation = factoryInputs.withValue {
                $0.append(account)
                return $0.count == 1
            }
            return isInitialActivation ? oldCore : newCore
        }, accountValidator: { account in
            AccountValidationAttempt(
                result: AccountValidationResult(installationBase: "https://new.example", version: "2.0"),
                error: nil,
                diagnostic: nil
            )
        })
        bootstrapper.onCoreChanged = { changes.append($0) }
        await bootstrapper.start()
        await bootstrapper.configure(server: " https://new.example/ ", apiKey: "new-key", headers: replacement.customHeaders)

        XCTAssertEqual(try store.load(), replacement)
        XCTAssertEqual(bootstrapper.credentials, replacement)
        XCTAssertIdentical(bootstrapper.core, newCore)
        XCTAssertEqual(factoryInputs.value(), [old, replacement])
        XCTAssertEqual(changes.count, 2)
        XCTAssertIdentical(changes[0], oldCore)
        XCTAssertIdentical(changes[1], newCore)
    }

    func testValidationMessagesDoNotContainCredentialValues() {
        let message = IOSAccountValidationPresentation.message(for: .unauthorized)

        XCTAssertFalse(message.contains("super-secret-key"))
        XCTAssertFalse(message.contains("secret-header"))
    }

    @MainActor
    func testValidationDiagnosticIsTransientAndDoesNotReplaceFriendlyMessage() async throws {
        let store = IOSMemoryCredentialStore()
        let core = try makeCore(for: IOSMinifluxCredentials(server: "https://example.com", apiKey: "key", customHeaders: []))
        let shouldFail = LockedBox(true)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core },
            accountValidator: { _ in
                if shouldFail.value() {
                    return AccountValidationAttempt(
                        result: nil,
                        error: .Network,
                        diagnostic: AccountValidationDiagnostic(category: "TLS/certificate", detail: "certificate verify failed")
                    )
                }
                return AccountValidationAttempt(
                    result: AccountValidationResult(installationBase: "https://example.com", version: "2.0"),
                    error: nil,
                    diagnostic: nil
                )
            }
        )

        await bootstrapper.configure(server: "https://example.com", apiKey: "api-secret", headers: [IOSCustomHTTPHeader(name: "X-Test", value: "header-secret")])

        XCTAssertEqual(bootstrapper.validationMessage, "The Miniflux server could not be reached. Check the server URL and network connection.")
        XCTAssertEqual(bootstrapper.validationDiagnostic?.category, "TLS/certificate")
        XCTAssertEqual(bootstrapper.validationDiagnostic?.detail, "certificate verify failed")
        XCTAssertFalse(bootstrapper.validationDiagnostic?.detail.contains("api-secret") == true)
        XCTAssertFalse(bootstrapper.validationDiagnostic?.detail.contains("header-secret") == true)

        shouldFail.withValue { $0 = false }
        await bootstrapper.configure(server: "https://example.com", apiKey: "api-secret", headers: [])

        XCTAssertNil(bootstrapper.validationDiagnostic)
        XCTAssertNil(bootstrapper.validationMessage)
    }

    @MainActor
    func testStartupFactoryRunsOffMainAndPublishesAfterCompletion() async throws {
        let account = IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let gate = FirstFactoryGate()
        let ranOnMainThread = LockedBox<Bool?>(nil)
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { credentials in
            ranOnMainThread.withValue { $0 = Thread.isMainThread }
            return gate.make(credentials, first: core, subsequent: core)
        })

        let startup = Task { await bootstrapper.start() }
        await gate.waitUntilFirstFactoryStarts()

        XCTAssertNil(bootstrapper.core)
        XCTAssertEqual(bootstrapper.state, .starting)
        XCTAssertEqual(ranOnMainThread.value(), false)
        gate.releaseFirst()
        await startup.value

        XCTAssertIdentical(bootstrapper.core, core)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
    }

    @MainActor
    func testRetryDiscardsStaleStartupResult() async throws {
        let account = IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let staleCore = try makeCore(for: account)
        let currentCore = try makeCore(for: account)
        let gate = FirstFactoryGate()
        var changes: [Flux?] = []
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { credentials in
            gate.make(credentials, first: staleCore, subsequent: currentCore)
        })
        bootstrapper.onCoreChanged = { changes.append($0) }

        let firstStartup = Task { await bootstrapper.start() }
        await gate.waitUntilFirstFactoryStarts()
        let retry = Task { await bootstrapper.retry() }
        await retry.value
        gate.releaseFirst()
        await firstStartup.value

        XCTAssertIdentical(bootstrapper.core, currentCore)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
        XCTAssertEqual(changes.count, 1)
        XCTAssertIdentical(changes[0], currentCore)
    }

    @MainActor
    func testDeactivateDiscardsInFlightStartupFailure() async throws {
        let account = IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let fallbackCore = try makeCore(for: account)
        let gate = FirstFactoryGate()
        var changes: [Flux?] = []
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { credentials in
            _ = gate.make(credentials, first: fallbackCore, subsequent: fallbackCore)
            throw NSError(domain: "FluxNewsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "stale failure"])
        })
        bootstrapper.onCoreChanged = { changes.append($0) }

        let startup = Task { await bootstrapper.start() }
        await gate.waitUntilFirstFactoryStarts()
        bootstrapper.deactivate()
        gate.releaseFirst()
        await startup.value

        XCTAssertNil(bootstrapper.core)
        XCTAssertEqual(bootstrapper.state, .starting)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes[0])
    }

    @MainActor
    func testRemoveAccountDiscardsInFlightStartupResult() async throws {
        let account = IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let gate = FirstFactoryGate()
        var changes: [Flux?] = []
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { credentials in
            gate.make(credentials, first: core, subsequent: core)
        })
        bootstrapper.onCoreChanged = { changes.append($0) }

        let startup = Task { await bootstrapper.start() }
        await gate.waitUntilFirstFactoryStarts()
        await bootstrapper.removeAccount()
        gate.releaseFirst()
        await startup.value

        XCTAssertNil(bootstrapper.core)
        XCTAssertNil(bootstrapper.credentials)
        XCTAssertEqual(bootstrapper.state, .accountRequired)
        XCTAssertEqual(bootstrapper.coreRevision, 0)
        XCTAssertTrue(changes.isEmpty)
    }

    @MainActor
    func testStaleConfigureActivationDoesNotReplaceActiveAccount() async throws {
        let old = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let replacement = IOSMinifluxCredentials(server: "https://new.example", apiKey: "new-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(old)
        let oldCore = try makeCore(for: old)
        let replacementCore = try makeCore(for: replacement)
        let gate = FirstFactoryGate()
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            if account == old { return oldCore }
            return gate.make(account, first: replacementCore, subsequent: replacementCore)
        }, accountValidator: { _ in
            AccountValidationAttempt(result: AccountValidationResult(installationBase: replacement.server, version: "2.0"), error: nil, diagnostic: nil)
        })
        await bootstrapper.start()

        let configure = Task { await bootstrapper.configure(server: replacement.server, apiKey: replacement.apiKey, headers: []) }
        await gate.waitUntilFirstFactoryStarts()
        bootstrapper.deactivate()
        gate.releaseFirst()
        await configure.value

        XCTAssertNil(bootstrapper.core)
        XCTAssertNil(bootstrapper.credentials)
        XCTAssertEqual(bootstrapper.coreRevision, 2)
    }

    @MainActor
    func testConfigureActivationFailureRestoresPreviousCredentials() async throws {
        let previous = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let replacement = IOSMinifluxCredentials(server: "https://new.example", apiKey: "new-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(previous)
        let previousCore = try makeCore(for: previous)
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            if account == previous { return previousCore }
            throw NSError(domain: "FluxNewsTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "activation failed"])
        }, accountValidator: { _ in
            AccountValidationAttempt(result: AccountValidationResult(installationBase: replacement.server, version: "2.0"), error: nil, diagnostic: nil)
        })
        await bootstrapper.start()
        await bootstrapper.configure(server: replacement.server, apiKey: replacement.apiKey, headers: [])

        XCTAssertEqual(try store.load(), previous)
        XCTAssertEqual(bootstrapper.credentials, previous)
        XCTAssertIdentical(bootstrapper.core, previousCore)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
        XCTAssertEqual(bootstrapper.validationMessage, "The account could not be activated. Your previous account is still active.")
    }
}
