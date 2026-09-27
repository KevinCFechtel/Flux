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

    private static let successfulAccountValidator: @Sendable (IOSMinifluxCredentials) throws -> AccountValidationAttempt = { credentials in
        AccountValidationAttempt(
            result: AccountValidationResult(installationBase: credentials.server, version: "2.0"),
            error: nil,
            diagnostic: nil
        )
    }

    func testLegacyMediaSettingsParserMapsRetainedSemantics() {
        let parsed = IOSLegacyMediaSettingsImport.parse([
            "autoDownloadAudioAfterSync": "true",
            "downloadAudioOnlyOnWifi": " false ",
            "deleteAudioAfterPlayback": "TRUE",
            "audioDownloadRetentionDays": " 14 ",
            "useBlackMode": "true"
        ])

        XCTAssertEqual(parsed.autoDownloadListeningList, true)
        XCTAssertEqual(parsed.unmeteredOnly, false)
        XCTAssertEqual(parsed.deleteAfterPlayback, true)
        XCTAssertEqual(parsed.retentionDays, 14)
        XCTAssertFalse(parsed.isEmpty)
    }

    func testLegacyMediaSettingsParserIgnoresInvalidAndRetiredValues() {
        let parsed = IOSLegacyMediaSettingsImport.parse([
            "autoDownloadAudioAfterSync": "yes",
            "downloadAudioOnlyOnWifi": "",
            "deleteAudioAfterPlayback": "1",
            "audioDownloadRetentionDays": "0",
            "brightnessMode": "dark",
            "syncOnStart": "true"
        ])

        XCTAssertNil(parsed.autoDownloadListeningList)
        XCTAssertNil(parsed.unmeteredOnly)
        XCTAssertNil(parsed.deleteAfterPlayback)
        XCTAssertNil(parsed.retentionDays)
        XCTAssertTrue(parsed.isEmpty)
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

        let result = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(result, .nativeAccountWins)
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

        let firstResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(firstResult, .noLegacyAccount)
        let secondResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(secondResult, .noLegacyAccount)
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
            },
            accountValidator: Self.successfulAccountValidator
        )
        let legacy = legacyAccount
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: { legacy }
        )

        let importResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(importResult, .imported)
        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(stored.server, legacy.serverURL)
        XCTAssertEqual(stored.apiKey, legacy.apiKey)
        XCTAssertEqual(stored.customHeaders.map(\.name), legacy.customHeaders.map(\.name))
        XCTAssertEqual(stored.customHeaders.map(\.value), legacy.customHeaders.map(\.value))
        XCTAssertNotNil(bootstrapper.core)
        let secondResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(secondResult, .nativeAccountWins)
    }

    @MainActor
    func testFailedActivationDoesNotMarkMigrationCompleteAndCanRetry() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IOSMemoryCredentialStore()
        final class FailureState: @unchecked Sendable {
            var shouldFail = true
        }
        let failureState = FailureState()
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { [weak self, failureState] credentials in
                if failureState.shouldFail {
                    throw NSError(domain: "FluxNewsTests.LegacyMigration", code: 1)
                }
                return try XCTUnwrap(self).makeCore(for: credentials)
            },
            accountValidator: Self.successfulAccountValidator
        )
        let legacy = legacyAccount
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyAccountReader: { legacy }
        )

        let failedResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(failedResult, .retryableFailure)
        XCTAssertNil(try store.load())
        XCTAssertNil(bootstrapper.core)

        failureState.shouldFail = false
        let retryResult = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(retryResult, .imported)
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

        let result = await coordinator.migrateAccountIfNeeded()
        XCTAssertEqual(result, .alreadyCompleted)
        XCTAssertFalse(legacyRead)
    }
}
