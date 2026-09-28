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

enum IOSLegacyFeedPreferenceMigrationOutcome: Equatable {
    case imported
    case alreadyCompleted
    case notEligible
    case retryableFailure
}

enum IOSLegacyGlobalPreferencesMigrationOutcome: Equatable {
    case notEligible
    case alreadyCompleted
    case imported
    case retryableFailure
}

enum IOSLegacySettingsFollowupMigrationOutcome: Equatable {
    case notEligible, alreadyCompleted, imported, retryableFailure
}

enum IOSLegacyToolbarMigrationOutcome: Equatable {
    case notEligible, alreadyCompleted, nativeConfigurationWins, noLegacyConfiguration, imported, retryableFailure
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
        static let feedPreferenceMigrationCompleted = "FluxNews.iOS.legacyMigration.feedPreferences.v1.completed"
        static let globalPreferencesMigrationCompleted = "FluxNews.iOS.legacyMigration.globalPreferences.v1.completed"
        static let settingsFollowupLocalCompleted = "FluxNews.iOS.legacyMigration.settingsFollowup.v2.local.completed"
        static let settingsFollowupCoreCompleted = "FluxNews.iOS.legacyMigration.settingsFollowup.v2.core.completed"
        static let settingsFollowupStartupCompleted = "FluxNews.iOS.legacyMigration.settingsFollowup.v2.startup.completed"
        static let toolbarMigrationCompleted = "FluxNews.iOS.legacyMigration.toolbar.v1.completed"
        static let removeArticlesWhenMarkedRead = "FluxNews.iOS.removeArticlesWhenMarkedRead"
        static let markReadOnScrollover = "FluxNews.iOS.markReadOnScrollover"
    }

    private let bootstrapper: CoreBootstrapper
    private let defaults: UserDefaults
    private let legacyAccountReader: () -> LegacyAccountImport?
    private let legacyMediaSettingsReader: () -> IOSLegacyMediaSettingsImport?
    private let legacyPlaybackReader: () -> [LegacyPlaybackProgressImport]?
    private let legacyPlaybackImporter: (([LegacyPlaybackImport]) async -> Result<LegacyPlaybackImportResult, Error>)?
    private let legacyDownloadReader: () -> [LegacyDownloadImport]?
    private let legacyDownloadImporter: ((Int64, String, UInt64) async -> Result<LegacyDownloadImportOutcome, Error>)?
    private let legacyFeedOpenInMinifluxReader: () -> [LegacyFeedOpenInMinifluxImport]?
    private let legacyFeedOpenInMinifluxImporter: ((Int64) async -> Result<LegacyFeedOpenInMinifluxImportOutcome, Error>)?
    private let legacyGlobalPreferencesReader: () -> LegacyGlobalPreferencesImport?
    private let legacySettingsReader: () -> LegacySettingsImport?
    private let legacyToolbarReader: () -> LegacyToolbarImport?
    private let mediaRootProvider: () -> URL?
    private let fileManager: FileManager
    private let logger = IOSAppLogger(category: "legacy_migration")
    private var inFlight = false

    init(
        bootstrapper: CoreBootstrapper,
        defaults: UserDefaults = .standard,
        legacyAccountReader: @escaping () -> LegacyAccountImport? = LegacyStateDiscovery.readAccountImport,
        legacyMediaSettingsReader: @escaping () -> IOSLegacyMediaSettingsImport? = LegacyStateDiscovery.readMediaSettingsImport,
        legacyPlaybackReader: @escaping () -> [LegacyPlaybackProgressImport]? = LegacyStateDiscovery.readPlaybackProgressImports,
        legacyPlaybackImporter: (([LegacyPlaybackImport]) async -> Result<LegacyPlaybackImportResult, Error>)? = nil,
        legacyDownloadReader: @escaping () -> [LegacyDownloadImport]? = { LegacyStateDiscovery.readDownloadImports() },
        legacyDownloadImporter: ((Int64, String, UInt64) async -> Result<LegacyDownloadImportOutcome, Error>)? = nil,
        legacyFeedOpenInMinifluxReader: @escaping () -> [LegacyFeedOpenInMinifluxImport]? = { LegacyStateDiscovery.readFeedOpenInMinifluxImports() },
        legacyFeedOpenInMinifluxImporter: ((Int64) async -> Result<LegacyFeedOpenInMinifluxImportOutcome, Error>)? = nil,
        legacyGlobalPreferencesReader: @escaping () -> LegacyGlobalPreferencesImport? = LegacyStateDiscovery.readGlobalPreferencesImport,
        legacySettingsReader: @escaping () -> LegacySettingsImport? = LegacyStateDiscovery.readSettingsImport,
        legacyToolbarReader: @escaping () -> LegacyToolbarImport? = LegacyStateDiscovery.readToolbarImport,
        mediaRootProvider: @escaping () -> URL? = { IOSMediaTransferPathConfiguration.mediaRootURL },
        fileManager: FileManager = .default
    ) {
        self.bootstrapper = bootstrapper
        self.defaults = defaults
        self.legacyAccountReader = legacyAccountReader
        self.legacyMediaSettingsReader = legacyMediaSettingsReader
        self.legacyPlaybackReader = legacyPlaybackReader
        self.legacyPlaybackImporter = legacyPlaybackImporter
        self.legacyDownloadReader = legacyDownloadReader
        self.legacyDownloadImporter = legacyDownloadImporter
        self.legacyFeedOpenInMinifluxReader = legacyFeedOpenInMinifluxReader
        self.legacyFeedOpenInMinifluxImporter = legacyFeedOpenInMinifluxImporter
        self.legacyGlobalPreferencesReader = legacyGlobalPreferencesReader
        self.legacySettingsReader = legacySettingsReader
        self.legacyToolbarReader = legacyToolbarReader
        self.mediaRootProvider = mediaRootProvider
        self.fileManager = fileManager
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

        if case let .failure(error) = await bootstrapper.importLegacyMediaSettings(legacySettings) {
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
        guard !defaults.bool(forKey: DefaultsKey.settingsFollowupLocalCompleted)
                || !defaults.bool(forKey: DefaultsKey.settingsFollowupCoreCompleted)
                || !defaults.bool(forKey: DefaultsKey.settingsFollowupStartupCompleted) else {
            return .alreadyCompleted
        }
        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }
        guard !defaults.bool(forKey: DefaultsKey.downloadMigrationCompleted) else { return .alreadyCompleted }
        guard let records = legacyDownloadReader() else { return .retryableFailure }
        guard !records.isEmpty else {
            defaults.set(true, forKey: DefaultsKey.downloadMigrationCompleted)
            return .imported
        }
        guard let mediaRoot = mediaRootProvider() else { return .retryableFailure }
        var hasRetryableRecord = false
        for record in records {
            let reference = "downloads/legacy/enclosure-\(record.enclosureID).audio"
            guard let sourceSize = readableRegularFileSize(at: record.sourceFile) else {
                hasRetryableRecord = true
                continue
            }
            let destination: URL
            let createdDestination: Bool
            do {
                destination = try MediaTransferFileLayout.destination(reference: reference, under: mediaRoot)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: destination.path) {
                    let stagingDestination = destination.appendingPathExtension("partial")
                    try? fileManager.removeItem(at: stagingDestination)
                    do {
                        try fileManager.copyItem(at: record.sourceFile, to: stagingDestination)
                        try fileManager.moveItem(at: stagingDestination, to: destination)
                    } catch {
                        try? fileManager.removeItem(at: stagingDestination)
                        throw error
                    }
                    createdDestination = true
                } else {
                    createdDestination = false
                }
            } catch {
                hasRetryableRecord = true
                continue
            }
            guard let destinationSize = readableRegularFileSize(at: destination),
                  destinationSize == sourceSize else {
                hasRetryableRecord = true
                continue
            }
            let result: Result<LegacyDownloadImportOutcome, Error>
            if let legacyDownloadImporter {
                result = await legacyDownloadImporter(record.enclosureID, reference, destinationSize)
            } else {
                result = await bootstrapper.importLegacyDownload(
                    enclosureID: record.enclosureID,
                    localFile: reference,
                    fileSizeBytes: destinationSize
                )
            }
            switch result {
            case .success(.imported): break
            case .success(.alreadyPresent):
                // Only this run can prove that it created a file Core did not adopt.
                if createdDestination { try? fileManager.removeItem(at: destination) }
            case .success(.missingEnclosure):
                // The source remains untouched, so an unadopted copy made by this
                // run can be recreated after a later authoritative sync.
                if createdDestination { try? fileManager.removeItem(at: destination) }
                hasRetryableRecord = true
            case .failure:
                // Retain a pre-existing or just-created copy: the operation may be
                // retried safely without changing the Flutter source.
                hasRetryableRecord = true
            }
        }
        guard !hasRetryableRecord else { return .retryableFailure }
        defaults.set(true, forKey: DefaultsKey.downloadMigrationCompleted)
        logger.info("Legacy downloads copied into Core media storage.")
        return .imported
    }

    @discardableResult
    func migrateFeedPreferencesIfNeeded() async -> IOSLegacyFeedPreferenceMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }
        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }
        guard !defaults.bool(forKey: DefaultsKey.feedPreferenceMigrationCompleted) else {
            return .alreadyCompleted
        }
        guard let records = legacyFeedOpenInMinifluxReader() else { return .retryableFailure }
        var hasRetryableRecord = false
        for record in records {
            guard record.openInMiniflux else { continue }
            let result: Result<LegacyFeedOpenInMinifluxImportOutcome, Error>
            if let legacyFeedOpenInMinifluxImporter {
                result = await legacyFeedOpenInMinifluxImporter(record.feedID)
            } else {
                result = await bootstrapper.importLegacyFeedOpenInMiniflux(feedID: record.feedID)
            }
            switch result {
            case .success(.imported), .success(.alreadyPresent): break
            case .success(.missingFeed), .failure: hasRetryableRecord = true
            }
        }
        guard !hasRetryableRecord else { return .retryableFailure }
        defaults.set(true, forKey: DefaultsKey.feedPreferenceMigrationCompleted)
        logger.info("Legacy positive Open in Miniflux feed preferences copied into Core.")
        return .imported
    }

    /// Imports each retained global preference only when the corresponding
    /// native UserDefaults key has never been written. Defaults are not
    /// presence, so explicit native false remains a native winner.
    @discardableResult
    func migrateGlobalPreferencesIfNeeded() async -> IOSLegacyGlobalPreferencesMigrationOutcome {
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }
        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }
        guard !defaults.bool(forKey: DefaultsKey.globalPreferencesMigrationCompleted) else {
            return .alreadyCompleted
        }
        guard let legacy = legacyGlobalPreferencesReader() else { return .retryableFailure }

        if defaults.object(forKey: DefaultsKey.markReadOnScrollover) == nil,
           let markReadOnScrollover = legacy.markReadOnScrollover {
            defaults.set(markReadOnScrollover, forKey: DefaultsKey.markReadOnScrollover)
        }
        if defaults.object(forKey: DefaultsKey.removeArticlesWhenMarkedRead) == nil,
           let removeArticlesWhenMarkedRead = legacy.removeArticlesWhenMarkedRead {
            defaults.set(removeArticlesWhenMarkedRead, forKey: DefaultsKey.removeArticlesWhenMarkedRead)
        }
        defaults.set(true, forKey: DefaultsKey.globalPreferencesMigrationCompleted)
        logger.info("Legacy global preferences copied where native values were absent.")
        return .imported
    }

    /// Versioned D9-A follow-up. Local, Core, and catalog-dependent Startup
    /// completion are separate so a missing catalog item cannot lose other work.
    @discardableResult
    func migrateSettingsFollowupIfNeeded() async -> IOSLegacySettingsFollowupMigrationOutcome {
        if defaults.bool(forKey: DefaultsKey.settingsFollowupLocalCompleted),
           defaults.bool(forKey: DefaultsKey.settingsFollowupCoreCompleted),
           defaults.bool(forKey: DefaultsKey.settingsFollowupStartupCompleted) {
            return .alreadyCompleted
        }
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }
        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }
        guard let legacy = legacySettingsReader() else { return .retryableFailure }

        var retryable = false
        if !defaults.bool(forKey: DefaultsKey.settingsFollowupLocalCompleted) {
            importLocalSettings(legacy)
            defaults.set(true, forKey: DefaultsKey.settingsFollowupLocalCompleted)
        }
        if !defaults.bool(forKey: DefaultsKey.settingsFollowupCoreCompleted) {
            switch await bootstrapper.importLegacyPolicySettings(
                backgroundSyncEnabled: legacy.backgroundSyncEnabled,
                autoDownloadListeningList: legacy.autoDownloadListeningList
            ) {
            case .success: defaults.set(true, forKey: DefaultsKey.settingsFollowupCoreCompleted)
            case .failure: retryable = true
            }
        }
        if !defaults.bool(forKey: DefaultsKey.settingsFollowupStartupCompleted) {
            switch await importStartupScope(legacy) {
            case .success: defaults.set(true, forKey: DefaultsKey.settingsFollowupStartupCompleted)
            case .failure: retryable = true
            }
        }
        if retryable { return .retryableFailure }
        return .imported
    }

    /// D9-C migration of Flutter's semantic iOS toolbar selection/order.
    /// Presence of the native array is authoritative, including an explicit
    /// empty selection. Sync and More are fixed native chrome and are never
    /// imported from Flutter.
    @discardableResult
    func migrateToolbarIfNeeded() async -> IOSLegacyToolbarMigrationOutcome {
        if defaults.bool(forKey: DefaultsKey.toolbarMigrationCompleted) {
            return .alreadyCompleted
        }
        guard !inFlight else { return .retryableFailure }
        inFlight = true
        defer { inFlight = false }

        do { guard try isCurrentMigratedAccount() else { return .notEligible } }
        catch { return .retryableFailure }

        if defaults.object(forKey: IOSArticleListActionPreferences.defaultsKey) != nil {
            defaults.set(true, forKey: DefaultsKey.toolbarMigrationCompleted)
            return .nativeConfigurationWins
        }

        guard let legacy = legacyToolbarReader() else { return .retryableFailure }
        guard let selectedActions = legacy.selectedActions else {
            defaults.set(true, forKey: DefaultsKey.toolbarMigrationCompleted)
            return .noLegacyConfiguration
        }
        defaults.set(
            selectedActions.map(\.rawValue),
            forKey: IOSArticleListActionPreferences.defaultsKey
        )
        defaults.set(true, forKey: DefaultsKey.toolbarMigrationCompleted)
        logger.info("Legacy iOS toolbar configuration copied into native action preferences.")
        return .imported
    }

    private func importLocalSettings(_ legacy: LegacySettingsImport) {
        func setBool(_ value: Bool?, key: String) {
            if defaults.object(forKey: key) == nil, let value { defaults.set(value, forKey: key) }
        }
        setBool(legacy.showArticleCount, key: "FluxNews.iOS.showArticleCount")
        setBool(legacy.hideEmptyNavigationEntries, key: "FluxNews.iOS.hideEmptyNavigationEntries")
        if legacy.tabActionExpands, defaults.object(forKey: "FluxNews.clickOnNews") == nil {
            defaults.set(ClickOnNews.openDetailView.rawValue, forKey: "FluxNews.clickOnNews")
        }
        importSwipeSide(
            full: legacy.leadingFull, additional: legacy.leadingAdditional,
            fullKey: "FluxNews.iOS.leadingSwipeFull", additionalKey: "FluxNews.iOS.leadingSwipeAdditional"
        )
        importSwipeSide(
            full: legacy.trailingFull, additional: legacy.trailingAdditional,
            fullKey: "FluxNews.iOS.trailingSwipeFull", additionalKey: "FluxNews.iOS.trailingSwipeAdditional"
        )
    }

    private func importSwipeSide(
        full legacyFull: IOSArticleSwipeAction??,
        additional legacyAdditional: IOSArticleSwipeAction??,
        fullKey: String,
        additionalKey: String
    ) {
        let fullIsNative = defaults.object(forKey: fullKey) != nil
        let additionalIsNative = defaults.object(forKey: additionalKey) != nil
        guard !fullIsNative || !additionalIsNative else { return }
        let currentFull = defaults.string(forKey: fullKey).flatMap(IOSArticleSwipeAction.init(rawValue:))
        let currentAdditional = defaults.string(forKey: additionalKey).flatMap(IOSArticleSwipeAction.init(rawValue:))
        let full = fullIsNative ? currentFull : legacyFull ?? currentFull
        var additional = additionalIsNative ? currentAdditional : legacyAdditional ?? currentAdditional
        if additional == full { additional = nil }
        if !fullIsNative, legacyFull != nil { defaults.set(full?.rawValue ?? "", forKey: fullKey) }
        if !additionalIsNative, legacyAdditional != nil { defaults.set(full == nil ? "" : (additional?.rawValue ?? ""), forKey: additionalKey) }
    }

    private func importStartupScope(_ legacy: LegacySettingsImport) async -> Result<Void, Error> {
        guard defaults.object(forKey: "FluxNews.iOS.startupScope") == nil else { return .success(()) }
        guard let mode = legacy.startupMode else { return .success(()) }
        switch mode {
        case 0:
            defaults.set(StartupScopePreference.allNews.rawValue, forKey: "FluxNews.iOS.startupScope")
        case 1:
            defaults.set(StartupScopePreference.starred.rawValue, forKey: "FluxNews.iOS.startupScope")
        case 2:
            guard let id = legacy.startupCategoryID, id > 0 else { return .success(()) }
            guard let core = bootstrapper.core,
                  let catalogResult = await bootstrapper.coreSessionExecutionCoordinator.responsiveResult(for: core, { try core.navigationCatalog() }) else {
                return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable)
            }
            guard case let .success(catalog) = catalogResult else { return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable) }
            guard catalog.categories.contains(where: { $0.id == id }) else { return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable) }
            defaults.set(StartupScopePreference.category.rawValue, forKey: "FluxNews.iOS.startupScope")
            defaults.set(id, forKey: "FluxNews.iOS.startupCategoryID")
        case 3:
            guard let id = legacy.startupFeedID, id > 0 else { return .success(()) }
            guard let core = bootstrapper.core,
                  let catalogResult = await bootstrapper.coreSessionExecutionCoordinator.responsiveResult(for: core, { try core.navigationCatalog() }) else {
                return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable)
            }
            guard case let .success(catalog) = catalogResult else { return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable) }
            guard catalog.feeds.contains(where: { $0.id == id }) else { return .failure(CoreBootstrapper.SettingsAccessError.coreUnavailable) }
            defaults.set(StartupScopePreference.feed.rawValue, forKey: "FluxNews.iOS.startupScope")
            defaults.set(id, forKey: "FluxNews.iOS.startupFeedID")
        default: break
        }
        return .success(())
    }

    private func mediaSettingsWriteFailed(_ error: Error) -> IOSLegacyMediaSettingsMigrationOutcome {
        logger.error("Legacy media settings migration remains retryable: \(String(reflecting: error))")
        return .retryableFailure
    }

    private func readableRegularFileSize(at url: URL) -> UInt64? {
        guard fileManager.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0 else {
            return nil
        }
        return UInt64(size)
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