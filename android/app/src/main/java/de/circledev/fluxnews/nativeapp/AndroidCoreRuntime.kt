package de.circledev.fluxnews.nativeapp

import android.os.Looper
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.flux_uniffi.AccountValidationResult
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.EventListener
import uniffi.flux_uniffi.EventSubscription
import uniffi.flux_uniffi.Flux
import uniffi.flux_uniffi.HttpHeader
import uniffi.flux_uniffi.InitializationConfig
import uniffi.flux_uniffi.validateMinifluxAccount

/**
 * Process-scoped owner for the one active UniFFI Core session.
 *
 * Local work has two fixed workers for short SQLite-bound calls. Remote work has one fixed worker
 * so a slow network operation cannot occupy either local worker. Core retains its own storage and
 * sync serialization; this runtime only protects session lifetime.
 */
class AndroidCoreRuntime {
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
    private val _events = MutableSharedFlow<CoreEvent>(
        replay = 0,
        extraBufferCapacity = CoreRuntimeExecutionPolicy.EVENT_BUFFER_CAPACITY,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    private var acceptingWork = false
    private var activeSession: CoreSession? = null
    private var nextGeneration = 0L

    val events: SharedFlow<CoreEvent> = _events.asSharedFlow()

    fun hasActiveSession(): Boolean = sessionLock.readLock().run {
        lock()
        try {
            activeSession != null && acceptingWork
        } finally {
            unlock()
        }
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
                    val session = createSession(config)
                    activeSession = session
                    acceptingWork = true
                    session.generation
                } finally {
                    unlock()
                }
            }
        }
    }

    /**
     * Builds the candidate before retiring the current session. If candidate initialization fails,
     * the current session remains active and callers can continue using the previous account.
     */
    suspend fun replaceSession(config: InitializationConfig): Long = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    val candidate = createSession(config)
                    val previous = activeSession
                    acceptingWork = false
                    try {
                        previous?.close()
                    } catch (error: Throwable) {
                        candidate.close()
                        acceptingWork = previous != null
                        throw error
                    }
                    activeSession = candidate
                    acceptingWork = true
                    candidate.generation
                } finally {
                    unlock()
                }
            }
        }
    }

    suspend fun closeSession() = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    closeActiveSessionLocked()
                } finally {
                    unlock()
                }
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
            } finally {
                unlock()
            }
        }
    }

    private fun createSession(config: InitializationConfig): CoreSession {
        val flux = Flux.initialize(config)
        try {
            val subscription = flux.subscribeEvents(RuntimeEventListener(_events))
            return CoreSession(++nextGeneration, config, flux, subscription)
        } catch (error: Throwable) {
            flux.close()
            throw error
        }
    }

    private fun closeActiveSessionLocked() {
        acceptingWork = false
        val session = activeSession ?: return
        try {
            session.close()
        } finally {
            activeSession = null
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
    ) {
        fun close() {
            try {
                subscription.unsubscribe()
            } finally {
                try {
                    subscription.close()
                } finally {
                    flux.close()
                }
            }
        }
    }

    private class RuntimeEventListener(
        private val events: MutableSharedFlow<CoreEvent>,
    ) : EventListener {
        override fun onEvent(event: CoreEvent) {
            events.tryEmit(event)
        }
    }
}

internal object CoreRuntimeExecutionPolicy {
    const val LOCAL_WORKERS = 2
    const val REMOTE_WORKERS = 1
    const val EVENT_BUFFER_CAPACITY = 64
}
