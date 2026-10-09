package de.circledev.fluxnews.nativeapp

import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.DownloadRetention
import uniffi.flux_uniffi.LegacyFeedOpenInMinifluxImportOutcome
import uniffi.flux_uniffi.SyncCompleted

/**
 * E9 settings follow-up. Only the account copied by the account migration can
 * consume Flutter settings. Core's legacy import operations preserve native
 * values. Independent completion markers keep each part retryable.
 */
internal class AndroidLegacySettingsMigration(
    private val reader: () -> LegacyAndroidSettingsReadResult,
    private val preferences: AndroidPreferenceStore,
    private val credentials: AndroidCredentialStore,
    private val runtime: AndroidCoreRuntime,
) : AndroidPostSyncEffect {
    internal constructor(
        context: Context,
        preferences: AndroidPreferenceStore,
        credentials: AndroidCredentialStore,
        runtime: AndroidCoreRuntime,
    ) : this(
        reader = LegacyAndroidStateReader(context)::readSettingsImport,
        preferences = preferences,
        credentials = credentials,
        runtime = runtime,
    )

    private val mutex = Mutex()

    override suspend fun apply(sessionGeneration: Long, metadata: SyncCompleted) {
        mutex.withLock {
            val provenance = preferences.read(AndroidLegacyMigrationCoordinator.IMPORTED_ACCOUNT_SERVER, "")
            if (provenance.isBlank()) return@withLock
            val active = credentials.read() ?: return@withLock
            if (active.serverUrl != provenance) return@withLock
            if (preferences.read(SETTINGS_DONE, false) && preferences.read(FEEDS_DONE, false)) return@withLock
            val settings = when (val result = reader()) {
                LegacyAndroidSettingsReadResult.Unavailable -> return@withLock
                is LegacyAndroidSettingsReadResult.Found -> result.settings
            }
            if (!preferences.read(SETTINGS_DONE, false)) {
                runtime.localForGeneration(sessionGeneration) { core ->
                    core.importLegacyPolicySettings(
                        backgroundSyncEnabled = settings.backgroundSyncEnabled,
                        autoDownloadListeningList = settings.autoDownloadListeningList,
                    )
                    core.importLegacyMediaSettings(
                        unmeteredOnly = settings.unmeteredDownloadsOnly,
                        retention = settings.retentionDays?.let { DownloadRetention.Days(it.toUInt()) },
                        deleteAfterPlayback = settings.deleteAfterPlayback,
                    )
                }
                preferences.write(SETTINGS_DONE, true)
            }
            if (!preferences.read(FEEDS_DONE, false)) {
                var missing = false
                for (feedId in settings.openInMinifluxFeedIds) {
                    val outcome = runtime.localForGeneration(sessionGeneration) {
                        it.importLegacyFeedOpenInMiniflux(feedId)
                    }
                    if (outcome == LegacyFeedOpenInMinifluxImportOutcome.MISSING_FEED) missing = true
                }
                if (!missing) preferences.write(FEEDS_DONE, true)
            }
        }
    }

    companion object {
        internal val SETTINGS_DONE = AndroidPreferenceKey.boolean("migration-e9-settings-done")
        internal val FEEDS_DONE = AndroidPreferenceKey.boolean("migration-e9-feeds-done")
    }
}
