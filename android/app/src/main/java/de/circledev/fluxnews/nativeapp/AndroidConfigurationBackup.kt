package de.circledev.fluxnews.nativeapp

import java.io.ByteArrayOutputStream
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject
import uniffi.flux_uniffi.BackupAccount
import uniffi.flux_uniffi.BackupPlatform
import uniffi.flux_uniffi.ConfigBackupException
import uniffi.flux_uniffi.ConfigBackupInput
import uniffi.flux_uniffi.ConfigBackupRestoreModel
import uniffi.flux_uniffi.PlatformSettingsPayload
import uniffi.flux_uniffi.exportConfigBackup
import uniffi.flux_uniffi.parseConfigBackup

/** Versioned Android-local settings. Core-owned settings deliberately do not appear here. */
internal data class AndroidBackupSettingsV1(
    val hideEmptyNavigationEntries: Boolean,
    val startupScope: String,
    val startupCategoryId: Long?,
    val startupFeedId: Long?,
    val openArticle: String,
    val presentationMode: String,
    val previewLines: Int,
    val showArticleCount: Boolean,
    val showRelativePublicationTime: Boolean,
    val removeArticlesWhenRead: Boolean,
    val markReadOnScrollover: Boolean,
    val leadingSwipeFull: String?,
    val leadingSwipeAdditional: String?,
    val trailingSwipeFull: String?,
    val trailingSwipeAdditional: String?,
    val actionBarActions: List<String>,
    val customHeaders: List<StoredCredentialHeader>,
) {
    companion object {
        const val VERSION = 1u

        suspend fun capture(
            navigation: AndroidNavigationPreferences,
            articles: AndroidArticlePreferences,
            actionBar: AndroidActionBarPreferences,
            headers: List<StoredCredentialHeader>,
        ): AndroidBackupSettingsV1 {
            val navigationState = navigation.state.first()
            val articleState = articles.state.first()
            val actionState = actionBar.state.first()
            return AndroidBackupSettingsV1(
                navigationState.hideEmptyNavigationEntries,
                navigationState.startupScope.storedValue,
                navigationState.startupCategoryId,
                navigationState.startupFeedId,
                articleState.openArticle.storedValue,
                articleState.presentationMode.storedValue,
                articleState.previewLines.lineCount,
                articleState.showArticleCount,
                articleState.showRelativePublicationTime,
                articleState.removeArticlesWhenRead,
                articleState.markReadOnScrollover,
                articleState.swipeConfiguration.fullSwipeAction(AndroidArticleSwipeSide.Leading)?.storedValue,
                articleState.swipeConfiguration.additionalAction(AndroidArticleSwipeSide.Leading)?.storedValue,
                articleState.swipeConfiguration.fullSwipeAction(AndroidArticleSwipeSide.Trailing)?.storedValue,
                articleState.swipeConfiguration.additionalAction(AndroidArticleSwipeSide.Trailing)?.storedValue,
                actionState.actions.map { it.storedValue },
                headers,
            )
        }

        fun decode(json: String): AndroidBackupSettingsV1 = try {
            val objectValue = JSONObject(json)
            val version = objectValue.getInt("version")
            require(version == VERSION.toInt())
            fun action(name: String): String? = objectValue.optString(name, "").takeIf { it.isNotEmpty() }
            val actions = objectValue.getJSONArray("actionBarActions").strings()
            val headers = objectValue.getJSONArray("customHeaders").let { values ->
                List(values.length()) { index ->
                    values.getJSONObject(index).let { StoredCredentialHeader(it.getString("name"), it.getString("value")) }
                }
            }
            AndroidBackupSettingsV1(
                objectValue.getBoolean("hideEmptyNavigationEntries"), objectValue.getString("startupScope"),
                objectValue.optLongOrNull("startupCategoryId"), objectValue.optLongOrNull("startupFeedId"),
                objectValue.getString("openArticle"), objectValue.getString("presentationMode"), objectValue.getInt("previewLines"),
                objectValue.getBoolean("showArticleCount"), objectValue.getBoolean("showRelativePublicationTime"),
                objectValue.getBoolean("removeArticlesWhenRead"), objectValue.getBoolean("markReadOnScrollover"),
                action("leadingSwipeFull"), action("leadingSwipeAdditional"), action("trailingSwipeFull"), action("trailingSwipeAdditional"),
                actions, headers,
            ).validated()
        } catch (error: Exception) {
            throw AndroidConfigurationBackupException.InvalidPlatformSettings
        }
    }

    fun encode(): String = JSONObject()
        .put("version", VERSION.toInt())
        .put("hideEmptyNavigationEntries", hideEmptyNavigationEntries)
        .put("startupScope", startupScope)
        .put("startupCategoryId", startupCategoryId)
        .put("startupFeedId", startupFeedId)
        .put("openArticle", openArticle)
        .put("presentationMode", presentationMode)
        .put("previewLines", previewLines)
        .put("showArticleCount", showArticleCount)
        .put("showRelativePublicationTime", showRelativePublicationTime)
        .put("removeArticlesWhenRead", removeArticlesWhenRead)
        .put("markReadOnScrollover", markReadOnScrollover)
        .put("leadingSwipeFull", leadingSwipeFull)
        .put("leadingSwipeAdditional", leadingSwipeAdditional)
        .put("trailingSwipeFull", trailingSwipeFull)
        .put("trailingSwipeAdditional", trailingSwipeAdditional)
        .put("actionBarActions", JSONArray(actionBarActions))
        .put("customHeaders", JSONArray().apply { customHeaders.forEach { put(JSONObject().put("name", it.name).put("value", it.value)) } })
        .toString()

    fun validated(): AndroidBackupSettingsV1 {
        val scope = AndroidStartupScopePreference.entries.firstOrNull { it.storedValue == startupScope }
            ?: throw AndroidConfigurationBackupException.InvalidPlatformSettings
        if (scope == AndroidStartupScopePreference.Category && (startupCategoryId ?: 0) <= 0) throw AndroidConfigurationBackupException.InvalidPlatformSettings
        if (scope == AndroidStartupScopePreference.Feed && (startupFeedId ?: 0) <= 0) throw AndroidConfigurationBackupException.InvalidPlatformSettings
        requireEnum(openArticle, AndroidArticleOpenPreference.entries.map { it.storedValue })
        requireEnum(presentationMode, AndroidArticlePresentationMode.entries.map { it.storedValue })
        require(previewLines in AndroidArticlePreviewLines.entries.map { it.lineCount })
        validateSwipe(leadingSwipeFull, leadingSwipeAdditional)
        validateSwipe(trailingSwipeFull, trailingSwipeAdditional)
        require(actionBarActions.distinct().size == actionBarActions.size)
        require(actionBarActions.all { action -> AndroidActionBarAction.fromStoredValue(action) != null })
        val names = mutableSetOf<String>()
        customHeaders.forEach { header ->
            val name = header.name.trim()
            require(name.isNotEmpty() && !name.contains('\n') && !name.contains('\r') && header.value.toByteArray().size <= 8 * 1024)
            require(names.add(name.lowercase()))
        }
        return copy(
            startupCategoryId = if (scope == AndroidStartupScopePreference.Category) startupCategoryId else null,
            startupFeedId = if (scope == AndroidStartupScopePreference.Feed) startupFeedId else null,
            leadingSwipeAdditional = leadingSwipeAdditional.takeUnless { it == leadingSwipeFull },
            trailingSwipeAdditional = trailingSwipeAdditional.takeUnless { it == trailingSwipeFull },
        )
    }

    private fun validateSwipe(full: String?, additional: String?) {
        require(full == null || AndroidArticleSwipeAction.fromStoredValue(full) != null)
        require(additional == null || AndroidArticleSwipeAction.fromStoredValue(additional) != null)
        require(full != null || additional == null)
    }
    private fun requireEnum(value: String, values: List<String>) { require(value in values) }
}

