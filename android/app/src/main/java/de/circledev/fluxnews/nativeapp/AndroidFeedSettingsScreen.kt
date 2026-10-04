package de.circledev.fluxnews.nativeapp

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.DetailRenderingMode
import uniffi.flux_uniffi.FeedPreferences

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun AndroidFeedSettingsDestination(
    feedId: Long,
    feedTitle: String,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Feed Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            painter = painterResource(R.drawable.ic_arrow_back),
                            contentDescription = "Back",
                        )
                    }
                },
            )
        },
    ) { padding ->
        AndroidCenteredContent(
            maxWidth = AndroidSettingsDetailMaxWidth,
            modifier = Modifier.fillMaxWidth().padding(padding),
        ) { contentModifier ->
            AndroidFeedSettingsScreen(
                feedId = feedId,
                feedTitle = feedTitle,
                modifier = contentModifier,
            )
        }
    }
}

@Composable
internal fun AndroidFeedSettingsScreen(
    feedId: Long,
    feedTitle: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val application = context.applicationContext as FluxApplication
    val coreRuntime = application.coreRuntime
    val notifications = LocalAndroidSystemNotifications.current
    val scope = rememberCoroutineScope()

    var preferences by remember(feedId) { mutableStateOf<FeedPreferences?>(null) }
    var error by remember(feedId) { mutableStateOf<String?>(null) }
    var saving by remember(feedId) { mutableStateOf(false) }
    var refreshGeneration by remember(feedId) { mutableIntStateOf(0) }
    var pendingNotificationEnable by remember(feedId) { mutableStateOf(false) }

    suspend fun reload() {
        runCatching { coreRuntime.local { core -> core.feedPreferences(feedId) } }
            .onSuccess {
                preferences = it
                error = null
            }
            .onFailure {
                preferences = null
                error = "Feed settings could not be loaded."
            }
    }

    fun update(change: suspend () -> Unit) {
        if (saving) return
        scope.launch {
            saving = true
            error = null
            runCatching { change() }
                .onSuccess { refreshGeneration += 1 }
                .onFailure { error = "Feed settings could not be saved." }
            saving = false
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        pendingNotificationEnable = false
        if (!granted) {
            error = "Notification permission is required before System Notifications can be enabled."
        } else {
            update {
                notifications.setFeedEnabled(feedId, true).getOrThrow()
            }
        }
    }

    LaunchedEffect(feedId, refreshGeneration) { reload() }

    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            feedTitle,
            style = MaterialTheme.typography.titleLarge,
        )

        val current = preferences
        if (current == null) {
            CircularProgressIndicator()
        } else {
            SettingsPickerRow(
                title = "Detail Rendering",
                selected = current.detailRendering,
                options = listOf(
                    DetailRenderingMode.RENDERED to "Rendered",
                    DetailRenderingMode.TEXT_ONLY to "Text Only",
                ),
                enabled = !saving,
            ) { mode ->
                update {
                    coreRuntime.local { core -> core.setFeedDetailRendering(feedId, mode) }
                }
            }

            SettingsSwitchRow(
                title = "Truncate Detail",
                checked = current.truncateDetail,
                enabled = !saving,
            ) { enabled ->
                update {
                    coreRuntime.local { core -> core.setFeedTruncateDetail(feedId, enabled) }
                }
            }

            HorizontalDivider()

            SettingsSwitchRow(
                title = "System Notifications",
                checked = current.systemNotificationsEnabled,
                enabled = !saving && !pendingNotificationEnable,
            ) { enabled ->
                if (
                    enabled &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    !notifications.hasRuntimePermission()
                ) {
                    pendingNotificationEnable = true
                    permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    update {
                        notifications.setFeedEnabled(feedId, enabled).getOrThrow()
                    }
                }
            }

            if (
                current.systemNotificationsEnabled &&
                !notifications.notificationsEnabledBySystem()
            ) {
                Text(
                    "Android notification settings currently block FluxNews notifications.",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                Button(
                    onClick = { context.startActivity(notifications.systemSettingsIntent()) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Open Android notification settings")
                }
            }

            HorizontalDivider()

            SettingsSwitchRow(
                title = "Open in Miniflux",
                checked = current.openInMiniflux,
                enabled = !saving,
            ) { enabled ->
                update {
                    coreRuntime.local { core -> core.setFeedOpenInMiniflux(feedId, enabled) }
                }
            }

            SettingsSwitchRow(
                title = "Automatically Download Audio",
                checked = current.autoDownloadAudio,
                enabled = !saving,
            ) { enabled ->
                update {
                    coreRuntime.local { core -> core.setFeedAutoDownloadAudio(feedId, enabled) }
                }
            }
        }

        error?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
        }
    }
}
