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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.SyncCancellation
import uniffi.flux_uniffi.SyncOutcome
import uniffi.flux_uniffi.SyncReason

internal val LocalAndroidBackgroundSync = staticCompositionLocalOf<AndroidBackgroundSync> {
    error("AndroidBackgroundSync was not provided")
}

internal class AndroidBackgroundSync(
    private val context: Context,
    private val coreRuntime: AndroidCoreRuntime,
    private val accountBootstrap: AndroidAccountBootstrap,
    private val postSyncEffects: AndroidPostSyncEffects,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val resumeLock = Any()
    private var resumeJob: Job? = null
    private var resumeCancellation: SyncCancellation? = null

    suspend fun enabled(): Result<Boolean> =
        runCatching { coreRuntime.local { it.coreSettings().backgroundSyncEnabled } }

    suspend fun setEnabled(enabled: Boolean): Result<Unit> = runCatching {
        coreRuntime.local { it.setBackgroundSyncEnabled(enabled) }
        reconcile(enabled)
        if (enabled) requestResumeIfNeeded()
    }

    suspend fun reconcileFromCore(): Result<Unit> = enabled().map { reconcile(it) }

    /**
     * Requests Core-owned foreground/resume freshness without introducing Android freshness state.
     *
     * The Core decides whether Background Sync is enabled, whether the last successful Sync is
     * stale and whether the request becomes a no-op, Delta or Full Sync.
     */
    fun requestResumeIfNeeded(): Boolean = synchronized(resumeLock) {
        if (resumeJob?.isActive == true) return false

        val cancellation = SyncCancellation()
        val job = scope.launch {
            try {
                val state = accountBootstrap.restoreStoredAccount()
                if (state !is AndroidAccountBootstrap.State.Ready) return@launch

                val generation = coreRuntime.activeSessionGeneration() ?: return@launch
                when (
                    val outcome = coreRuntime.remoteForGeneration(generation) { core ->
                        core.syncCancellable(SyncReason.RESUME, cancellation)
                    }
                ) {
                    is SyncOutcome.Completed -> {
                        if (!cancellation.isCancelled() && coreRuntime.activeSessionGeneration() == generation) {
                            postSyncEffects.handle(generation, outcome.metadata)
                        }
                    }
                    is SyncOutcome.Cancelled -> Unit
                }
            } catch (_: Exception) {
                // Resume is an opportunistic fallback. Normal foreground data remains available.
            } finally {
                synchronized(resumeLock) {
                    if (resumeCancellation === cancellation) {
                        resumeCancellation = null
                        resumeJob = null
                    }
                }
            }
        }
        resumeCancellation = cancellation
        resumeJob = job
        true
    }

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

        val generation = app.coreRuntime.activeSessionGeneration() ?: return Result.retry()
        val enabled = runCatching {
            app.coreRuntime.localForGeneration(generation) { it.coreSettings().backgroundSyncEnabled }
        }.getOrElse { return Result.retry() }
        if (!enabled) {
            WorkManager.getInstance(applicationContext).cancelUniqueWork(AndroidBackgroundSync.WORK_NAME)
            return Result.success()
        }

        val cancellation = SyncCancellation()
        return try {
            when (
                val outcome = app.coreRuntime.remoteForGeneration(generation) {
                    it.syncCancellable(SyncReason.BACKGROUND, cancellation)
                }
            ) {
                is SyncOutcome.Completed -> {
                    if (cancellation.isCancelled() || app.coreRuntime.activeSessionGeneration() != generation) {
                        Result.success()
                    } else {
                        app.postSyncEffects.handle(generation, outcome.metadata)
                        Result.success()
                    }
                }
                is SyncOutcome.Cancelled -> Result.success()
            }
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
