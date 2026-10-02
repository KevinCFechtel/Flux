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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
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
    val diagnostics = (LocalContext.current.applicationContext as FluxApplication).diagnostics
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
                        IconButton(onClick = { if (compactDetail) selected = null else onBack() }) {
                            Icon(
                                painter = painterResource(R.drawable.ic_arrow_back),
                                contentDescription = "Back",
                            )
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
                    SettingsDetail(selected ?: SettingsDestination.Account, bootstrap, navigationPreferences, navigationPreferenceState, navigationCategories, navigationFeeds, articlePreferences, articleState, actionBarPreferences, actionBarState, coreArticleSettings, mediaSettings, downloadedData, backgroundSync, configurationBackup, diagnostics, onAccountChanged, Modifier.fillMaxSize())
                }
            } else if (selected == null) {
                SettingsList(null, { selected = it }, contentModifier)
            } else {
                SettingsDetail(selected!!, bootstrap, navigationPreferences, navigationPreferenceState, navigationCategories, navigationFeeds, articlePreferences, articleState, actionBarPreferences, actionBarState, coreArticleSettings, mediaSettings, downloadedData, backgroundSync, configurationBackup, diagnostics, onAccountChanged, contentModifier)
            }
        }
    }
}

@Composable
private fun SettingsList(selected: SettingsDestination?, onSelected: (SettingsDestination) -> Unit, modifier: Modifier) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        SettingsDestination.entries.forEach { destination ->
            Surface(color = if (selected == destination) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth().clickable { onSelected(destination) }) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text(destination.title, style = MaterialTheme.typography.titleMedium); Text(destination.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    Text("›", style = MaterialTheme.typography.titleLarge)
                }
            }
        }
    }
}

@Composable
private fun SettingsDetail(destination: SettingsDestination, bootstrap: AndroidAccountBootstrap, navigationPreferences: AndroidNavigationPreferences, navigationState: AndroidNavigationPreferenceState, categories: List<AndroidNavigationCategoryRef>, feeds: List<AndroidNavigationFeedRef>, articlePreferences: AndroidArticlePreferences, articleState: AndroidArticlePreferenceState, actionBarPreferences: AndroidActionBarPreferences, actionBarState: AndroidActionBarPreferenceState, coreArticleSettings: AndroidCoreArticleSettings, mediaSettings: AndroidMediaSettings, downloadedData: AndroidDownloadedData, backgroundSync: AndroidBackgroundSync, configurationBackup: AndroidConfigurationBackupController, diagnostics: AndroidAppDiagnostics, onAccountChanged: (AndroidAccountBootstrap.State) -> Unit, modifier: Modifier) {
    when (destination) {
        SettingsDestination.Account -> AccountConfigurationScreen(bootstrap, true, onAccountChanged, { onAccountChanged(AndroidAccountBootstrap.State.AccountRequired) }, modifier = modifier)
        SettingsDestination.Articles -> ArticleSettingsScreen(articlePreferences, articleState, coreArticleSettings, modifier)
        SettingsDestination.ActionBar -> ActionBarSettingsScreen(actionBarPreferences, actionBarState, modifier)
        SettingsDestination.Navigation -> NavigationSettingsScreen(navigationPreferences, navigationState, categories, feeds, modifier)
        SettingsDestination.Media -> MediaSettingsScreen(mediaSettings, modifier)
        SettingsDestination.DownloadedData -> DownloadedDataSettingsScreen(downloadedData, modifier)
        SettingsDestination.BackgroundSync -> BackgroundSyncSettingsScreen(backgroundSync, modifier)
        SettingsDestination.ConfigurationBackup -> ConfigurationBackupScreen(configurationBackup, { (bootstrap.state as? AndroidAccountBootstrap.State.Ready)?.let(onAccountChanged) }, modifier)
        SettingsDestination.SupportDiagnostics -> SupportDiagnosticsScreen(diagnostics, modifier)
        SettingsDestination.About -> AboutSettingsScreen(modifier)
    }
}

