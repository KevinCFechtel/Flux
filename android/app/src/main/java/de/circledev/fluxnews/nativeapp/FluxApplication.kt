package de.circledev.fluxnews.nativeapp

import android.app.Application

/**
 * Process bootstrap.
 *
 * E1-C only establishes Android platform trust for the Rust transport before any core request can
 * run. The process-scoped core owner, the bounded off-main executor and session lifecycle remain
 * E1-D work and are deliberately absent here.
 */
class FluxApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AndroidPlatformTrust.initialize(this)
    }
}
