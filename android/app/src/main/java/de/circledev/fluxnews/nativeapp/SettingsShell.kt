package de.circledev.fluxnews.nativeapp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

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
 *
 * Compact settings own one app bar: Settings root goes back to News, while a detail goes back to
 * the Settings list. Wide list/detail settings keep one Settings app bar and both panes visible.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsShell(
    bootstrap: AndroidAccountBootstrap,
    navigationPreferences: AndroidNavigationPreferences,
    navigationPreferenceState: AndroidNavigationPreferenceState,
    navigationCategories: List<AndroidNavigationCategoryRef>,
    navigationFeeds: List<AndroidNavigationFeedRef>,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxSize()) {
        val listDetail = maxWidth >= 840.dp
        var selected by remember {
            mutableStateOf<SettingsDestination?>(if (listDetail) SettingsDestination.Account else null)
        }
        val showingCompactDetail = !listDetail && selected != null

        BackHandler(enabled = showingCompactDetail) {
            selected = null
        }

        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Settings") },
                    navigationIcon = {
                        TextButton(
                            onClick = {
                                if (showingCompactDetail) selected = null else onBack()
                            },
                        ) {
                            Text(if (showingCompactDetail) "‹ Settings" else "‹ News")
                        }
                    },
                )
            },
        ) { padding ->
            val contentModifier = Modifier.fillMaxSize().padding(padding)
            if (listDetail) {
                Row(contentModifier) {
                    SettingsList(
                        selected = selected,
                        onSelected = { selected = it },
                        modifier = Modifier.width(340.dp).fillMaxHeight(),
                    )
                    HorizontalDivider(modifier = Modifier.width(1.dp).fillMaxHeight())
                    androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
                        SettingsDetail(
                            destination = selected ?: SettingsDestination.Account,
                            bootstrap = bootstrap,
                            navigationPreferences = navigationPreferences,
                            navigationPreferenceState = navigationPreferenceState,
                            navigationCategories = navigationCategories,
                            navigationFeeds = navigationFeeds,
                            onAccountChanged = onAccountChanged,
                        )
                    }
                }
            } else if (selected == null) {
                SettingsList(
                    selected = null,
                    onSelected = { selected = it },
                    modifier = contentModifier,
                )
            } else {
                SettingsDetail(
                    destination = selected!!,
                    bootstrap = bootstrap,
                    navigationPreferences = navigationPreferences,
                    navigationPreferenceState = navigationPreferenceState,
                    navigationCategories = navigationCategories,
                    navigationFeeds = navigationFeeds,
                    onAccountChanged = onAccountChanged,
                    modifier = contentModifier,
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
    Column(modifier = modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        SettingsDestination.entries.forEach { destination ->
            Surface(
                color = if (selected == destination) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth().clickable { onSelected(destination) },
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
    navigationPreferences: AndroidNavigationPreferences,
    navigationPreferenceState: AndroidNavigationPreferenceState,
    navigationCategories: List<AndroidNavigationCategoryRef>,
    navigationFeeds: List<AndroidNavigationFeedRef>,
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
        SettingsDestination.Navigation -> NavigationSettingsScreen(
            preferences = navigationPreferences,
            state = navigationPreferenceState,
            categories = navigationCategories,
            feeds = navigationFeeds,
            modifier = modifier,
        )
        else -> PendingSettingsDestination(destination, modifier)
    }
}

@Composable
private fun NavigationSettingsScreen(
    preferences: AndroidNavigationPreferences,
    state: AndroidNavigationPreferenceState,
    categories: List<AndroidNavigationCategoryRef>,
    feeds: List<AndroidNavigationFeedRef>,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    Column(
        modifier = modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Navigation", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Choose which news scope FluxNews opens with and whether empty feeds are shown.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        SettingsSwitchRow(
            title = "Hide empty feeds",
            checked = state.hideEmptyNavigationEntries,
            onCheckedChange = { value -> scope.launch { preferences.setHideEmptyNavigationEntries(value) } },
        )

        HorizontalDivider()
        Text("Startup scope", style = MaterialTheme.typography.titleMedium)
        AndroidStartupScopePreference.entries.forEach { option ->
            val enabled = when (option) {
                AndroidStartupScopePreference.Category -> categories.isNotEmpty()
                AndroidStartupScopePreference.Feed -> feeds.isNotEmpty()
                else -> true
            }
            SettingsRadioRow(
                title = option.displayName,
                selected = state.startupScope == option,
                enabled = enabled,
                onClick = {
                    scope.launch {
                        preferences.setStartupScope(option)
                        if (option == AndroidStartupScopePreference.Category && state.startupCategoryId == null) {
                            categories.firstOrNull()?.let { preferences.setStartupCategoryId(it.id) }
                        }
                        if (option == AndroidStartupScopePreference.Feed && state.startupFeedId == null) {
                            feeds.firstOrNull()?.let { preferences.setStartupFeedId(it.id) }
                        }
                    }
                },
            )
        }

        if (categories.isEmpty() || feeds.isEmpty()) {
            Text(
                "Category and Feed startup scopes become available after the first successful sync.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (state.startupScope == AndroidStartupScopePreference.Category && categories.isNotEmpty()) {
            HorizontalDivider()
            Text("Startup category", style = MaterialTheme.typography.titleMedium)
            categories.forEach { category ->
                SettingsRadioRow(
                    title = category.title,
                    selected = state.startupCategoryId == category.id,
                    onClick = { scope.launch { preferences.setStartupCategoryId(category.id) } },
                )
            }
        }

        if (state.startupScope == AndroidStartupScopePreference.Feed && feeds.isNotEmpty()) {
            HorizontalDivider()
            Text("Startup feed", style = MaterialTheme.typography.titleMedium)
            feeds.forEach { feed ->
                SettingsRadioRow(
                    title = feed.title,
                    selected = state.startupFeedId == feed.id,
                    onClick = { scope.launch { preferences.setStartupFeedId(feed.id) } },
                )
            }
        }
    }
}

@Composable
private fun SettingsSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onCheckedChange(!checked) }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun SettingsRadioRow(
    title: String,
    selected: Boolean,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick, enabled = enabled)
        Text(
            title,
            modifier = Modifier.padding(start = 8.dp),
            style = MaterialTheme.typography.bodyLarge,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
        )
    }
}

@Composable
private fun PendingSettingsDestination(
    destination: SettingsDestination,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
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
