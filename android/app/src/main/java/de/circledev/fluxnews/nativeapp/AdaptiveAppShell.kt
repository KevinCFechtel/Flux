package de.circledev.fluxnews.nativeapp

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.NavigationCountMode
import uniffi.flux_uniffi.NavigationProjection

private object ShellRoute {
    const val Timeline = "timeline"
    const val Search = "search"
    const val ListeningList = "listening-list"
    const val Settings = "settings"
}

private data class NewsNavigationModel(
    val projection: NavigationProjection? = null,
    val error: String? = null,
)

/**
 * The timeline is the app root. Scope selection stays inside its transient/permanent news drawer;
 * Search, Listening List and Settings are real secondary Navigation Compose destinations.
 */
@Composable
internal fun AdaptiveAppShell(
    bootstrap: AndroidAccountBootstrap,
    coreRuntime: AndroidCoreRuntime,
    timelineStore: AndroidArticleTimelineStore,
    navigationPreferences: AndroidNavigationPreferences,
    state: AndroidAccountBootstrap.State.Ready,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    val navController = rememberNavController()
    val sessionGeneration by coreRuntime.sessionGeneration.collectAsState()
    val retainedTimelineSelection = timelineStore.retainedSelectionForSession(sessionGeneration)
    var timelineSelection by remember(timelineStore, sessionGeneration) {
        mutableStateOf(
            retainedTimelineSelection ?: AndroidArticleTimelineSelection(scope = AndroidNewsScope.All),
        )
    }
    var navigation by remember { mutableStateOf(NewsNavigationModel()) }
    var preferenceState by remember { mutableStateOf<AndroidNavigationPreferenceState?>(null) }
    var startupScopeApplied by remember(timelineStore, sessionGeneration) {
        mutableStateOf(retainedTimelineSelection != null)
    }
    val navigationRefreshes = remember { Channel<Unit>(capacity = Channel.CONFLATED) }

    suspend fun reloadNavigation() {
        navigation = try {
            NewsNavigationModel(
                projection = coreRuntime.local { core -> core.navigationProjection(NavigationCountMode.UNREAD) },
            )
        } catch (_: Exception) {
            NewsNavigationModel(error = "Navigation data could not be loaded.")
        }
    }

    LaunchedEffect(coreRuntime, timelineStore) {
        coreRuntime.events.collect { runtimeEvent ->
            timelineStore.handleCoreEvent(runtimeEvent)
            if (runtimeEvent.event.requiresNavigationRefresh()) {
                navigationRefreshes.trySend(Unit)
            }
        }
    }
    LaunchedEffect(coreRuntime, navigationRefreshes) {
        reloadNavigation()
        for (ignored in navigationRefreshes) {
            reloadNavigation()
        }
    }
    LaunchedEffect(navigationPreferences) {
        navigationPreferences.state.collect { preferenceState = it }
    }
    LaunchedEffect(preferenceState, navigation.projection) {
        if (!startupScopeApplied) {
            val preferences = preferenceState
            val projection = navigation.projection
            if (preferences != null && projection != null) {
                timelineSelection = timelineSelection.selectingScope(
                    AndroidNavigationPolicy.resolveStartupScope(
                        preferences = preferences,
                        categories = projection.catalog.categories.map {
                            AndroidNavigationCategoryRef(it.id, it.title)
                        },
                        feeds = projection.catalog.feeds.map {
                            AndroidNavigationFeedRef(it.id, it.categoryId, it.title)
                        },
                    ),
                )
                startupScopeApplied = true
            }
        }
    }

    val currentPreferences = preferenceState ?: AndroidNavigationPreferenceState()
    val categories = navigation.projection?.catalog?.categories?.map {
        AndroidNavigationCategoryRef(it.id, it.title)
    }.orEmpty()
    val feeds = navigation.projection?.catalog?.feeds?.map {
        AndroidNavigationFeedRef(it.id, it.categoryId, it.title)
    }.orEmpty()

    NavHost(
        navController = navController,
        startDestination = ShellRoute.Timeline,
        modifier = modifier,
        enterTransition = { forwardEnterTransition() },
        exitTransition = { forwardExitTransition() },
        popEnterTransition = { backEnterTransition() },
        popExitTransition = { backExitTransition() },
    ) {
        composable(ShellRoute.Timeline) {
            TimelineDestination(
                selection = timelineSelection,
                navigation = navigation,
                preferences = currentPreferences,
                state = state,
                timelineStore = timelineStore,
                sessionGeneration = sessionGeneration,
                navController = navController,
                onSelectionChanged = { timelineSelection = it },
            )
        }
        composable(ShellRoute.Search) {
            SecondaryDestination(
                title = "Search",
                message = "Native article search is connected to this destination in E4.",
                onBack = navController::popBackStack,
            )
        }
        composable(ShellRoute.ListeningList) {
            SecondaryDestination(
                title = "Listening List",
                message = "Native media presentation is connected to this destination in the media phase.",
                onBack = navController::popBackStack,
            )
        }
        composable(ShellRoute.Settings) {
            SettingsDestination(
                bootstrap = bootstrap,
                navigationPreferences = navigationPreferences,
                navigationPreferenceState = currentPreferences,
                navigationCategories = categories,
                navigationFeeds = feeds,
                onAccountChanged = onAccountChanged,
                onBack = navController::popBackStack,
            )
        }
    }
}

