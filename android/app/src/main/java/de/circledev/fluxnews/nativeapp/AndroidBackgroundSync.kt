package de.circledev.fluxnews.nativeapp

import android.content.Context
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import uniffi.flux_uniffi.SyncCancellation
import uniffi.flux_uniffi.SyncReason

internal val LocalAndroidBackgroundSync = staticCompositionLocalOf<AndroidBackgroundSync> {
    error("AndroidBackgroundSync was not provided")
}

/** Android scheduler for the Core-owned Background Sync preference. */
internal class AndroidBackgroundSync(
    private val context: Context,
    private val coreRuntime: AndroidCoreRuntime,
) {
    suspend fun enabled(): Result<Boolean> = runCatching {
        coreRuntime.local { it.coreSettings().backgroundSyncEnabled }
    }

    suspend fun setEnabled(enabled: Boolean): Result<Unit> = runCatching {
        coreRuntime.local { it.setBackgroundSyncEnabled(enabled) }
        reconcile(enabled)
    }

    suspend fun reconcileFromCore(): Result<Unit> = enabled().map { reconcile(it) }

    private fun reconcile(enabled: Boolean) {
        val manager = WorkManager.getInstance(context)
        if (!enabled) {
            manager.cancelUniqueWork(WORK_NAME)
            return
        }
        val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
        val request = PeriodicWorkRequestBuilder<AndroidBackgroundSyncWorker>(30, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .build()
        manager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    companion object { internal const val WORK_NAME = "flux-background-sync" }
}

/**
 * Headless process-safe entry point. It restores the account/Core session before asking Core to
 * execute a Background run. Core remains authoritative for enabled/staleness/full-vs-delta policy.
 */
internal class AndroidBackgroundSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val app = applicationContext as FluxApplication
        val state = app.accountBootstrap.restoreStoredAccount()
        if (state !is AndroidAccountBootstrap.State.Ready) return Result.success()

        val enabled = runCatching {
            app.coreRuntime.local { it.coreSettings().backgroundSyncEnabled }
        }.getOrElse { return Result.retry() }
        if (!enabled) {
            WorkManager.getInstance(applicationContext).cancelUniqueWork(AndroidBackgroundSync.WORK_NAME)
            return Result.success()
        }

        val cancellation = SyncCancellation()
        return try {
            app.coreRuntime.remote { it.syncCancellable(SyncReason.BACKGROUND, cancellation) }
            if (isStopped || cancellation.isCancelled()) Result.failure() else Result.success()
        } catch (_: Exception) {
            if (isStopped) Result.failure() else Result.retry()
        }
    }
}
