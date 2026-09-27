import Foundation

enum IOSLegacyAccountMigrationOutcome: Equatable {
    case nativeAccountWins
    case alreadyCompleted
    case noLegacyAccount
    case imported
    case retryableFailure
}

enum IOSLegacyMediaSettingsMigrationOutcome: Equatable {
    case notEligible
    case alreadyCompleted
    case imported
    case retryableFailure
}

enum IOSLegacyPlaybackMigrationOutcome: Equatable {
    case notEligible
    case alreadyCompleted
    case imported
    case retryableFailure
}

enum IOSLegacyDownloadMigrationOutcome: Equatable {
    case notEligible, alreadyCompleted, imported, retryableFailure
}

struct IOSLegacyMediaSettingsImport: Equatable {
    let unmeteredOnly: Bool?
    let deleteAfterPlayback: Bool?
    let retentionDays: UInt32?

    var isEmpty: Bool {
        unmeteredOnly == nil && deleteAfterPlayback == nil && retentionDays == nil
    }

    static func parse(_ values: [String: String]) -> Self {
        func parseBool(_ key: String) -> Bool? {
            switch values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }

        let retentionDays = values["audioDownloadRetentionDays"]
            .flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }

        return Self(
            unmeteredOnly: parseBool("downloadAudioOnlyOnWifi"),
            deleteAfterPlayback: parseBool("deleteAudioAfterPlayback"),
            retentionDays: retentionDays
        )
    }
}

@MainActor
final class IOSLegacyMigrationCoordinator {
    private enum DefaultsKey {
        static let accountMigrationCompleted = "FluxNews.iOS.legacyMigration.account.v1.completed"
        static let migratedAccountServer = "FluxNews.iOS.legacyMigration.account.v1.server"
        static let mediaSettingsMigrationCompleted = "FluxNews.iOS.legacyMigration.mediaSettings.v1.completed"
        static let playbackMigrationCompleted = "FluxNews.iOS.legacyMigration.playback.v1.completed"
        static let downloadMigrationCompleted = "FluxNews.iOS.legacyMigration.downloads.v1.completed"
    }

    private let bootstrapper: CoreBootstrapper
    private let defaults: UserDefaults
    private let legacyAccountReader: () -> LegacyAccountImport?
    private let legacyMediaSettingsReader: () -> IOSLegacyMediaSettingsImport?
    private let legacyPlaybackReader: () -> [LegacyPlaybackProgressImport]?
    private let legacyPlaybackImporter: (([LegacyPlaybackImport]) async -> Result<LegacyPlaybackImportResult, Error>)?
    private let legacyDownloadReader: () -> [LegacyDownloadImport]?
    private let logger = IOSAppLogger(category: "legacy_migration")
    private var inFlight = false

    init(
        bootstrapper: CoreBootstrapper,
        defaults: UserDefaults = .standard,
        legacyAccountReader: @escaping () -> LegacyAccountImport? = LegacyStateDiscovery.readAccountImport,
        legacyMediaSettingsReader: @escaping () -> IOSLegacyMediaSettingsImport? = LegacyStateDiscovery.readMediaSettingsImport,
        legacyPlaybackReader: @escaping () -> [LegacyPlaybackProgressImport]? = LegacyStateDiscovery.readPlaybackProgressImports,
        legacyPlaybackImporter: (([LegacyPlaybackImport]) async -> Result<LegacyPlaybackImportResult, Error>)? = nil,
        legacyDownloadReader: @escaping () -> [LegacyDownloadImport]? = { LegacyStateDiscovery.readDownloadImports() }
    ) {
        self.bootstrapper = bootstrapper
        self.defaults = defaults
        self.legacyAccountReader = legacyAccountReader
        self.legacyMediaSettingsReader = legacyMediaSettingsReader
        self.legacyPlaybackReader = legacyPlaybackReader
        self.legacyPlaybackImporter = legacyPlaybackImporter
        self.legacyDownloadReader = legacyDownloadReader
    }

