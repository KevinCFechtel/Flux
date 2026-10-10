package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine

/**
 * Read-only, privacy-safe presentation of durable E9 stage markers. The UI never
 * reads Flutter secrets, filenames, server URLs, article titles, or API keys.
 * "Checked" is intentional: an import step can finish with no legacy data or
 * when existing native/Core values correctly take precedence.
 */
internal data class AndroidLegacyMigrationNotice(
    val importedServer: String = "",
    val acknowledged: Boolean = false,
    val settingsComplete: Boolean = false,
    val localComplete: Boolean = false,
    val feedsComplete: Boolean = false,
    val startupComplete: Boolean = false,
    val playbackComplete: Boolean = false,
    val downloadsComplete: Boolean = false,
    val widgetsComplete: Boolean = false,
    val playbackStatus: String = "",
    val downloadsStatus: String = "",
    val feedsStatus: String = "",
    val startupStatus: String = "",
    val completionKind: String = "",
    val skippedPlaybackDetails: String = "",
    val skippedDownloadDetails: String = "",
) {
    val steps: List<AndroidLegacyMigrationNoticeStep>
        get() = listOf(
            AndroidLegacyMigrationNoticeStep("Account", true, "Credentials transferred securely"),
            AndroidLegacyMigrationNoticeStep(
                "Settings",
                settingsComplete && localComplete,
                "App- und Medien-Settings geprüft",
            ),
            AndroidLegacyMigrationNoticeStep(
                "Feeds & startup view",
                feedsComplete && startupComplete,
                listOf(feedsStatus, startupStatus).filter(String::isNotBlank).joinToString("; ")
                    .ifBlank { "Feed preferences and startup view checked" },
            ),
            AndroidLegacyMigrationNoticeStep("Playback progress", playbackComplete, skippedPlaybackDetails.takeIf { it.isNotBlank() }?.let { "Completed with skipped items: $it" } ?: playbackStatus.ifBlank { "Audio positions checked" }),
            AndroidLegacyMigrationNoticeStep("Downloads", downloadsComplete, skippedDownloadDetails.takeIf { it.isNotBlank() }?.let { "Completed with skipped items: $it" } ?: downloadsStatus.ifBlank { "Offline audio checked" }),
            AndroidLegacyMigrationNoticeStep("Widgets", widgetsComplete, "Widget preferences checked"),
        )

    val completedSteps: Int get() = steps.count { it.complete }
    val complete: Boolean get() = steps.all { it.complete }
    val completedWithSkippedItems: Boolean get() = completionKind == "completed_with_skipped_items"
    val canFinishPartial: Boolean get() =
        settingsComplete && localComplete && feedsComplete && startupComplete && widgetsComplete &&
            (!playbackComplete || !downloadsComplete) &&
            (playbackComplete || playbackStatus.isNotBlank()) &&
            (downloadsComplete || downloadsStatus.isNotBlank())

    fun appliesTo(serverUrl: String?): Boolean =
        importedServer.isNotBlank() && serverUrl != null && importedServer == serverUrl && !acknowledged
}

internal data class AndroidLegacyMigrationNoticeStep(
    val title: String,
    val complete: Boolean,
    val description: String,
)

internal class AndroidLegacyMigrationNoticeStore(private val preferences: AndroidPreferenceStore) {
    private val account = preferences.observe(AndroidLegacyMigrationCoordinator.IMPORTED_ACCOUNT_SERVER, "")
    private val acknowledged = preferences.observe(ACKNOWLEDGED, false)
    private val completionFlags: Flow<Array<Boolean>> = combine(
        listOf(
            preferences.observe(AndroidLegacySettingsMigration.SETTINGS_DONE, false),
            preferences.observe(AndroidLegacySettingsMigration.LOCAL_DONE, false),
            preferences.observe(AndroidLegacySettingsMigration.FEEDS_DONE, false),
            preferences.observe(AndroidLegacySettingsMigration.STARTUP_DONE, false),
            preferences.observe(AndroidLegacyPlaybackMigration.PLAYBACK_DONE, false),
            preferences.observe(AndroidLegacyDownloadMigration.DOWNLOADS_DONE, false),
            preferences.observe(AndroidLegacySettingsMigration.WIDGET_DONE, false),
        ),
    ) { values -> values }

    private val finalization = combine(
        listOf(
            preferences.observe(COMPLETION_KIND, ""),
            preferences.observe(SKIPPED_PLAYBACK_DETAILS, ""),
            preferences.observe(SKIPPED_DOWNLOAD_DETAILS, ""),
        ),
    ) { values -> values }

    private val reasons: Flow<Array<String>> = combine(
        listOf(
            preferences.observe(AndroidLegacyPlaybackMigration.PLAYBACK_STATUS, ""),
            preferences.observe(AndroidLegacyDownloadMigration.DOWNLOADS_STATUS, ""),
            preferences.observe(AndroidLegacySettingsMigration.FEEDS_STATUS, ""),
            preferences.observe(AndroidLegacySettingsMigration.STARTUP_STATUS, ""),
        ),
    ) { values -> values }

