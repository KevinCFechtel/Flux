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

    override fun onCreate() {
        super.onCreate()
        AndroidPlatformTrust.initialize(this)
    }
}
