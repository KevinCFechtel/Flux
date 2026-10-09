package de.circledev.fluxnews.nativeapp

import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.LegacyPlaybackImport
import uniffi.flux_uniffi.SyncCompleted

/**
 * Retryable E9 playback import, always resolved by the authoritative Core.
 * Flutter article progress has no reliable update timestamp, so the import
 * passes null and Core preserves any existing native progress.
 */
internal class AndroidLegacyPlaybackMigration(
    private val legacyReader: () -> LegacyAndroidPlaybackReadResult,
    private val preferenceStore: AndroidPreferenceStore,
    private val credentialStore: AndroidCredentialStore,
    private val coreRuntime: AndroidCoreRuntime,
) : AndroidPostSyncEffect {
    internal constructor(
        context: Context,
        preferenceStore: AndroidPreferenceStore,
        credentialStore: AndroidCredentialStore,
        coreRuntime: AndroidCoreRuntime,
    ) : this(
        legacyReader = LegacyAndroidStateReader(context)::readPlaybackImports,
        preferenceStore = preferenceStore,
        credentialStore = credentialStore,
        coreRuntime = coreRuntime,
    )

    private val mutex = Mutex()

    override suspend fun apply(sessionGeneration: Long, metadata: SyncCompleted) {
        mutex.withLock {
            val provenance = preferenceStore.read(AndroidLegacyMigrationCoordinator.IMPORTED_ACCOUNT_SERVER, "")
            if (provenance.isBlank()) return@withLock
            if (credentialStore.read()?.serverUrl != provenance) return@withLock
            if (preferenceStore.read(PLAYBACK_DONE, false)) return@withLock

            val records = when (val result = legacyReader()) {
                LegacyAndroidPlaybackReadResult.Unavailable -> return@withLock
                is LegacyAndroidPlaybackReadResult.Found -> result.records
            }
            val outcome = coreRuntime.localForGeneration(sessionGeneration) { core ->
                core.importLegacyPlayback(
                    records.map {
                        LegacyPlaybackImport(
                            articleId = it.articleId,
                            positionMs = it.positionMs,
                            updatedAt = null,
                        )
                    },
                )
            }
            // An empty batch is a valid completed import only after both
            // legacy sources have been successfully inspected.
            if (outcome.skippedMissing == 0u && outcome.skippedAmbiguous == 0u) {
                preferenceStore.write(PLAYBACK_DONE, true)
            }
        }
    }

    companion object {
        internal val PLAYBACK_DONE = AndroidPreferenceKey.boolean("migration-e9-playback-done")
    }
}
