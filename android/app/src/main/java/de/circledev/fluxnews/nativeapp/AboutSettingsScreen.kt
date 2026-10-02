package de.circledev.fluxnews.nativeapp

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

@Composable
internal fun AboutSettingsScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("FluxNews", style = MaterialTheme.typography.titleLarge)
        Text("Version ${packageInfo.versionName ?: "unknown"} (${packageInfo.longVersionCode})", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("A native Miniflux client with a shared Rust core.")
        HorizontalDivider()
        SettingsSectionTitle("Open Source")
        LinkButton("Flux source code", "https://github.com/KevinCFechtel/Flux")
        LinkButton("Open-source license", "https://github.com/KevinCFechtel/Flux/blob/main/LICENSE")
        Text("FluxNews includes open-source components. Their license notices remain part of the corresponding source distributions and packaged dependencies.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider()
        SettingsSectionTitle("Legal")
        Text("FluxNews is an independent Miniflux client. Miniflux is a separate open-source project.", style = MaterialTheme.typography.bodyMedium)
        LinkButton("Miniflux project", "https://miniflux.app")
    }
}

@Composable
private fun LinkButton(title: String, url: String) {
    val context = LocalContext.current
    TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }) { Text(title) }
}
