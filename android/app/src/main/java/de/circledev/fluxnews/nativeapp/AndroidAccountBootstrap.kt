package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.InitializationConfig

/** Process-scoped account/session restoration for normal and headless Android startup paths. */
class AndroidAccountBootstrap private constructor(
    private val credentialReader: () -> StoredAccountCredentials?,
    private val hasActiveSession: () -> Boolean,
    private val sessionOpener: (InitializationConfig) -> Unit,
    storagePaths: AndroidStoragePaths,
) {
    internal constructor(
        credentialStore: AndroidCredentialStore,
        coreRuntime: AndroidCoreRuntime,
        storagePaths: AndroidStoragePaths,
    ) : this(
        credentialReader = credentialStore::read,
        hasActiveSession = coreRuntime::hasActiveSession,
        sessionOpener = { config -> coreRuntime.openSession(config) },
        storagePaths = storagePaths,
    )

    internal constructor(
        credentialReader: () -> StoredAccountCredentials?,
        hasActiveSession: () -> Boolean,
        sessionOpener: (InitializationConfig) -> Unit,
        storagePaths: AndroidStoragePaths,
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(credentialReader, hasActiveSession, sessionOpener, storagePaths)

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
        if (hasActiveSession()) {
            return@withLock state
        }

        state = State.Starting
        try {
            val credentials = credentialReader()
            if (credentials == null) {
                state = State.AccountRequired
            } else {
                sessionOpener(configFactory.create(credentials))
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
