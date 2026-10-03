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

        tracker.receive(sample(first = 0, offset = 0, visible = rows(0, 1L, 2L, 3L)), enabled = true)
        val emitted = tracker.receive(
            sample(first = 2, offset = 10, visible = rows(2, 3L)),
            enabled = true,
        )

        assertTrue(emitted.isEmpty())
    }

    @Test
    fun forwardCrossingEmitsOnlyPreviouslyVisibleRowsOnce() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L, 5L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L, 3L)),
            enabled = true,
        )

        val first = tracker.receive(
            sample(first = 1, offset = 10, visible = rows(1, 2L, 3L, 4L)),
            enabled = true,
        )
        val fast = tracker.receive(
            sample(first = 4, offset = 5, visible = rows(4, 5L)),
            enabled = true,
        )

        assertEquals(listOf(1L), first)
        assertEquals(listOf(2L, 3L, 4L), fast)
        assertTrue(
            tracker.receive(
                sample(first = 4, offset = 20, visible = rows(4, 5L)),
                enabled = true,
            ).isEmpty(),
        )
    }

    @Test
    fun rearmedArticleCanEmitAgainAfterBecomingUnread() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )

        assertEquals(
            listOf(1L),
            tracker.receive(
                sample(first = 1, offset = 5, visible = rows(1, 2L, 3L)),
                enabled = true,
            ),
        )
        tracker.endUserScroll()
        tracker.rearm(listOf(1L))

        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )
        assertEquals(
            listOf(1L),
            tracker.receive(
                sample(first = 1, offset = 5, visible = rows(1, 2L, 3L)),
                enabled = true,
            ),
        )
    }

    @Test
    fun skippedIntermediateRowsStillEmitDuringForwardJump() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L, 5L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )

        val emitted = tracker.receive(
            sample(first = 3, offset = 10, visible = rows(3, 4L, 5L)),
            enabled = true,
        )

        assertEquals(listOf(1L, 2L, 3L), emitted)
    }

    @Test
    fun newDragDuringActiveScrollPreservesObservedRows() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L, 4L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )
        tracker.receive(
            sample(first = 1, offset = 10, visible = rows(1, 2L, 3L)),
            enabled = true,
        )

        val emittedOnRetouch = tracker.beginUserScroll(
            sample(first = 2, offset = 5, visible = rows(2, 3L, 4L)),
            enabled = true,
        )

        assertEquals(listOf(2L), emittedOnRetouch)
    }

    @Test
    fun reverseMovementNeverEmitsAndQualificationSurvivesDirectionChange() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 20, visible = rows(0, 1L, 2L)),
            enabled = true,
        )

        assertTrue(
            tracker.receive(
                sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
                enabled = true,
            ).isEmpty(),
        )
        assertEquals(
            listOf(1L),
            tracker.receive(
                sample(first = 1, offset = 5, visible = rows(1, 2L, 3L)),
                enabled = true,
            ),
        )
    }

    @Test
    fun layoutChangeRebaselinesInsteadOfManufacturingCrossing() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )

        val resized = AndroidScrolloverGeometrySample(
            firstVisibleIndex = 1,
            firstVisibleScrollOffset = 5,
            viewportStartOffset = 0,
            viewportEndOffset = 250,
            visibleRows = listOf(
                AndroidScrolloverVisibleRow(2L, 1, 0, 120),
                AndroidScrolloverVisibleRow(3L, 2, 120, 120),
            ),
        )

        assertTrue(tracker.receive(resized, enabled = true).isEmpty())
    }

    @Test
    fun structuralSnapshotResetDropsOldQualification() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )

        tracker.updateSnapshot(listOf(10L, 11L, 12L))
        val emitted = tracker.receive(
            sample(first = 2, offset = 5, visible = rows(2, 12L)),
            enabled = true,
        )

        assertTrue(emitted.isEmpty())
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

    @Test
    fun endingUserScrollClearsQualification() {
        val tracker = AndroidScrolloverTracker()
        tracker.updateSnapshot(listOf(1L, 2L, 3L))
        tracker.beginUserScroll(
            sample(first = 0, offset = 0, visible = rows(0, 1L, 2L)),
            enabled = true,
        )
        tracker.endUserScroll()

        assertTrue(
            tracker.receive(
                sample(first = 2, offset = 0, visible = rows(2, 3L)),
                enabled = true,
            ).isEmpty(),
        )
    }

    private fun sample(
        first: Int,
        offset: Int,
        visible: List<AndroidScrolloverVisibleRow>,
    ) = AndroidScrolloverGeometrySample(
        firstVisibleIndex = first,
        firstVisibleScrollOffset = offset,
        viewportStartOffset = 0,
        viewportEndOffset = 250,
        visibleRows = visible,
    )

    private fun rows(startIndex: Int, vararg ids: Long): List<AndroidScrolloverVisibleRow> =
        ids.mapIndexed { offset, id ->
            AndroidScrolloverVisibleRow(
                articleId = id,
                index = startIndex + offset,
                offset = offset * 100,
                size = 100,
            )
        }
}