    val state: Flow<AndroidLegacyMigrationNotice> = combine(
        account,
        acknowledged,
        completionFlags,
        reasons,
        finalization,
    ) { server, dismissed, flags, details, finish ->
        AndroidLegacyMigrationNotice(
            importedServer = server,
            acknowledged = dismissed,
            settingsComplete = flags[0],
            localComplete = flags[1],
            feedsComplete = flags[2],
            startupComplete = flags[3],
            playbackComplete = flags[4],
            downloadsComplete = flags[5],
            widgetsComplete = flags[6],
            playbackStatus = details[0],
            downloadsStatus = details[1],
            feedsStatus = details[2],
            startupStatus = details[3],
            completionKind = finish[0],
            skippedPlaybackDetails = finish[1],
            skippedDownloadDetails = finish[2],
        )
    }

    suspend fun acknowledge() {
        preferences.write(ACKNOWLEDGED, true)
    }

    /** Finish only after successful import attempts, preserving exact retry reasons. */
    suspend fun finishWithUnresolvedMedia() {
        preferences.finishLegacyMigrationWithSkippedMedia(
            requiredKeys = listOf(
                AndroidLegacySettingsMigration.SETTINGS_DONE,
                AndroidLegacySettingsMigration.LOCAL_DONE,
                AndroidLegacySettingsMigration.FEEDS_DONE,
                AndroidLegacySettingsMigration.STARTUP_DONE,
                AndroidLegacySettingsMigration.WIDGET_DONE,
            ),
            playbackDone = AndroidLegacyPlaybackMigration.PLAYBACK_DONE,
            downloadsDone = AndroidLegacyDownloadMigration.DOWNLOADS_DONE,
            playbackReason = AndroidLegacyPlaybackMigration.PLAYBACK_STATUS,
            downloadsReason = AndroidLegacyDownloadMigration.DOWNLOADS_STATUS,
            skippedPlayback = SKIPPED_PLAYBACK_DETAILS,
            skippedDownloads = SKIPPED_DOWNLOAD_DETAILS,
            completionKind = COMPLETION_KIND,
            acknowledged = ACKNOWLEDGED,
        )
    }

    companion object {
        internal val ACKNOWLEDGED = AndroidPreferenceKey.boolean("migration-e9-summary-acknowledged")
        internal val COMPLETION_KIND = AndroidPreferenceKey.string("migration-e9-completion-kind-v1")
        internal val SKIPPED_PLAYBACK_DETAILS = AndroidPreferenceKey.string("migration-e9-skipped-playback-details-v1")
        internal val SKIPPED_DOWNLOAD_DETAILS = AndroidPreferenceKey.string("migration-e9-skipped-download-details-v1")
    }
}

@Composable
internal fun AndroidLegacyMigrationNoticeDialog(
    state: AndroidLegacyMigrationNotice,
    syncing: Boolean,
    onSync: () -> Unit,
    onClose: () -> Unit,
    onFinishPartial: () -> Unit,
) {
    val steps = state.steps
    var confirmSkip by remember { mutableStateOf(false) }
    if (confirmSkip) {
        AlertDialog(
            onDismissRequest = { confirmSkip = false },
            title = { Text("Finish migration?") },
            text = { Text("Successfully matched playback positions and downloads have already been imported. Only unresolved entries will be skipped. Original Flutter files remain untouched. Automatic retries will stop.") },
            confirmButton = {
                Button(onClick = { confirmSkip = false; onFinishPartial() }) {
                    Text("Skip unresolved entries")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmSkip = false }) { Text("Keep retrying") }
            },
        )
    }
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (state.completedWithSkippedItems) "Migration completed with skipped items" else if (state.complete) "Migration complete" else "Import from FluxNews") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    if (state.complete) {
                        if (state.completedWithSkippedItems) "Import completed with skipped items. Successfully imported data was preserved; unresolved media entries were intentionally skipped." else "Your previous data has been checked. Existing native data was preserved."
                    } else {
                        "Wir übernehmen die bisherigen Settings und Mediendaten. Einzelne Schritte werden nach der Synchronisierung geprüft."
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                LinearProgressIndicator(
                    progress = { state.completedSteps.toFloat() / steps.size },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${state.completedSteps} von ${steps.size} areas checked",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                steps.forEach { step ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Text(
                            if (step.complete) "✓" else "○",
                            color = if (step.complete) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Column {
                            Text(step.title, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                if (step.complete) step.description else if ((step.title == "Playback progress" && state.playbackStatus.isNotBlank()) || (step.title == "Downloads" && state.downloadsStatus.isNotBlank()) || (step.title == "Feeds & startup view" && (state.feedsStatus.isNotBlank() || state.startupStatus.isNotBlank()))) step.description else "Pending – checked after the next successful sync",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                if (!state.complete) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (syncing) CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.padding(4.dp))
                        Text(
                            if (syncing) "Sync in progress…"
                            else "Pending steps will be retried after synchronization.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        },
        // Keep all actions in a single aligned group instead of splitting
        // them between Material 3's widely separated dialog button slots.
        confirmButton = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.End,
            ) {
                if (!state.complete) {
                    TextButton(onClick = onSync, enabled = !syncing) {
                        Text("Sync now")
                    }
                    if (state.canFinishPartial) {
                        TextButton(onClick = { confirmSkip = true }, enabled = !syncing) {
                            Text("Finish with unresolved items")
                        }
                    }
                }
                Button(onClick = onClose) {
                    Text(if (state.complete) "Done" else "Continue in background")
                }
            }
        },
    )
}
