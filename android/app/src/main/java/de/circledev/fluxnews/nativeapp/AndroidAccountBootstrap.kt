package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Process-scoped account/session restoration for normal and headless Android startup paths. */
class AndroidAccountBootstrap internal constructor(
    private val credentialStore: AndroidCredentialStore,
    private val coreRuntime: AndroidCoreRuntime,
    storagePaths: AndroidStoragePaths,
) {
    sealed interface State {
        data object Starting : State
        data object AccountRequired : State
        data class Ready(val serverUrl: String) : State
        data class RecoverableError(val message: String) : State
    }

    private val configFactory = AndroidInitializationConfigFactory(storagePaths)
    private val bootstrapMutex = Mutex()

    @Volatile
    var state: State = State.Starting
        private set

    /**
     * Restores the one stored account after process start. Concurrent callers serialize here so
     * Activity recreation, future Workers, and services cannot create competing Core sessions.
     */
    suspend fun restoreStoredAccount(): State = bootstrapMutex.withLock {
        if (coreRuntime.hasActiveSession()) {
            return@withLock state
        }

        state = State.Starting
        try {
            val credentials = credentialStore.read()
            if (credentials == null) {
                state = State.AccountRequired
            } else {
                coreRuntime.openSession(configFactory.create(credentials))
                state = State.Ready(credentials.serverUrl)
            }
        } catch (error: Exception) {
            state = State.RecoverableError(safeStartupMessage(error))
        }
        state
    }

    private fun safeStartupMessage(error: Exception): String = when (error) {
        is CredentialStorageException -> "Stored account credentials could not be read."
        else -> "The stored account could not be started."
    }
}