private fun CoreEvent.requiresNavigationRefresh(): Boolean = when (this) {
    is CoreEvent.ArticleReadStateChanged,
    is CoreEvent.ArticleStarredStateChanged,
    -> true
    is CoreEvent.SyncDidComplete -> metadata.navigationChanged || metadata.dataChanged
    else -> false
}

private fun forwardEnterTransition(): EnterTransition =
    slideInHorizontally(animationSpec = tween(260), initialOffsetX = { it / 5 }) + fadeIn(animationSpec = tween(220))

private fun forwardExitTransition(): ExitTransition =
    slideOutHorizontally(animationSpec = tween(260), targetOffsetX = { -it / 12 }) + fadeOut(animationSpec = tween(180))

private fun backEnterTransition(): EnterTransition =
    slideInHorizontally(animationSpec = tween(240), initialOffsetX = { -it / 12 }) + fadeIn(animationSpec = tween(200))

private fun backExitTransition(): ExitTransition =
    slideOutHorizontally(animationSpec = tween(240), targetOffsetX = { it / 5 }) + fadeOut(animationSpec = tween(180))

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimelineDestination(
    selection: AndroidArticleTimelineSelection,
    navigation: NewsNavigationModel,
    preferences: AndroidNavigationPreferenceState,
    state: AndroidAccountBootstrap.State.Ready,
    timelineStore: AndroidArticleTimelineStore,
    sessionGeneration: Long?,
    navController: NavHostController,
    onSelectionChanged: (AndroidArticleTimelineSelection) -> Unit,
) {
    val scope = selection.scope
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
        val persistentNewsNavigation = maxWidth >= 600.dp && maxHeight >= 600.dp
        val compactLandscape = !persistentNewsNavigation && maxWidth > maxHeight

        if (persistentNewsNavigation) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        modifier = Modifier.width(320.dp),
                        drawerContainerColor = MaterialTheme.colorScheme.background,
                        drawerTonalElevation = 0.dp,
                    ) {
                        NewsNavigationContent(
                            navigation = navigation,
                            preferences = preferences,
                            timelineStore = timelineStore,
                            selectedScope = scope,
                            onScopeSelected = { onSelectionChanged(selection.selectingScope(it)) },
                            onSearch = { navController.navigate(ShellRoute.Search) },
                            onListeningList = { navController.navigate(ShellRoute.ListeningList) },
                            onSettings = { navController.navigate(ShellRoute.Settings) },
                        )
                    }
                },
            ) {
                NewsRootContent(
                    selection = selection,
                    navigation = navigation,
                    state = state,
                    timelineStore = timelineStore,
                    sessionGeneration = sessionGeneration,
                    persistentNavigation = true,
                    scopeTitleLeading = false,
                    onOpenNavigation = {},
                    onSelectionChanged = onSelectionChanged,
                )
            }
        } else {
            val drawerState = rememberDrawerState(DrawerValue.Closed)
            val coroutineScope = rememberCoroutineScope()
            fun navigateAfterDrawerCloses(route: String) {
                coroutineScope.launch {
                    drawerState.close()
                    navController.navigate(route)
                }
            }
            val modalDrawerWidth = minOf(maxWidth * 0.85f, 360.dp)
            ModalNavigationDrawer(
                drawerState = drawerState,
                drawerContent = {
                    ModalDrawerSheet(
                        modifier = Modifier.width(modalDrawerWidth),
                        drawerContainerColor = MaterialTheme.colorScheme.background,
                        drawerTonalElevation = 0.dp,
                    ) {
                        NewsNavigationContent(
                            navigation = navigation,
                            preferences = preferences,
                            timelineStore = timelineStore,
                            selectedScope = scope,
                            onScopeSelected = {
                                onSelectionChanged(selection.selectingScope(it))
                                coroutineScope.launch { drawerState.close() }
                            },
                            onSearch = { navigateAfterDrawerCloses(ShellRoute.Search) },
                            onListeningList = { navigateAfterDrawerCloses(ShellRoute.ListeningList) },
                            onSettings = { navigateAfterDrawerCloses(ShellRoute.Settings) },
                        )
                    }
                },
            ) {
                NewsRootContent(
                    scope = scope,
                    navigation = navigation,
                    state = state,
                    timelineStore = timelineStore,
                    sessionGeneration = sessionGeneration,
                    persistentNavigation = false,
                    scopeTitleLeading = compactLandscape,
                    onOpenNavigation = { coroutineScope.launch { drawerState.open() } },
                    onSelectionChanged = onSelectionChanged,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewsRootContent(
    selection: AndroidArticleTimelineSelection,
    navigation: NewsNavigationModel,
    state: AndroidAccountBootstrap.State.Ready,
    timelineStore: AndroidArticleTimelineStore,
    sessionGeneration: Long?,
    persistentNavigation: Boolean,
    scopeTitleLeading: Boolean,
    onOpenNavigation: () -> Unit,
    onSelectionChanged: (AndroidArticleTimelineSelection) -> Unit,
) {
    val scope = selection.scope
    val timelineState by timelineStore.state.collectAsState()
    val articlePreferences by LocalAndroidArticlePreferences.current.state.collectAsState(
        initial = AndroidArticlePreferenceState(),
    )
    val timelineCount = timelineState.total.takeIf { timelineState.selection?.scope == scope }

    val layoutDirection = LocalLayoutDirection.current
    val appBarColors = TopAppBarDefaults.topAppBarColors(
        containerColor = Color.Transparent,
        scrolledContainerColor = Color.Transparent,
    )
    Box(Modifier.fillMaxSize()) {
        Scaffold(
            contentWindowInsets = WindowInsets(0, 0, 0, 0),
            topBar = {
                Box(Modifier.fillMaxWidth()) {
                    FloatingChromeTopGradient(
                        modifier = Modifier.align(Alignment.TopCenter),
                    )
                    if (scopeTitleLeading) {
                        TopAppBar(
                    title = {
                        ScopeNavigationCapsule(
                            scope = scope,
                            showArticleCount = articlePreferences.showArticleCount,
                            timelineCount = timelineCount,
                            readFilter = timelineState.selection?.readFilter,
                            opensNavigation = !persistentNavigation,
                            onOpenNavigation = onOpenNavigation,
                        )
                    },
                    actions = {
                        ArticleListPresentationControls(
                            selection = selection,
                            onSelectionChanged = onSelectionChanged,
                        )
                    },
                    colors = appBarColors,
                )
            } else {
                CenterAlignedTopAppBar(
                    title = {
                        ScopeNavigationCapsule(
                            scope = scope,
                            showArticleCount = articlePreferences.showArticleCount,
                            timelineCount = timelineCount,
                            readFilter = timelineState.selection?.readFilter,
                            opensNavigation = !persistentNavigation,
                            onOpenNavigation = onOpenNavigation,
                        )
                    },
                    actions = {
                        ArticleListPresentationControls(
                            selection = selection,
                            onSelectionChanged = onSelectionChanged,
                        )
                    },
                    colors = appBarColors,
                )
                }
            }
        },
    ) { padding ->
        AndroidArticleTimeline(
            store = timelineStore,
            selection = selection,
            sessionGeneration = sessionGeneration,
            accountKey = state.serverUrl,
            topContentPadding = padding.calculateTopPadding(),
            modifier = Modifier
                .fillMaxSize()
                .padding(
                    start = padding.calculateStartPadding(layoutDirection),
                    end = padding.calculateEndPadding(layoutDirection),
                ),
        )
    }
    }
}

@Composable
private fun ArticleListPresentationControls(
    selection: AndroidArticleTimelineSelection,
    onSelectionChanged: (AndroidArticleTimelineSelection) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }) {
            Text(
                when (selection.readFilter) {
                    AndroidArticleReadFilter.Unread -> "Unread"
                    AndroidArticleReadFilter.All -> "All"
                },
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = {
                    Text(
                        if (selection.readFilter == AndroidArticleReadFilter.Unread) {
                            "Show all articles"
                        } else {
                            "Show unread only"
                        },
                    )
                },
                onClick = {
                    expanded = false
                    onSelectionChanged(selection.togglingReadFilter())
                },
            )
            DropdownMenuItem(
                text = {
                    Text(
                        when (selection.sort) {
                            AndroidArticleSortOrder.OldestFirst -> "Newest first"
                            AndroidArticleSortOrder.NewestFirst -> "Oldest first"
                        },
                    )
                },
                onClick = {
                    expanded = false
                    onSelectionChanged(selection.togglingSortOrder())
                },
            )
        }
    }
}

