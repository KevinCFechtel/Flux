package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidScrolloverTrackerTest {
    @Test
    fun programmaticMovementNeverEmitsCandidates() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))

        tracker.observe(sample(0), scrolling = false, enabled = true)
        assertTrue(tracker.observe(sample(2), scrolling = true, enabled = true).isEmpty())
        assertTrue(tracker.observe(sample(2), scrolling = false, enabled = true).isEmpty())
    }

    @Test
    fun firstArticleEmitsWhenFirstVisibleIndexAdvances() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        assertEquals(
            listOf(1L),
            tracker.observe(sample(1), scrolling = true, enabled = true),
        )
    }

    @Test
    fun firstArticleStillEmitsWhenListMovesBeforeDragStartSignal() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))

        tracker.observe(sample(0), scrolling = false, enabled = true)

        // LazyList starts moving before DragInteraction.Start reaches its collector.
        assertTrue(
            tracker.observe(sample(1), scrolling = true, enabled = true).isEmpty(),
        )

        assertEquals(
            listOf(1L),
            tracker.beginUserScroll(sample(1), enabled = true),
        )
    }

    @Test
    fun slowForwardBackwardForwardRemainsReliable() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        assertEquals(listOf(1L), tracker.observe(sample(1), scrolling = true, enabled = true))
        assertTrue(tracker.observe(sample(0), scrolling = true, enabled = true).isEmpty())
        assertTrue(tracker.observe(sample(1), scrolling = true, enabled = true).isEmpty())
        assertEquals(listOf(2L), tracker.observe(sample(2), scrolling = true, enabled = true))
    }

    @Test
    fun finalIndexChangeBeforeIdleStillEmits() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        assertEquals(
            listOf(1L),
            tracker.observe(sample(1), scrolling = false, enabled = true),
        )
    }

    @Test
    fun rearmedArticleCanEmitAgain() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)
        assertEquals(listOf(1L), tracker.observe(sample(1), scrolling = true, enabled = true))
        tracker.observe(sample(1), scrolling = false, enabled = true)

        tracker.rearm(listOf(1L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        assertEquals(listOf(1L), tracker.observe(sample(1), scrolling = true, enabled = true))
    }

    @Test
    fun appendOnlySnapshotKeepsActiveSession() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L, 5L))

        assertEquals(listOf(1L), tracker.observe(sample(1), scrolling = true, enabled = true))
    }

    @Test
    fun newDragDuringActiveSessionDoesNotResetProgress() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)
        assertEquals(listOf(1L), tracker.observe(sample(1), scrolling = true, enabled = true))

        assertEquals(listOf(2L), tracker.beginUserScroll(sample(2), enabled = true))
    }

    @Test
    fun structuralSnapshotResetStopsOldSession() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.observe(sample(0), scrolling = false, enabled = true)
        tracker.beginUserScroll(sample(0), enabled = true)

        tracker.updateSnapshot(listOf(10L, 11L, 12L))

        assertTrue(tracker.observe(sample(2), scrolling = true, enabled = true).isEmpty())
    }

    @Test
    fun slowReadWriterDoesNotBlockLaterScrolloverCandidates() = runBlocking {
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val writes = mutableListOf<List<Long>>()
        val requests = Channel<AndroidScrolloverMutationRequest>(Channel.UNLIMITED)

        val consumer = launch {
            consumeAndroidScrolloverMutationRequests(
                requests = requests,
                markRead = { ids ->
                    writes += ids
                    if (writes.size == 1) {
                        firstWriteStarted.complete(Unit)
                        releaseFirstWrite.await()
                    }
                    emptyList()
                },
                rearm = {},
                completeInteraction = {},
            )
        }

        requests.send(AndroidScrolloverMutationRequest.MarkRead(listOf(1L)))
        firstWriteStarted.await()
        requests.send(AndroidScrolloverMutationRequest.MarkRead(listOf(2L)))
        releaseFirstWrite.complete(Unit)
        requests.close()
        consumer.join()

        assertEquals(listOf(listOf(1L), listOf(2L)), writes)
    }

    private fun sample(firstVisibleIndex: Int) =
        AndroidScrolloverPositionSample(firstVisibleIndex = firstVisibleIndex)
}
