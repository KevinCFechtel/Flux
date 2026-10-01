package de.circledev.fluxnews.nativeapp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.text.NumberFormat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.DownloadNetworkPolicy

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
    val articlePreferences = LocalAndroidArticlePreferences.current
    val actionBarPreferences = LocalAndroidActionBarPreferences.current
    val coreArticleSettings = LocalAndroidCoreArticleSettings.current
    val mediaSettings = LocalAndroidMediaSettings.current
    val downloadedData = LocalAndroidDownloadedData.current
    val backgroundSync = LocalAndroidBackgroundSync.current
    val configurationBackup = LocalAndroidConfigurationBackup.current
    var articleState by remember { mutableStateOf(AndroidArticlePreferenceState()) }
    var actionBarState by remember { mutableStateOf(AndroidActionBarPreferenceState()) }

    LaunchedEffect(articlePreferences) { articlePreferences.state.collect { articleState = it } }
    LaunchedEffect(actionBarPreferences) { actionBarPreferences.state.collect { actionBarState = it } }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val listDetail = maxWidth >= 840.dp
        var selected by remember { mutableStateOf<SettingsDestination?>(if (listDetail) SettingsDestination.Account else null) }
        val compactDetail = !listDetail && selected != null
        BackHandler(enabled = compactDetail) { selected = null }
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(if (compactDetail) selected!!.title else "Settings") },
                    navigationIcon = {
                        TextButton(onClick = { if (compactDetail) selected = null else onBack() }) {
                            Text(if (compactDetail) "‹ Settings" else "‹ News")
                        }
                    },
                )
            },
        ) { padding ->
            val contentModifier = Modifier.fillMaxSize().padding(padding)
            if (listDetail) {
                Row(contentModifier) {
                    SettingsList(selected, { selected = it }, Modifier.width(340.dp).fillMaxHeight())
                    HorizontalDivider(Modifier.width(1.dp).fillMaxHeight())
                    SettingsDetail(selected ?: SettingsDestination.Account, bootstrap, navigationPreferences, navigationPreferenceState, navigationCategories, navigationFeeds, articlePreferences, articleState, actionBarPreferences, actionBarState, coreArticleSettings, mediaSettings, downloadedData, backgroundSync, configurationBackup, onAccountChanged, Modifier.fillMaxSize())
                }
            } else if (selected == null) {
                SettingsList(null, { selected = it }, contentModifier)
            } else {
                SettingsDetail(selected!!, bootstrap, navigationPreferences, navigationPreferenceState, navigationCategories, navigationFeeds, articlePreferences, articleState, actionBarPreferences, actionBarState, coreArticleSettings, mediaSettings, downloadedData, backgroundSync, configurationBackup, onAccountChanged, contentModifier)
            }
        }
    }
}