@Composable
private fun FloatingChromeTopGradient(
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val statusBarHeight = with(density) {
        WindowInsets.statusBars.getTop(this).toDp()
    }
    val background = MaterialTheme.colorScheme.background
    val totalHeight = statusBarHeight + 81.dp
    val opacities = if (isSystemInDarkTheme()) {
        listOf(0.96f, 0.94f, 0.88f, 0.74f, 0.50f, 0.25f, 0.10f, 0f)
    } else {
        listOf(0.96f, 0.91f, 0.84f, 0.68f, 0.44f, 0.20f, 0.08f, 0f)
    }
    val stopOffsets = listOf(
        0.dp,
        (statusBarHeight.value * 0.5f).dp,
        statusBarHeight,
        statusBarHeight + 10.dp,
        statusBarHeight + 28.dp,
        statusBarHeight + 52.dp,
        statusBarHeight + 68.dp,
        totalHeight,
    )
    val colorStops = stopOffsets
        .zip(opacities)
        .map { (offset, opacity) ->
            (offset.value / totalHeight.value).coerceIn(0f, 1f) to background.copy(alpha = opacity)
        }
        .toTypedArray()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(totalHeight)
            .background(
                Brush.verticalGradient(
                    colorStops = colorStops,
                ),
            ),
    )
}

