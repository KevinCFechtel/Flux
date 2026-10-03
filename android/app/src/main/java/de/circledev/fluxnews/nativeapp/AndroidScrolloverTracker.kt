package de.circledev.fluxnews.nativeapp

internal data class AndroidScrolloverPositionSample(
    val firstVisibleIndex: Int,
)

/**
 * Lightweight Compose-native Scrollover detector.
 *
 * The tracker keeps an idle baseline separate from an active user-scroll baseline.
 * LazyList position changes and DragInteraction.Start are delivered independently,
 * so an index change that arrives just before the drag event must not overwrite the
 * last idle position. Programmatic scrolling never activates the user-scroll phase.
 */
internal class AndroidScrolloverTracker {
    private val orderedIds = mutableListOf<Long>()
    private val emittedIds = mutableSetOf<Long>()
    private var baselineFirstVisibleIndex: Int? = null
    private var userScrollActive = false

    fun updateSnapshot(ids: List<Long>) {
        if (ids.size == orderedIds.size && ids.indices.all { ids[it] == orderedIds[it] }) return

        val previousSize = orderedIds.size
        val appendOnly = ids.size >= previousSize &&
            (0 until previousSize).all { ids[it] == orderedIds[it] }

        if (appendOnly) {
            for (index in previousSize until ids.size) {
                orderedIds += ids[index]
            }
            return
        }

        orderedIds.clear()
        orderedIds.addAll(ids)
        emittedIds.retainAll(ids.toSet())
        baselineFirstVisibleIndex = null
        userScrollActive = false
    }

    fun beginUserScroll(
        sample: AndroidScrolloverPositionSample,
        enabled: Boolean,
    ): List<Long> {
        if (!enabled) {
            userScrollActive = false
            return emptyList()
        }

        if (userScrollActive) {
            return emitForwardCrossings(sample.firstVisibleIndex)
        }

        userScrollActive = true
        if (baselineFirstVisibleIndex == null) {
            baselineFirstVisibleIndex = sample.firstVisibleIndex
            return emptyList()
        }
        return emitForwardCrossings(sample.firstVisibleIndex)
    }

    fun observe(
        sample: AndroidScrolloverPositionSample,
        scrolling: Boolean,
        enabled: Boolean,
    ): List<Long> {
        val currentIndex = sample.firstVisibleIndex

        if (!enabled) {
            userScrollActive = false
            if (!scrolling) baselineFirstVisibleIndex = currentIndex
            return emptyList()
        }

        if (!scrolling) {
            val candidates = if (userScrollActive) {
                emitForwardCrossings(currentIndex)
            } else {
                emptyList()
            }
            userScrollActive = false
            baselineFirstVisibleIndex = currentIndex
            return candidates
        }

        if (!userScrollActive) {
            // Movement can arrive before DragInteraction.Start, or it can be
            // programmatic. Keep the previous idle baseline intact so the former
            // is not lost; without a user drag we emit nothing.
            return emptyList()
        }

        return emitForwardCrossings(currentIndex)
    }

    fun rearm(articleIds: Collection<Long>) {
        emittedIds.removeAll(articleIds.toSet())
    }

    private fun emitForwardCrossings(currentIndex: Int): List<Long> {
        val previousIndex = baselineFirstVisibleIndex
        baselineFirstVisibleIndex = currentIndex
        if (previousIndex == null || currentIndex <= previousIndex) return emptyList()

        val start = previousIndex.coerceAtLeast(0)
        val endExclusive = currentIndex.coerceAtMost(orderedIds.size)
        if (start >= endExclusive) return emptyList()

        val candidates = buildList {
            for (index in start until endExclusive) {
                val id = orderedIds[index]
                if (id !in emittedIds) add(id)
            }
        }
        emittedIds.addAll(candidates)
        return candidates
    }
}
