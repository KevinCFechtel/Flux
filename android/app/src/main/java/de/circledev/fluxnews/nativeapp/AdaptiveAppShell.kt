package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.NavigationCountMode
import uniffi.flux_uniffi.NavigationProjection

/** Product-level news scopes shared by the Android navigation shell and the E3 timeline. */
internal sealed interface AndroidNewsScope {
    data object All : AndroidNewsScope
    data object Starred : AndroidNewsScope
    data class Category(val id: Long, val title: String) : AndroidNewsScope
    data class Feed(val id: Long, val categoryId: Long, val title: String) : AndroidNewsScope
}

private sealed interface ShellScreen {
    data object Timeline : ShellScreen
    data object Search : ShellScreen
    data object ListeningList : ShellScreen
    data object Settings : ShellScreen
}

private data class NewsNavigationModel(
    val projection: NavigationProjection? = null,
    val error: String? = null,
)

/**
 * The timeline is the app root. News scope navigation is transient on phone-sized canvases and
 * persistent when both dimensions provide tablet/foldable room. Settings, Search and Listening
 * List are secondary surfaces rather than top-level tabs.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AdaptiveAppShell(
    bootstrap: AndroidAccountBootstrap,
    coreRuntime: AndroidCoreRuntime,
    state: AndroidAccountBootstrap.State.Ready,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    var screen by remember { mutableStateOf<ShellScreen>(ShellScreen.Timeline) }
    var selectedScope by remember { mutableStateOf<AndroidNewsScope>(AndroidNewsScope.All) }
    var navigation by remember { mutableStateOf(NewsNavigationModel()) }

    suspend fun reloadNavigation() {
        navigation = try {
            NewsNavigationModel(
                projection = coreRuntime.local { core ->
                    core.navigationProjection(NavigationCountMode.UNREAD)
                },
            )
        } catch (_: Exception) {
            NewsNavigationModel(error = "Navigation data could not be loaded.")
        }
    }

    LaunchedEffect(coreRuntime) {
        reloadNavigation()
        coreRuntime.events.collect { reloadNavigation() }
    }

    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxSize()) {
        // A wide phone in landscape must remain transient. Requiring useful height as well as
        // width mirrors the iOS size-class contract without naming device models.
        val persistentNewsNavigation = maxWidth >= 600.dp && maxHeight >= 600.dp

        if (screen == ShellScreen.Settings) {
            SettingsScreen(
                bootstrap = bootstrap,
                onAccountChanged = onAccountChanged,
                onBack = { screen = ShellScreen.Timeline },
            )
            return@BoxWithConstraints
        }

        if (persistentNewsNavigation) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(modifier = Modifier.width(320.dp)) {
                        NewsNavigationContent(
                            navigation = navigation,
                            selectedScope = selectedScope,
                            onScopeSelected = {
                                selectedScope = it
                                screen = ShellScreen.Timeline
                            },
                            onSearch = { screen = ShellScreen.Search },
                            onListeningList = { screen = ShellScreen.ListeningList },
                            onSettings = { screen = ShellScreen.Settings },
                        )
                    }
                },
            ) {
                NewsRootContent(
                    screen = screen,
                    scope = selectedScope,
                    navigation = navigation,
                    state = state,
                    persistentNavigation = true,
                    onOpenNavigation = {},
                )
            }
        } else {
            val drawerState = rememberDrawerState(DrawerValue.Closed)
            val coroutineScope = rememberCoroutineScope()
            ModalNavigationDrawer(
                drawerState = drawerState,
                drawerContent = {
                    ModalDrawerSheet(modifier = Modifier.widthIn(max = 360.dp)) {
                        NewsNavigationContent(
                            navigation = navigation,
                            selectedScope = selectedScope,
                            onScopeSelected = {
                                selectedScope = it
                                screen = ShellScreen.Timeline
                                coroutineScope.launch { drawerState.close() }
                            },
                            onSearch = {
                                screen = ShellScreen.Search
                                coroutineScope.launch { drawerState.close() }
                            },
                            onListeningList = {
                                screen = ShellScreen.ListeningList
                                coroutineScope.launch { drawerState.close() }
                            },
                            onSettings = {
                                screen = ShellScreen.Settings
                                coroutineScope.launch { drawerState.close() }
                            },
                        )
                    }
                },
            ) {
                NewsRootContent(
                    screen = screen,
                    scope = selectedScope,
                    navigation = navigation,
                    state = state,
                    persistentNavigation = false,
                    onOpenNavigation = { coroutineScope.launch { drawerState.open() } },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewsRootContent(
    screen: ShellScreen,
    scope: AndroidNewsScope,
    navigation: NewsNavigationModel,
    state: AndroidAccountBootstrap.State.Ready,
    persistentNavigation: Boolean,
    onOpenNavigation: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    if (!persistentNavigation) {
                        IconButton(onClick = onOpenNavigation) {
                            Icon(
                                painter = painterResource(R.drawable.ic_menu),
                                contentDescription = "Open navigation",
                            )
                        }
                    }
                },
                title = {
                    when (screen) {
                        ShellScreen.Timeline -> {
                            if (persistentNavigation) {
                                ScopeTitle(scope, navigation)
                            } else {
                                TextButton(onClick = onOpenNavigation) {
                                    ScopeTitle(scope, navigation)
                                    Icon(
                                        painter = painterResource(R.drawable.ic_expand_more),
                                        contentDescription = "Choose news scope",
                                        modifier = Modifier.padding(start = 4.dp),
                                    )
                                }
                            }
                        }
                        ShellScreen.Search -> Text("Search")
                        ShellScreen.ListeningList -> Text("Listening List")
                        ShellScreen.Settings -> Unit
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (screen) {
                ShellScreen.Timeline -> NewsTimelinePlaceholder(scope, navigation, state)
                ShellScreen.Search -> SecondaryPlaceholder(
                    title = "Search",
                    message = "Native article search is connected to this destination in E3.",
                )
                ShellScreen.ListeningList -> SecondaryPlaceholder(
                    title = "Listening List",
                    message = "Native media presentation is connected to this destination in the media phase.",
                )
                ShellScreen.Settings -> Unit
            }
        }
    }
}

@Composable
private fun NewsNavigationContent(
    navigation: NewsNavigationModel,
    selectedScope: AndroidNewsScope,
    onScopeSelected: (AndroidNewsScope) -> Unit,
    onSearch: () -> Unit,
    onListeningList: () -> Unit,
    onSettings: () -> Unit,
) {
    val projection = navigation.projection
    val feedCounts = projection?.feedCounts?.associate { it.id to it.count }.orEmpty()
    val categoryCounts = projection?.categoryCounts?.associate { it.id to it.count }.orEmpty()
    var expandedCategories by remember { mutableStateOf(setOf<Long>()) }

    LaunchedEffect(selectedScope, projection) {
        if (selectedScope is AndroidNewsScope.Feed) {
            expandedCategories = expandedCategories + selectedScope.categoryId
        }
    }

    Column(
        modifier = Modifier
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 12.dp),
    ) {
        Text(
            "FluxNews",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
        )
        Text(
            "News",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        NavigationDrawerItem(
            label = { DrawerLabel("All News", projection?.unreadTotal ?: 0) },
            selected = selectedScope == AndroidNewsScope.All,
            onClick = { onScopeSelected(AndroidNewsScope.All) },
            icon = { DrawerIcon(R.drawable.ic_news, "All News") },
        )
        NavigationDrawerItem(
            label = { DrawerLabel("Starred", projection?.starredTotal ?: 0) },
            selected = selectedScope == AndroidNewsScope.Starred,
            onClick = { onScopeSelected(AndroidNewsScope.Starred) },
            icon = { DrawerIcon(R.drawable.ic_star, "Starred") },
        )
        NavigationDrawerItem(
            label = { Text("Listening List") },
            selected = false,
            onClick = onListeningList,
            icon = { DrawerIcon(R.drawable.ic_headphones, "Listening List") },
        )
        NavigationDrawerItem(
            label = { Text("Search") },
            selected = false,
            onClick = onSearch,
            icon = { DrawerIcon(R.drawable.ic_search, "Search") },
        )

        HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp))
        Text(
            "Feeds",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )

        if (projection == null) {
            Text(
                navigation.error ?: "Loading feeds…",
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            projection.catalog.categories.forEach { category ->
                val categoryScope = AndroidNewsScope.Category(category.id, category.title)
                val expanded = category.id in expandedCategories
                CategoryNavigationRow(
                    title = category.title,
                    count = categoryCounts[category.id] ?: 0,
                    selected = selectedScope == categoryScope,
                    containsSelectedFeed = selectedScope is AndroidNewsScope.Feed &&
                        selectedScope.categoryId == category.id,
                    expanded = expanded,
                    onToggleExpanded = {
                        expandedCategories = if (expanded) {
                            expandedCategories - category.id
                        } else {
                            expandedCategories + category.id
                        }
                    },
                    onSelected = { onScopeSelected(categoryScope) },
                )
                if (expanded) {
                    projection.catalog.feeds
                        .filter { it.categoryId == category.id }
                        .forEach { feed ->
                            val feedScope = AndroidNewsScope.Feed(
                                id = feed.id,
                                categoryId = feed.categoryId,
                                title = feed.title,
                            )
                            FeedNavigationRow(
                                title = feed.title,
                                count = feedCounts[feed.id] ?: 0,
                                selected = selectedScope == feedScope,
                                onClick = { onScopeSelected(feedScope) },
                            )
                        }
                }
            }

            val knownCategoryIds = projection.catalog.categories.mapTo(mutableSetOf()) { it.id }
            projection.catalog.feeds
                .filter { it.categoryId !in knownCategoryIds }
                .forEach { feed ->
                    val feedScope = AndroidNewsScope.Feed(feed.id, feed.categoryId, feed.title)
                    FeedNavigationRow(
                        title = feed.title,
                        count = feedCounts[feed.id] ?: 0,
                        selected = selectedScope == feedScope,
                        onClick = { onScopeSelected(feedScope) },
                    )
                }
        }

        Spacer(Modifier.height(12.dp))
        HorizontalDivider()
        NavigationDrawerItem(
            label = { Text("Settings") },
            selected = false,
            onClick = onSettings,
            icon = { DrawerIcon(R.drawable.ic_settings, "Settings") },
            modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
        )
    }
}

@Composable
private fun CategoryNavigationRow(
    title: String,
    count: ULong,
    selected: Boolean,
    containsSelectedFeed: Boolean,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onSelected: () -> Unit,
) {
    Surface(
        color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onToggleExpanded) {
                Icon(
                    painter = painterResource(
                        if (expanded) R.drawable.ic_expand_more else R.drawable.ic_chevron_right,
                    ),
                    contentDescription = if (expanded) "Collapse $title" else "Expand $title",
                )
            }
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onSelected)
                    .padding(end = 16.dp, top = 14.dp, bottom = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_folder),
                    contentDescription = null,
                    tint = if (containsSelectedFeed) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    title,
                    modifier = Modifier.weight(1f).padding(start = 12.dp),
                    fontWeight = if (containsSelectedFeed) FontWeight.Medium else FontWeight.Normal,
                )
                CountText(count)
            }
        }
    }
}

@Composable
private fun FeedNavigationRow(
    title: String,
    count: ULong,
    selected: Boolean,
    onClick: () -> Unit,
) {
    NavigationDrawerItem(
        label = { DrawerLabel(title, count) },
        selected = selected,
        onClick = onClick,
        icon = {
            Text(
                "•",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        },
        modifier = Modifier.padding(start = 32.dp),
    )
}

@Composable
private fun DrawerLabel(title: String, count: ULong) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, modifier = Modifier.weight(1f))
        CountText(count)
    }
}

@Composable
private fun CountText(count: ULong) {
    if (count > 0u) {
        Text(
            if (count > 999u) "999+" else count.toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun DrawerIcon(drawable: Int, description: String) {
    Icon(painter = painterResource(drawable), contentDescription = description)
}

@Composable
private fun ScopeTitle(scope: AndroidNewsScope, navigation: NewsNavigationModel) {
    val count = when (scope) {
        AndroidNewsScope.All -> navigation.projection?.unreadTotal
        AndroidNewsScope.Starred -> navigation.projection?.starredTotal
        is AndroidNewsScope.Category -> navigation.projection?.categoryCounts?.firstOrNull { it.id == scope.id }?.count
        is AndroidNewsScope.Feed -> navigation.projection?.feedCounts?.firstOrNull { it.id == scope.id }?.count
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(scopeTitle(scope), style = MaterialTheme.typography.titleLarge)
        if (count != null && count > 0u) {
            Text(
                if (count > 999u) "999+" else count.toString(),
                modifier = Modifier.padding(start = 8.dp),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun scopeTitle(scope: AndroidNewsScope): String = when (scope) {
    AndroidNewsScope.All -> "All News"
    AndroidNewsScope.Starred -> "Starred"
    is AndroidNewsScope.Category -> scope.title
    is AndroidNewsScope.Feed -> scope.title
}

/** E3 replaces this content while retaining the finalized E2 navigation shell and scope model. */
@Composable
private fun NewsTimelinePlaceholder(
    scope: AndroidNewsScope,
    navigation: NewsNavigationModel,
    state: AndroidAccountBootstrap.State.Ready,
) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(scopeTitle(scope), style = MaterialTheme.typography.headlineLarge)
            Text("Native article timeline arrives in E3", style = MaterialTheme.typography.titleMedium)
            navigation.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error)
            }
            Text(state.serverUrl, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SecondaryPlaceholder(title: String, message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, style = MaterialTheme.typography.headlineMedium)
            Text(
                message,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    bootstrap: AndroidAccountBootstrap,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text("‹ News") }
                },
            )
        },
    ) { padding ->
        SettingsShell(
            bootstrap = bootstrap,
            onAccountChanged = onAccountChanged,
            modifier = Modifier.fillMaxSize().padding(padding),
        )
    }
}
