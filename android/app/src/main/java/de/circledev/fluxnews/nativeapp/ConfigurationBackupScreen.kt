package de.circledev.fluxnews.nativeapp

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.io.ByteArrayOutputStream
import java.time.LocalDate
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.ConfigBackupException
import uniffi.flux_uniffi.SyncReason

internal val LocalAndroidConfigurationBackup = staticCompositionLocalOf<AndroidConfigurationBackupController> {
    error("AndroidConfigurationBackupController was not provided")
}

@Composable
internal fun ConfigurationBackupScreen(
    controller: AndroidConfigurationBackupController,
    onRestored: () -> Unit,
    modifier: Modifier = Modifier,
    allowExport: Boolean = true,
    onDismiss: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var exportPassword by remember { mutableStateOf("") }
    var exportConfirmation by remember { mutableStateOf("") }
    var pendingExport by remember { mutableStateOf<ByteArray?>(null) }
    var pendingImport by remember { mutableStateOf<Uri?>(null) }
    var importPassword by remember { mutableStateOf("") }
    var confirmRestore by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val createDocument = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val bytes = pendingExport
        pendingExport = null
        if (uri == null || bytes == null) return@rememberLauncherForActivityResult
        scope.launch {
            working = true
            try {
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("No writable output stream.")
                status = "Configuration backup exported."
            } catch (_: Exception) { error = "The selected location could not be written." }
            working = false
        }
    }
    val openDocument = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        pendingImport = uri
        if (uri != null) error = null
    }

    if (confirmRestore) AlertDialog(
        onDismissRequest = { if (!working) confirmRestore = false },
        title = { Text("Restore Configuration?") },
        text = { Text("This replaces the current account and configuration. Existing synchronized article state will be rebuilt from Miniflux.") },
        dismissButton = { TextButton(enabled = !working, onClick = { confirmRestore = false }) { Text("Cancel") } },
        confirmButton = { TextButton(enabled = !working, onClick = {
            val uri = pendingImport ?: return@TextButton
            confirmRestore = false
            scope.launch {
                working = true; error = null; status = null
                try {
                    controller.restore(context.readBackup(uri), importPassword)
                    val app = context.applicationContext as FluxApplication
                    app.backgroundSync.reconcileFromCore()
                    app.syncCoordinator.requestSync(SyncReason.MANUAL)
                    status = "Configuration restored. Synchronization will start now."
                    onRestored()
                } catch (failure: Exception) { error = backupMessage(failure) }
                working = false
            }
        }) { Text("Restore", color = MaterialTheme.colorScheme.error) } },
    )

    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        onDismiss?.let { dismiss -> TextButton(onClick = dismiss) { Text("Back to account setup") } }
        if (allowExport) {
            Text("Backups are password-encrypted and include the account, Core settings, feed preferences, and Android settings. Articles, downloads, and playback state are not included.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            SettingsSectionTitle("Export")
            OutlinedTextField(exportPassword, { exportPassword = it }, label = { Text("Backup password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(exportConfirmation, { exportConfirmation = it }, label = { Text("Confirm backup password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(enabled = !working && exportPassword.isNotEmpty() && exportPassword == exportConfirmation, onClick = {
                scope.launch {
                    working = true; error = null; status = null
                    try {
                        pendingExport = controller.export(exportPassword)
                        createDocument.launch("FluxNews Configuration Backup ${LocalDate.now()}.fluxbackup")
                    } catch (failure: Exception) { error = backupMessage(failure); pendingExport = null }
                    working = false
                }
            }) { Text("Export Configuration Backup") }
        }
        SettingsSectionTitle("Restore")
        Text("Use a backup created by FluxNews for Android. Restoring replaces this installation's configuration.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedButton(enabled = !working, onClick = { openDocument.launch(arrayOf("application/octet-stream", "application/*", "*/*")) }) { Text(if (pendingImport == null) "Choose Backup to Restore" else "Choose Another Backup") }
        OutlinedTextField(importPassword, { importPassword = it }, label = { Text("Backup password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
        Button(enabled = !working && pendingImport != null && importPassword.isNotEmpty(), onClick = { confirmRestore = true }) { Text("Restore Configuration Backup") }
        if (working) CircularProgressIndicator(Modifier.size(24.dp))
        status?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

private fun Context.readBackup(uri: Uri): ByteArray {
    contentResolver.openInputStream(uri)?.use { input ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (output.size() + read > AndroidConfigurationBackupController.MAX_INPUT_BYTES) throw AndroidConfigurationBackupException.FileTooLarge
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }
    throw IllegalStateException("No readable input stream.")
}

private fun backupMessage(error: Exception): String = when (error) {
    is ConfigBackupException.EmptyPassword -> "Enter a backup password."
    is ConfigBackupException.NotFluxBackup -> "Not a valid FluxNews backup."
    is ConfigBackupException.UnsupportedVersion -> "This backup uses an unsupported format."
    is ConfigBackupException.PlatformMismatch -> "This backup was created for another platform."
    is ConfigBackupException.DecryptionFailed -> "The backup could not be decrypted. The password may be incorrect or the file may be damaged."
    is ConfigBackupException.InvalidCryptoMetadata, is ConfigBackupException.MalformedPayload, is ConfigBackupException.InvalidContents -> "The backup is damaged or contains invalid data."
    is ConfigBackupException.InputTooLarge, AndroidConfigurationBackupException.FileTooLarge -> "The selected backup is too large."
    AndroidConfigurationBackupException.InvalidPlatformSettings -> "This backup contains unsupported Android settings."
    AndroidConfigurationBackupException.NoConfiguredAccount -> "Configure a Miniflux account before exporting a backup."
    AndroidConfigurationBackupException.RollbackFailed -> "The restore failed and the previous configuration could not be recovered. Restart FluxNews before making further changes."
    else -> "The configuration backup operation failed."
}