private fun JSONObject.optLongOrNull(name: String): Long? = if (isNull(name)) null else getLong(name)
private fun JSONArray.strings(): List<String> = List(length()) { getString(it) }

internal sealed class AndroidConfigurationBackupException(message: String) : Exception(message) {
    data object NoConfiguredAccount : AndroidConfigurationBackupException("No configured account.")
    data object InvalidPlatformSettings : AndroidConfigurationBackupException("Invalid Android backup settings.")
    data object FileTooLarge : AndroidConfigurationBackupException("Backup exceeds supported size.")
    data object RestoreFailed : AndroidConfigurationBackupException("Configuration restore failed.")
    data object RollbackFailed : AndroidConfigurationBackupException("Configuration restore rollback failed.")
}

/** Shared service for Settings and the fresh-install account flow. It never persists backup bytes. */
internal class AndroidConfigurationBackupController(
    private val bootstrap: AndroidAccountBootstrap,
    private val runtime: AndroidCoreRuntime,
    private val navigation: AndroidNavigationPreferences,
    private val articles: AndroidArticlePreferences,
    private val actionBar: AndroidActionBarPreferences,
) {
    suspend fun export(password: String): ByteArray {
        if (password.isEmpty()) throw ConfigBackupException.EmptyPassword()
        val credentials = bootstrap.credentialsForConfigurationBackup() ?: throw AndroidConfigurationBackupException.NoConfiguredAccount
        val snapshot = runtime.local { it.configurationSnapshot() }
        val native = AndroidBackupSettingsV1.capture(navigation, articles, actionBar, credentials.customHeaders).validated()
        return exportConfigBackup(
            ConfigBackupInput(BackupPlatform.ANDROID, BackupAccount(snapshot.installationBase, credentials.apiKey), snapshot.coreSettings, snapshot.feedPreferences, PlatformSettingsPayload(AndroidBackupSettingsV1.VERSION, native.encode())),
            password,
        )
    }

    suspend fun restore(bytes: ByteArray, password: String) {
        if (bytes.size > MAX_INPUT_BYTES) throw AndroidConfigurationBackupException.FileTooLarge
        if (password.isEmpty()) throw ConfigBackupException.EmptyPassword()
        val restored = parseConfigBackup(bytes, password, BackupPlatform.ANDROID)
        if (restored.platformSettings.schemaVersion != AndroidBackupSettingsV1.VERSION) throw AndroidConfigurationBackupException.InvalidPlatformSettings
        val native = AndroidBackupSettingsV1.decode(restored.platformSettings.dataJson)
        bootstrap.withConfigurationBackupLock { restoreValidated(restored, native) }
    }

    private suspend fun restoreValidated(restored: ConfigBackupRestoreModel, native: AndroidBackupSettingsV1) {
        val replacementCredentials = StoredAccountCredentials(restored.account.installationBase, restored.account.apiKey, native.customHeaders)
        val previousCredentials = bootstrap.credentialsForConfigurationBackup()
        val previousNative = previousCredentials?.let { AndroidBackupSettingsV1.capture(navigation, articles, actionBar, it.customHeaders).validated() }
        val previousSnapshot = if (runtime.hasActiveSession()) runtime.local { it.configurationSnapshot() } else null
        try {
            if (previousSnapshot != null) runtime.local { it.replaceConfiguration(restored.account.installationBase, restored.coreSettings, restored.feedPreferences) }
            else {
                runtime.openSession(bootstrap.initializationConfigFor(replacementCredentials))
                runtime.local { it.replaceConfiguration(restored.account.installationBase, restored.coreSettings, restored.feedPreferences) }
            }
            bootstrap.writeCredentialsForConfigurationBackup(replacementCredentials)
            apply(native)
            runtime.replaceSession(bootstrap.initializationConfigFor(replacementCredentials))
            bootstrap.publishRestoredAccount(replacementCredentials)
        } catch (failure: Exception) {
            val rolledBack = rollback(previousSnapshot, previousCredentials, previousNative)
            if (!rolledBack) {
                bootstrap.publishConfigurationRecoveryError()
                throw AndroidConfigurationBackupException.RollbackFailed
            }
            throw failure
        }
    }

    private suspend fun rollback(snapshot: uniffi.flux_uniffi.ConfigurationSnapshot?, credentials: StoredAccountCredentials?, native: AndroidBackupSettingsV1?): Boolean = try {
        if (snapshot != null && runtime.hasActiveSession()) runtime.local { it.replaceConfiguration(snapshot.installationBase, snapshot.coreSettings, snapshot.feedPreferences) }
        if (credentials != null) {
            bootstrap.writeCredentialsForConfigurationBackup(credentials)
            if (native != null) apply(native)
            runtime.replaceSession(bootstrap.initializationConfigFor(credentials))
            bootstrap.publishRestoredAccount(credentials)
        } else {
            // A fresh-session replacement has already committed into the Core store. Reset it
            // before retiring the temporary session so no restored configuration survives a failed import.
            if (runtime.hasActiveSession()) runtime.local { it.resetCoreState() }
            runtime.closeSession()
            bootstrap.clearCredentialsForConfigurationBackup()
        }
        true
    } catch (_: Exception) { false }

    private suspend fun apply(settings: AndroidBackupSettingsV1) {
        navigation.setHideEmptyNavigationEntries(settings.hideEmptyNavigationEntries)
        navigation.setStartupScope(AndroidStartupScopePreference.entries.first { it.storedValue == settings.startupScope })
        navigation.setStartupCategoryId(settings.startupCategoryId)
        navigation.setStartupFeedId(settings.startupFeedId)
        articles.setOpenArticle(AndroidArticleOpenPreference.entries.first { it.storedValue == settings.openArticle })
        articles.setPresentationMode(AndroidArticlePresentationMode.entries.first { it.storedValue == settings.presentationMode })
        articles.setPreviewLines(AndroidArticlePreviewLines.entries.first { it.lineCount == settings.previewLines })
        articles.setShowArticleCount(settings.showArticleCount)
        articles.setShowRelativePublicationTime(settings.showRelativePublicationTime)
        articles.setRemoveArticlesWhenRead(settings.removeArticlesWhenRead)
        articles.setMarkReadOnScrollover(settings.markReadOnScrollover)
        var swipe = AndroidArticleSwipeConfiguration.Default
        listOf(AndroidArticleSwipeSide.Leading to settings.leadingSwipeFull, AndroidArticleSwipeSide.Leading to settings.leadingSwipeAdditional, AndroidArticleSwipeSide.Trailing to settings.trailingSwipeFull, AndroidArticleSwipeSide.Trailing to settings.trailingSwipeAdditional).forEachIndexed { index, (side, value) ->
            val slot = if (index % 2 == 0) AndroidArticleSwipeSlot.FullSwipe else AndroidArticleSwipeSlot.Additional
            swipe = swipe.setting(value?.let(AndroidArticleSwipeAction::fromStoredValue), side, slot)
            articles.setSwipeAction(swipe, value?.let(AndroidArticleSwipeAction::fromStoredValue), side, slot)
        }
        actionBar.setActions(settings.actionBarActions.map { AndroidActionBarAction.fromStoredValue(it)!! })
    }

    companion object { const val MAX_INPUT_BYTES = 2 * 1024 * 1024 }
}
