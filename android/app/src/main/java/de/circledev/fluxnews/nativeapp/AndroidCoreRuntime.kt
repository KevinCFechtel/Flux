package de.circledev.fluxnews.nativeapp

import android.os.Looper
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.flux_uniffi.AccountValidationResult
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.DiagnosticListener
import uniffi.flux_uniffi.EventListener
import uniffi.flux_uniffi.EventSubscription
import uniffi.flux_uniffi.Flux
import uniffi.flux_uniffi.HttpHeader
import uniffi.flux_uniffi.InitializationConfig
import uniffi.flux_uniffi.validateMinifluxAccount

/** Process-scoped owner for the one active UniFFI Core session. */
class AndroidCoreRuntime(
    private val diagnosticListener: DiagnosticListener? = null,
) {
    private val localDispatcher = Executors.newFixedThreadPool(
        CoreRuntimeExecutionPolicy.LOCAL_WORKERS,
    ) { runnable -> Thread(runnable, "FluxCore-local").apply { isDaemon = true } }
        .asCoroutineDispatcher()
    private val remoteDispatcher = Executors.newFixedThreadPool(
        CoreRuntimeExecutionPolicy.REMOTE_WORKERS,
    ) { runnable -> Thread(runnable, "FluxCore-remote").apply { isDaemon = true } }
        .asCoroutineDispatcher()
    private val lifecycleMutex = Mutex()
    private val sessionLock = ReentrantReadWriteLock(true)
    private val _events = MutableSharedFlow<AndroidCoreRuntimeEvent>(
        replay = 0,
        extraBufferCapacity = CoreRuntimeExecutionPolicy.EVENT_BUFFER_CAPACITY,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    private var acceptingWork = false
    private var activeSession: CoreSession? = null
    private var nextGeneration = 0L
    private val mutableSessionGeneration = MutableStateFlow<Long?>(null)

    val events: SharedFlow<AndroidCoreRuntimeEvent> = _events.asSharedFlow()
    val sessionGeneration: StateFlow<Long?> = mutableSessionGeneration.asStateFlow()

    fun hasActiveSession(): Boolean = sessionLock.readLock().run {
        lock()
        try { activeSession != null && acceptingWork } finally { unlock() }
    }

    /** Monotonic identity for the currently installed Core session, or null when no session is active. */
    fun activeSessionGeneration(): Long? = sessionLock.readLock().run {
        lock()
        try { activeSession?.generation?.takeIf { acceptingWork } } finally { unlock() }
    }

    suspend fun validateAccount(
        serverUrl: String,
        apiKey: String,
        customHeaders: List<HttpHeader>,
    ): AccountValidationResult = withContext(remoteDispatcher) {
        requireOffMainThread()
        validateMinifluxAccount(serverUrl, apiKey, customHeaders)
    }

    suspend fun openSession(config: InitializationConfig): Long = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    check(activeSession == null) { "A Core session is already active." }
                    installSession(config)
                } finally { unlock() }
            }
        }
    }

    /**
     * Never opens two Core instances on the same persistent store. Replacement first retires the
     * old instance, then opens the candidate. If candidate initialization fails, the previous
     * InitializationConfig is reopened before the failure is returned to the account lifecycle.
     */
    suspend fun replaceSession(config: InitializationConfig): Long = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    val previousConfig = activeSession?.initializationConfig
                    closeActiveSessionLocked()
                    try {
                        installSession(config)
                    } catch (replacementError: Throwable) {
                        if (previousConfig != null) {
                            try {
                                installSession(previousConfig)
                            } catch (rollbackError: Throwable) {
                                replacementError.addSuppressed(rollbackError)
                            }
                        }
                        throw replacementError
                    }
                } finally { unlock() }
            }
        }
    }

    suspend fun closeSession() = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try { closeActiveSessionLocked() } finally { unlock() }
            }
        }
    }

    suspend fun <T> local(block: (Flux) -> T): T = execute(localDispatcher, block)
    suspend fun <T> remote(block: (Flux) -> T): T = execute(remoteDispatcher, block)

    private suspend fun <T> execute(
        dispatcher: kotlinx.coroutines.CoroutineDispatcher,
        block: (Flux) -> T,
    ): T = withContext(dispatcher) {
        requireOffMainThread()
        sessionLock.readLock().run {
            lock()
            try {
                val session = activeSession
                check(acceptingWork && session != null) { "No active Core session." }
                block(session.flux)
            } finally { unlock() }
        }
    }

    private fun installSession(config: InitializationConfig): Long {
        val flux = diagnosticListener?.let { Flux.initializeWithDiagnostics(config, it) } ?: Flux.initialize(config)
        try {
            val generation = ++nextGeneration
            val subscription = flux.subscribeEvents(RuntimeEventListener(generation, _events))
            activeSession = CoreSession(generation, config, flux, subscription)
            acceptingWork = true
            mutableSessionGeneration.value = generation
            return generation
        } catch (error: Throwable) {
            flux.close()
            throw error
        }
    }

    private fun closeActiveSessionLocked() {
        acceptingWork = false
        mutableSessionGeneration.value = null
        val session = activeSession ?: return
        try {
            session.subscription.unsubscribe()
        } finally {
            try {
                session.subscription.close()
            } finally {
                try {
                    session.flux.close()
                } finally {
                    activeSession = null
                }
            }
        }
    }

    private fun requireOffMainThread() {
        check(Looper.getMainLooper().thread !== Thread.currentThread()) {
            "Synchronous Core work must not run on the Android main thread."
        }
    }

    private data class CoreSession(
        val generation: Long,
        val initializationConfig: InitializationConfig,
        val flux: Flux,
        val subscription: EventSubscription,
    )

    private class RuntimeEventListener(
        private val generation: Long,
        private val events: MutableSharedFlow<AndroidCoreRuntimeEvent>,
    ) : EventListener {
        override fun onEvent(event: CoreEvent) {
            events.tryEmit(AndroidCoreRuntimeEvent(generation = generation, event = event))
        }
    }
}

internal data class AndroidCoreRuntimeEvent(
    val generation: Long,
    val event: CoreEvent,
)

internal object CoreRuntimeExecutionPolicy {
    const val LOCAL_WORKERS = 2
    const val REMOTE_WORKERS = 1
    const val EVENT_BUFFER_CAPACITY = 64
}