@Composable
private fun NewsNavigationContent(
    navigation: NewsNavigationModel,
    preferences: AndroidNavigationPreferenceState,
    timelineStore: AndroidArticleTimelineStore,
    selectedScope: AndroidNewsScope,
    onScopeSelected: (AndroidNewsScope) -> Unit,
    onSearch: () -> Unit,
    onListeningList: () -> Unit,
    onSettings: () -> Unit,
) {
    val projection = navigation.projection
    val timelineState by timelineStore.state.collectAsState()
    val feedIconVariant = if (isSystemInDarkTheme()) {
        uniffi.flux_uniffi.FeedIconVariant.DARK
    } else {
        uniffi.flux_uniffi.FeedIconVariant.NORMAL
    }
    val feedCounts = projection?.feedCounts?.associate { it.id to it.count }.orEmpty()
    val categoryCounts = projection?.categoryCounts?.associate { it.id to it.count }.orEmpty()
    val categoryRefs = projection?.catalog?.categories?.map { AndroidNavigationCategoryRef(it.id, it.title) }.orEmpty()
    val feedRefs = projection?.catalog?.feeds?.map { AndroidNavigationFeedRef(it.id, it.categoryId, it.title) }.orEmpty()
    val visibleFeedIds = AndroidNavigationPolicy.visibleFeedIds(
        preferences.hideEmptyNavigationEntries,
        feedRefs,
        feedCounts,
    )
    val visibleCategoryIds = if (preferences.hideEmptyNavigationEntries) {
        AndroidNavigationPolicy.visibleCategoryIds(categoryRefs, feedRefs, visibleFeedIds)
    } else {
        categoryRefs.mapTo(mutableSetOf()) { it.id }
    }
    var expandedCategories by remember { mutableStateOf(setOf<Long>()) }
    val darkMode = isSystemInDarkTheme()
    val selectedDrawerContainer = if (darkMode) {
        MaterialTheme.colorScheme.background
    } else {
        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.42f)
    }
    val drawerItemColors = NavigationDrawerItemDefaults.colors(
        selectedContainerColor = selectedDrawerContainer,
        unselectedContainerColor = MaterialTheme.colorScheme.background,
        selectedIconColor = MaterialTheme.colorScheme.primary,
        selectedTextColor = MaterialTheme.colorScheme.primary,
        unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
        unselectedTextColor = MaterialTheme.colorScheme.onSurface,
    )

    LaunchedEffect(selectedScope, projection) {
        if (selectedScope is AndroidNewsScope.Feed) {
            expandedCategories = expandedCategories + selectedScope.categoryId
        }
    }

    Column(
        modifier = Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_fluxnews_logo),
                contentDescription = null,
                modifier = Modifier.size(30.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
            Text(
                "FluxNews",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
        }
        Text(
            "News",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        NavigationDrawerItem(
            label = { DrawerLabel("All News", projection?.unreadTotal ?: 0uL) },
            selected = selectedScope == AndroidNewsScope.All,
            onClick = { onScopeSelected(AndroidNewsScope.All) },
            icon = { DrawerIcon(R.drawable.ic_news, "All News") },
            colors = drawerItemColors,
        )
        NavigationDrawerItem(
            label = { DrawerLabel("Starred", projection?.starredTotal ?: 0uL) },
            selected = selectedScope == AndroidNewsScope.Starred,
            onClick = { onScopeSelected(AndroidNewsScope.Starred) },
            icon = { DrawerIcon(R.drawable.ic_star, "Starred") },
            colors = drawerItemColors,
        )
        NavigationDrawerItem(
            label = { Text("Listening List") },
            selected = false,
            onClick = onListeningList,
            icon = { DrawerIcon(R.drawable.ic_headphones, "Listening List") },
            colors = drawerItemColors,
        )
        NavigationDrawerItem(
            label = { Text("Search") },
            selected = false,
            onClick = onSearch,
            icon = { DrawerIcon(R.drawable.ic_search, "Search") },
            colors = drawerItemColors,
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
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            projection.catalog.categories
                .filter { it.id in visibleCategoryIds }
                .forEach { category ->
                    val categoryScope = AndroidNewsScope.Category(category.id, category.title)
                    val expanded = category.id in expandedCategories
                    CategoryNavigationRow(
                        title = category.title,
                        count = categoryCounts[category.id] ?: 0uL,
                        selected = selectedScope == categoryScope,
                        containsSelectedFeed = selectedScope is AndroidNewsScope.Feed && selectedScope.categoryId == category.id,
                        expanded = expanded,
                        onToggleExpanded = {
                            expandedCategories = if (expanded) expandedCategories - category.id else expandedCategories + category.id
                        },
                        onSelected = { onScopeSelected(categoryScope) },
                    )
                    if (expanded) {
                        projection.catalog.feeds
                            .filter { it.categoryId == category.id && it.id in visibleFeedIds }
                            .forEach { feed ->
                                val feedScope = AndroidNewsScope.Feed(feed.id, feed.categoryId, feed.title)
                                FeedNavigationRow(
                                    feedId = feed.id,
                                    title = feed.title,
                                    count = feedCounts[feed.id] ?: 0uL,
                                    selected = selectedScope == feedScope,
                                    iconPng = timelineState.feedIconPngByFeedId[feed.id],
                                    iconVariant = feedIconVariant,
                                    onRequestFeedIcon = timelineStore::ensureFeedIcon,
                                    onClick = { onScopeSelected(feedScope) },
                                )
                            }
                    }
                }

            val knownCategoryIds = projection.catalog.categories.mapTo(mutableSetOf()) { it.id }
            projection.catalog.feeds
                .filter { it.categoryId !in knownCategoryIds && it.id in visibleFeedIds }
                .forEach { feed ->
                    val feedScope = AndroidNewsScope.Feed(feed.id, feed.categoryId, feed.title)
                    FeedNavigationRow(
                        feedId = feed.id,
                        title = feed.title,
                        count = feedCounts[feed.id] ?: 0uL,
                        selected = selectedScope == feedScope,
                        iconPng = timelineState.feedIconPngByFeedId[feed.id],
                        iconVariant = feedIconVariant,
                        onRequestFeedIcon = timelineStore::ensureFeedIcon,
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
            colors = drawerItemColors,
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
    val selectedContainer = if (selected && !isSystemInDarkTheme()) {
        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.42f)
    } else {
        MaterialTheme.colorScheme.background
    }
    Surface(
        color = selectedContainer,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onToggleExpanded) {
                Icon(
                    painterResource(if (expanded) R.drawable.ic_expand_more else R.drawable.ic_chevron_right),
                    if (expanded) "Collapse $title" else "Expand $title",
                )
            }
            Row(
                modifier = Modifier.weight(1f).clickable(onClick = onSelected).padding(end = 16.dp, top = 14.dp, bottom = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    painterResource(R.drawable.ic_folder),
                    null,
                    tint = if (selected || containsSelectedFeed) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    title,
                    modifier = Modifier.weight(1f).padding(start = 12.dp),
                    fontWeight = if (selected || containsSelectedFeed) FontWeight.Medium else FontWeight.Normal,
                    color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                )
                CountText(count)
            }
        }
    }
}

@Composable
private fun FeedNavigationRow(
    feedId: Long,
    title: String,
    count: ULong,
    selected: Boolean,
    iconPng: ByteArray?,
    iconVariant: uniffi.flux_uniffi.FeedIconVariant,
    onRequestFeedIcon: suspend (Long, uniffi.flux_uniffi.FeedIconVariant) -> Unit,
    onClick: () -> Unit,
) {
    val selectedContainer = if (selected && !isSystemInDarkTheme()) {
        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.42f)
    } else {
        MaterialTheme.colorScheme.background
    }
    Surface(
        color = selectedContainer,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.fillMaxWidth().padding(start = 32.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FeedIcon(
                feedId = feedId,
                title = title,
                pngData = iconPng,
                variant = iconVariant,
                onRequest = onRequestFeedIcon,
            )
            Text(
                title,
                modifier = Modifier.weight(1f).padding(start = 12.dp),
                fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            )
            CountText(count)
        }
    }
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
    Icon(painterResource(drawable), description)
}

