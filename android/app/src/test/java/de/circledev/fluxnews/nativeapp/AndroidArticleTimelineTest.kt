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
    fun pageCompletionFromRetiredCoreSessionCannotOverwriteNewSessionSnapshot() = runBlocking {
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
                when (call) {
                    1 -> ArticlePage(
                        articles = listOf(article(1)),
                        total = 2uL,
                        nextCursor = cursor,
                    )
                    2 -> {
                        assertFalse(includeTotal)
                        pageStarted.complete(Unit)
                        releasePage.await()
                        ArticlePage(
                            articles = listOf(article(2)),
                            total = null,
                            nextCursor = null,
                        )
                    }
                    else -> ArticlePage(
                        articles = listOf(article(9)),
                        total = 1uL,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { sessionGeneration },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)

        store.reset(selection)
        val staleAppend = async { store.loadNextPage() }
        pageStarted.await()

        sessionGeneration = 4
        store.reset(selection)
        releasePage.complete(Unit)
        staleAppend.await()

        assertEquals(3, call)
        assertEquals(listOf(9L), store.state.value.articles.map { it.id })
        assertEquals(1uL, store.state.value.total)
        assertNull(store.state.value.nextCursor)
        assertFalse(store.state.value.loadingNextPage)
        assertEquals(2L, store.state.value.queryGeneration)
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


    @Test
    fun rowPolicyPreservesSemanticAccessoryOrderAndImageModes() {
        val article = article(
            id = 7,
            read = false,
            starred = true,
            commentsUrl = "https://example.test/comments",
            imageUrl = "https://example.test/image.jpg",
        )

        assertEquals(
            listOf(
                AndroidArticleAccessory.Unread,
                AndroidArticleAccessory.Star,
                AndroidArticleAccessory.Comments,
                AndroidArticleAccessory.Audio,
            ),
            AndroidArticleRowPolicy.accessories(article, hasAudio = true),
        )
        assertFalse(
            AndroidArticleRowPolicy.showsImage(
                AndroidArticlePresentationMode.Compact,
                article.imageUrl,
            ),
        )
        assertTrue(
            AndroidArticleRowPolicy.showsImage(
                AndroidArticlePresentationMode.Visual,
                article.imageUrl,
            ),
        )
        assertTrue(
            AndroidArticleRowPolicy.showsImage(
                AndroidArticlePresentationMode.VisualCompact,
                article.imageUrl,
            ),
        )
        assertFalse(
            AndroidArticleRowPolicy.showsImage(
                AndroidArticlePresentationMode.Visual,
                null,
            ),
        )
    }

    @Test
    fun audioProjectionIsBatchedOncePerLoadedPage() = runBlocking {
        val cursor = ArticleCursor(
            publishedAt = "2026-10-01T10:00:00Z",
            articleId = 2,
        )
        val audioCalls = mutableListOf<List<Long>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, includeTotal ->
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
            activeSessionGeneration = { 12L },
            audioArticleIdsLoader = { ids ->
                audioCalls += ids
                ids.filterTo(mutableSetOf()) { it % 2L == 1L }
            },
            testOnly = Unit,
        )

        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        store.loadNextPage()

        assertEquals(listOf(listOf(1L, 2L), listOf(3L)), audioCalls)
        assertEquals(setOf(1L, 3L), store.state.value.audioArticleIds)
    }

    @Test
    fun publishedAtParserAcceptsRfc3339Offsets() {
        assertEquals(
            1_759_320_000_000L,
            parseArticlePublishedAtMillis("2025-10-01T12:00:00Z"),
        )
        assertEquals(
            parseArticlePublishedAtMillis("2025-10-01T12:00:00Z"),
            parseArticlePublishedAtMillis("2025-10-01T14:00:00+02:00"),
        )
        assertNull(parseArticlePublishedAtMillis("not-a-date"))
    }

    private fun article(
        id: Long,
        read: Boolean = false,
        starred: Boolean = false,
        commentsUrl: String = "",
        imageUrl: String? = null,
    ): ArticleSummary = ArticleSummary(
        id = id,
        feedId = 10,
        categoryId = 20,
        feedTitle = "Feed",
        title = "Article $id",
        url = "https://example.test/$id",
        commentsUrl = commentsUrl,
        publishedAt = "2026-10-01T12:00:00Z",
        isRead = read,
        isStarred = starred,
        readingTimeMinutes = 3u,
        preview = "Preview",
        imageUrl = imageUrl,
    )
}
