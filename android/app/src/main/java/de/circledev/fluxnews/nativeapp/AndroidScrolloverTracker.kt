package de.circledev.fluxnews.nativeapp

internal data class AndroidScrolloverPositionSample(
    val firstVisibleIndex: Int,
)

/**
 * Lightweight Compose-native Scrollover detector.
 *
 * A real user drag starts the session and the session remains active through the
 * following fling until LazyList becomes idle. During that session an article is
 * considered crossed as soon as the first-visible item index advances beyond it.
 *
 * This deliberately favors reliability over proving that every crossed row was
 * independently sampled as visible. Programmatic list movement never starts a
 * session, and reverse movement never emits candidates.
 */
internal class AndroidScrolloverTracker {
    private val orderedIds = mutableListOf<Long>()
    private val emittedIds = mutableSetOf<Long>()
    private var previousFirstVisibleIndex: Int? = null
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
        previousFirstVisibleIndex = null
        userScrollActive = false
    }

    fun beginUserScroll(
        sample: AndroidScrolloverPositionSample,
        enabled: Boolean,
    ): List<Long> {
        if (!enabled) {
            endUserScroll()
            return emptyList()
        }

        if (!userScrollActive) {
            userScrollActive = true
            previousFirstVisibleIndex = sample.firstVisibleIndex
            return emptyList()
        }

        return receive(sample, enabled = true)
    }

    fun endUserScroll() {
        userScrollActive = false
        previousFirstVisibleIndex = null
    }

    fun rearm(articleIds: Collection<Long>) {
        emittedIds.removeAll(articleIds.toSet())
    }

    fun receive(
        sample: AndroidScrolloverPositionSample,
        enabled: Boolean,
    ): List<Long> {
        if (!userScrollActive) {
            previousFirstVisibleIndex = sample.firstVisibleIndex
            return emptyList()
        }

        if (!enabled) {
            previousFirstVisibleIndex = sample.firstVisibleIndex
            return emptyList()
        }

        val previousIndex = previousFirstVisibleIndex
        val currentIndex = sample.firstVisibleIndex
        previousFirstVisibleIndex = currentIndex

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
