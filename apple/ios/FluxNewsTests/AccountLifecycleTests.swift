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

    private final class MutableCredentialStore: IOSCredentialStoreProtocol {
        var result: Result<IOSMinifluxCredentials?, Error>

        init(result: Result<IOSMinifluxCredentials?, Error>) {
            self.result = result
        }

        func load() throws -> IOSMinifluxCredentials? { try result.get() }
        func save(_ credentials: IOSMinifluxCredentials) throws { result = .success(credentials) }
        func remove() throws { result = .success(nil) }
    }

    private final class RecordingKeychainDataStore: IOSKeychainDataStoreProtocol {
        var storedData: Data?
        var loadError: Error?
        private(set) var savedAccessibility: IOSKeychainAccessibility?
        private(set) var updatedAccessibility: IOSKeychainAccessibility?
        private(set) var removed = false

        func loadData(service: String, account: String) throws -> Data? {
            if let loadError { throw loadError }
            return storedData
        }

        func saveData(
            _ data: Data,
            service: String,
            account: String,
            accessibility: IOSKeychainAccessibility
        ) throws {
            storedData = data
            savedAccessibility = accessibility
        }

        func updateAccessibility(
            service: String,
            account: String,
            accessibility: IOSKeychainAccessibility
        ) throws {
            updatedAccessibility = accessibility
        }

        func remove(service: String, account: String) throws {
            removed = true
            storedData = nil
        }
    }

    @MainActor
    private final class FakeSystemNotificationCenter: IOSSystemNotificationCenter {
        var status: IOSSystemNotificationAuthorizationStatus = .authorized
        var authorizationResult = true
        var authorizationError: Error?
        var failingIdentifiers: Set<String> = []
        private(set) var authorizationRequestCount = 0
        private(set) var requests: [IOSSystemNotificationRequest] = []

        func authorizationStatus() async -> IOSSystemNotificationAuthorizationStatus {
            status
        }

        func requestAuthorization() async throws -> Bool {
            authorizationRequestCount += 1
            if let authorizationError { throw authorizationError }
            return authorizationResult
        }

        func add(_ request: IOSSystemNotificationRequest) async throws {
            if failingIdentifiers.contains(request.identifier) {
                throw NSError(domain: "FluxNewsTests.Notification", code: 1)
            }
            requests.append(request)
        }
    }

    private final class FakeBackgroundTaskScheduler: IOSBackgroundTaskScheduling {
        struct Submission: Equatable {
            let identifier: String
            let earliestBeginDate: Date
        }

        private(set) var registrationCount = 0
        private(set) var submissions: [Submission] = []
        private(set) var cancellations: [String] = []
        private(set) var launchHandler: ((IOSBackgroundTaskContext) -> Void)?

        @discardableResult
        func registerAppRefresh(
            identifier: String,
            launchHandler: @escaping (IOSBackgroundTaskContext) -> Void
        ) -> Bool {
            registrationCount += 1
            self.launchHandler = launchHandler
            return true
        }

        func submitAppRefresh(
            identifier: String,
            earliestBeginDate: Date
        ) throws {
            submissions.append(
                Submission(
                    identifier: identifier,
                    earliestBeginDate: earliestBeginDate
                )
            )
        }

        func cancel(identifier: String) {
            cancellations.append(identifier)
        }
    }

    @MainActor
    private final class CoreQuiescenceGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func block() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
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

    func testKeychainStoreSavesCredentialsForBackgroundAccessAfterFirstUnlock() throws {
        let keychain = RecordingKeychainDataStore()
        let store = IOSKeychainCredentialStore(keychain: keychain)
        let credentials = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "secret",
            customHeaders: []
        )

        try store.save(credentials)

        XCTAssertEqual(keychain.savedAccessibility, .backgroundAfterFirstUnlock)
        XCTAssertEqual(
            try JSONDecoder().decode(IOSMinifluxCredentials.self, from: XCTUnwrap(keychain.storedData)),
            credentials
        )
    }

    func testKeychainStoreMigratesReadableLegacyCredentialAccessibility() throws {
        let credentials = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "secret",
            customHeaders: []
        )
        let keychain = RecordingKeychainDataStore()
        keychain.storedData = try JSONEncoder().encode(credentials)
        let store = IOSKeychainCredentialStore(keychain: keychain)

        XCTAssertEqual(try store.load(), credentials)
        XCTAssertEqual(keychain.updatedAccessibility, .backgroundAfterFirstUnlock)
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

        XCTAssertEqual(bootstrapper.state, .recoverableError(String(localized: "FluxNews could not start. Check the account configuration and try again.")))
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

    @MainActor
    func testAccountEditWaitsForCoreQuiescenceBeforeCreatingReplacement() async throws {
        let old = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let replacement = IOSMinifluxCredentials(server: "https://new.example", apiKey: "new-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(old)
        let oldCore = try makeCore(for: old)
        let newCore = try makeCore(for: replacement)
        let factoryInputs = LockedBox<[IOSMinifluxCredentials]>([])
        let gate = CoreQuiescenceGate()
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { account in
                factoryInputs.withValue { $0.append(account) }
                return account == old ? oldCore : newCore
            },
            accountValidator: { _ in
                AccountValidationAttempt(
                    result: AccountValidationResult(installationBase: replacement.server, version: "2.0"),
                    error: nil,
                    diagnostic: nil
                )
            }
        )
        await bootstrapper.start()
        bootstrapper.prepareForCoreReplacement = { await gate.block() }

        let configure = Task {
            await bootstrapper.configure(
                server: replacement.server,
                apiKey: replacement.apiKey,
                headers: []
            )
        }
        await gate.waitUntilEntered()

        XCTAssertEqual(factoryInputs.value(), [old])
        XCTAssertIdentical(bootstrapper.core, oldCore)

        gate.release()
        await configure.value

        XCTAssertEqual(factoryInputs.value(), [old, replacement])
        XCTAssertIdentical(bootstrapper.core, newCore)
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

        XCTAssertEqual(bootstrapper.validationMessage, String(localized: "The Miniflux server could not be reached. Check the server URL and network connection."))
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
    func testEnsureStartedConcurrentCallersShareOneInFlightBootstrap() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let gate = FirstFactoryGate()
        let factoryCalls = LockedBox(0)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { credentials in
                factoryCalls.withValue { $0 += 1 }
                return gate.make(credentials, first: core, subsequent: core)
            }
        )

        let first = Task { await bootstrapper.ensureStarted() }
        await gate.waitUntilFirstFactoryStarts()
        let second = Task { await bootstrapper.ensureStarted() }
        await Task.yield()

        XCTAssertEqual(factoryCalls.value(), 1)
        XCTAssertNil(bootstrapper.core)

        gate.releaseFirst()
        let firstCore = await first.value
        let secondCore = await second.value

        XCTAssertIdentical(firstCore, core)
        XCTAssertIdentical(secondCore, core)
        XCTAssertEqual(factoryCalls.value(), 1)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
    }

    @MainActor
    func testEnsureStartedRetriesAfterProtectedCredentialsBecomeAvailable() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = MutableCredentialStore(result: .failure(IOSCredentialStoreError.temporarilyUnavailable))
        let core = try makeCore(for: account)
        let factoryCalls = LockedBox(0)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in
                factoryCalls.withValue { $0 += 1 }
                return core
            }
        )

        let unavailableCore = await bootstrapper.ensureStarted()
        XCTAssertNil(unavailableCore)
        XCTAssertEqual(bootstrapper.state, .starting)
        XCTAssertNil(bootstrapper.core)
        XCTAssertEqual(factoryCalls.value(), 0)

        store.result = .success(account)
        let readyCore = await bootstrapper.ensureStarted()

        XCTAssertIdentical(readyCore, core)
        XCTAssertIdentical(bootstrapper.core, core)
        XCTAssertEqual(factoryCalls.value(), 1)
        XCTAssertTrue({ if case .ready = bootstrapper.state { return true }; return false }())
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
        await bootstrapper.deactivate()
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
    func testRemoveAccountWaitsForCoreQuiescence() async throws {
        let account = IOSMinifluxCredentials(server: "https://miniflux.example", apiKey: "key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let gate = CoreQuiescenceGate()
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { _ in core })
        await bootstrapper.start()
        bootstrapper.prepareForCoreReplacement = { await gate.block() }

        let removal = Task { await bootstrapper.removeAccount() }
        await gate.waitUntilEntered()

        XCTAssertIdentical(bootstrapper.core, core)
        XCTAssertEqual(bootstrapper.credentials, account)

        gate.release()
        await removal.value

        XCTAssertNil(bootstrapper.core)
        XCTAssertNil(bootstrapper.credentials)
        XCTAssertEqual(bootstrapper.state, .accountRequired)
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
        await bootstrapper.deactivate()
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
        var prepareCount = 0
        var abortCount = 0
        await bootstrapper.start()
        bootstrapper.prepareForCoreReplacement = { prepareCount += 1 }
        bootstrapper.onCoreReplacementAborted = { abortCount += 1 }
        await bootstrapper.configure(server: replacement.server, apiKey: replacement.apiKey, headers: [])

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(abortCount, 1)
        XCTAssertEqual(try store.load(), previous)
        XCTAssertEqual(bootstrapper.credentials, previous)
        XCTAssertIdentical(bootstrapper.core, previousCore)
        XCTAssertEqual(bootstrapper.coreRevision, 1)
        XCTAssertEqual(bootstrapper.validationMessage, String(localized: "The account could not be activated. Your previous account is still active."))
    }
    @MainActor
    func testCoreSessionCoordinatorQuiescenceCancelsAndWaitsForActiveExecution() async throws {
        let credentials = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let core = try makeCore(for: credentials)
        let coordinator = IOSCoreSessionExecutionCoordinator()
        let cancelled = LockedBox(false)
        coordinator.activate(core)

        let lease = try XCTUnwrap(
            coordinator.beginExecution(
                for: core,
                cancellation: { cancelled.withValue { $0 = true } }
            )
        )

        let quiescence = Task { @MainActor in
            await coordinator.quiesce()
        }
        await Task.yield()

        XCTAssertTrue(cancelled.value())
        XCTAssertTrue(coordinator.isQuiescing)
        XCTAssertEqual(coordinator.activeExecutionCount, 1)
        XCTAssertNil(coordinator.beginExecution(for: core))

        coordinator.finish(lease)
        await quiescence.value

        XCTAssertEqual(coordinator.activeExecutionCount, 0)
        XCTAssertTrue(coordinator.isQuiescing)
    }

    @MainActor
    func testCoreSessionCoordinatorRejectsStaleCoreAfterReplacement() async throws {
        let oldCredentials = IOSMinifluxCredentials(
            server: "https://old.example",
            apiKey: "old",
            customHeaders: []
        )
        let newCredentials = IOSMinifluxCredentials(
            server: "https://new.example",
            apiKey: "new",
            customHeaders: []
        )
        let oldCore = try makeCore(for: oldCredentials)
        let newCore = try makeCore(for: newCredentials)
        let coordinator = IOSCoreSessionExecutionCoordinator()

        coordinator.activate(oldCore)
        await coordinator.quiesce()
        coordinator.deactivate()
        coordinator.activate(newCore)

        XCTAssertNil(coordinator.beginExecution(for: oldCore))
        let lease = try XCTUnwrap(coordinator.beginExecution(for: newCore))
        coordinator.finish(lease)
    }

    @MainActor
    func testAccountEditWaitsForAppWideCoreSessionExecutionBeforeReplacement() async throws {
        let old = IOSMinifluxCredentials(
            server: "https://old.example",
            apiKey: "old-key",
            customHeaders: []
        )
        let replacement = IOSMinifluxCredentials(
            server: "https://new.example",
            apiKey: "new-key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(old)
        let oldCore = try makeCore(for: old)
        let newCore = try makeCore(for: replacement)
        let factoryInputs = LockedBox<[IOSMinifluxCredentials]>([])
        let coordinator = IOSCoreSessionExecutionCoordinator()
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreSessionExecutionCoordinator: coordinator,
            coreFactory: { account in
                factoryInputs.withValue { $0.append(account) }
                return account == old ? oldCore : newCore
            },
            accountValidator: { _ in
                AccountValidationAttempt(
                    result: AccountValidationResult(
                        installationBase: replacement.server,
                        version: "2.0"
                    ),
                    error: nil,
                    diagnostic: nil
                )
            }
        )
        await bootstrapper.start()
        let quiescenceRequested = expectation(
            description: "Core-session replacement requests cancellation of admitted work"
        )
        let lease = try XCTUnwrap(
            coordinator.beginExecution(
                for: oldCore,
                cancellation: { quiescenceRequested.fulfill() }
            )
        )

        let configure = Task { @MainActor in
            await bootstrapper.configure(
                server: replacement.server,
                apiKey: replacement.apiKey,
                headers: []
            )
        }
        await fulfillment(of: [quiescenceRequested], timeout: 5)

        XCTAssertTrue(coordinator.isQuiescing)
        XCTAssertEqual(factoryInputs.value(), [old])
        XCTAssertIdentical(bootstrapper.core, oldCore)

        coordinator.finish(lease)
        await configure.value

        XCTAssertEqual(factoryInputs.value(), [old, replacement])
        XCTAssertIdentical(bootstrapper.core, newCore)
        XCTAssertFalse(coordinator.isQuiescing)
    }


    @MainActor
    func testBackgroundTaskRegistrationRegistersIdentifierOnlyOnce() {
        let scheduler = FakeBackgroundTaskScheduler()
        let registration = IOSBackgroundTaskRegistration(
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            launchHandler: { _ in }
        )

        XCTAssertTrue(registration.register())
        XCTAssertTrue(registration.register())
        XCTAssertEqual(scheduler.registrationCount, 1)
    }

    @MainActor
    func testBackgroundSchedulingUsesPreferredEarliestBeginDateWhenEnabled() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let now = Date(timeIntervalSince1970: 1_000)
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            preferredInterval: 1_800,
            now: { now },
            settingsReader: { _ in true }
        )

        await coordinator.refreshScheduling()

        XCTAssertEqual(
            scheduler.submissions,
            [
                .init(
                    identifier: "dev.test.backgroundSync",
                    earliestBeginDate: Date(timeIntervalSince1970: 2_800)
                )
            ]
        )
        XCTAssertTrue(scheduler.cancellations.isEmpty)
    }

    @MainActor
    func testDisabledBackgroundSyncCancelsSuccessorWithoutRunningCoreSync() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let syncCalls = LockedBox(0)
        let completion = expectation(description: "background task completes")
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            settingsReader: { _ in false },
            syncRunner: { _, _ in
                syncCalls.withValue { $0 += 1 }
                return .cancelled
            }
        )

        coordinator.handle(
            IOSBackgroundTaskContext(
                setExpirationHandler: { _ in },
                complete: { success in
                    XCTAssertTrue(success)
                    completion.fulfill()
                }
            )
        )

        await fulfillment(of: [completion], timeout: 5)

        XCTAssertEqual(syncCalls.value(), 0)
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(scheduler.cancellations, ["dev.test.backgroundSync"])
    }

    @MainActor
    func testSuccessfulBackgroundSyncCompletesOnceAndPublishesSuccessHook() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let completion = expectation(description: "background task completes")
        let published = expectation(description: "success hook publishes")
        let completionCalls = LockedBox<[Bool]>([])
        let metadata = SyncCompleted(
            reason: .background,
            newArticles: 1,
            updatedArticles: 0,
            mutationsDelivered: 0,
            dataChanged: true,
            navigationChanged: true,
            newArticlesByFeed: [],
            systemNotificationCandidates: []
        )
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            settingsReader: { _ in true },
            syncRunner: { _, _ in .completed(metadata: metadata) }
        )
        coordinator.onSuccessfulBackgroundSync = { result in
            XCTAssertEqual(result.reason, .background)
            published.fulfill()
        }

        coordinator.handle(
            IOSBackgroundTaskContext(
                setExpirationHandler: { _ in },
                complete: { success in
                    completionCalls.withValue { $0.append(success) }
                    completion.fulfill()
                }
            )
        )

        await fulfillment(of: [published, completion], timeout: 5)

        XCTAssertEqual(completionCalls.value(), [true])
        XCTAssertEqual(scheduler.submissions.count, 1)
    }

    @MainActor
    func testBackgroundTaskExpirationCancelsCoreRunAndCompletesFailureOnce() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let syncStarted = expectation(description: "background sync starts")
        let cancellationObserved = expectation(description: "Core cancellation observed")
        let completion = expectation(description: "background task completes")
        let completionCalls = LockedBox<[Bool]>([])
        let expiration = LockedBox<(() -> Void)?>(nil)
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            settingsReader: { _ in true },
            syncRunner: { _, cancellation in
                syncStarted.fulfill()
                while !cancellation.isCancelled() {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                cancellationObserved.fulfill()
                return .cancelled
            }
        )

        coordinator.handle(
            IOSBackgroundTaskContext(
                setExpirationHandler: { handler in
                    expiration.withValue { $0 = handler }
                },
                complete: { success in
                    completionCalls.withValue { $0.append(success) }
                    completion.fulfill()
                }
            )
        )

        await fulfillment(of: [syncStarted], timeout: 5)
        expiration.value()?()
        await fulfillment(of: [cancellationObserved, completion], timeout: 5)

        XCTAssertEqual(completionCalls.value(), [false])
    }


    @MainActor
    func testResumeTriggerUsesDedicatedResumeSyncRunner() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let resumeStarted = expectation(description: "resume sync starts")
        let backgroundCalls = LockedBox(0)
        let metadata = SyncCompleted(
            reason: .resume,
            newArticles: 0,
            updatedArticles: 0,
            mutationsDelivered: 0,
            dataChanged: false,
            navigationChanged: false,
            newArticlesByFeed: [],
            systemNotificationCandidates: []
        )
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            syncRunner: { _, _ in
                backgroundCalls.withValue { $0 += 1 }
                return .cancelled
            },
            resumeSyncRunner: { _, _ in
                resumeStarted.fulfill()
                return .completed(metadata: metadata)
            }
        )

        coordinator.resumeIfNeeded()

        await fulfillment(of: [resumeStarted], timeout: 5)
        XCTAssertEqual(backgroundCalls.value(), 0)
        XCTAssertTrue(scheduler.submissions.isEmpty)
    }


    @MainActor
    func testBackgroundSyncPreferenceReadsPersistedCoreSetting() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        try core.setBackgroundSyncEnabled(enabled: false)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: FakeBackgroundTaskScheduler(),
            identifier: "dev.test.backgroundSync"
        )

        let result = await coordinator.backgroundSyncPreference()

        switch result {
        case let .success(enabled):
            XCTAssertFalse(enabled)
        case let .failure(error):
            XCTFail("Unexpected preference read failure: \(error)")
        }
    }

    @MainActor
    func testBackgroundSyncPreferenceWriteUpdatesCoreSchedulingAndResume() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let resumeStarted = expectation(description: "resume requested after enabling")
        let metadata = SyncCompleted(
            reason: .resume,
            newArticles: 0,
            updatedArticles: 0,
            mutationsDelivered: 0,
            dataChanged: false,
            navigationChanged: false,
            newArticlesByFeed: [],
            systemNotificationCandidates: []
        )
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            resumeSyncRunner: { _, _ in
                resumeStarted.fulfill()
                return .completed(metadata: metadata)
            }
        )

        let disabled = await coordinator.setBackgroundSyncPreference(false)
        if case let .failure(error) = disabled {
            XCTFail("Unexpected disable failure: \(error)")
        }
        XCTAssertFalse(try core.coreSettings().backgroundSyncEnabled)
        XCTAssertEqual(scheduler.cancellations, ["dev.test.backgroundSync"])
        XCTAssertTrue(scheduler.submissions.isEmpty)

        let enabled = await coordinator.setBackgroundSyncPreference(true)
        if case let .failure(error) = enabled {
            XCTFail("Unexpected enable failure: \(error)")
        }
        await fulfillment(of: [resumeStarted], timeout: 5)

        XCTAssertTrue(try core.coreSettings().backgroundSyncEnabled)
        XCTAssertEqual(scheduler.submissions.count, 1)
    }


    @MainActor
    func testFailedBackgroundSyncPreferenceWriteDoesNotChangeScheduling() async throws {
        let account = IOSMinifluxCredentials(
            server: "https://miniflux.example",
            apiKey: "key",
            customHeaders: []
        )
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let core = try makeCore(for: account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core }
        )
        let scheduler = FakeBackgroundTaskScheduler()
        let coordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler,
            identifier: "dev.test.backgroundSync",
            settingsWriter: { _, _ in
                throw NSError(domain: "FluxNewsTests", code: 7)
            }
        )

        let original = try core.coreSettings().backgroundSyncEnabled
        let result = await coordinator.setBackgroundSyncPreference(!original)

        if case .success = result {
            XCTFail("Expected preference write to fail")
        }
        XCTAssertEqual(try core.coreSettings().backgroundSyncEnabled, original)
        XCTAssertTrue(scheduler.submissions.isEmpty)
        XCTAssertTrue(scheduler.cancellations.isEmpty)
    }


    @MainActor
    func testSystemNotificationAuthorizationRequestsOnlyWhenUndetermined() async throws {
        let center = FakeSystemNotificationCenter()
        center.status = .notDetermined
        let manager = IOSSystemNotificationManager(center: center)

        try await manager.ensureAuthorization()

        XCTAssertEqual(center.authorizationRequestCount, 1)

        center.status = .authorized
        try await manager.ensureAuthorization()
        XCTAssertEqual(center.authorizationRequestCount, 1)
    }

    @MainActor
    func testSystemNotificationAuthorizationDeniedIsReportedWithoutRequestingAgain() async {
        let center = FakeSystemNotificationCenter()
        center.status = .denied
        let manager = IOSSystemNotificationManager(center: center)

        do {
            try await manager.ensureAuthorization()
            XCTFail("Expected denied authorization to fail")
        } catch {
            XCTAssertTrue(error is IOSSystemNotificationError)
        }

        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    @MainActor
    func testSystemNotificationDeliveryAcknowledgesOnlySuccessfullyAddedCandidates() async {
        let center = FakeSystemNotificationCenter()
        center.failingIdentifiers = ["flux.system-notification.2"]
        let manager = IOSSystemNotificationManager(center: center)
        var acknowledged: [Int64] = []
        let candidates = [
            SystemNotificationCandidate(
                candidateId: 1,
                feedId: 10,
                feedTitle: "Feed One",
                newCount: 2
            ),
            SystemNotificationCandidate(
                candidateId: 2,
                feedId: 20,
                feedTitle: "Feed Two",
                newCount: 1
            ),
        ]

        await manager.deliver(candidates) { candidateID in
            acknowledged.append(candidateID)
            return true
        }

        XCTAssertEqual(acknowledged, [1])
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.identifier, "flux.system-notification.1")
        XCTAssertEqual(center.requests.first?.title, "Feed One")
        XCTAssertEqual(center.requests.first?.candidateID, 1)
        XCTAssertEqual(center.requests.first?.feedID, 10)
        XCTAssertFalse(center.requests.first?.body.isEmpty ?? true)
    }

    @MainActor
    func testSystemNotificationFeedRouteBuffersUntilPresentationIsAttached() {
        let center = FakeSystemNotificationCenter()
        let manager = IOSSystemNotificationManager(center: center)
        var selectedFeedIDs: [Int64] = []

        manager.route(feedID: 42)
        XCTAssertTrue(selectedFeedIDs.isEmpty)

        manager.onFeedSelected = { selectedFeedIDs.append($0) }

        XCTAssertEqual(selectedFeedIDs, [42])
        manager.route(feedID: 43)
        XCTAssertEqual(selectedFeedIDs, [42, 43])
    }

}
