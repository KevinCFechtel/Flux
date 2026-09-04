import XCTest
@testable import FluxNews

final class AccountLifecycleTests: XCTestCase {
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

    func testValidationMessagesDoNotContainCredentialValues() {
        let message = IOSAccountValidationPresentation.message(for: .unauthorized)

        XCTAssertFalse(message.contains("super-secret-key"))
        XCTAssertFalse(message.contains("secret-header"))
    }
}
