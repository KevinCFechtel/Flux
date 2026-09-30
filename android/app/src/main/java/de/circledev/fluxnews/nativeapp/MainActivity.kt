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
        val application = application as FluxApplication
        val bootstrap = application.accountBootstrap
        val coreRuntime = application.coreRuntime
        setContent {
            FluxNewsTheme {
                FluxNewsApp(bootstrap, coreRuntime)
            }
        }
    }
}

@Composable
private fun FluxNewsApp(
    bootstrap: AndroidAccountBootstrap,
    coreRuntime: AndroidCoreRuntime,
) {
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
            is AndroidAccountBootstrap.State.Ready -> AdaptiveAppShell(
                bootstrap = bootstrap,
                coreRuntime = coreRuntime,
                state = state,
                onAccountChanged = { bootstrapState = it },
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
