package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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

private enum class SettingsDestination(val title: String, val subtitle: String) {
    Account("Account", "Miniflux server, credentials and local account data"),
    Articles("Articles", "Article presentation and reading behavior"),
    ActionBar("Action Bar", "Article list actions"),
    Navigation("Navigation", "Startup scope and navigation behavior"),
    Media("Media", "Playback and Listening List preferences"),
    DownloadedData("Downloaded Data", "Downloaded media storage"),
    BackgroundSync("Background Sync", "Background refresh preference"),
    ConfigurationBackup("Configuration Backup", "Encrypted configuration export and restore"),
    SupportDiagnostics("Support Diagnostics", "Logging, viewer and support export"),
    About("About", "Version, open source and legal information"),
}

/**
 * Android settings information architecture mirrors the completed iOS product surface, while the
 * navigation itself follows Android responsive-list/detail conventions.
 */
@Composable
internal fun SettingsShell(
    bootstrap: AndroidAccountBootstrap,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxSize()) {
        val listDetail = maxWidth >= 840.dp
        var selected by remember { mutableStateOf<SettingsDestination?>(if (listDetail) SettingsDestination.Account else null) }

        if (listDetail) {
            Row(Modifier.fillMaxSize()) {
                SettingsList(
                    selected = selected,
                    onSelected = { selected = it },
                    modifier = Modifier.width(340.dp).fillMaxHeight(),
                )
                HorizontalDivider(modifier = Modifier.width(1.dp).fillMaxHeight())
                Box(Modifier.fillMaxSize()) {
                    SettingsDetail(
                        destination = selected ?: SettingsDestination.Account,
                        bootstrap = bootstrap,
                        onAccountChanged = onAccountChanged,
                    )
                }
            }
        } else if (selected == null) {
            SettingsList(
                selected = null,
                onSelected = { selected = it },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Column(Modifier.fillMaxSize()) {
                TextButton(
                    onClick = { selected = null },
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                ) {
                    Text("‹ Settings")
                }
                SettingsDetail(
                    destination = selected!!,
                    bootstrap = bootstrap,
                    onAccountChanged = onAccountChanged,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

@Composable
private fun SettingsList(
    selected: SettingsDestination?,
    onSelected: (SettingsDestination) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.verticalScroll(rememberScrollState()),
    ) {
        Text(
            "Settings",
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
            style = MaterialTheme.typography.headlineMedium,
        )
        SettingsDestination.entries.forEach { destination ->
            Surface(
                color = if (selected == destination) {
                    MaterialTheme.colorScheme.secondaryContainer
                } else {
                    MaterialTheme.colorScheme.surface
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onSelected(destination) },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(destination.title, style = MaterialTheme.typography.titleMedium)
                        Text(
                            destination.subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Text("›", style = MaterialTheme.typography.titleLarge)
                }
            }
        }
    }
}

@Composable
private fun SettingsDetail(
    destination: SettingsDestination,
    bootstrap: AndroidAccountBootstrap,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (destination) {
        SettingsDestination.Account -> AccountConfigurationScreen(
            bootstrap = bootstrap,
            allowsRemoval = true,
            onAccountActivated = onAccountChanged,
            onAccountRemoved = { onAccountChanged(AndroidAccountBootstrap.State.AccountRequired) },
            modifier = modifier,
        )
        else -> PendingSettingsDestination(destination, modifier)
    }
}

@Composable
private fun PendingSettingsDestination(
    destination: SettingsDestination,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(destination.title, style = MaterialTheme.typography.headlineMedium)
        Text(
            destination.subtitle,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            "This E2 settings destination is reserved by the native shell. Its product controls are added in the corresponding E2 settings slice rather than being duplicated in the shell.",
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
