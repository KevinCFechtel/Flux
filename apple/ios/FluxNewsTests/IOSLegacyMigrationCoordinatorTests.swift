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

    @MainActor
    private func makeReadyBootstrapper(
        account: IOSMinifluxCredentials,
        defaults: UserDefaults
    ) async throws -> (CoreBootstrapper, IOSMemoryCredentialStore) {
        let store = IOSMemoryCredentialStore()
        try store.save(account)
        let bootstrapper = CoreBootstrapper(
            credentialStore: store,
            coreFactory: { [weak self] credentials in
                try XCTUnwrap(self).makeCore(for: credentials)
            },
            defaults: defaults
        )
        await bootstrapper.start()
        XCTAssertNotNil(bootstrapper.core)
        return (bootstrapper, store)
    }

    private func markAccountAsMigrated(_ account: IOSMinifluxCredentials, defaults: UserDefaults) {
        defaults.set(account.server, forKey: "FluxNews.iOS.legacyMigration.account.v1.server")
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
        XCTAssertEqual(
            defaults.string(forKey: "FluxNews.iOS.legacyMigration.account.v1.server"),
            legacy.serverURL
        )
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

    @MainActor
    func testMediaSettingsMigrationImportsAllRetainedValues() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let legacyValues = [
            "autoDownloadAudioAfterSync": "true",
            "downloadAudioOnlyOnWifi": "true",
            "deleteAudioAfterPlayback": "true",
            "audioDownloadRetentionDays": "14"
        ]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyMediaSettingsReader: { IOSLegacyMediaSettingsImport.parse(legacyValues) }
        )

        let outcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(outcome, .imported)
        let settings = try XCTUnwrap(try bootstrapper.core?.coreSettings())
        XCTAssertEqual(settings.downloadNetworkPolicy, .unmeteredOnly)
        XCTAssertEqual(settings.downloadRetention, .days(days: 14))
        XCTAssertTrue(settings.deleteAfterPlayback)
        XCTAssertTrue(settings.autoDownloadListeningList)
    }

    @MainActor
    func testMediaSettingsMigrationWritesOnlyPresentValues() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyMediaSettingsReader: {
                IOSLegacyMediaSettingsImport.parse(["deleteAudioAfterPlayback": "true"])
            }
        )

        let outcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(outcome, .imported)
        let settings = try XCTUnwrap(try bootstrapper.core?.coreSettings())
        XCTAssertEqual(settings.downloadNetworkPolicy, .anyNetwork)
        XCTAssertEqual(settings.downloadRetention, .forever)
        XCTAssertTrue(settings.deleteAfterPlayback)
        XCTAssertFalse(settings.autoDownloadListeningList)
    }

    @MainActor
    func testMediaSettingsMigrationSkipsNativeOrDifferentMigratedAccount() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://native.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        var legacyRead = false
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyMediaSettingsReader: {
                legacyRead = true
                return IOSLegacyMediaSettingsImport.parse(["deleteAudioAfterPlayback": "true"])
            }
        )

        let nativeOutcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(nativeOutcome, .notEligible)
        XCTAssertFalse(legacyRead)
        defaults.set("https://old-migrated.example", forKey: "FluxNews.iOS.legacyMigration.account.v1.server")
        let oldAccountOutcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(oldAccountOutcome, .notEligible)
        XCTAssertFalse(legacyRead)
    }

    @MainActor
    func testMediaSettingsCompletionMarkerPreventsAnotherRead() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        defaults.set(true, forKey: "FluxNews.iOS.legacyMigration.mediaSettings.v1.completed")
        var legacyRead = false
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyMediaSettingsReader: {
                legacyRead = true
                return IOSLegacyMediaSettingsImport.parse([:])
            }
        )

        let outcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(outcome, .alreadyCompleted)
        XCTAssertFalse(legacyRead)
    }

    @MainActor
    func testMediaSettingsFailureRetriesWithoutMutatingLegacyState() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let legacyValues = ["autoDownloadAudioAfterSync": "true"]
        var reads = 0
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyMediaSettingsReader: {
                reads += 1
                return IOSLegacyMediaSettingsImport.parse(legacyValues)
            }
        )
        let core = try XCTUnwrap(bootstrapper.core)
        await bootstrapper.coreSessionExecutionCoordinator.quiesce()

        let failedOutcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(failedOutcome, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.mediaSettings.v1.completed"))
        XCTAssertEqual(legacyValues, ["autoDownloadAudioAfterSync": "true"])

        bootstrapper.coreSessionExecutionCoordinator.resume(core)
        let retryOutcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(retryOutcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.mediaSettings.v1.completed"))
        XCTAssertEqual(reads, 2)
        let settings = try XCTUnwrap(try bootstrapper.core?.coreSettings())
        XCTAssertTrue(settings.autoDownloadListeningList)
    }
}