    /// Imports only when native credentials are absent. The completion marker is
    /// deliberately written only after a successfully activated native account,
    /// making a terminated/failed attempt safe to retry on the next launch.
    @discardableResult
    func migrateAccountIfNeeded() async -> IOSLegacyAccountMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }

        do {
            if try bootstrapper.credentialStore.load() != nil {
                logger.info("Legacy account migration skipped because native credentials already exist.")
                return .nativeAccountWins
            }
        } catch IOSCredentialStoreError.temporarilyUnavailable {
            logger.info("Legacy account migration deferred until native credentials become available.")
            return .retryableFailure
        } catch {
            logger.error("Legacy account migration could not inspect native credentials: \(String(reflecting: error))")
            return .retryableFailure
        }

        if defaults.bool(forKey: DefaultsKey.accountMigrationCompleted) {
            return .alreadyCompleted
        }

        guard let legacy = legacyAccountReader() else {
            // Absence is not marked complete: production Keychain access may be
            // temporarily unavailable and a later foreground launch can retry.
            return .noLegacyAccount
        }

        let headers = legacy.customHeaders.map {
            IOSCustomHTTPHeader(name: $0.name, value: $0.value)
        }
        await bootstrapper.configure(
            server: legacy.serverURL,
            apiKey: legacy.apiKey,
            headers: headers
        )

        let importedCredentials: IOSMinifluxCredentials
        do {
            guard let stored = try bootstrapper.credentialStore.load(),
                  bootstrapper.core != nil else {
                logger.warning("Legacy account validation or activation failed; migration remains retryable.")
                return .retryableFailure
            }
            importedCredentials = stored
        } catch {
            logger.error("Legacy account activation could not be verified: \(String(reflecting: error))")
            return .retryableFailure
        }

        defaults.set(normalizedServerIdentifier(importedCredentials.server), forKey: DefaultsKey.migratedAccountServer)
        defaults.set(true, forKey: DefaultsKey.accountMigrationCompleted)
        logger.info("Legacy account copied into native account storage and activated.")
        return .imported
    }

    /// Imports retained media policies only for the exact native account created
    /// by this coordinator. Native accounts without that provenance always win.
    @discardableResult
    func migrateMediaSettingsIfNeeded() async -> IOSLegacyMediaSettingsMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }

        do {
            guard try isCurrentMigratedAccount() else { return .notEligible }
        } catch {
            logger.error("Legacy media settings migration could not inspect native credentials: \(String(reflecting: error))")
            return .retryableFailure
        }

        guard !defaults.bool(forKey: DefaultsKey.mediaSettingsMigrationCompleted) else {
            return .alreadyCompleted
        }
        guard let legacySettings = legacyMediaSettingsReader() else {
            return .retryableFailure
        }

        if let unmeteredOnly = legacySettings.unmeteredOnly,
           case let .failure(error) = await bootstrapper.setDownloadNetworkPolicyPreference(
               unmeteredOnly ? .unmeteredOnly : .anyNetwork
           ) {
            return mediaSettingsWriteFailed(error)
        }
        if let retentionDays = legacySettings.retentionDays,
           case let .failure(error) = await bootstrapper.setDownloadRetentionPreference(.days(days: retentionDays)) {
            return mediaSettingsWriteFailed(error)
        }
        if let deleteAfterPlayback = legacySettings.deleteAfterPlayback,
           case let .failure(error) = await bootstrapper.setDeleteAfterPlaybackPreference(deleteAfterPlayback) {
            return mediaSettingsWriteFailed(error)
        }
        defaults.set(true, forKey: DefaultsKey.mediaSettingsMigrationCompleted)
        logger.info("Legacy media policy settings copied into Core settings.")
        return .imported
    }

    /// Imports article-keyed Flutter progress through the authoritative Core
    /// resolver. `updatedAt` remains nil because Flutter retained no timestamp.
    @discardableResult
    func migratePlaybackProgressIfNeeded() async -> IOSLegacyPlaybackMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }

        do {
            guard try isCurrentMigratedAccount() else { return .notEligible }
        } catch {
            logger.error("Legacy playback migration could not inspect native credentials: \(String(reflecting: error))")
            return .retryableFailure
        }
        guard !defaults.bool(forKey: DefaultsKey.playbackMigrationCompleted) else {
            return .alreadyCompleted
        }
        guard let legacyRecords = legacyPlaybackReader() else {
            return .retryableFailure
        }
        let records = legacyRecords.map {
            LegacyPlaybackImport(articleId: $0.articleID, positionMs: $0.positionMs, updatedAt: nil)
        }
        let result: Result<LegacyPlaybackImportResult, Error>
        if let legacyPlaybackImporter {
            result = await legacyPlaybackImporter(records)
        } else {
            result = await bootstrapper.importLegacyPlayback(records)
        }
        switch result {
        case let .success(importResult):
            logger.info(
                "Legacy playback imported=\(importResult.imported) missing=\(importResult.skippedMissing) ambiguous=\(importResult.skippedAmbiguous) existing=\(importResult.alreadyPresent)."
            )
            let outcome = Self.playbackMigrationOutcome(for: importResult)
            if outcome == .imported {
                defaults.set(true, forKey: DefaultsKey.playbackMigrationCompleted)
            }
            return outcome
        case let .failure(error):
            logger.error("Legacy playback migration remains retryable: \(String(reflecting: error))")
            return .retryableFailure
        }
    }

    @discardableResult
    func migrateDownloadsIfNeeded() async -> IOSLegacyDownloadMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }
        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }
        guard !defaults.bool(forKey: DefaultsKey.downloadMigrationCompleted) else { return .alreadyCompleted }
        guard let records = legacyDownloadReader(), let mediaRoot = IOSMediaTransferPathConfiguration.mediaRootURL else {
            return .retryableFailure
        }
        let fileManager = FileManager.default
        for record in records {
            let reference = "downloads/legacy/enclosure-\(record.enclosureID).audio"
            guard let size = try? record.sourceFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { continue }
            let destination: URL
            do {
                destination = try MediaTransferFileLayout.destination(reference: reference, under: mediaRoot)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: record.sourceFile, to: destination)
                }
            } catch { return .retryableFailure }
            switch await bootstrapper.importLegacyDownload(enclosureID: record.enclosureID, localFile: reference, fileSizeBytes: UInt64(size)) {
            case .success(.imported): break
            case .success(.alreadyPresent), .success(.missingEnclosure):
                // This destination is unique to this migration and was never Core state.
                try? fileManager.removeItem(at: destination)
            case .failure: return .retryableFailure
            }
        }
        defaults.set(true, forKey: DefaultsKey.downloadMigrationCompleted)
        logger.info("Legacy downloads copied into Core media storage.")
        return .imported
    }

    private func mediaSettingsWriteFailed(_ error: Error) -> IOSLegacyMediaSettingsMigrationOutcome {
        logger.error("Legacy media settings migration remains retryable: \(String(reflecting: error))")
        return .retryableFailure
    }

    static func playbackMigrationOutcome(
        for importResult: LegacyPlaybackImportResult
    ) -> IOSLegacyPlaybackMigrationOutcome {
        // A later authoritative reconcile may make these article-keyed records resolvable.
        importResult.skippedMissing > 0 ? .retryableFailure : .imported
    }

    private func normalizedServerIdentifier(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host else { return trimmed.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? trimmed.lowercased()
    }

    private func isCurrentMigratedAccount() throws -> Bool {
        guard let stored = try bootstrapper.credentialStore.load(),
              let migratedServer = defaults.string(forKey: DefaultsKey.migratedAccountServer) else {
            return false
        }
        return migratedServer == normalizedServerIdentifier(stored.server)
    }
}
