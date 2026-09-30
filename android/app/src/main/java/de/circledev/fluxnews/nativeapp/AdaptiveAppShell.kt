package de.circledev.fluxnews.nativeapp

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

internal enum class AppDestination(
    val label: String,
    @DrawableRes val iconRes: Int,
) {
    News("News", R.drawable.ic_news),
    Settings("Settings", R.drawable.ic_settings),
}

/**
 * One adaptive shell for phone, tablet, desktop-window and foldable environments.
 *
 * Width is deliberately derived from the current available Compose window rather than a device
 * model. Compact windows use bottom navigation; wider windows keep primary navigation visible.
 */
@Composable
internal fun AdaptiveAppShell(
    bootstrap: AndroidAccountBootstrap,
    state: AndroidAccountBootstrap.State.Ready,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithWidth(modifier.fillMaxSize()) { widthClass ->
        var destination by remember { mutableStateOf(AppDestination.News) }
        when (widthClass) {
            ShellWidthClass.Compact -> CompactShell(
                destination = destination,
                onDestination = { destination = it },
                content = {
                    ShellDestinationContent(destination, bootstrap, state, onAccountChanged)
                },
            )
            ShellWidthClass.Medium,
            ShellWidthClass.Expanded -> WideShell(
                destination = destination,
                onDestination = { destination = it },
                expanded = widthClass == ShellWidthClass.Expanded,
                content = {
                    ShellDestinationContent(destination, bootstrap, state, onAccountChanged)
                },
            )
        }
    }
}

private enum class ShellWidthClass { Compact, Medium, Expanded }

@Composable
private fun BoxWithWidth(
    modifier: Modifier,
    content: @Composable (ShellWidthClass) -> Unit,
) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier) {
        val widthClass = when {
            maxWidth < 600.dp -> ShellWidthClass.Compact
            maxWidth < 840.dp -> ShellWidthClass.Medium
            else -> ShellWidthClass.Expanded
        }
        content(widthClass)
    }
}

@Composable
private fun CompactShell(
    destination: AppDestination,
    onDestination: (AppDestination) -> Unit,
    content: @Composable () -> Unit,
) {
    androidx.compose.material3.Scaffold(
        bottomBar = {
            NavigationBar {
                AppDestination.entries.forEach { item ->
                    NavigationBarItem(
                        selected = destination == item,
                        onClick = { onDestination(item) },
                        icon = { DestinationIcon(item) },
                        label = { Text(item.label) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) { content() }
    }
}

@Composable
private fun WideShell(
    destination: AppDestination,
    onDestination: (AppDestination) -> Unit,
    expanded: Boolean,
    content: @Composable () -> Unit,
) {
    Row(Modifier.fillMaxSize()) {
        if (expanded) {
            ExpandedNavigation(destination, onDestination)
        } else {
            NavigationRail(modifier = Modifier.fillMaxHeight()) {
                AppDestination.entries.forEach { item ->
                    NavigationRailItem(
                        selected = destination == item,
                        onClick = { onDestination(item) },
                        icon = { DestinationIcon(item) },
                        label = { Text(item.label) },
                    )
                }
            }
        }
        Box(Modifier.fillMaxSize()) { content() }
    }
}

@Composable
private fun ExpandedNavigation(
    destination: AppDestination,
    onDestination: (AppDestination) -> Unit,
) {
    Surface(
        modifier = Modifier.width(220.dp).fillMaxHeight(),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = Modifier.padding(vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "FluxNews",
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
                style = MaterialTheme.typography.titleLarge,
            )
            HorizontalDivider(modifier = Modifier.padding(bottom = 8.dp))
            AppDestination.entries.forEach { item ->
                androidx.compose.material3.NavigationDrawerItem(
                    label = { Text(item.label) },
                    selected = destination == item,
                    onClick = { onDestination(item) },
                    icon = { DestinationIcon(item) },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun DestinationIcon(destination: AppDestination) {
    Icon(
        painter = painterResource(destination.iconRes),
        contentDescription = destination.label,
    )
}

@Composable
private fun ShellDestinationContent(
    destination: AppDestination,
    bootstrap: AndroidAccountBootstrap,
    state: AndroidAccountBootstrap.State.Ready,
    onAccountChanged: (AndroidAccountBootstrap.State) -> Unit,
) {
    when (destination) {
        AppDestination.News -> NewsShellPlaceholder(state)
        AppDestination.Settings -> SettingsShell(
            bootstrap = bootstrap,
            onAccountChanged = onAccountChanged,
        )
    }
}

/** E3 replaces only this destination content; the adaptive E2 shell remains. */
@Composable
private fun NewsShellPlaceholder(state: AndroidAccountBootstrap.State.Ready) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("FluxNews", style = MaterialTheme.typography.headlineLarge)
            Text("Native article timeline arrives in E3", style = MaterialTheme.typography.titleMedium)
            Text(state.serverUrl, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