@Composable
private fun ScopeNavigationCapsule(
    scope: AndroidNewsScope,
    showArticleCount: Boolean,
    timelineCount: ULong?,
    readFilter: AndroidArticleReadFilter?,
    opensNavigation: Boolean,
    onOpenNavigation: () -> Unit,
) {
    val darkMode = isSystemInDarkTheme()
    Surface(
        onClick = onOpenNavigation,
        enabled = opensNavigation,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.background.copy(
            alpha = if (darkMode) 0.70f else 0.85f,
        ),
        contentColor = MaterialTheme.colorScheme.onSurface,
        tonalElevation = 0.dp,
        shadowElevation = if (darkMode) 0.5.dp else 0.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_fluxnews_logo),
                contentDescription = null,
                modifier = Modifier.size(26.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
            Column {
                Text(
                    scopeTitle(scope),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                if (showArticleCount && timelineCount != null) {
                    Text(
                        scopeCountLabel(scope, readFilter, timelineCount),
                        maxLines = 1,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (opensNavigation) {
                Icon(
                    painter = painterResource(R.drawable.ic_expand_more),
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

private fun scopeCountLabel(
    scope: AndroidNewsScope,
    readFilter: AndroidArticleReadFilter?,
    count: ULong,
): String =
    if (readFilter == AndroidArticleReadFilter.Unread && scope != AndroidNewsScope.Starred) {
        "$count unread"
    } else {
        "$count " + if (count == 1uL) "article" else "articles"
    }

private fun scopeTitle(scope: AndroidNewsScope): String = when (scope) {
    AndroidNewsScope.All -> "All News"
    AndroidNewsScope.Starred -> "Starred"
    is AndroidNewsScope.Category -> scope.title
    is AndroidNewsScope.Feed -> scope.title
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SecondaryDestination(title: String, message: String, onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
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
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            Text(
                message,
                modifier = Modifier.padding(24.dp),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SettingsDestination(
    bootstrap: AndroidAccountBootstrap,
    navigationPreferences: AndroidNavigationPreferences,
    navigationPreferenceState: AndroidNavigationPreferenceState,
    navigationCategories: List<AndroidNavigationCategoryRef>,
    navigationFeeds: List<AndroidNavigationFeedRef>,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    onBack: () -> Unit,
) {
    SettingsShell(
        bootstrap = bootstrap,
        navigationPreferences = navigationPreferences,
        navigationPreferenceState = navigationPreferenceState,
        navigationCategories = navigationCategories,
        navigationFeeds = navigationFeeds,
        onAccountChanged = onAccountChanged,
        onBack = onBack,
        modifier = Modifier.fillMaxSize(),
    )
}
