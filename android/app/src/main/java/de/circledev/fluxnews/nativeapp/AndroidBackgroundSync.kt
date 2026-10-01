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
import kotlinx.coroutines.CancellationException
import uniffi.flux_uniffi.SyncCancellation
import uniffi.flux_uniffi.SyncReason

internal val LocalAndroidBackgroundSync = staticCompositionLocalOf<AndroidBackgroundSync> {
    error("AndroidBackgroundSync was not provided")
}

internal class AndroidBackgroundSync(private val context: Context, private val coreRuntime: AndroidCoreRuntime) {
    suspend fun enabled(): Result<Boolean> = runCatching { coreRuntime.local { it.coreSettings().backgroundSyncEnabled } }

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
        val request = PeriodicWorkRequestBuilder<AndroidBackgroundSyncWorker>(30, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        manager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    companion object { internal const val WORK_NAME = "flux-background-sync" }
}

internal class AndroidBackgroundSyncWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
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
            Result.success()
        } catch (cancelled: CancellationException) {
            cancellation.cancel()
            throw cancelled
        } catch (_: Exception) {
            Result.retry()
        } finally {
            // WorkManager cancels CoroutineWorker by cancelling its coroutine. Mirror that cancellation
            // into the Core handle before leaving the worker so native sync can stop promptly as well.
            if (isStopped) cancellation.cancel()
        }
    }
}
