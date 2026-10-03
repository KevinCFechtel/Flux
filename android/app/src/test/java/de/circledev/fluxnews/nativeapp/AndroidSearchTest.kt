package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.flux_uniffi.ArticleSummary
import uniffi.flux_uniffi.SearchArticlesResult

class AndroidSearchTest {
    @Test
    fun paginationUsesResultCountAndDeduplicates() {
        assertEquals(0L, AndroidSearchPaginationPolicy.nextOffset(0, 10))
        assertEquals(7L, AndroidSearchPaginationPolicy.nextOffset(7, 10))
        assertEquals(null, AndroidSearchPaginationPolicy.nextOffset(10, 10))
        assertEquals(
            listOf(1L, 2L),
            AndroidSearchPaginationPolicy.deduplicated(
                listOf(article(1), article(1), article(2)),
            ).map { it.id },
        )
    }

    @Test
    fun newerSearchSuppressesOlderCompletion() = runBlocking {
        val firstRelease = CompletableDeferred<Unit>()
        val store = AndroidSearchStore(
            searchLoader = { _, request ->
                if (request.query == "first") {
                    firstRelease.await()
                    SearchArticlesResult(1, listOf(article(1)))
                } else {
                    SearchArticlesResult(1, listOf(article(2)))
                }
            },
            activeSessionGeneration = { 9L },
            testOnly = Unit,
        )
        store.activateSession(9L)
        store.setQuery("first")
        store.submit()
        repeat(10) { yield() }
        store.setQuery("second")
        store.submit()
        repeat(10) { yield() }
        firstRelease.complete(Unit)
        repeat(10) { yield() }

        assertEquals("second", store.state.value.submittedQuery)
        assertEquals(listOf(2L), store.state.value.results.map { it.id })
    }

    @Test
    fun failedReadMutationRollsBackOptimisticState() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val store = AndroidSearchStore(
            searchLoader = { _, _ -> SearchArticlesResult(1, listOf(article(1))) },
            readWriter = { _, _, _ ->
                started.complete(Unit)
                release.await()
                error("expected")
            },
            activeSessionGeneration = { 10L },
            testOnly = Unit,
        )
        store.activateSession(10L)
        store.setQuery("article")
        store.submit()
        store.state.first { !it.searching && it.results.size == 1 }

        val mutation = async {
            store.setReadExplicit(1L, true)
        }
        started.await()
        assertTrue(store.state.value.results.single().isRead)

        release.complete(Unit)
        assertFalse(mutation.await())
        assertFalse(store.state.value.results.single().isRead)
    }

    private fun article(id: Long) = ArticleSummary(
        id = id,
        feedId = 10L,
        categoryId = 20L,
        feedTitle = "Feed",
        title = "Article",
        url = "https://example.test/article",
        commentsUrl = "",
        publishedAt = "2026-10-03T00:00:00Z",
        isRead = false,
        isStarred = false,
        readingTimeMinutes = 3u,
        preview = "Preview",
        imageUrl = null,
    )
}
