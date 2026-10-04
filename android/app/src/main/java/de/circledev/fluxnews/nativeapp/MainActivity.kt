package de.circledev.fluxnews.nativeapp

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.Text
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import uniffi.flux_uniffi.SyncReason

class MainActivity : ComponentActivity() {
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as FluxApplication).systemNotifications.routeIntent(intent)
    }

    private companion object {
        const val BASELINE_PROFILE_TIMELINE_EXTRA = "flux.baselineProfile.timeline"
    }
    private fun isBaselineProfileTimelineLaunch(): Boolean =
        BuildConfig.BUILD_TYPE == "nonMinifiedRelease" &&
            intent?.getBooleanExtra(BASELINE_PROFILE_TIMELINE_EXTRA, false) == true

    override fun onResume() {
        super.onResume()
        if (!isBaselineProfileTimelineLaunch()) {
            (application as FluxApplication).backgroundSync.requestResumeIfNeeded()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (isBaselineProfileTimelineLaunch()) {
            setContent {
                FluxNewsTheme {
                    BaselineProfileTimelineFixture()
                }
            }
            return
        }

        val application = application as FluxApplication
        application.systemNotifications.routeIntent(intent)
        val bootstrap = application.accountBootstrap
        val coreRuntime = application.coreRuntime
        val syncCoordinator = application.syncCoordinator
        val timelineStore = application.timelineStore
        val searchStore = application.searchStore
        val readerStore = application.readerStore
        val articleOpenResolver = application.articleOpenResolver
        val navigationPreferences = application.navigationPreferences
        val articlePreferences = application.articlePreferences
        val actionBarPreferences = application.actionBarPreferences
        val configurationBackup = application.configurationBackup
        val widgetProjection = application.widgetProjection
        setContent {
            FluxNewsTheme {
                val coreArticleSettings = remember(coreRuntime) { AndroidCoreArticleSettings(coreRuntime) }
                val mediaSettings = remember(coreRuntime) { AndroidMediaSettings(coreRuntime) }
                val downloadedData = remember(coreRuntime) { AndroidDownloadedData(coreRuntime) }
                val backgroundSync = application.backgroundSync
                val systemNotifications = application.systemNotifications
                CompositionLocalProvider(
                    LocalAndroidArticlePreferences provides articlePreferences,
                    LocalAndroidActionBarPreferences provides actionBarPreferences,
                    LocalAndroidCoreArticleSettings provides coreArticleSettings,
                    LocalAndroidMediaSettings provides mediaSettings,
                    LocalAndroidDownloadedData provides downloadedData,
                    LocalAndroidBackgroundSync provides backgroundSync,
                    LocalAndroidSystemNotifications provides systemNotifications,
                    LocalAndroidConfigurationBackup provides configurationBackup,
                ) {
                    FluxNewsApp(
                        bootstrap,
                        coreRuntime,
                        syncCoordinator,
                        timelineStore,
                        searchStore,
                        readerStore,
                        articleOpenResolver,
                        navigationPreferences,
                        backgroundSync,
                        systemNotifications,
                        widgetProjection,
                    )
                }
            }
        }
    }
}

@Composable
private fun FluxNewsApp(
    bootstrap: AndroidAccountBootstrap,
    coreRuntime: AndroidCoreRuntime,
    syncCoordinator: AndroidSyncCoordinator,
    timelineStore: AndroidArticleTimelineStore,
    searchStore: AndroidSearchStore,
    readerStore: AndroidReaderStore,
    articleOpenResolver: AndroidArticleOpenResolver,
    navigationPreferences: AndroidNavigationPreferences,
    backgroundSync: AndroidBackgroundSync,
    systemNotifications: AndroidSystemNotificationManager,
    widgetProjection: AndroidWidgetProjectionCoordinator,
) {
    var bootstrapState by remember { mutableStateOf(bootstrap.state) }; var retryGeneration by remember { mutableStateOf(0) }; var showingRestore by remember { mutableStateOf(false) }
    LaunchedEffect(bootstrap, retryGeneration) { bootstrapState = bootstrap.restoreStoredAccount() }
    val readyState = bootstrapState as? AndroidAccountBootstrap.State.Ready
    LaunchedEffect(readyState?.serverUrl) { if (readyState != null) backgroundSync.reconcileFromCore() }
    fun acceptActivatedAccount(ready: AndroidAccountBootstrap.State.Ready) { bootstrapState = ready; syncCoordinator.requestSync(SyncReason.APP_START) }
    Surface(modifier = Modifier.fillMaxSize()) {
        when (val state = bootstrapState) {
            AndroidAccountBootstrap.State.Starting -> StartupProgress()
            AndroidAccountBootstrap.State.AccountRequired -> if (showingRestore) {
                StandaloneStartupSurface(title = "Restore Configuration") { contentModifier ->
                    ConfigurationBackupScreen(
                        LocalAndroidConfigurationBackup.current,
                        { showingRestore = false; (bootstrap.state as? AndroidAccountBootstrap.State.Ready)?.let(::acceptActivatedAccount) },
                        contentModifier,
                        allowExport = false,
                        onDismiss = { showingRestore = false },
                    )
                }
            } else {
                StandaloneStartupSurface(title = "Set Up FluxNews") { contentModifier ->
                    AccountConfigurationScreen(
                        bootstrap,
                        false,
                        ::acceptActivatedAccount,
                        { bootstrapState = AndroidAccountBootstrap.State.AccountRequired },
                        { showingRestore = true },
                        contentModifier,
                        showTitle = false,
                    )
                }
            }
            is AndroidAccountBootstrap.State.RecoverableError -> RecoverableStartup(state.message, bootstrap, { bootstrapState = AndroidAccountBootstrap.State.Starting; retryGeneration += 1 }, ::acceptActivatedAccount)
            is AndroidAccountBootstrap.State.Ready -> AdaptiveAppShell(
                bootstrap = bootstrap,
                coreRuntime = coreRuntime,
                syncCoordinator = syncCoordinator,
                timelineStore = timelineStore,
                searchStore = searchStore,
                readerStore = readerStore,
                articleOpenResolver = articleOpenResolver,
                navigationPreferences = navigationPreferences,
                systemNotifications = systemNotifications,
                widgetProjection = widgetProjection,
                state = state,
                onAccountChanged = { changedState ->
                    bootstrapState = changedState
                    if (changedState is AndroidAccountBootstrap.State.Ready) {
                        syncCoordinator.requestSync(SyncReason.APP_START)
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable private fun StartupProgress() { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) { CircularProgressIndicator(); Text("Starting FluxNews…", style = MaterialTheme.typography.bodyLarge) } } }
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StandaloneStartupSurface(
    title: String,
    content: @Composable (Modifier) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
            )
        },
    ) { padding ->
        AndroidCenteredContent(
            maxWidth = AndroidFormContentMaxWidth,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            content = content,
        )
    }
}

@Composable
private fun RecoverableStartup(
    message: String,
    bootstrap: AndroidAccountBootstrap,
    onRetry: () -> Unit,
    onAccountActivated: (AndroidAccountBootstrap.State.Ready) -> Unit,
) {
    StandaloneStartupSurface(title = "FluxNews could not start") { contentModifier ->
        Column(modifier = contentModifier) {
            Column(
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(message, color = MaterialTheme.colorScheme.error)
                Button(onClick = onRetry) { Text("Retry") }
            }
            AccountConfigurationScreen(
                bootstrap,
                false,
                onAccountActivated,
                {},
                modifier = Modifier.weight(1f),
                showTitle = false,
            )
        }
    }
}
