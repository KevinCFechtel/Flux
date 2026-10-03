package de.circledev.fluxnews.nativeapp

internal data class AndroidScrolloverVisibleRow(
    val articleId: Long,
    val index: Int,
    val offset: Int,
    val size: Int,
)

internal data class AndroidScrolloverGeometrySample(
    val firstVisibleIndex: Int,
    val firstVisibleScrollOffset: Int,
    val viewportStartOffset: Int,
    val viewportEndOffset: Int,
    val visibleRows: List<AndroidScrolloverVisibleRow>,
)

/**
 * Compose-native Scrollover detector.
 *
 * Only a user drag starts a qualifying session. The session remains active through the fling and
 * ends when the LazyList becomes idle. Programmatic movement therefore never starts qualification.
 * An article must have actually intersected the viewport during the current user session before a
 * later forward crossing can emit it.
 */
internal class AndroidScrolloverTracker {
    private val orderedIds = mutableListOf<Long>()
    private val positions = mutableMapOf<Long, Int>()
    private val qualifiedIds = linkedSetOf<Long>()
    private val emittedIds = mutableSetOf<Long>()
    private var previousPosition: ScrollPosition? = null
    private var previousVisibleSizes: Map<Long, Int> = emptyMap()
    private var previousViewport: Pair<Int, Int>? = null
    private var userScrollActive = false

    fun updateSnapshot(ids: List<Long>) {
        if (ids.size == orderedIds.size && ids.indices.all { ids[it] == orderedIds[it] }) return

        val previousSize = orderedIds.size
        val appendOnly = ids.size >= previousSize &&
            (0 until previousSize).all { ids[it] == orderedIds[it] }

        if (appendOnly) {
            for (index in previousSize until ids.size) {
                val id = ids[index]
                orderedIds += id
                positions[id] = index
            }
            return
        }

        orderedIds.clear()
        orderedIds.addAll(ids)
        positions.clear()
        ids.forEachIndexed { index, id -> positions[id] = index }
        qualifiedIds.retainAll(positions.keys)
        emittedIds.retainAll(positions.keys)
        invalidateGeometry(clearQualification = true)
    }

    fun beginUserScroll(
        sample: AndroidScrolloverGeometrySample,
        enabled: Boolean,
    ): List<Long> {
        if (!userScrollActive) {
            userScrollActive = true
            rebaseline(sample, enabled)
            return emptyList()
        }

        // A new touch can interrupt an active fling before the geometry collector
        // publishes its latest sample. Preserve the current interaction and process
        // that movement instead of clearing already observed rows.
        return receive(sample, enabled)
    }

    fun endUserScroll() {
        userScrollActive = false
        invalidateGeometry(clearQualification = true)
    }

    fun rearm(articleIds: Collection<Long>) {
        emittedIds.removeAll(articleIds.toSet())
    }

    fun receive(
        sample: AndroidScrolloverGeometrySample,
        enabled: Boolean,
    ): List<Long> {
        if (!userScrollActive) {
            storeGeometry(sample)
            return emptyList()
        }

        val previous = previousPosition
        if (previous == null || hasMaterialLayoutChange(sample)) {
            rebaseline(sample, enabled)
            return emptyList()
        }

        val current = ScrollPosition(sample.firstVisibleIndex, sample.firstVisibleScrollOffset)
        val direction = current.compareTo(previous)
        val candidates = if (enabled && direction > 0) {
            // Only IDs that were actually observed intersecting the viewport may emit.
            // Keeping this strict mirrors the iOS geometry contract and prevents a
            // layout jump or skipped composition from manufacturing read candidates.
            qualifiedIds.asSequence()
                .filter { it !in emittedIds }
                .filter { id -> positions[id]?.let { it < sample.firstVisibleIndex } == true }
                .sortedBy { positions[it] ?: Int.MAX_VALUE }
                .toList()
        } else {
            emptyList()
        }

        if (enabled) {
            qualifyVisible(sample)
        } else {
            qualifiedIds.clear()
        }
        storeGeometry(sample)

        candidates.forEach(emittedIds::add)
        return candidates
    }

    private fun rebaseline(sample: AndroidScrolloverGeometrySample, enabled: Boolean) {
        qualifiedIds.clear()
        if (enabled) qualifyVisible(sample)
        storeGeometry(sample)
    }

    private fun qualifyVisible(sample: AndroidScrolloverGeometrySample) {
        sample.visibleRows.asSequence()
            .filter { row ->
                row.offset + row.size > sample.viewportStartOffset &&
                    row.offset < sample.viewportEndOffset
            }
            .mapTo(qualifiedIds) { it.articleId }
    }

    private fun hasMaterialLayoutChange(sample: AndroidScrolloverGeometrySample): Boolean {
        if (previousViewport != (sample.viewportStartOffset to sample.viewportEndOffset)) return true
        val currentSizes = sample.visibleRows.associate { it.articleId to it.size }
        return previousVisibleSizes.any { (id, size) ->
            currentSizes[id]?.let { it != size } == true
        }
    }

    private fun storeGeometry(sample: AndroidScrolloverGeometrySample) {
        previousPosition = ScrollPosition(sample.firstVisibleIndex, sample.firstVisibleScrollOffset)
        previousVisibleSizes = sample.visibleRows.associate { it.articleId to it.size }
        previousViewport = sample.viewportStartOffset to sample.viewportEndOffset
    }

    private fun invalidateGeometry(clearQualification: Boolean) {
        previousPosition = null
        previousVisibleSizes = emptyMap()
        previousViewport = null
        if (clearQualification) qualifiedIds.clear()
    }

    private data class ScrollPosition(
        val index: Int,
        val offset: Int,
    ) : Comparable<ScrollPosition> {
        override fun compareTo(other: ScrollPosition): Int =
            if (index != other.index) index.compareTo(other.index) else offset.compareTo(other.offset)
    }
}
