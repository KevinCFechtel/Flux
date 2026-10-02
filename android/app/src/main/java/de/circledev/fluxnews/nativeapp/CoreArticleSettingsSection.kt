package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.ReadArticleRetention

@Composable
internal fun CoreArticleSettingsSection(settings: AndroidCoreArticleSettings) {
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
    SettingsSectionTitle("Storage & Reader")

    when {
        loading -> CircularProgressIndicator()
        state != null -> {
            val current = state!!
            val retentionOptions = listOf(
                ReadArticleRetention.DAYS30,
                ReadArticleRetention.DAYS60,
                ReadArticleRetention.DAYS90,
                ReadArticleRetention.DAYS180,
                ReadArticleRetention.DAYS365,
            )
            SettingsPickerRow(
                title = "Keep read articles",
                selected = current.retention,
                options = retentionOptions.map { it to it.androidDisplayName() },
                enabled = !saving,
            ) { option ->
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

            val detailLimitOptions = listOf(5_000u, 10_000u, 20_000u)
            SettingsPickerRow(
                title = "Reader detail limit",
                selected = current.detailCharacterLimit,
                options = detailLimitOptions.map { option ->
                    option to "${option.toInt().formattedWithGrouping()} characters"
                },
                enabled = !saving,
            ) { option ->
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

            Text(
                "Read article retention controls how long synchronized read items remain in local history. The Reader detail limit controls how much article text the Core keeps when a feed uses truncated Reader content.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            HorizontalDivider()
            CoreSwitchRow("Sync article changes immediately", current.liveMutationDelivery, !saving) { enabled ->
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
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator()
            Text("Saving…", style = MaterialTheme.typography.bodySmall)
        }
    }

    error?.let {
        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        if (state == null) TextButton(onClick = ::reload) { Text("Retry") }
    }
}

@Composable
private fun CoreSwitchRow(title: String, checked: Boolean, enabled: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth()
            .then(if (enabled) Modifier.clickable { onCheckedChange(!checked) } else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

private fun Int.formattedWithGrouping(): String = String.format("%,d", this)
