package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.ReadArticleRetention

@Composable
internal fun CoreArticleSettingsSection(
    settings: AndroidCoreArticleSettings,
) {
    var state by remember { mutableStateOf<AndroidCoreArticleSettings.State?>(null) }
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun reload() {
        scope.launch {
            loading = true
            error = null
            settings.load().fold(
                onSuccess = { state = it },
                onFailure = { error = "Core article settings could not be loaded. Please try again." },
            )
            loading = false
        }
    }

    LaunchedEffect(settings) {
        settings.load().fold(
            onSuccess = { state = it },
            onFailure = { error = "Core article settings could not be loaded. Please try again." },
        )
        loading = false
    }

    HorizontalDivider()
    Text("Storage & Reader", style = MaterialTheme.typography.titleMedium)

    when {
        loading -> CircularProgressIndicator()
        state != null -> {
            val current = state!!
            SettingsChoiceGroup("Keep read articles") {
                listOf(
                    ReadArticleRetention.DAYS30,
                    ReadArticleRetention.DAYS60,
                    ReadArticleRetention.DAYS90,
                    ReadArticleRetention.DAYS180,
                    ReadArticleRetention.DAYS365,
                ).forEach { option ->
                    SettingsRadioRow(
                        title = option.androidDisplayName(),
                        selected = current.retention == option,
                        enabled = !saving,
                    ) {
                        val previous = current
                        state = current.copy(retention = option)
                        saving = true
                        error = null
                        scope.launch {
                            settings.setRetention(option).onFailure {
                                state = previous
                                error = "Read article retention setting could not be saved. Please try again."
                            }
                            saving = false
                        }
                    }
                }
            }

            SettingsChoiceGroup("Reader detail limit") {
                listOf(5_000u, 10_000u, 20_000u).forEach { option ->
                    SettingsRadioRow(
                        title = "${option.toInt().formattedWithGrouping()} characters",
                        selected = current.detailCharacterLimit == option,
                        enabled = !saving,
                    ) {
                        val previous = current
                        state = current.copy(detailCharacterLimit = option)
                        saving = true
                        error = null
                        scope.launch {
                            settings.setDetailCharacterLimit(option).onFailure {
                                state = previous
                                error = "Reader detail limit setting could not be saved. Please try again."
                            }
                            saving = false
                        }
                    }
                }
            }

            Text(
                "Read article retention controls how long synchronized read items remain in local history. The Reader detail limit controls how much article text the Core keeps when a feed uses truncated Reader content.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            HorizontalDivider()
            SettingsSwitchRow(
                title = "Sync article changes immediately",
                checked = current.liveMutationDelivery,
                enabled = !saving,
            ) { enabled ->
                val previous = current
                state = current.copy(liveMutationDelivery = enabled)
                saving = true
                error = null
                scope.launch {
                    settings.setLiveMutationDelivery(enabled).onFailure {
                        state = previous
                        error = "Immediate article sync setting could not be saved. Please try again."
                    }
                    saving = false
                }
            }
            Text(
                "When enabled, read/unread and star changes are saved locally first and then sent to Miniflux immediately. If delivery fails, FluxNews keeps the change pending for a later retry.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    if (saving) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator()
            Text("Saving…", style = MaterialTheme.typography.bodySmall)
        }
    }

    error?.let {
        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        if (state == null) {
            androidx.compose.material3.TextButton(onClick = ::reload) { Text("Retry") }
        }
    }
}

private fun Int.formattedWithGrouping(): String = String.format("%,d", this)
