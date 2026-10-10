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
            AndroidLegacyMigrationNoticeStep("Playback progress", playbackComplete, playbackStatus.ifBlank { "Audio positions checked" }),
            AndroidLegacyMigrationNoticeStep("Downloads", downloadsComplete, downloadsStatus.ifBlank { "Offline audio checked" }),
            AndroidLegacyMigrationNoticeStep("Widgets", widgetsComplete, "Widget preferences checked"),
        )

    val completedSteps: Int get() = steps.count { it.complete }
    val complete: Boolean get() = steps.all { it.complete }

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
    ) { server, dismissed, flags, details ->
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
        )
    }

    suspend fun acknowledge() {
        preferences.write(ACKNOWLEDGED, true)
    }

    companion object {
        internal val ACKNOWLEDGED = AndroidPreferenceKey.boolean("migration-e9-summary-acknowledged")
    }
}

@Composable
internal fun AndroidLegacyMigrationNoticeDialog(
    state: AndroidLegacyMigrationNotice,
    syncing: Boolean,
    onSync: () -> Unit,
    onClose: () -> Unit,
) {
    val steps = state.steps
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (state.complete) "Migration complete" else "Import from FluxNews") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    if (state.complete) {
                        "Your previous data has been checked. Existing native data was preserved."
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
                                if (step.complete) step.description else if (step.description.contains("checked")) "Pending – checked after the next successful sync" else step.description,
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
        confirmButton = {
            Button(onClick = onClose) {
                Text(if (state.complete) "Done" else "Continue in background")
            }
        },
        dismissButton = {
            if (!state.complete) {
                TextButton(onClick = onSync, enabled = !syncing) { Text("Sync now") }
            }
        },
    )
}