@Composable
private fun SettingsList(selected: SettingsDestination?, onSelected: (SettingsDestination) -> Unit, modifier: Modifier) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        SettingsDestination.entries.forEach { destination ->
            Surface(
                color = if (selected == destination) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth().clickable { onSelected(destination) },
            ) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(destination.title, style = MaterialTheme.typography.titleMedium)
                        Text(destination.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
    navigationState: AndroidNavigationPreferenceState,
    categories: List<AndroidNavigationCategoryRef>,
    feeds: List<AndroidNavigationFeedRef>,
    articlePreferences: AndroidArticlePreferences,
    articleState: AndroidArticlePreferenceState,
    actionBarPreferences: AndroidActionBarPreferences,
    actionBarState: AndroidActionBarPreferenceState,
    coreArticleSettings: AndroidCoreArticleSettings,
    mediaSettings: AndroidMediaSettings,
    downloadedData: AndroidDownloadedData,
    backgroundSync: AndroidBackgroundSync,
    configurationBackup: AndroidConfigurationBackupController,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier,
) {
    when (destination) {
        SettingsDestination.Account -> AccountConfigurationScreen(bootstrap, true, onAccountChanged, { onAccountChanged(AndroidAccountBootstrap.State.AccountRequired) }, modifier = modifier)
        SettingsDestination.Articles -> ArticleSettingsScreen(articlePreferences, articleState, coreArticleSettings, modifier)
        SettingsDestination.ActionBar -> ActionBarSettingsScreen(actionBarPreferences, actionBarState, modifier)
        SettingsDestination.Navigation -> NavigationSettingsScreen(navigationPreferences, navigationState, categories, feeds, modifier)
        SettingsDestination.Media -> MediaSettingsScreen(mediaSettings, modifier)
        SettingsDestination.DownloadedData -> DownloadedDataSettingsScreen(downloadedData, modifier)
        SettingsDestination.BackgroundSync -> BackgroundSyncSettingsScreen(backgroundSync, modifier)
        SettingsDestination.ConfigurationBackup -> ConfigurationBackupScreen(configurationBackup, { (bootstrap.state as? AndroidAccountBootstrap.State.Ready)?.let(onAccountChanged) }, modifier)
        else -> PendingSettingsDestination(destination, modifier)
    }
}

@Composable
private fun ArticleSettingsScreen(preferences: AndroidArticlePreferences, state: AndroidArticlePreferenceState, core: AndroidCoreArticleSettings, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Articles", style = MaterialTheme.typography.headlineMedium)
        Text("Choose how articles are presented and how reading interactions behave.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        SettingsChoiceGroup("Open article") {
            AndroidArticleOpenPreference.entries.forEach { option -> SettingsRadioRow(option.displayName, state.openArticle == option) { scope.launch { preferences.setOpenArticle(option) } } }
        }
        SettingsChoiceGroup("Presentation") {
            AndroidArticlePresentationMode.entries.forEach { option -> SettingsRadioRow(option.displayName, state.presentationMode == option) { scope.launch { preferences.setPresentationMode(option) } } }
        }
        SettingsChoiceGroup("Preview lines") {
            AndroidArticlePreviewLines.entries.forEach { option -> SettingsRadioRow(option.displayName, state.previewLines == option) { scope.launch { preferences.setPreviewLines(option) } } }
        }
        HorizontalDivider()
        SettingsSwitchRow("Show article count", state.showArticleCount) { scope.launch { preferences.setShowArticleCount(it) } }
        SettingsSwitchRow("Show relative publication time", state.showRelativePublicationTime) { scope.launch { preferences.setShowRelativePublicationTime(it) } }
        SettingsSwitchRow("Remove articles when read", state.removeArticlesWhenRead) { scope.launch { preferences.setRemoveArticlesWhenRead(it) } }
        SettingsSwitchRow("Mark read on scrollover", state.markReadOnScrollover) { scope.launch { preferences.setMarkReadOnScrollover(it) } }
        CoreArticleSettingsSection(core)
        ArticleSwipeSettingsSection(preferences, state.swipeConfiguration)
    }
}

@Composable
private fun ArticleSwipeSettingsSection(preferences: AndroidArticlePreferences, configuration: AndroidArticleSwipeConfiguration) {
    val scope = rememberCoroutineScope()
    HorizontalDivider()
    Text("Swipe actions", style = MaterialTheme.typography.titleMedium)
    Text("Choose up to two actions on each side. The Full Swipe action is the outer action and is triggered when the row is swiped all the way.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    SwipeSideSettings("Swipe right", AndroidArticleSwipeSide.Leading, configuration, preferences, scope)
    SwipeSideSettings("Swipe left", AndroidArticleSwipeSide.Trailing, configuration, preferences, scope)
}

@Composable
private fun SwipeSideSettings(title: String, side: AndroidArticleSwipeSide, configuration: AndroidArticleSwipeConfiguration, preferences: AndroidArticlePreferences, scope: CoroutineScope) {
    Column {
        Text(title, style = MaterialTheme.typography.titleSmall)
        SwipeSlotSettings("Full Swipe", side, AndroidArticleSwipeSlot.FullSwipe, configuration.fullSwipeAction(side), configuration, preferences, scope, true)
        SwipeSlotSettings("Additional Action", side, AndroidArticleSwipeSlot.Additional, configuration.additionalAction(side), configuration, preferences, scope, true, configuration.fullSwipeAction(side) != null)
    }
}

@Composable
private fun SwipeSlotSettings(label: String, side: AndroidArticleSwipeSide, slot: AndroidArticleSwipeSlot, selected: AndroidArticleSwipeAction?, configuration: AndroidArticleSwipeConfiguration, preferences: AndroidArticlePreferences, scope: CoroutineScope, allowNone: Boolean, enabled: Boolean = true) {
    Column {
        Text(label, style = MaterialTheme.typography.labelLarge)
        if (allowNone) SettingsRadioRow("None", selected == null, enabled) { scope.launch { preferences.setSwipeAction(configuration, null, side, slot) } }
        AndroidArticleSwipeAction.entries.forEach { action -> SettingsRadioRow(action.displayName, selected == action, enabled) { scope.launch { preferences.setSwipeAction(configuration, action, side, slot) } } }
    }
}

@Composable
private fun ActionBarSettingsScreen(preferences: AndroidActionBarPreferences, state: AndroidActionBarPreferenceState, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    val available = AndroidActionBarAction.entries.filterNot(state.actions::contains)
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Action Bar", style = MaterialTheme.typography.headlineMedium)
        Text("Choose the article-list actions and their display priority.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Article List Actions", style = MaterialTheme.typography.titleMedium)
        ActionBarFixedRow("Sync", "Always shown")
        state.actions.forEachIndexed { index, action ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(action.displayName, Modifier.weight(1f))
                TextButton(enabled = index > 0, onClick = { scope.launch { preferences.moveUp(action, state.actions) } }) { Text("↑") }
                TextButton(enabled = index < state.actions.lastIndex, onClick = { scope.launch { preferences.moveDown(action, state.actions) } }) { Text("↓") }
                TextButton(onClick = { scope.launch { preferences.remove(action, state.actions) } }) { Text("Remove") }
            }
        }
        ActionBarFixedRow("More", "Always available")
        Text("Sync stays fixed at the beginning and More stays available as the fallback. The order of selected actions sets their display priority.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (available.isNotEmpty()) {
            HorizontalDivider()
            Text("Available Actions", style = MaterialTheme.typography.titleMedium)
            available.forEach { action -> TextButton(onClick = { scope.launch { preferences.add(action, state.actions) } }, modifier = Modifier.fillMaxWidth()) { Text("+ ${action.displayName}", Modifier.fillMaxWidth()) } }
        }
        HorizontalDivider()
        TextButton(onClick = { scope.launch { preferences.resetToDefault() } }) { Text("Reset to Default") }
    }
}

