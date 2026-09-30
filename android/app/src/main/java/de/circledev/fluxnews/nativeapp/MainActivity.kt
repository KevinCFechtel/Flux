package de.circledev.fluxnews.nativeapp

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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val application = application as FluxApplication
        val bootstrap = application.accountBootstrap
        val coreRuntime = application.coreRuntime
        val syncCoordinator = application.syncCoordinator
        val navigationPreferences = application.navigationPreferences
        val articlePreferences = application.articlePreferences
        setContent {
            FluxNewsTheme {
                CompositionLocalProvider(LocalAndroidArticlePreferences provides articlePreferences) {
                    FluxNewsApp(bootstrap, coreRuntime, syncCoordinator, navigationPreferences)
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
    navigationPreferences: AndroidNavigationPreferences,
) {
    var bootstrapState by remember { mutableStateOf(bootstrap.state) }
    var retryGeneration by remember { mutableStateOf(0) }
    LaunchedEffect(bootstrap, retryGeneration) {
        bootstrapState = bootstrap.restoreStoredAccount()
    }
    val readyState = bootstrapState as? AndroidAccountBootstrap.State.Ready
    LaunchedEffect(readyState?.serverUrl) {
        if (readyState != null) {
            syncCoordinator.requestSync(SyncReason.APP_START)
        }
    }

    fun acceptActivatedAccount(ready: AndroidAccountBootstrap.State.Ready) {
        bootstrapState = ready
        // Explicitly request a fresh run even when replacement kept the same canonical server URL.
        // The coordinator deduplicates this with the readiness effect for first-time activation.
        syncCoordinator.requestSync(SyncReason.APP_START)
    }

    Surface(modifier = Modifier.fillMaxSize()) {
        when (val state = bootstrapState) {
            AndroidAccountBootstrap.State.Starting -> StartupProgress()
            AndroidAccountBootstrap.State.AccountRequired -> AccountConfigurationScreen(
                bootstrap = bootstrap,
                allowsRemoval = false,
                onAccountActivated = ::acceptActivatedAccount,
                onAccountRemoved = { bootstrapState = AndroidAccountBootstrap.State.AccountRequired },
                modifier = Modifier.fillMaxSize(),
            )
            is AndroidAccountBootstrap.State.RecoverableError -> RecoverableStartup(
                message = state.message,
                bootstrap = bootstrap,
                onRetry = {
                    bootstrapState = AndroidAccountBootstrap.State.Starting
                    retryGeneration += 1
                },
                onAccountActivated = ::acceptActivatedAccount,
            )
            is AndroidAccountBootstrap.State.Ready -> AdaptiveAppShell(
                bootstrap = bootstrap,
                coreRuntime = coreRuntime,
                navigationPreferences = navigationPreferences,
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

@Composable
private fun StartupProgress() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            CircularProgressIndicator()
            Text("Starting FluxNews…", style = MaterialTheme.typography.bodyLarge)
        }
    }
}

@Composable
private fun RecoverableStartup(
    message: String,
    bootstrap: AndroidAccountBootstrap,
    onRetry: () -> Unit,
    onAccountActivated: (AndroidAccountBootstrap.State.Ready) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("FluxNews could not start", style = MaterialTheme.typography.headlineSmall)
            Text(message, color = MaterialTheme.colorScheme.error)
            Button(onClick = onRetry) { Text("Retry") }
        }
        AccountConfigurationScreen(
            bootstrap = bootstrap,
            allowsRemoval = false,
            onAccountActivated = onAccountActivated,
            onAccountRemoved = {},
            modifier = Modifier.weight(1f),
        )
    }
}
