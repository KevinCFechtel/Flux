import Foundation

enum IOSLegacyAccountMigrationOutcome: Equatable {
    case nativeAccountWins
    case alreadyCompleted
    case noLegacyAccount
    case imported
    case retryableFailure
}

@MainActor
final class IOSLegacyMigrationCoordinator {
    private enum DefaultsKey {
        static let accountMigrationCompleted = "FluxNews.iOS.legacyMigration.account.v1.completed"
    }

    private let bootstrapper: CoreBootstrapper
    private let defaults: UserDefaults
    private let legacyAccountReader: () -> LegacyAccountImport?
    private let logger = IOSAppLogger(category: "legacy_migration")
    private var inFlight = false

    init(
        bootstrapper: CoreBootstrapper,
        defaults: UserDefaults = .standard,
        legacyAccountReader: @escaping () -> LegacyAccountImport? = LegacyStateDiscovery.readAccountImport
    ) {
        self.bootstrapper = bootstrapper
        self.defaults = defaults
        self.legacyAccountReader = legacyAccountReader
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

        do {
            guard try bootstrapper.credentialStore.load() != nil,
                  bootstrapper.core != nil else {
                logger.warning("Legacy account validation or activation failed; migration remains retryable.")
                return .retryableFailure
            }
        } catch {
            logger.error("Legacy account activation could not be verified: \(String(reflecting: error))")
            return .retryableFailure
        }

        defaults.set(true, forKey: DefaultsKey.accountMigrationCompleted)
        logger.info("Legacy account copied into native account storage and activated.")
        return .imported
    }
}