@Composable
private fun ActionBarFixedRow(title: String, status: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) { Text(title, Modifier.weight(1f)); Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
private fun NavigationSettingsScreen(preferences: AndroidNavigationPreferences, state: AndroidNavigationPreferenceState, categories: List<AndroidNavigationCategoryRef>, feeds: List<AndroidNavigationFeedRef>, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Navigation", style = MaterialTheme.typography.headlineMedium)
        Text("Choose which news scope FluxNews opens with and whether empty feeds are shown.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        SettingsSwitchRow("Hide empty feeds", state.hideEmptyNavigationEntries) { scope.launch { preferences.setHideEmptyNavigationEntries(it) } }
        HorizontalDivider()
        Text("Startup scope", style = MaterialTheme.typography.titleMedium)
        AndroidStartupScopePreference.entries.forEach { option ->
            val enabled = when (option) { AndroidStartupScopePreference.Category -> categories.isNotEmpty(); AndroidStartupScopePreference.Feed -> feeds.isNotEmpty(); else -> true }
            SettingsRadioRow(option.displayName, state.startupScope == option, enabled) {
                scope.launch {
                    preferences.setStartupScope(option)
                    if (option == AndroidStartupScopePreference.Category && state.startupCategoryId == null) categories.firstOrNull()?.let { preferences.setStartupCategoryId(it.id) }
                    if (option == AndroidStartupScopePreference.Feed && state.startupFeedId == null) feeds.firstOrNull()?.let { preferences.setStartupFeedId(it.id) }
                }
            }
        }
        if (categories.isEmpty() || feeds.isEmpty()) Text("Category and Feed startup scopes become available after the first successful sync.", style = MaterialTheme.typography.bodySmall)
        if (state.startupScope == AndroidStartupScopePreference.Category) categories.forEach { category -> SettingsRadioRow(category.title, state.startupCategoryId == category.id) { scope.launch { preferences.setStartupCategoryId(category.id) } } }
        if (state.startupScope == AndroidStartupScopePreference.Feed) feeds.forEach { feed -> SettingsRadioRow(feed.title, state.startupFeedId == feed.id) { scope.launch { preferences.setStartupFeedId(feed.id) } } }
    }
}

@Composable
private fun MediaSettingsScreen(settings: AndroidMediaSettings, modifier: Modifier) {
    var state by remember { mutableStateOf<AndroidMediaSettings.State?>(null) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun reload() { settings.load().fold({ state = it; error = null }, { error = "Media settings could not be loaded. Please try again." }) }
    LaunchedEffect(settings) { reload() }
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Media", style = MaterialTheme.typography.headlineMedium)
        val current = state
        if (current == null) CircularProgressIndicator() else {
            Text("Downloads", style = MaterialTheme.typography.titleMedium)
            SettingsRadioRow("Any Network", current.downloadNetworkPolicy == DownloadNetworkPolicy.ANY_NETWORK, !saving) { scope.launch { saving = true; settings.setDownloadNetworkPolicy(DownloadNetworkPolicy.ANY_NETWORK).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } }
            SettingsRadioRow("Unmetered Networks Only", current.downloadNetworkPolicy == DownloadNetworkPolicy.UNMETERED_ONLY, !saving) { scope.launch { saving = true; settings.setDownloadNetworkPolicy(DownloadNetworkPolicy.UNMETERED_ONLY).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } }
            Text("Keep Downloads", style = MaterialTheme.typography.titleSmall)
            AndroidDownloadRetentionChoice.entries.forEach { choice -> SettingsRadioRow(choice.displayName, current.downloadRetention == choice, !saving) { scope.launch { saving = true; settings.setDownloadRetention(choice).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } } }
            HorizontalDivider()
            Text("Listening List", style = MaterialTheme.typography.titleMedium)
            SettingsSwitchRow("Automatically download Listening List audio", current.autoDownloadListeningList, !saving) { value -> scope.launch { saving = true; settings.setAutoDownloadListeningList(value).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } }
            SettingsSwitchRow("Delete download after playback completes", current.deleteAfterPlayback, !saving) { value -> scope.launch { saving = true; settings.setDeleteAfterPlayback(value).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } }
            SettingsSwitchRow("Remove completed items from Listening List", current.removeCompletedListeningList, !saving) { value -> scope.launch { saving = true; settings.setRemoveCompletedListeningList(value).fold({ reload() }, { error = "Media setting could not be saved. Please try again." }); saving = false } }
        }
        if (saving) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) { CircularProgressIndicator(Modifier.size(20.dp)); Text("Saving…") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun DownloadedDataSettingsScreen(data: AndroidDownloadedData, modifier: Modifier) {
    var summary by remember { mutableStateOf<AndroidDownloadedData.Summary?>(null) }
    var loading by remember { mutableStateOf(true) }
    var deleting by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun reload() { loading = true; data.summary().fold({ summary = it; error = null }, { error = "Downloaded data could not be loaded. Please try again." }); loading = false }
    LaunchedEffect(data) { reload() }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { if (!deleting) confirmDelete = false },
        title = { Text("Delete All Downloads?") },
        text = { Text("All locally downloaded audio files will be removed. Listening List items and playback progress will not be deleted.") },
        dismissButton = { TextButton(enabled = !deleting, onClick = { confirmDelete = false }) { Text("Cancel") } },
        confirmButton = { TextButton(enabled = !deleting, onClick = { confirmDelete = false; scope.launch { deleting = true; data.requestDeleteAll().fold({ reload() }, { error = "Downloads could not be deleted. Please try again." }); deleting = false } }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
    )
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Downloaded Data", style = MaterialTheme.typography.headlineMedium)
        if (loading && summary == null) CircularProgressIndicator() else summary?.let { current ->
            DownloadedDataValueRow("Downloaded Files", NumberFormat.getIntegerInstance().format(current.fileCount.toLong()))
            DownloadedDataValueRow("Storage Used", formatBytes(current.totalSizeBytes))
            Text("This includes local audio files that are still waiting for physical deletion. Listening List items and playback progress are stored separately.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            HorizontalDivider()
            Button(enabled = !deleting && current.fileCount > 0uL, onClick = { confirmDelete = true }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError)) { Text("Delete All Downloads") }
        }
        if (deleting) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) { CircularProgressIndicator(Modifier.size(20.dp)); Text("Deleting Downloads…") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(enabled = !loading && !deleting, onClick = { scope.launch { reload() } }) { Text("Refresh") }
    }
}

@Composable
private fun DownloadedDataValueRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) { Text(label, Modifier.weight(1f)); Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

private fun formatBytes(bytes: ULong): String {
    var amount = bytes.toDouble()
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var index = 0
    while (amount >= 1000.0 && index < units.lastIndex) { amount /= 1000.0; index++ }
    return if (index == 0) "$bytes B" else String.format(java.util.Locale.getDefault(), "%.1f %s", amount, units[index])
}

@Composable
internal fun SettingsChoiceGroup(title: String, content: @Composable () -> Unit) {
    Column { Text(title, style = MaterialTheme.typography.titleMedium); content() }
}

@Composable
internal fun SettingsSwitchRow(title: String, checked: Boolean, enabled: Boolean = true, onCheckedChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().then(if (enabled) Modifier.clickable { onCheckedChange(!checked) } else Modifier).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked, onCheckedChange, enabled = enabled)
    }
}

@Composable
internal fun SettingsRadioRow(title: String, selected: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick, enabled = enabled)
        Text(title, Modifier.padding(start = 8.dp), color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = .38f))
    }
}

@Composable
private fun PendingSettingsDestination(destination: SettingsDestination, modifier: Modifier) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(destination.title, style = MaterialTheme.typography.headlineMedium)
        Text(destination.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("This E2 settings destination is reserved by the native shell. Its product controls are added in the corresponding E2 settings slice rather than being duplicated in the shell.")
    }
}
