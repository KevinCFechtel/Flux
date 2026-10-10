package de.circledev.fluxnews.nativeapp

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.LegacyDownloadImportOutcome
import uniffi.flux_uniffi.SyncCompleted

/**
 * Copies verified Flutter downloads to a distinct native media root, then
 * adopts them through Core. Does not mutate or delete Flutter source files.
 */
internal class AndroidLegacyDownloadMigration(
    private val legacyReader: () -> LegacyAndroidDownloadReadResult,
    private val preferences: AndroidPreferenceStore,
    private val credentials: AndroidCredentialStore,
    private val runtime: AndroidCoreRuntime,
    private val mediaRoot: File,
) : AndroidPostSyncEffect {
    internal constructor(
        context: Context,
        preferences: AndroidPreferenceStore,
        credentials: AndroidCredentialStore,
        runtime: AndroidCoreRuntime,
        mediaRoot: File,
    ) : this(
        legacyReader = LegacyAndroidStateReader(context)::readDownloadImports,
        preferences = preferences,
        credentials = credentials,
        runtime = runtime,
        mediaRoot = mediaRoot,
    )

    private val mutex = Mutex()

    override suspend fun apply(sessionGeneration: Long, metadata: SyncCompleted) {
        mutex.withLock {
            val provenance = preferences.read(AndroidLegacyMigrationCoordinator.IMPORTED_ACCOUNT_SERVER, "")
            if (provenance.isBlank() || credentials.read()?.serverUrl != provenance) return@withLock
            if (preferences.read(DOWNLOADS_DONE, false)) return@withLock
            val records = when (val result = legacyReader()) {
                LegacyAndroidDownloadReadResult.Unavailable -> return@withLock
                is LegacyAndroidDownloadReadResult.Found -> result.records
            }
            var shouldRetry = false
            var missingEnclosures = 0
            var failedFiles = 0
            for (record in records) {
                val reference = "downloads/legacy/enclosure-${record.enclosureId}.audio"
                val destination = AndroidMediaTransferFileLayout.destination(mediaRoot, reference)
                var created = false
                try {
                    val sourceLength = record.sourceFile.length()
                    require(sourceLength > 0 && record.sourceFile.isFile && record.sourceFile.canRead())
                    if (!destination.exists()) {
                        val directory = requireNotNull(destination.parentFile)
                        check(directory.isDirectory || directory.mkdirs())
                        val partial = File(directory, ".enclosure-${record.enclosureId}.migration-partial")
                        // A leftover staging file is never an authoritative native download.
                        if (partial.exists()) check(partial.delete())
                        try {
                            record.sourceFile.inputStream().use { input ->
                                FileOutputStream(partial).use { output ->
                                    input.copyTo(output)
                                    output.fd.sync()
                                }
                            }
                            check(partial.length() == sourceLength)
                            try {
                                Files.move(partial.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
                            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                                Files.move(partial.toPath(), destination.toPath())
                            }
                            created = true
                        } finally {
                            partial.delete()
                        }
                    }
                    check(destination.isFile && destination.length() == sourceLength)
                    val outcome = runtime.localForGeneration(sessionGeneration) {
                        it.importLegacyDownload(
                            enclosureId = record.enclosureId,
                            localFile = reference,
                            fileSizeBytes = sourceLength.toULong(),
                        )
                    }
                    when (outcome) {
                        LegacyDownloadImportOutcome.IMPORTED -> Unit
                        LegacyDownloadImportOutcome.ALREADY_PRESENT -> if (created) destination.delete()
                        LegacyDownloadImportOutcome.MISSING_ENCLOSURE -> {
                            if (created) destination.delete()
                            shouldRetry = true
                            missingEnclosures++
                        }
                    }
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // If Core may have accepted this file before the exception,
                    // retain it for the next idempotent import attempt.
                    shouldRetry = true
                    failedFiles++
                }
            }
            if (!shouldRetry) {
                preferences.write(DOWNLOADS_DONE, true)
                preferences.remove(DOWNLOADS_STATUS)
            } else {
                preferences.write(DOWNLOADS_STATUS, buildList {
                    if (missingEnclosures > 0) add("$missingEnclosures missing audio attachment(s)")
                    if (failedFiles > 0) add("$failedFiles file(s) could not be adopted")
                }.joinToString("; "))
            }
        }
    }

    companion object {
        internal val DOWNLOADS_DONE = AndroidPreferenceKey.boolean("migration-e9-downloads-done")
        internal val DOWNLOADS_STATUS = AndroidPreferenceKey.string("migration-e9-downloads-status")
    }
}
