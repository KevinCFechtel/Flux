package de.circledev.fluxnews.nativeapp

import android.app.Application
import android.content.Context
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Process bootstrap.
 *
 * Platform trust must complete before any session can make a Core network request. The runtime is
 * intentionally empty after process death; AndroidAccountBootstrap reconstructs its session from
 * the native credential store when an app or future headless entry point requests readiness.
 */
class FluxApplication : Application(), SingletonImageLoader.Factory {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val storagePaths: AndroidStoragePaths by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidStoragePaths.create(applicationContext) }
    val preferenceStore: AndroidPreferenceStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidPreferenceStore.create(applicationContext) }
    internal val diagnostics: AndroidAppDiagnostics by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidAppDiagnostics(applicationContext, storagePaths, preferenceStore) }
    val coreRuntime: AndroidCoreRuntime by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidCoreRuntime(AndroidCoreDiagnosticListener(diagnostics)) }
    val syncCoordinator: AndroidSyncCoordinator by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidSyncCoordinator(coreRuntime) }
    internal val backgroundSync: AndroidBackgroundSync by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidBackgroundSync(applicationContext, coreRuntime) }
    val credentialStore: AndroidCredentialStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidCredentialStore(applicationContext) }
    internal val navigationPreferences: AndroidNavigationPreferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidNavigationPreferences(preferenceStore) }
    internal val articlePreferences: AndroidArticlePreferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidArticlePreferences(preferenceStore) }
    internal val actionBarPreferences: AndroidActionBarPreferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AndroidActionBarPreferences(preferenceStore) }
    internal val configurationBackup: AndroidConfigurationBackupController by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidConfigurationBackupController(accountBootstrap, coreRuntime, navigationPreferences, articlePreferences, actionBarPreferences)
    }
    val accountBootstrap: AndroidAccountBootstrap by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidAccountBootstrap(credentialStore = credentialStore, preferenceStore = preferenceStore, coreRuntime = coreRuntime, storagePaths = storagePaths)
    }

    override fun newImageLoader(context: Context): ImageLoader =
        ImageLoader.Builder(context.applicationContext)
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizePercent(context.applicationContext, 0.15)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(context.applicationContext.cacheDir.resolve("article-images"))
                    .maxSizeBytes(256L * 1024L * 1024L)
                    .build()
            }
            .build()

    override fun onCreate() {
        super.onCreate()
        AndroidPlatformTrust.initialize(this)
        applicationScope.launch {
            diagnostics.initialize()
            runCatching { credentialStore.read() }.getOrNull()?.let { credentials ->
                diagnostics.setSensitiveValues(buildList {
                    add(credentials.apiKey)
                    credentials.customHeaders.forEach { add(it.value) }
                })
            }
            diagnostics.record(AndroidAppLogLevel.Info, "app", "FluxNews process started")
        }
    }
}
