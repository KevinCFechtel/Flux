import XCTest
@testable import FluxNews

final class AccountLifecycleTests: XCTestCase {
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
        var activated: IOSMinifluxCredentials?
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            activated = account
            return try self.makeCore(for: account)
        })

        await bootstrapper.start()

        XCTAssertTrue({ if case .ready = bootstrapper.state { return true }; return false }())
        XCTAssertEqual(activated, credentials)
        XCTAssertEqual(bootstrapper.credentials, credentials)
    }

    @MainActor
    func testFailedAccountEditKeepsPreviousAccountAndRuntime() async throws {
        let previous = IOSMinifluxCredentials(server: "https://old.example", apiKey: "old-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(previous)
        let core = try makeCore(for: previous)
        var validatorInput: IOSMinifluxCredentials?
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { _ in core }, accountValidator: { account in
            validatorInput = account
            throw AccountValidationError.Unauthorized
        })
        await bootstrapper.start()

        await bootstrapper.configure(server: "https://new.example", apiKey: "new-key", headers: [IOSCustomHTTPHeader(name: "X-Tenant", value: "new")])

        XCTAssertEqual(validatorInput?.customHeaders.first?.value, "new")
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
        var factoryInputs: [IOSMinifluxCredentials] = []
        var changes: [Flux?] = []
        let bootstrapper = CoreBootstrapper(credentialStore: store, coreFactory: { account in
            factoryInputs.append(account)
            return factoryInputs.count == 1 ? oldCore : newCore
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
        XCTAssertEqual(factoryInputs, [old, replacement])
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
        var shouldFail = true
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { _ in core },
            accountValidator: { _ in
                if shouldFail {
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

        shouldFail = false
        await bootstrapper.configure(server: "https://example.com", apiKey: "api-secret", headers: [])

        XCTAssertNil(bootstrapper.validationDiagnostic)
        XCTAssertNil(bootstrapper.validationMessage)
    }
}
