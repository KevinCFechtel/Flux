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
    navigationPreferences: AndroidNavigationPreferences,
    state: AndroidAccountBootstrap.State.Ready,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    val navController = rememberNavController()
    val timelineStore = remember(coreRuntime) { AndroidArticleTimelineStore(coreRuntime) }
    val sessionGeneration by coreRuntime.sessionGeneration.collectAsState()
    var selectedScope by remember { mutableStateOf<AndroidNewsScope>(AndroidNewsScope.All) }
    var navigation by remember { mutableStateOf(NewsNavigationModel()) }
    var preferenceState by remember { mutableStateOf<AndroidNavigationPreferenceState?>(null) }
    var startupScopeApplied by remember { mutableStateOf(false) }
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
                selectedScope = AndroidNavigationPolicy.resolveStartupScope(
                    preferences = preferences,
                    categories = projection.catalog.categories.map {
                        AndroidNavigationCategoryRef(it.id, it.title)
                    },
                    feeds = projection.catalog.feeds.map {
                        AndroidNavigationFeedRef(it.id, it.categoryId, it.title)
                    },
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
                scope = selectedScope,
                navigation = navigation,
                preferences = currentPreferences,
                state = state,
                timelineStore = timelineStore,
                sessionGeneration = sessionGeneration,
                navController = navController,
                onScopeSelected = { selectedScope = it },
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
    scope: AndroidNewsScope,
    navigation: NewsNavigationModel,
    preferences: AndroidNavigationPreferenceState,
    state: AndroidAccountBootstrap.State.Ready,
    timelineStore: AndroidArticleTimelineStore,
    sessionGeneration: Long?,
    navController: NavHostController,
    onScopeSelected: (AndroidNewsScope) -> Unit,
) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
        val persistentNewsNavigation = maxWidth >= 600.dp && maxHeight >= 600.dp
        val compactLandscape = !persistentNewsNavigation && maxWidth > maxHeight

        if (persistentNewsNavigation) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(modifier = Modifier.width(320.dp)) {
                        NewsNavigationContent(
                            navigation = navigation,
                            preferences = preferences,
                            selectedScope = scope,
                            onScopeSelected = onScopeSelected,
                            onSearch = { navController.navigate(ShellRoute.Search) },
                            onListeningList = { navController.navigate(ShellRoute.ListeningList) },
                            onSettings = { navController.navigate(ShellRoute.Settings) },
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
                    persistentNavigation = true,
                    scopeTitleLeading = false,
                    onOpenNavigation = {},
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
                    ModalDrawerSheet(modifier = Modifier.width(modalDrawerWidth)) {
                        NewsNavigationContent(
                            navigation = navigation,
                            preferences = preferences,
                            selectedScope = scope,
                            onScopeSelected = {
                                onScopeSelected(it)
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
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewsRootContent(
    scope: AndroidNewsScope,
    navigation: NewsNavigationModel,
    state: AndroidAccountBootstrap.State.Ready,
    timelineStore: AndroidArticleTimelineStore,
    sessionGeneration: Long?,
    persistentNavigation: Boolean,
    scopeTitleLeading: Boolean,
    onOpenNavigation: () -> Unit,
) {
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
                        colors = appBarColors,
                    )
                }
            }
        },
    ) { padding ->
        AndroidArticleTimeline(
            store = timelineStore,
            selection = AndroidArticleTimelineSelection(scope = scope),
            sessionGeneration = sessionGeneration,
            accountKey = state.serverUrl,
            topContentPadding = padding.calculateTopPadding(),
            modifier = Modifier
                .fillMaxSize()
                .padding(
                    start = padding.calculateStartPadding(layoutDirection),
                    end = padding.calculateEndPadding(layoutDirection),
                    bottom = padding.calculateBottomPadding(),
                ),
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
    val opacities = if (isSystemInDarkTheme()) {
        listOf(0.90f, 0.70f, 0.55f, 0.45f, 0.25f, 0.15f, 0f)
    } else {
        listOf(0.90f, 0.62f, 0.46f, 0.36f, 0.20f, 0.12f, 0f)
    }
    val stops = listOf(0f, 0.16f, 0.34f, 0.51f, 0.68f, 0.84f, 1f)
    val colorStops = stops
        .zip(opacities)
        .map { (stop, opacity) -> stop to background.copy(alpha = opacity) }
        .toTypedArray()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(statusBarHeight + 81.dp)
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
    selectedScope: AndroidNewsScope,
    onScopeSelected: (AndroidNewsScope) -> Unit,
    onSearch: () -> Unit,
    onListeningList: () -> Unit,
    onSettings: () -> Unit,
) {
    val projection = navigation.projection
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

    LaunchedEffect(selectedScope, projection) {
        if (selectedScope is AndroidNewsScope.Feed) {
            expandedCategories = expandedCategories + selectedScope.categoryId
        }
    }

    Column(
        modifier = Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
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
            label = { DrawerLabel("All News", projection?.unreadTotal ?: 0uL) },
            selected = selectedScope == AndroidNewsScope.All,
            onClick = { onScopeSelected(AndroidNewsScope.All) },
            icon = { DrawerIcon(R.drawable.ic_news, "All News") },
        )
        NavigationDrawerItem(
            label = { DrawerLabel("Starred", projection?.starredTotal ?: 0uL) },
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
                                    title = feed.title,
                                    count = feedCounts[feed.id] ?: 0uL,
                                    selected = selectedScope == feedScope,
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
                        title = feed.title,
                        count = feedCounts[feed.id] ?: 0uL,
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
private fun FeedNavigationRow(title: String, count: ULong, selected: Boolean, onClick: () -> Unit) {
    NavigationDrawerItem(
        label = { DrawerLabel(title, count) },
        selected = selected,
        onClick = onClick,
        icon = { Text("•", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.primary) },
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
    Surface(
        onClick = onOpenNavigation,
        enabled = opensNavigation,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.84f),
        contentColor = MaterialTheme.colorScheme.onSurface,
        tonalElevation = 0.dp,
        shadowElevation = 1.dp,
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
