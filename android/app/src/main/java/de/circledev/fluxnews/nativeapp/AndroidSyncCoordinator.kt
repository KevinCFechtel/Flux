package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.SyncCancellation
import uniffi.flux_uniffi.SyncReason

/**
 * Process-scoped owner for foreground Sync runs.
 *
 * The coordinator deliberately outlives Activity/Compose scopes so configuration changes cannot
 * cancel a synchronous Rust call accidentally. Cancellation is cooperative and always travels
 * through Core's run-scoped SyncCancellation object.
 */
class AndroidSyncCoordinator private constructor(
    private val scope: CoroutineScope,
    private val cancellationFactory: () -> AndroidSyncCancellationHandle,
    private val syncRunner: suspend (SyncReason, AndroidSyncCancellationHandle) -> Unit,
) {
    internal constructor(coreRuntime: AndroidCoreRuntime) : this(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
        cancellationFactory = { CoreSyncCancellationHandle() },
        syncRunner = { reason, cancellation ->
            val coreCancellation = (cancellation as CoreSyncCancellationHandle).coreCancellation
            coreRuntime.remote { core -> core.syncCancellable(reason, coreCancellation) }
        },
    )

    internal constructor(
        scope: CoroutineScope,
        cancellationFactory: () -> AndroidSyncCancellationHandle,
        syncRunner: suspend (SyncReason, AndroidSyncCancellationHandle) -> Unit,
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(scope, cancellationFactory, syncRunner)

    sealed interface State {
        data object Idle : State
        data class Syncing(val generation: Long, val reason: SyncReason) : State
        data class Succeeded(val generation: Long, val reason: SyncReason) : State
        data class Cancelled(val generation: Long, val reason: SyncReason) : State
        data class Failed(
            val generation: Long,
            val reason: SyncReason,
            val message: String,
        ) : State
    }

    private data class ActiveRun(
        val generation: Long,
        val reason: SyncReason,
        val cancellation: AndroidSyncCancellationHandle,
        val job: Job,
    )

    private val lock = Any()
    private val _state = MutableStateFlow<State>(State.Idle)
    private var nextGeneration = 0L
    private var activeRun: ActiveRun? = null

    val state: StateFlow<State> = _state.asStateFlow()

    /** Starts a run only when no foreground Sync is already active. */
    fun requestSync(reason: SyncReason): Boolean = synchronized(lock) {
        if (activeRun != null) return false

        val generation = ++nextGeneration
        val cancellation = cancellationFactory()
        _state.value = State.Syncing(generation, reason)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            runSync(generation, reason, cancellation)
        }
        activeRun = ActiveRun(generation, reason, cancellation, job)
        job.start()
        true
    }

    /** Signals Core cancellation without cancelling the Kotlin owner of the synchronous call. */
    fun cancelActiveSync(): Boolean = synchronized(lock) {
        val run = activeRun ?: return false
        run.cancellation.cancel()
        true
    }

    /**
     * User cancellation is deliberately limited to a user-owned Manual Sync. Startup/background
     * ownership must not become cancellable merely because the same coordinator exposes state.
     */
    fun cancelManualSync(): Boolean = synchronized(lock) {
        val run = activeRun ?: return false
        if (run.reason != SyncReason.MANUAL) return false
        run.cancellation.cancel()
        true
    }

    private suspend fun runSync(
        generation: Long,
        reason: SyncReason,
        cancellation: AndroidSyncCancellationHandle,
    ) {
        val terminalState = try {
            syncRunner(reason, cancellation)
            if (cancellation.isCancelled()) {
                State.Cancelled(generation, reason)
            } else {
                State.Succeeded(generation, reason)
            }
        } catch (_: Exception) {
            if (cancellation.isCancelled()) {
                State.Cancelled(generation, reason)
            } else {
                State.Failed(
                    generation = generation,
                    reason = reason,
                    message = "Sync failed. Showing locally stored data.",
                )
            }
        }

        synchronized(lock) {
            if (activeRun?.generation == generation) {
                activeRun = null
                _state.value = terminalState
            }
        }
    }
}

internal interface AndroidSyncCancellationHandle {
    fun cancel()
    fun isCancelled(): Boolean
}

private class CoreSyncCancellationHandle : AndroidSyncCancellationHandle {
    val coreCancellation = SyncCancellation()

    override fun cancel() = coreCancellation.cancel()

    override fun isCancelled(): Boolean = coreCancellation.isCancelled()
}
