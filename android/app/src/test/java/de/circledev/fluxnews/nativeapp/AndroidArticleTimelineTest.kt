package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.flux_uniffi.ArticleCursor
import uniffi.flux_uniffi.ArticlePage
import uniffi.flux_uniffi.ArticleScope
import uniffi.flux_uniffi.ArticleSort
import uniffi.flux_uniffi.ArticleSummary
import uniffi.flux_uniffi.ReadFilter
import uniffi.flux_uniffi.StarredFilter

class AndroidArticleTimelineTest {
    @Test
    fun selectionMapsScopesFiltersSortAndBoundedPageSize() {
        val all = AndroidArticleTimelineSelection(AndroidNewsScope.All).coreQuery()
        assertEquals(ArticleScope.All, all.scope)
        assertEquals(ReadFilter.UNREAD, all.readFilter)
        assertEquals(StarredFilter.ALL, all.starredFilter)
        assertEquals(ArticleSort.OLDEST_FIRST, all.sort)
        assertEquals(64u, all.limit)
        assertNull(all.cursor)

        val starred = AndroidArticleTimelineSelection(
            scope = AndroidNewsScope.Starred,
            readFilter = AndroidArticleReadFilter.All,
            sort = AndroidArticleSortOrder.NewestFirst,
        ).coreQuery()
        assertEquals(ArticleScope.All, starred.scope)
        assertEquals(ReadFilter.ALL, starred.readFilter)
        assertEquals(StarredFilter.STARRED, starred.starredFilter)
        assertEquals(ArticleSort.NEWEST_FIRST, starred.sort)

        val category = AndroidArticleTimelineSelection(
            AndroidNewsScope.Category(7, "Category"),
        ).coreQuery()
        assertEquals(ArticleScope.Category(id = 7), category.scope)

        val cursor = ArticleCursor(
            publishedAt = "2026-10-01T12:00:00Z",
            articleId = 99,
        )
        val feed = AndroidArticleTimelineSelection(
            AndroidNewsScope.Feed(42, 7, "Feed"),
        ).coreQuery(cursor)
        assertEquals(ArticleScope.Feed(id = 42), feed.scope)
        assertEquals(cursor, feed.cursor)
    }

    @Test
    fun firstPageOwnsTotalAndFollowingPageAppendsOnlyNewStableIds() = runBlocking {
        var sessionGeneration: Long? = 4
        val calls = mutableListOf<Pair<Boolean, ArticleCursor?>>()
        val cursor = ArticleCursor(
            publishedAt = "2026-10-01T10:00:00Z",
            articleId = 2,
        )
        val store = AndroidArticleTimelineStore(
            pageLoader = { query, includeTotal ->
                calls += includeTotal to query.cursor
                if (includeTotal) {
                    ArticlePage(
                        articles = listOf(article(1), article(2)),
                        total = 3uL,
                        nextCursor = cursor,
                    )
                } else {
                    ArticlePage(
                        articles = listOf(article(2), article(3)),
                        total = null,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { sessionGeneration },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)

        store.reset(selection)

        assertEquals(listOf(1L, 2L), store.state.value.articles.map { it.id })
        assertEquals(3uL, store.state.value.total)
        assertEquals(cursor, store.state.value.nextCursor)
        assertFalse(store.state.value.initialLoading)

        store.loadNextPage()

        assertEquals(listOf(1L, 2L, 3L), store.state.value.articles.map { it.id })
        assertEquals(3uL, store.state.value.total)
        assertNull(store.state.value.nextCursor)
        assertEquals(listOf(true to null, false to cursor), calls)
        sessionGeneration = null
    }

    @Test
    fun staleFirstPageCannotPublishAfterNewerSelectionReset() = runBlocking {
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var call = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                call += 1
                if (call == 1) {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                    ArticlePage(
                        articles = listOf(article(1)),
                        total = 1uL,
                        nextCursor = null,
                    )
                } else {
                    ArticlePage(
                        articles = listOf(article(2)),
                        total = 1uL,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { 9L },
            testOnly = Unit,
        )

        val oldRequest = async {
            store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        }
        firstStarted.await()

        store.reset(
            AndroidArticleTimelineSelection(
                AndroidNewsScope.Feed(22, 7, "Current"),
            ),
        )
        releaseFirst.complete(Unit)
        oldRequest.await()

        assertEquals(listOf(2L), store.state.value.articles.map { it.id })
        assertEquals(
            AndroidNewsScope.Feed(22, 7, "Current"),
            store.state.value.selection?.scope,
        )
        assertEquals(2L, store.state.value.queryGeneration)
    }

    @Test
    fun pageCompletionFromRetiredCoreSessionIsDiscarded() = runBlocking {
        var sessionGeneration: Long? = 3
        val pageStarted = CompletableDeferred<Unit>()
        val releasePage = CompletableDeferred<Unit>()
        var call = 0
        val cursor = ArticleCursor(
            publishedAt = "2026-10-01T10:00:00Z",
            articleId = 1,
        )
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, includeTotal ->
                call += 1
                if (includeTotal) {
                    ArticlePage(
                        articles = listOf(article(1)),
                        total = 2uL,
                        nextCursor = cursor,
                    )
                } else {
                    pageStarted.complete(Unit)
                    releasePage.await()
                    ArticlePage(
                        articles = listOf(article(2)),
                        total = null,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { sessionGeneration },
            testOnly = Unit,
        )

        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        val append = async { store.loadNextPage() }
        pageStarted.await()

        sessionGeneration = 4
        releasePage.complete(Unit)
        append.await()

        assertEquals(2, call)
        assertEquals(listOf(1L), store.state.value.articles.map { it.id })
        assertEquals(cursor, store.state.value.nextCursor)
        assertFalse(store.state.value.loadingNextPage)
    }

    @Test
    fun repeatedCursorOrDuplicateOnlyPageStopsPagination() = runBlocking {
        val cursor = ArticleCursor(
            publishedAt = "2026-10-01T10:00:00Z",
            articleId = 1,
        )
        var call = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, includeTotal ->
                call += 1
                if (includeTotal) {
                    ArticlePage(
                        articles = listOf(article(1)),
                        total = 2uL,
                        nextCursor = cursor,
                    )
                } else {
                    ArticlePage(
                        articles = listOf(article(1)),
                        total = null,
                        nextCursor = cursor,
                    )
                }
            },
            activeSessionGeneration = { 1L },
            testOnly = Unit,
        )

        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        store.loadNextPage()
        store.loadNextPage()

        assertEquals(2, call)
        assertEquals(listOf(1L), store.state.value.articles.map { it.id })
        assertNull(store.state.value.nextCursor)
        assertTrue(store.state.value.errorMessage == null)
    }

    private fun article(id: Long): ArticleSummary = ArticleSummary(
        id = id,
        feedId = 10,
        categoryId = 20,
        feedTitle = "Feed",
        title = "Article $id",
        url = "https://example.test/$id",
        commentsUrl = "",
        publishedAt = "2026-10-01T12:00:00Z",
        isRead = false,
        isStarred = false,
        readingTimeMinutes = 3u,
        preview = "Preview",
        imageUrl = null,
    )
}
