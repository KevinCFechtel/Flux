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
            // Playback migration runs before download migration. Hydrate read,
            // non-starred historical articles before matching persisted positions.
            // Failures remain retryable; never discard any legacy progress.
            for (record in records) {
                try {
                    coreRuntime.remoteForGeneration(sessionGeneration) {
                        it.restoreLegacyPlaybackArticle(record.articleId)
                    }
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // An unavailable remote article must not prevent the rest
                    // of the playback batch from importing.
                }
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
            val missing = outcome.skippedMissing.toInt()
            val ambiguous = outcome.skippedAmbiguous.toInt()
            if (missing == 0 && ambiguous == 0) {
                preferenceStore.write(PLAYBACK_DONE, true)
                preferenceStore.remove(PLAYBACK_STATUS)
            } else {
                preferenceStore.write(
                    PLAYBACK_STATUS,
                    buildList {
                        if (missing > 0) add("$missing missing article(s)")
                        if (ambiguous > 0) add("$ambiguous ambiguous audio attachment(s)")
                    }.joinToString("; "),
                )
            }
        }
    }

    companion object {
        internal val PLAYBACK_DONE = AndroidPreferenceKey.boolean("migration-e9-playback-done")
        internal val PLAYBACK_STATUS = AndroidPreferenceKey.string("migration-e9-playback-status")
    }
}
