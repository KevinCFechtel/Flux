package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.flux_uniffi.SyncReason

class AndroidSyncCoordinatorTest {
    @Test
    fun onlyOneForegroundSyncRunsAtATime() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val coordinator = coordinator { _, _ -> release.await() }

        assertTrue(coordinator.requestSync(SyncReason.APP_START))
        assertFalse(coordinator.requestSync(SyncReason.MANUAL))
        release.complete(Unit)
        awaitTerminal(coordinator)

        assertTrue(coordinator.state.value is AndroidSyncCoordinator.State.Succeeded)
        assertTrue(coordinator.requestSync(SyncReason.MANUAL))
    }

    @Test
    fun cancellationUsesRunScopedHandleAndPublishesCancelled() = runBlocking {
        val release = CompletableDeferred<Unit>()
        var observedHandle: FakeCancellation? = null
        val coordinator = AndroidSyncCoordinator(
            scope = this,
            cancellationFactory = { FakeCancellation().also { observedHandle = it } },
            syncRunner = { _, _ -> release.await() },
            testOnly = Unit,
        )

        assertTrue(coordinator.requestSync(SyncReason.MANUAL))
        assertTrue(coordinator.cancelActiveSync())
        assertTrue(observedHandle?.isCancelled() == true)
        release.complete(Unit)
        awaitTerminal(coordinator)

        assertTrue(coordinator.state.value is AndroidSyncCoordinator.State.Cancelled)
    }

    @Test
    fun userCancellationOnlyCancelsManualRuns() = runBlocking {
        val startupRelease = CompletableDeferred<Unit>()
        var startupHandle: FakeCancellation? = null
        val coordinator = AndroidSyncCoordinator(
            scope = this,
            cancellationFactory = { FakeCancellation().also { startupHandle = it } },
            syncRunner = { _, _ -> startupRelease.await() },
            testOnly = Unit,
        )

        assertTrue(coordinator.requestSync(SyncReason.APP_START))
        assertFalse(coordinator.cancelManualSync())
        assertFalse(startupHandle?.isCancelled() == true)
        startupRelease.complete(Unit)
        awaitTerminal(coordinator)

        val manualRelease = CompletableDeferred<Unit>()
        val manualCoordinator = AndroidSyncCoordinator(
            scope = this,
            cancellationFactory = { FakeCancellation() },
            syncRunner = { _, _ -> manualRelease.await() },
            testOnly = Unit,
        )
        assertTrue(manualCoordinator.requestSync(SyncReason.MANUAL))
        assertTrue(manualCoordinator.cancelManualSync())
        manualRelease.complete(Unit)
        awaitTerminal(manualCoordinator)
        assertTrue(manualCoordinator.state.value is AndroidSyncCoordinator.State.Cancelled)
    }

    @Test
    fun successPresentationIsImmediateAndOnlyDismissesAfterItsGenerationExpires() {
        assertFalse(
            AndroidSyncPresentationPolicy.successVisible(
                state = AndroidSyncCoordinator.State.Syncing(
                    generation = 7L,
                    reason = SyncReason.MANUAL,
                ),
                dismissedGeneration = null,
            ),
        )
        assertTrue(
            AndroidSyncPresentationPolicy.successVisible(
                state = AndroidSyncCoordinator.State.Succeeded(
                    generation = 7L,
                    reason = SyncReason.MANUAL,
                ),
                dismissedGeneration = null,
            ),
        )
        assertFalse(
            AndroidSyncPresentationPolicy.successVisible(
                state = AndroidSyncCoordinator.State.Succeeded(
                    generation = 7L,
                    reason = SyncReason.MANUAL,
                ),
                dismissedGeneration = 7L,
            ),
        )
        assertFalse(
            AndroidSyncPresentationPolicy.successVisible(
                state = AndroidSyncCoordinator.State.Succeeded(
                    generation = 7L,
                    reason = SyncReason.APP_START,
                ),
                dismissedGeneration = null,
            ),
        )
    }

    @Test
    fun failureKeepsARecoverableLocalDataMessage() = runBlocking {
        val coordinator = coordinator { _, _ -> error("token=must-not-leak") }

        assertTrue(coordinator.requestSync(SyncReason.APP_START))
        awaitTerminal(coordinator)

        val state = coordinator.state.value as AndroidSyncCoordinator.State.Failed
        assertEquals("Sync failed. Showing locally stored data.", state.message)
        assertFalse(state.message.contains("must-not-leak"))
    }

    private fun kotlinx.coroutines.CoroutineScope.coordinator(
        runner: suspend (SyncReason, AndroidSyncCancellationHandle) -> Unit,
    ) = AndroidSyncCoordinator(
        scope = this,
        cancellationFactory = { FakeCancellation() },
        syncRunner = runner,
        testOnly = Unit,
    )

    private suspend fun awaitTerminal(coordinator: AndroidSyncCoordinator) {
        repeat(100) {
            if (coordinator.state.value !is AndroidSyncCoordinator.State.Syncing) return
            yield()
        }
        error("Sync did not reach a terminal state")
    }

    private class FakeCancellation : AndroidSyncCancellationHandle {
        private var cancelled = false

        override fun cancel() {
            cancelled = true
        }

        override fun isCancelled(): Boolean = cancelled
    }
}
