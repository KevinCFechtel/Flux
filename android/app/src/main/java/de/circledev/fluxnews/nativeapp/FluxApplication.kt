package de.circledev.fluxnews.nativeapp

import android.app.Application

/**
 * Process bootstrap.
 *
 * Platform trust must complete before any session can make a Core network request. The runtime is
 * intentionally empty after process death; a later account bootstrap reconstructs its session.
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

    override fun onCreate() {
        super.onCreate()
        AndroidPlatformTrust.initialize(this)
    }
}