@Composable
private fun ArticleSettingsScreen(preferences: AndroidArticlePreferences, state: AndroidArticlePreferenceState, core: AndroidCoreArticleSettings, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Articles", style = MaterialTheme.typography.headlineMedium)
        Text("Choose how articles are presented and how reading interactions behave.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        SettingsPickerRow(
            title = "Open article",
            selected = state.openArticle,
            options = AndroidArticleOpenPreference.entries.map { it to it.displayName },
        ) { option -> scope.launch { preferences.setOpenArticle(option) } }
        SettingsPickerRow(
            title = "Presentation",
            selected = state.presentationMode,
            options = AndroidArticlePresentationMode.entries.map { it to it.displayName },
        ) { option -> scope.launch { preferences.setPresentationMode(option) } }
        SettingsPickerRow(
            title = "Preview lines",
            selected = state.previewLines,
            options = AndroidArticlePreviewLines.entries.map { it to it.displayName },
        ) { option -> scope.launch { preferences.setPreviewLines(option) } }
        HorizontalDivider()
        SettingsSwitchRow("Show article count", state.showArticleCount) { scope.launch { preferences.setShowArticleCount(it) } }
        SettingsSwitchRow("Show relative publication time", state.showRelativePublicationTime) { scope.launch { preferences.setShowRelativePublicationTime(it) } }
        SettingsSwitchRow("Remove articles when read", state.removeArticlesWhenRead) { scope.launch { preferences.setRemoveArticlesWhenRead(it) } }
        SettingsSwitchRow("Mark read on scrollover", state.markReadOnScrollover) { scope.launch { preferences.setMarkReadOnScrollover(it) } }
        CoreArticleSettingsSection(core); ArticleSwipeSettingsSection(preferences, state.swipeConfiguration)
    }
}

@Composable private fun ArticleSwipeSettingsSection(preferences: AndroidArticlePreferences, configuration: AndroidArticleSwipeConfiguration) { val scope = rememberCoroutineScope(); HorizontalDivider(); Text("Swipe actions", style = MaterialTheme.typography.titleMedium); Text("Choose up to two actions on each side. The Full Swipe action is the outer action and is triggered when the row is swiped all the way.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); SwipeSideSettings("Swipe right", AndroidArticleSwipeSide.Leading, configuration, preferences, scope); SwipeSideSettings("Swipe left", AndroidArticleSwipeSide.Trailing, configuration, preferences, scope) }
@Composable private fun SwipeSideSettings(title: String, side: AndroidArticleSwipeSide, configuration: AndroidArticleSwipeConfiguration, preferences: AndroidArticlePreferences, scope: CoroutineScope) { Column { Text(title, style = MaterialTheme.typography.titleSmall); SwipeSlotSettings("Full Swipe", side, AndroidArticleSwipeSlot.FullSwipe, configuration.fullSwipeAction(side), configuration, preferences, scope, true); SwipeSlotSettings("Additional Action", side, AndroidArticleSwipeSlot.Additional, configuration.additionalAction(side), configuration, preferences, scope, true, configuration.fullSwipeAction(side) != null) } }
@Composable
private fun SwipeSlotSettings(
    label: String,
    side: AndroidArticleSwipeSide,
    slot: AndroidArticleSwipeSlot,
    selected: AndroidArticleSwipeAction?,
    configuration: AndroidArticleSwipeConfiguration,
    preferences: AndroidArticlePreferences,
    scope: CoroutineScope,
    allowNone: Boolean,
    enabled: Boolean = true,
) {
    val options = buildList<Pair<AndroidArticleSwipeAction?, String>> {
        if (allowNone) add(null to "None")
        AndroidArticleSwipeAction.entries.forEach { add(it to it.displayName) }
    }
    SettingsPickerRow(
        title = label,
        selected = selected,
        options = options,
        enabled = enabled,
    ) { action ->
        scope.launch { preferences.setSwipeAction(configuration, action, side, slot) }
    }
}

@Composable
private fun ActionBarSettingsScreen(preferences: AndroidActionBarPreferences, state: AndroidActionBarPreferenceState, modifier: Modifier) {
    val scope = rememberCoroutineScope(); val available = AndroidActionBarAction.entries.filterNot(state.actions::contains)
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Action Bar", style = MaterialTheme.typography.headlineMedium); Text("Choose the article-list actions and their display priority.", color = MaterialTheme.colorScheme.onSurfaceVariant); Text("Article List Actions", style = MaterialTheme.typography.titleMedium); ActionBarFixedRow("Sync", "Always shown")
        state.actions.forEachIndexed { index, action -> Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) { Text(action.displayName, Modifier.weight(1f)); TextButton(enabled = index > 0, onClick = { scope.launch { preferences.moveUp(action, state.actions) } }) { Text("↑") }; TextButton(enabled = index < state.actions.lastIndex, onClick = { scope.launch { preferences.moveDown(action, state.actions) } }) { Text("↓") }; TextButton(onClick = { scope.launch { preferences.remove(action, state.actions) } }) { Text("Remove") } } }
        ActionBarFixedRow("More", "Always available"); Text("Sync stays fixed at the beginning and More stays available as the fallback. The order of selected actions sets their display priority.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (available.isNotEmpty()) { HorizontalDivider(); Text("Available Actions", style = MaterialTheme.typography.titleMedium); available.forEach { action -> TextButton(onClick = { scope.launch { preferences.add(action, state.actions) } }, modifier = Modifier.fillMaxWidth()) { Text("+ ${action.displayName}", Modifier.fillMaxWidth()) } } }
        HorizontalDivider(); TextButton(onClick = { scope.launch { preferences.resetToDefault() } }) { Text("Reset to Default") }
    }
}
@Composable private fun ActionBarFixedRow(title: String, status: String) { Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) { Text(title, Modifier.weight(1f)); Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }

@Composable
private fun NavigationSettingsScreen(preferences: AndroidNavigationPreferences, state: AndroidNavigationPreferenceState, categories: List<AndroidNavigationCategoryRef>, feeds: List<AndroidNavigationFeedRef>, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Navigation", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Choose which news scope FluxNews opens with and whether empty feeds are shown.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SettingsSwitchRow("Hide empty feeds", state.hideEmptyNavigationEntries) {
            scope.launch { preferences.setHideEmptyNavigationEntries(it) }
        }
        HorizontalDivider()
        val startupScopeOptions = AndroidStartupScopePreference.entries
            .filter { option ->
                when (option) {
                    AndroidStartupScopePreference.Category -> categories.isNotEmpty()
                    AndroidStartupScopePreference.Feed -> feeds.isNotEmpty()
                    else -> true
                }
            }
            .map { it to it.displayName }
        SettingsPickerRow(
            title = "Startup scope",
            selected = state.startupScope,
            options = startupScopeOptions,
        ) { option ->
            scope.launch {
                preferences.setStartupScope(option)
                if (option == AndroidStartupScopePreference.Category && state.startupCategoryId == null) {
                    categories.firstOrNull()?.let { preferences.setStartupCategoryId(it.id) }
                }
                if (option == AndroidStartupScopePreference.Feed && state.startupFeedId == null) {
                    feeds.firstOrNull()?.let { preferences.setStartupFeedId(it.id) }
                }
            }
        }
        if (categories.isEmpty() || feeds.isEmpty()) {
            Text(
                "Category and Feed startup scopes become available after the first successful sync.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (state.startupScope == AndroidStartupScopePreference.Category && categories.isNotEmpty()) {
            val selectedCategory = categories.firstOrNull { it.id == state.startupCategoryId } ?: categories.first()
            SettingsPickerRow(
                title = "Startup category",
                selected = selectedCategory.id,
                options = categories.map { it.id to it.title },
            ) { categoryId -> scope.launch { preferences.setStartupCategoryId(categoryId) } }
        }
        if (state.startupScope == AndroidStartupScopePreference.Feed && feeds.isNotEmpty()) {
            val selectedFeed = feeds.firstOrNull { it.id == state.startupFeedId } ?: feeds.first()
            SettingsPickerRow(
                title = "Startup feed",
                selected = selectedFeed.id,
                options = feeds.map { it.id to it.title },
            ) { feedId -> scope.launch { preferences.setStartupFeedId(feedId) } }
        }
    }
}

