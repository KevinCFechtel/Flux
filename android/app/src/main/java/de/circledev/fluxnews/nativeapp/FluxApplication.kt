package de.circledev.fluxnews.nativeapp

import android.app.Application

/**
 * Process bootstrap.
 *
 * Platform trust must complete before any session can make a Core network request. The runtime is
 * intentionally empty after process death; AndroidAccountBootstrap reconstructs its session from
 * the native credential store when an app or future headless entry point requests readiness.
 */
class FluxApplication : Application() {
    val coreRuntime: AndroidCoreRuntime by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidCoreRuntime()
    }
    val credentialStore: AndroidCredentialStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidCredentialStore(applicationContext)
    }
    val preferenceStore: AndroidPreferenceStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidPreferenceStore.create(applicationContext)
    }
    val storagePaths: AndroidStoragePaths by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidStoragePaths.create(applicationContext)
    }
    val accountBootstrap: AndroidAccountBootstrap by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidAccountBootstrap(
            credentialStore = credentialStore,
            coreRuntime = coreRuntime,
            storagePaths = storagePaths,
        )
    }

    override fun onCreate() {
        super.onCreate()
        AndroidPlatformTrust.initialize(this)
    }
}
