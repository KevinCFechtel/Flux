package de.circledev.fluxnews.nativeapp

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.flux_uniffi.InitializationConfig

class AndroidAccountBootstrapTest {
    @Test
    fun missingCredentialsRequireAccountWithoutOpeningCore() = withPaths { paths ->
        var opened = false
        val bootstrap = bootstrap(paths, credentialReader = { null }) { opened = true }

        val state = runBlocking { bootstrap.restoreStoredAccount() }

        assertEquals(AndroidAccountBootstrap.State.AccountRequired, state)
        assertFalse(opened)
    }

    @Test
    fun storedCredentialsOpenCanonicalCoreSession() = withPaths { paths ->
        val credentials = StoredAccountCredentials(
            serverUrl = "https://miniflux.example/subpath",
            apiKey = "secret",
            customHeaders = listOf(StoredCredentialHeader("X-Tenant", "tenant-secret")),
        )
        var opened: InitializationConfig? = null
        val bootstrap = bootstrap(paths, credentialReader = { credentials }) { opened = it }

        val state = runBlocking { bootstrap.restoreStoredAccount() }

        assertEquals(AndroidAccountBootstrap.State.Ready(credentials.serverUrl), state)
        assertEquals(paths.persistentData.absolutePath, opened?.persistentData)
        assertEquals(paths.cache.absolutePath, opened?.cache)
        assertEquals(paths.media.absolutePath, opened?.media)
        assertEquals(credentials.serverUrl, opened?.baseUrl)
        assertEquals(credentials.apiKey, opened?.apiKey)
        assertEquals("X-Tenant", opened?.customHeaders?.single()?.name)
        assertEquals("tenant-secret", opened?.customHeaders?.single()?.value)
    }

    @Test
    fun credentialFailureIsRecoverableAndDoesNotExposeSecret() = withPaths { paths ->
        val secret = "must-not-leak"
        val bootstrap = bootstrap(
            paths,
            credentialReader = { throw CredentialStorageException("failed: $secret") },
        ) { error("Core must not open") }

        val state = runBlocking { bootstrap.restoreStoredAccount() }

        assertTrue(state is AndroidAccountBootstrap.State.RecoverableError)
        val message = (state as AndroidAccountBootstrap.State.RecoverableError).message
        assertEquals("Stored account credentials could not be read.", message)
        assertFalse(message.contains(secret))
    }

    @Test
    fun existingSessionIsNotOpenedAgain() = withPaths { paths ->
        var opens = 0
        val bootstrap = AndroidAccountBootstrap(
            credentialReader = { error("Credentials must not be reread") },
            hasActiveSession = { true },
            sessionOpener = { opens += 1 },
            storagePaths = paths,
            testOnly = Unit,
        )

        val state = runBlocking { bootstrap.restoreStoredAccount() }

        assertEquals(AndroidAccountBootstrap.State.Starting, state)
        assertEquals(0, opens)
    }

    private fun bootstrap(
        paths: AndroidStoragePaths,
        credentialReader: () -> StoredAccountCredentials?,
        sessionOpener: (InitializationConfig) -> Unit,
    ) = AndroidAccountBootstrap(
        credentialReader = credentialReader,
        hasActiveSession = { false },
        sessionOpener = sessionOpener,
        storagePaths = paths,
        testOnly = Unit,
    )

    private fun withPaths(block: (AndroidStoragePaths) -> Unit) {
        val root = Files.createTempDirectory("flux-account-bootstrap").toFile()
        try {
            val noBackup = File(root, "no-backup").also { check(it.mkdirs()) }
            val cache = File(root, "cache").also { check(it.mkdirs()) }
            block(AndroidStoragePaths.fromDirectories(noBackup, cache))
        } finally {
            root.deleteRecursively()
        }
    }
}
