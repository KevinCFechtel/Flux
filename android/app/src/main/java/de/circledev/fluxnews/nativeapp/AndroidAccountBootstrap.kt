package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.AccountValidationResult
import uniffi.flux_uniffi.HttpHeader
import uniffi.flux_uniffi.InitializationConfig

/** Process-scoped account/session lifecycle for normal and headless Android startup paths. */
class AndroidAccountBootstrap private constructor(
    private val credentialReader: () -> StoredAccountCredentials?,
    private val credentialWriter: (StoredAccountCredentials) -> Unit,
    private val hasActiveSession: () -> Boolean,
    private val sessionOpener: suspend (InitializationConfig) -> Unit,
    private val sessionReplacer: suspend (InitializationConfig) -> Unit,
    private val accountValidator: suspend (String, String, List<HttpHeader>) -> AccountValidationResult,
    storagePaths: AndroidStoragePaths,
) {
    internal constructor(
        credentialStore: AndroidCredentialStore,
        coreRuntime: AndroidCoreRuntime,
        storagePaths: AndroidStoragePaths,
    ) : this(
        credentialReader = credentialStore::read,
        credentialWriter = credentialStore::write,
        hasActiveSession = coreRuntime::hasActiveSession,
        sessionOpener = { config -> coreRuntime.openSession(config) },
        sessionReplacer = { config -> coreRuntime.replaceSession(config) },
        accountValidator = coreRuntime::validateAccount,
        storagePaths = storagePaths,
    )

    internal constructor(
        credentialReader: () -> StoredAccountCredentials?,
        credentialWriter: (StoredAccountCredentials) -> Unit = {},
        hasActiveSession: () -> Boolean,
        sessionOpener: suspend (InitializationConfig) -> Unit,
        sessionReplacer: suspend (InitializationConfig) -> Unit = {},
        accountValidator: suspend (String, String, List<HttpHeader>) -> AccountValidationResult =
            { _, _, _ -> error("Account validation was not configured for this test.") },
        storagePaths: AndroidStoragePaths,
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(
        credentialReader,
        credentialWriter,
        hasActiveSession,
        sessionOpener,
        sessionReplacer,
        accountValidator,
        storagePaths,
    )

    sealed interface State {
        data object Starting : State
        data object AccountRequired : State
        data class Ready(val serverUrl: String, val serverVersion: String? = null) : State
        data class RecoverableError(val message: String) : State
    }

    sealed interface ActivationResult {
        data class Activated(val serverUrl: String, val serverVersion: String) : ActivationResult
        data class Rejected(val message: String) : ActivationResult
    }

    private val configFactory = AndroidInitializationConfigFactory(storagePaths)
    private val lifecycleMutex = Mutex()

    @Volatile
    var state: State = State.Starting
        private set

    /**
     * Restores the one stored account after process start. Concurrent lifecycle callers serialize
     * here so Activity recreation, future Workers, and services cannot create competing sessions.
     */
    suspend fun restoreStoredAccount(): State = lifecycleMutex.withLock {
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

    /**
     * Validates candidates before persistence, stores the canonical installation base returned by
     * Core, then activates it. Failed activation restores the previous credential envelope and the
     * rollback-safe runtime keeps the previous session active.
     */
    suspend fun activateAccount(
        serverUrl: String,
        apiKey: String,
        customHeaders: List<StoredCredentialHeader>,
    ): ActivationResult = lifecycleMutex.withLock {
        val proposedServer = serverUrl.trim()
        val proposedApiKey = apiKey.trim()
        if (proposedServer.isEmpty() || proposedApiKey.isEmpty()) {
            return@withLock ActivationResult.Rejected("Enter both a Miniflux server URL and API key.")
        }

        val headers = customHeaders.map { HttpHeader(name = it.name, value = it.value) }
        val validation = try {
            accountValidator(proposedServer, proposedApiKey, headers)
        } catch (_: Exception) {
            return@withLock ActivationResult.Rejected("The Miniflux account could not be validated.")
        }

        val normalized = StoredAccountCredentials(
            serverUrl = validation.installationBase,
            apiKey = proposedApiKey,
            customHeaders = customHeaders,
        )
        val previous = try {
            credentialReader()
        } catch (_: Exception) {
            return@withLock ActivationResult.Rejected("The existing account credentials could not be read.")
        }

        try {
            credentialWriter(normalized)
            try {
                val config = configFactory.create(normalized)
                if (hasActiveSession()) sessionReplacer(config) else sessionOpener(config)
            } catch (error: Exception) {
                previous?.let(credentialWriter)
                throw error
            }
        } catch (_: Exception) {
            return@withLock ActivationResult.Rejected(
                "The account could not be activated. Your previous account is still active.",
            )
        }

        state = State.Ready(normalized.serverUrl, validation.version)
        ActivationResult.Activated(normalized.serverUrl, validation.version)
    }

    private fun safeStartupMessage(error: Exception): String = when (error) {
        is CredentialStorageException -> "Stored account credentials could not be read."
        else -> "The stored account could not be started."
    }
}
