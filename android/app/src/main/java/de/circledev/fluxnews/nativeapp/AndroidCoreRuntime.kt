package de.circledev.fluxnews.nativeapp

import android.os.Looper
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.channels.BufferOverflow
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.EventListener
import uniffi.flux_uniffi.EventSubscription
import uniffi.flux_uniffi.Flux
import uniffi.flux_uniffi.InitializationConfig

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

    suspend fun openSession(config: InitializationConfig): Long = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    check(activeSession == null) { "A Core session is already active." }
                    installSession(config)
                } finally {
                    unlock()
                }
            }
        }
    }

    suspend fun replaceSession(config: InitializationConfig): Long = lifecycleMutex.withLock {
        withContext(remoteDispatcher) {
            requireOffMainThread()
            sessionLock.writeLock().run {
                lock()
                try {
                    closeActiveSessionLocked()
                    installSession(config)
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

    private fun installSession(config: InitializationConfig): Long {
        val flux = Flux.initialize(config)
        try {
            val subscription = flux.subscribeEvents(RuntimeEventListener(_events))
            val generation = ++nextGeneration
            activeSession = CoreSession(generation, config, flux, subscription)
            acceptingWork = true
            return generation
        } catch (error: Throwable) {
            flux.close()
            throw error
        }
    }

    private fun closeActiveSessionLocked() {
        // The write lock excludes calls that already captured the Flux object and blocks new ones.
        acceptingWork = false
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
