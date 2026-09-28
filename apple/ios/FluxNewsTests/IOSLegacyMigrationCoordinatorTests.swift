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

    private func makeLegacyDownload(enclosureID: Int64, contents: String = "legacy-audio") throws -> LegacyDownloadImport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("audio_\(enclosureID).mp3")
        try Data(contents.utf8).write(to: source)
        return LegacyDownloadImport(enclosureID: enclosureID, sourceFile: source)
    }

    private func legacyDownloadDestination(_ enclosureID: Int64, under mediaRoot: URL) throws -> URL {
        try MediaTransferFileLayout.destination(
            reference: "downloads/legacy/enclosure-\(enclosureID).audio",
            under: mediaRoot
        )
    }

    func testLegacyMediaSettingsParserExcludesIncompatibleSyncTriggeredAutoDownload() {
        let parsed = IOSLegacyMediaSettingsImport.parse([
            "autoDownloadAudioAfterSync": "true",
            "downloadAudioOnlyOnWifi": " false ",
            "deleteAudioAfterPlayback": "TRUE",
            "audioDownloadRetentionDays": " 14 ",
            "useBlackMode": "true"
        ])

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

        XCTAssertNil(parsed.unmeteredOnly)
        XCTAssertNil(parsed.deleteAfterPlayback)
        XCTAssertNil(parsed.retentionDays)
        XCTAssertTrue(parsed.isEmpty)
    }

    func testLegacyPlaybackProgressParserAcceptsOnlyValidProgressEntries() {
        let parsed = LegacyStateDiscovery.parsePlaybackProgressImports([
            "audio_progress_12345": "98765",
            "audio_progress_2": "0",
            "audio_progress_0": "10",
            "audio_progress_-4": "10",
            "audio_progress_bad": "10",
            "audio_progress_3": "not-a-number",
            "audio_progress_4": "-1",
            "audio_progress_5": "18446744073709551616",
            "minifluxURL": "https://legacy.example",
            "audio_download_ts_6": "100"
        ])

        XCTAssertEqual(
            parsed,
            [
                .init(articleID: 2, positionMs: 0),
                .init(articleID: 12345, positionMs: 98765)
            ]
        )
    }

    @MainActor
    func testPlaybackMigrationTreatsImportedAlreadyPresentAndAmbiguousAsTerminal() {
        XCTAssertEqual(
            IOSLegacyMigrationCoordinator.playbackMigrationOutcome(
                for: LegacyPlaybackImportResult(
                    imported: 1,
                    skippedMissing: 0,
                    skippedAmbiguous: 0,
                    alreadyPresent: 0
                )
            ),
            .imported
        )
        XCTAssertEqual(
            IOSLegacyMigrationCoordinator.playbackMigrationOutcome(
                for: LegacyPlaybackImportResult(
                    imported: 0,
                    skippedMissing: 0,
                    skippedAmbiguous: 0,
                    alreadyPresent: 1
                )
            ),
            .imported
        )
        XCTAssertEqual(
            IOSLegacyMigrationCoordinator.playbackMigrationOutcome(
                for: LegacyPlaybackImportResult(
                    imported: 0,
                    skippedMissing: 0,
                    skippedAmbiguous: 1,
                    alreadyPresent: 0
                )
            ),
            .imported
        )
    }

    @MainActor
    func testPlaybackMigrationTreatsMissingAsRetryable() {
        XCTAssertEqual(
            IOSLegacyMigrationCoordinator.playbackMigrationOutcome(
                for: LegacyPlaybackImportResult(
                    imported: 1,
                    skippedMissing: 1,
                    skippedAmbiguous: 1,
                    alreadyPresent: 1
                )
            ),
            .retryableFailure
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
        XCTAssertFalse(settings.autoDownloadListeningList)
    }

    @MainActor
    func testMediaSettingsMigrationNeverChangesListeningListAutoDownload() async throws {
        for legacyValue in ["true", "false"] {
            for nativeValue in [true, false] {
                let (defaults, suite) = makeDefaults()
                defer { defaults.removePersistentDomain(forName: suite) }
                let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
                let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
                markAccountAsMigrated(account, defaults: defaults)
                let core = try XCTUnwrap(bootstrapper.core)
                try core.setAutoDownloadListeningList(enabled: nativeValue)
                let coordinator = IOSLegacyMigrationCoordinator(
                    bootstrapper: bootstrapper,
                    defaults: defaults,
                    legacyMediaSettingsReader: {
                        IOSLegacyMediaSettingsImport.parse(["autoDownloadAudioAfterSync": legacyValue])
                    }
                )

                let outcome = await coordinator.migrateMediaSettingsIfNeeded()
                XCTAssertEqual(outcome, .imported)
                XCTAssertEqual(try core.coreSettings().autoDownloadListeningList, nativeValue)
            }
        }
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
        let legacyValues = ["downloadAudioOnlyOnWifi": "true"]
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
        XCTAssertEqual(legacyValues, ["downloadAudioOnlyOnWifi": "true"])

        bootstrapper.coreSessionExecutionCoordinator.resume(core)
        let retryOutcome = await coordinator.migrateMediaSettingsIfNeeded()
        XCTAssertEqual(retryOutcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.mediaSettings.v1.completed"))
        XCTAssertEqual(reads, 2)
        let settings = try XCTUnwrap(try bootstrapper.core?.coreSettings())
        XCTAssertFalse(settings.autoDownloadListeningList)
    }

    @MainActor
    func testPlaybackMigrationCompletesEmptyLegacySourceAndPreventsAnotherRead() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        var reads = 0
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: {
                reads += 1
                return []
            }
        )

        let first = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(first, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        let second = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(second, .alreadyCompleted)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testPlaybackMigrationSkipsNativeAndDifferentMigratedAccounts() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://native.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        var legacyRead = false
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: {
                legacyRead = true
                return [.init(articleID: 1, positionMs: 100)]
            }
        )

        let nativeOutcome = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(nativeOutcome, .notEligible)
        defaults.set("https://old-migrated.example", forKey: "FluxNews.iOS.legacyMigration.account.v1.server")
        let oldAccountOutcome = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(oldAccountOutcome, .notEligible)
        XCTAssertFalse(legacyRead)
    }

    @MainActor
    func testPlaybackMigrationReadOrCoreFailureRetriesWithoutMutatingLegacyState() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        var readSucceeds = false
        let legacyRecords: [LegacyPlaybackProgressImport] = []
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: { readSucceeds ? legacyRecords : nil }
        )

        let readFailure = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(readFailure, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))

        readSucceeds = true
        let core = try XCTUnwrap(bootstrapper.core)
        await bootstrapper.coreSessionExecutionCoordinator.quiesce()
        let coreFailure = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(coreFailure, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        XCTAssertEqual(legacyRecords, [])

        bootstrapper.coreSessionExecutionCoordinator.resume(core)
        let retry = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(retry, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
    }

    @MainActor
    func testPlaybackMigrationMissingRecordsRemainPendingAndAreReadAgain() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        var reads = 0
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: {
                reads += 1
                return [.init(articleID: 999, positionMs: 100)]
            }
        )

        let first = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(first, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        let second = await coordinator.migratePlaybackProgressIfNeeded()
        XCTAssertEqual(second, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testPlaybackMigrationRetriesMissingThenCompletesAfterImport() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let legacyRecords = [LegacyPlaybackProgressImport(articleID: 42, positionMs: 100)]
        var results = [
            LegacyPlaybackImportResult(imported: 0, skippedMissing: 1, skippedAmbiguous: 0, alreadyPresent: 0),
            LegacyPlaybackImportResult(imported: 1, skippedMissing: 0, skippedAmbiguous: 0, alreadyPresent: 0)
        ]
        var importedRecords = [[LegacyPlaybackImport]]()
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: { legacyRecords },
            legacyPlaybackImporter: { records in
                importedRecords.append(records)
                return .success(results.removeFirst())
            }
        )

        let first = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(first, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        let second = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(second, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        XCTAssertEqual(importedRecords.map { $0.map(\.articleId) }, [[42], [42]])
    }

    @MainActor
    func testPlaybackMigrationRetriesMissingThenLetsNativeStateWin() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        var results = [
            LegacyPlaybackImportResult(imported: 0, skippedMissing: 1, skippedAmbiguous: 0, alreadyPresent: 0),
            LegacyPlaybackImportResult(imported: 0, skippedMissing: 0, skippedAmbiguous: 0, alreadyPresent: 1)
        ]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: { [.init(articleID: 42, positionMs: 100)] },
            legacyPlaybackImporter: { _ in .success(results.removeFirst()) }
        )

        let first = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(first, .retryableFailure)
        let second = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(second, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
    }

    @MainActor
    func testPlaybackMigrationMixedBatchRemainsPendingUntilMissingRecordResolves() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        var results = [
            LegacyPlaybackImportResult(imported: 1, skippedMissing: 1, skippedAmbiguous: 1, alreadyPresent: 1),
            LegacyPlaybackImportResult(imported: 1, skippedMissing: 0, skippedAmbiguous: 1, alreadyPresent: 2)
        ]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyPlaybackReader: {
                [
                    .init(articleID: 1, positionMs: 100),
                    .init(articleID: 2, positionMs: 100),
                    .init(articleID: 3, positionMs: 100),
                    .init(articleID: 4, positionMs: 100)
                ]
            },
            legacyPlaybackImporter: { _ in .success(results.removeFirst()) }
        )

        let first = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(first, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
        let second = await awaitPlaybackOutcome(coordinator)
        XCTAssertEqual(second, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.playback.v1.completed"))
    }

    @MainActor
    private func awaitPlaybackOutcome(
        _ coordinator: IOSLegacyMigrationCoordinator
    ) async -> IOSLegacyPlaybackMigrationOutcome {
        await coordinator.migratePlaybackProgressIfNeeded()
    }

    @MainActor
    func testDownloadMigrationImportedRetainsCoreOwnedCopyAndCompletes() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 11)
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in .success(.imported) },
            mediaRootProvider: { mediaRoot }
        )

        let outcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(outcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(11, under: mediaRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceFile.path))
    }

    @MainActor
    func testDownloadMigrationAlreadyPresentCleansOnlyCopyCreatedForThisAttempt() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 12)
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in .success(.alreadyPresent) },
            mediaRootProvider: { mediaRoot }
        )

        let outcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(outcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try legacyDownloadDestination(12, under: mediaRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceFile.path))
    }

    @MainActor
    func testDownloadMigrationMissingEnclosureRemainsPendingThenImportsOnRetry() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 13)
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var outcomes: [LegacyDownloadImportOutcome] = [.missingEnclosure, .imported]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in .success(outcomes.removeFirst()) },
            mediaRootProvider: { mediaRoot }
        )

        let firstOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(firstOutcome, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try legacyDownloadDestination(13, under: mediaRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceFile.path))

        let secondOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(secondOutcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(13, under: mediaRoot).path))
    }

    @MainActor
    func testDownloadMigrationMissingEnclosureThenAlreadyPresentIsTerminalWithoutOverwritingNativeState() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 14)
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var outcomes: [LegacyDownloadImportOutcome] = [.missingEnclosure, .alreadyPresent]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in .success(outcomes.removeFirst()) },
            mediaRootProvider: { mediaRoot }
        )

        let firstOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(firstOutcome, .retryableFailure)
        let secondOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(secondOutcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try legacyDownloadDestination(14, under: mediaRoot).path))
    }

    @MainActor
    func testDownloadMigrationMixedBatchRemainsPendingUntilMissingRecordResolves() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let records = try [makeLegacyDownload(enclosureID: 21), makeLegacyDownload(enclosureID: 22), makeLegacyDownload(enclosureID: 23)]
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var outcomes: [Int64: [LegacyDownloadImportOutcome]] = [
            21: [.imported, .alreadyPresent],
            22: [.alreadyPresent, .alreadyPresent],
            23: [.missingEnclosure, .imported]
        ]
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { records },
            legacyDownloadImporter: { enclosureID, _, _ in .success(outcomes[enclosureID]!.removeFirst()) },
            mediaRootProvider: { mediaRoot }
        )

        let firstOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(firstOutcome, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(21, under: mediaRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try legacyDownloadDestination(22, under: mediaRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try legacyDownloadDestination(23, under: mediaRoot).path))

        let secondOutcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(secondOutcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(21, under: mediaRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(23, under: mediaRoot).path))
    }

    @MainActor
    func testDownloadMigrationRetainsPreexistingMigrationCopyForRestartSafeRetry() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 31, contents: "source")
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = try legacyDownloadDestination(31, under: mediaRoot)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("interrupted-copy".utf8).write(to: destination)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in .success(.missingEnclosure) },
            mediaRootProvider: { mediaRoot }
        )

        let outcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(try Data(contentsOf: destination), Data("interrupted-copy".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceFile.path))
    }

    @MainActor
    func testDownloadMigrationFailureRemainsRetryableAndRetainsCopy() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let record = try makeLegacyDownload(enclosureID: 32)
        let mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [record] },
            legacyDownloadImporter: { _, _, _ in
                .failure(NSError(domain: "FluxNewsTests", code: 1))
            },
            mediaRootProvider: { mediaRoot }
        )

        let outcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertFalse(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try legacyDownloadDestination(32, under: mediaRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceFile.path))
    }

    @MainActor
    func testDownloadMigrationCompletesAnAccessibleEmptyLegacySet() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = IOSMinifluxCredentials(server: "https://legacy.example", apiKey: "key", customHeaders: [])
        let (bootstrapper, _) = try await makeReadyBootstrapper(account: account, defaults: defaults)
        markAccountAsMigrated(account, defaults: defaults)
        let coordinator = IOSLegacyMigrationCoordinator(
            bootstrapper: bootstrapper,
            defaults: defaults,
            legacyDownloadReader: { [] },
            mediaRootProvider: { nil }
        )

        let outcome = await coordinator.migrateDownloadsIfNeeded()
        XCTAssertEqual(outcome, .imported)
        XCTAssertTrue(defaults.bool(forKey: "FluxNews.iOS.legacyMigration.downloads.v1.completed"))
    }
}
