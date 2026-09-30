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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val bootstrap = (application as FluxApplication).accountBootstrap
        setContent {
            FluxNewsTheme {
                FluxNewsApp(bootstrap)
            }
        }
    }
}

@Composable
private fun FluxNewsApp(bootstrap: AndroidAccountBootstrap) {
    var bootstrapState by remember { mutableStateOf(bootstrap.state) }
    var retryGeneration by remember { mutableStateOf(0) }
    LaunchedEffect(bootstrap, retryGeneration) {
        bootstrapState = bootstrap.restoreStoredAccount()
    }

    Surface(modifier = Modifier.fillMaxSize()) {
        when (val state = bootstrapState) {
            AndroidAccountBootstrap.State.Starting -> StartupProgress()
            AndroidAccountBootstrap.State.AccountRequired -> AccountConfigurationScreen(
                bootstrap = bootstrap,
                allowsRemoval = false,
                onAccountActivated = { bootstrapState = it },
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
                onAccountActivated = { bootstrapState = it },
            )
            is AndroidAccountBootstrap.State.Ready -> ReadyPlaceholder(
                state = state,
                bootstrap = bootstrap,
                onAccountChanged = { bootstrapState = it },
            )
        }
    }
}

@Composable
private fun StartupProgress() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
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

/** Temporary E2 shell destination. E3 replaces the content with the native article timeline. */
@Composable
private fun ReadyPlaceholder(
    state: AndroidAccountBootstrap.State.Ready,
    bootstrap: AndroidAccountBootstrap,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
) {
    var accountOpen by remember { mutableStateOf(false) }
    if (accountOpen) {
        AccountConfigurationScreen(
            bootstrap = bootstrap,
            allowsRemoval = true,
            onAccountActivated = { onAccountChanged(it) },
            onAccountRemoved = {
                accountOpen = false
                onAccountChanged(AndroidAccountBootstrap.State.AccountRequired)
            },
            modifier = Modifier.fillMaxSize(),
        )
        return
    }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.widthIn(max = 680.dp).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("FluxNews", style = MaterialTheme.typography.headlineLarge)
            Text("Account session ready", style = MaterialTheme.typography.titleMedium)
            Text(state.serverUrl, color = MaterialTheme.colorScheme.onSurfaceVariant)
            state.serverVersion?.let { Text("Miniflux $it", color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = { accountOpen = true }) { Text("Account") }
        }
    }
}
