import XCTest
@testable import FluxNews

final class IOSLegacyMigrationCoordinatorTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "FluxNews.LegacyMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
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

    private var legacyAccount: LegacyAccountImport {
        LegacyAccountImport(
            serverURL: "https://legacy.example",
            apiKey: "legacy-key",
            customHeaders: [.init(name: "X-Tenant", value: "legacy-tenant")]
        )
    }

    @MainActor
    func testNativeAccountWinsWithoutReadingLegacyState() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let native = IOSMinifluxCredentials(server: "https://native.example", apiKey: "native-key", customHeaders: [])
        let store = IOSMemoryCredentialStore()
        try store.save(native)
        let bootstrapper = CoreBootstrapper(credentialStore: store)
        var legacyRead = false
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: {
                legacyRead = true
                return self.legacyAccount
            }
        )

        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .nativeAccountWins)
        XCTAssertFalse(legacyRead)
        XCTAssertEqual(try store.load(), native)
    }

    @MainActor
    func testMissingLegacyAccountRemainsRetryable() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let bootstrapper = CoreBootstrapper(credentialStore: IOSMemoryCredentialStore())
        var reads = 0
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: {
                reads += 1
                return nil
            }
        )

        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .noLegacyAccount)
        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .noLegacyAccount)
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testSuccessfulImportCopiesCredentialsAndBecomesNativeWinner() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IOSMemoryCredentialStore()
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { [weak self] credentials in
                try XCTUnwrap(self).makeCore(for: credentials)
            }
        )
        let legacy = legacyAccount
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: { legacy }
        )

        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .imported)
        XCTAssertEqual(
            try store.load(),
            IOSMinifluxCredentials(
                server: legacy.serverURL,
                apiKey: legacy.apiKey,
                customHeaders: legacy.customHeaders.map { .init(name: $0.name, value: $0.value) }
            )
        )
        XCTAssertNotNil(bootstrapper.core)
        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .nativeAccountWins)
    }

    @MainActor
    func testFailedActivationDoesNotMarkMigrationCompleteAndCanRetry() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IOSMemoryCredentialStore()
        var shouldFail = true
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { [weak self] credentials in
                if shouldFail {
                    throw NSError(domain: "FluxNewsTests.LegacyMigration", code: 1)
                }
                return try XCTUnwrap(self).makeCore(for: credentials)
            }
        )
        let legacy = legacyAccount
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: { legacy }
        )

        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .retryableFailure)
        XCTAssertNil(try store.load())
        XCTAssertNil(bootstrapper.core)

        shouldFail = false
        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .imported)
        XCTAssertNotNil(try store.load())
        XCTAssertNotNil(bootstrapper.core)
    }

    @MainActor
    func testCompletionMarkerSkipsLegacyReadWhenNativeCredentialsAreAbsent() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "FluxNews.iOS.legacyMigration.account.v1.completed")
        let bootstrapper = CoreBootstrapper(credentialStore: IOSMemoryCredentialStore())
        var legacyRead = false
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: {
                legacyRead = true
                return self.legacyAccount
            }
        )

        XCTAssertEqual(await coordinator.migrateAccountIfNeeded(), .alreadyCompleted)
        XCTAssertFalse(legacyRead)
    }
}
