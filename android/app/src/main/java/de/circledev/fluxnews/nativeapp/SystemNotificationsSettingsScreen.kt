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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.FeedSystemNotificationSetting

@Composable
internal fun SystemNotificationsSettingsScreen(
    manager: AndroidSystemNotificationManager,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var settings by remember { mutableStateOf<List<FeedSystemNotificationSetting>?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var pendingEnableFeedId by remember { mutableStateOf<Long?>(null) }
    var refreshGeneration by remember { mutableStateOf(0) }

    suspend fun refresh() {
        manager.feedSettings()
            .onSuccess {
                settings = it
                message = null
            }
            .onFailure {
                settings = emptyList()
                message = "System Notification settings could not be loaded."
            }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val feedId = pendingEnableFeedId
        pendingEnableFeedId = null
        if (!granted || feedId == null) {
            message = "Notification permission is required before a feed can be enabled."
        } else {
            scope.launch {
                manager.setFeedEnabled(feedId, true)
                    .onFailure { message = "This feed could not be enabled for System Notifications." }
                refreshGeneration += 1
            }
        }
    }

    LaunchedEffect(manager, refreshGeneration) { refresh() }

    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "Choose which feeds may post a single aggregated Android notification when background sync finds new articles.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (
            !manager.notificationsEnabledBySystem() &&
            (manager.hasRuntimePermission() || message != null)
        ) {
            Text(
                "Android notification settings currently block FluxNews notifications.",
                color = MaterialTheme.colorScheme.error,
            )
            Button(
                onClick = { context.startActivity(manager.systemSettingsIntent()) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Open Android notification settings")
            }
        }

        message?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
        }

        val current = settings
        when {
            current == null -> CircularProgressIndicator()
            current.isEmpty() && message == null -> Text(
                "Feeds become available after the first successful sync.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            else -> current.orEmpty().forEach { setting ->
                SettingsSwitchRow(
                    title = setting.feedTitle,
                    checked = setting.systemNotificationsEnabled,
                ) { enabled ->
                    if (
                        enabled &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        !manager.hasRuntimePermission()
                    ) {
                        pendingEnableFeedId = setting.feedId
                        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        scope.launch {
                            manager.setFeedEnabled(setting.feedId, enabled)
                                .onFailure {
                                    message = "System Notification setting could not be saved."
                                }
                            refreshGeneration += 1
                        }
                    }
                }
            }
        }
    }
}