@Composable
private fun MediaSettingsScreen(settings: AndroidMediaSettings, modifier: Modifier) {
    var state by remember { mutableStateOf<AndroidMediaSettings.State?>(null) }; var saving by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }; val scope = rememberCoroutineScope()
    suspend fun reload() { settings.load().fold({ state = it; error = null }, { error = "Media settings could not be loaded. Please try again." }) }; LaunchedEffect(settings) { reload() }
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Media", style = MaterialTheme.typography.headlineMedium); val current = state
        if (current == null) CircularProgressIndicator() else {
            Text("Downloads", style = MaterialTheme.typography.titleMedium)
            SettingsPickerRow(
                title = "Download Network",
                selected = current.downloadNetworkPolicy,
                options = listOf(
                    DownloadNetworkPolicy.ANY_NETWORK to "Any Network",
                    DownloadNetworkPolicy.UNMETERED_ONLY to "Unmetered Networks Only",
                ),
                enabled = !saving,
            ) { policy ->
                scope.launch {
                    saving = true
                    settings.setDownloadNetworkPolicy(policy).fold(
                        { reload() },
                        { error = "Media setting could not be saved. Please try again." },
                    )
                    saving = false
                }
            }
            SettingsPickerRow(
                title = "Keep Downloads",
                selected = current.downloadRetention,
                options = AndroidDownloadRetentionChoice.entries.map { it to it.displayName },
                enabled = !saving,
            ) { choice ->
                scope.launch {
                    saving = true
                    settings.setDownloadRetention(choice).fold(
                        { reload() },
                        { error = "Media setting could not be saved. Please try again." },
                    )
                    saving = false
                }
            }
            HorizontalDivider()
            Text("Listening List", style = MaterialTheme.typography.titleMedium)
            SettingsSwitchRow("Automatically download Listening List audio", current.autoDownloadListeningList, !saving) { value ->
                scope.launch {
                    saving = true
                    settings.setAutoDownloadListeningList(value).fold(
                        { reload() },
                        { error = "Media setting could not be saved. Please try again." },
                    )
                    saving = false
                }
            }
            SettingsSwitchRow("Delete download after playback completes", current.deleteAfterPlayback, !saving) { value ->
                scope.launch {
                    saving = true
                    settings.setDeleteAfterPlayback(value).fold(
                        { reload() },
                        { error = "Media setting could not be saved. Please try again." },
                    )
                    saving = false
                }
            }
            SettingsSwitchRow("Remove completed items from Listening List", current.removeCompletedListeningList, !saving) { value ->
                scope.launch {
                    saving = true
                    settings.setRemoveCompletedListeningList(value).fold(
                        { reload() },
                        { error = "Media setting could not be saved. Please try again." },
                    )
                    saving = false
                }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun DownloadedDataSettingsScreen(downloadedData: AndroidDownloadedData, modifier: Modifier) {
    var summary by remember { mutableStateOf<AndroidDownloadedData.Summary?>(null) }; var loading by remember { mutableStateOf(false) }; var deleting by remember { mutableStateOf(false) }; var confirmDelete by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }; val scope = rememberCoroutineScope()
    suspend fun reload() { loading = true; downloadedData.summary().fold({ summary = it; error = null }, { error = "Downloaded data could not be loaded. Please try again." }); loading = false }; LaunchedEffect(downloadedData) { reload() }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete All Downloads?") }, text = { Text("This removes all downloaded media files. Listening List membership and playback progress are kept.") }, confirmButton = { TextButton(onClick = { confirmDelete = false; scope.launch { deleting = true; downloadedData.requestDeleteAll().fold({ reload() }, { error = "Downloads could not be deleted. Please try again." }); deleting = false } }) { Text("Delete") } }, dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } })
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Downloaded Data", style = MaterialTheme.typography.headlineMedium)
        if (loading && summary == null) CircularProgressIndicator() else summary?.let { current -> DownloadedDataValueRow("Downloaded Files", NumberFormat.getIntegerInstance().format(current.fileCount.toLong())); DownloadedDataValueRow("Storage Used", formatBytes(current.totalSizeBytes)); Text("This includes local audio files that are still waiting for physical deletion. Listening List items and playback progress are stored separately.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); HorizontalDivider(); Button(enabled = !deleting && current.fileCount > 0uL, onClick = { confirmDelete = true }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError)) { Text("Delete All Downloads") } }
        if (deleting) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) { CircularProgressIndicator(Modifier.size(20.dp)); Text("Deleting Downloads…") }; error?.let { Text(it, color = MaterialTheme.colorScheme.error) }; TextButton(enabled = !loading && !deleting, onClick = { scope.launch { reload() } }) { Text("Refresh") }
    }
}
@Composable private fun DownloadedDataValueRow(label: String, value: String) { Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) { Text(label, Modifier.weight(1f)); Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
private fun formatBytes(bytes: ULong): String { var amount = bytes.toDouble(); val units = arrayOf("B", "KB", "MB", "GB", "TB"); var index = 0; while (amount >= 1000.0 && index < units.lastIndex) { amount /= 1000.0; index++ }; return if (index == 0) "$bytes B" else String.format(java.util.Locale.getDefault(), "%.1f %s", amount, units[index]) }

@Composable
internal fun <T> SettingsPickerRow(
    title: String,
    selected: T,
    options: List<Pair<T, String>>,
    enabled: Boolean = true,
    onSelected: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == selected }?.second ?: selected.toString()
    Box(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (enabled) Modifier.clickable { expanded = true } else Modifier)
                .padding(vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                modifier = Modifier.weight(1f),
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = .38f),
            )
            Text(
                selectedLabel,
                color = if (enabled) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .38f),
                style = MaterialTheme.typography.bodyMedium,
            )
            Icon(
                painter = painterResource(R.drawable.ic_expand_more),
                contentDescription = null,
                modifier = Modifier.padding(start = 6.dp),
                tint = if (enabled) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .38f),
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            options.forEach { (value, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = {
                        expanded = false
                        if (value != selected) onSelected(value)
                    },
                    trailingIcon = {
                        if (value == selected) {
                            Text("✓", color = MaterialTheme.colorScheme.primary)
                        }
                    },
                )
            }
        }
    }
}

@Composable
internal fun SettingsSwitchRow(
    title: String,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (enabled) Modifier.clickable { onCheckedChange(!checked) } else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f))
        Switch(checked, onCheckedChange, enabled = enabled)
    }
}
