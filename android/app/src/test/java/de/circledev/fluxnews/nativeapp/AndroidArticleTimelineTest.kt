package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
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
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.FeedIconVariant
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
    fun readEventsPatchVisibleRowsAndIgnoreRetiredSessions() = runBlocking {
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2)),
                    total = 2uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 7L },
            selectionCountLoader = { 1uL },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 6L,
                event = CoreEvent.ArticleReadStateChanged(articleId = 1L, read = true),
            ),
        )
        assertEquals(listOf(1L, 2L), store.state.value.articles.map { it.id })

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 7L,
                event = CoreEvent.ArticleReadStateChanged(articleId = 1L, read = true),
            ),
        )

        assertEquals(listOf(2L), store.state.value.articles.map { it.id })
        assertEquals(1uL, store.state.value.total)
    }

    @Test
    fun unloadedUnreadRemovalRefreshesOnlySelectionTotal() = runBlocking {
        var pageCalls = 0
        var countCalls = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                pageCalls += 1
                ArticlePage(
                    articles = listOf(article(1)),
                    total = 2uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 8L },
            selectionCountLoader = {
                countCalls += 1
                1uL
            },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 8L,
                event = CoreEvent.ArticleReadStateChanged(articleId = 2L, read = true),
            ),
        )

        assertEquals(1, pageCalls)
        assertEquals(1, countCalls)
        assertEquals(listOf(1L), store.state.value.articles.map { it.id })
        assertEquals(1uL, store.state.value.total)
    }

    @Test
    fun allFilterStatusEventsPatchRowsWithoutReloadingTimeline() = runBlocking {
        var pageCalls = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                pageCalls += 1
                ArticlePage(
                    articles = listOf(article(1)),
                    total = 1uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 3L },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(
            scope = AndroidNewsScope.All,
            readFilter = AndroidArticleReadFilter.All,
        )
        store.reset(selection)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 3L,
                event = CoreEvent.ArticleReadStateChanged(articleId = 1L, read = true),
            ),
        )
        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 3L,
                event = CoreEvent.ArticleStarredStateChanged(articleId = 1L, starred = true),
            ),
        )

        assertEquals(1, pageCalls)
        assertTrue(store.state.value.articles.single().isRead)
        assertTrue(store.state.value.articles.single().isStarred)
        assertEquals(1uL, store.state.value.total)
    }

    @Test
    fun filteredReadReentryTriggersOneSnapshotRefresh() = runBlocking {
        var pageCalls = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                pageCalls += 1
                if (pageCalls == 1) {
                    ArticlePage(
                        articles = listOf(article(1)),
                        total = 1uL,
                        nextCursor = null,
                    )
                } else {
                    ArticlePage(
                        articles = listOf(article(1), article(2)),
                        total = 2uL,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { 4L },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 4L,
                event = CoreEvent.ArticleReadStateChanged(articleId = 2L, read = false),
            ),
        )

        assertEquals(2, pageCalls)
        assertEquals(listOf(1L, 2L), store.state.value.articles.map { it.id })
        assertEquals(2uL, store.state.value.total)
    }

    @Test
    fun starredScopeRemovesVisibleRowsAndRefreshesForReentry() = runBlocking {
        var pageCalls = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                pageCalls += 1
                if (pageCalls == 1) {
                    ArticlePage(
                        articles = listOf(article(1, starred = true)),
                        total = 1uL,
                        nextCursor = null,
                    )
                } else {
                    ArticlePage(
                        articles = listOf(article(2, starred = true)),
                        total = 1uL,
                        nextCursor = null,
                    )
                }
            },
            activeSessionGeneration = { 5L },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(
            scope = AndroidNewsScope.Starred,
            readFilter = AndroidArticleReadFilter.All,
        )
        store.reset(selection)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 5L,
                event = CoreEvent.ArticleStarredStateChanged(articleId = 1L, starred = false),
            ),
        )
        assertTrue(store.state.value.articles.isEmpty())
        assertEquals(0uL, store.state.value.total)

        store.handleCoreEvent(
            AndroidCoreRuntimeEvent(
                generation = 5L,
                event = CoreEvent.ArticleStarredStateChanged(articleId = 2L, starred = true),
            ),
        )

        assertEquals(2, pageCalls)
        assertEquals(listOf(2L), store.state.value.articles.map { it.id })
        assertEquals(1uL, store.state.value.total)
    }


    @Test
    fun scrolloverWritesOnlyUnreadVisibleRowsAndKeepsUnreadSnapshotStable() = runBlocking {
        val writes = mutableListOf<Pair<Long, List<Long>>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2, read = true), article(3)),
                    total = 3uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 11L },
            scrolloverReadWriter = { generation, ids -> writes += generation to ids },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)

        val failed = store.markReadFromScrollover(listOf(1L, 2L, 1L, 99L, 3L))

        assertTrue(failed.isEmpty())
        assertEquals(listOf(11L to listOf(1L, 3L)), writes)
        assertEquals(listOf(1L, 2L, 3L), store.state.value.articles.map { it.id })
        assertTrue(store.state.value.articles.first { it.id == 1L }.isRead)
        assertTrue(store.state.value.articles.first { it.id == 3L }.isRead)
        assertEquals(1uL, store.state.value.total)
    }

    @Test
    fun scrolloverPublishesOneConfirmationOnlyAfterInteractionCompletes() = runBlocking {
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2)),
                    total = 2uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 21L },
            scrolloverReadWriter = { _, _ -> },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        val feedback = async(start = CoroutineStart.UNDISPATCHED) { store.feedback.first() }

        assertTrue(store.markReadFromScrollover(listOf(1L)).isEmpty())
        assertTrue(store.markReadFromScrollover(listOf(2L)).isEmpty())
        assertFalse(feedback.isCompleted)

        store.completeScrolloverInteraction()

        assertEquals(
            AndroidTimelineHaptic.Confirmation,
            withTimeout(1_000) { feedback.await() },
        )
    }

    @Test
    fun failedScrolloverDoesNotPublishConfirmation() = runBlocking {
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1)),
                    total = 1uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 22L },
            scrolloverReadWriter = { _, _ -> error("write failed") },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))

        assertEquals(listOf(1L), store.markReadFromScrollover(listOf(1L)))
        store.completeScrolloverInteraction()

        assertNull(withTimeoutOrNull(100) { store.feedback.first() })
    }

    @Test
    fun scrolloverUndoAppearsAfterQualifiedBurstAndRestoresUnreadState() = runBlocking {
        var now = 1_000L
        val unreadWrites = mutableListOf<Pair<Long, List<Long>>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2), article(3)),
                    total = 3uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 31L },
            selectionCountLoader = { 3uL },
            scrolloverReadWriter = { _, _ -> },
            scrolloverUnreadWriter = { generation, ids -> unreadWrites += generation to ids },
            monotonicMillis = { now },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))

        assertTrue(store.markReadFromScrollover(listOf(1L, 2L, 3L)).isEmpty())
        store.completeScrolloverInteraction()

        assertTrue(store.undoState.value.visible)
        assertEquals(listOf(1L, 2L, 3L), store.undoState.value.articleIds)
        assertEquals(0uL, store.state.value.total)

        val feedback = async(start = CoroutineStart.UNDISPATCHED) { store.feedback.first() }
        val restored = store.undoScrollover()

        assertEquals(listOf(1L, 2L, 3L), restored)
        assertEquals(listOf(31L to listOf(1L, 2L, 3L)), unreadWrites)
        assertTrue(store.state.value.articles.none { it.isRead })
        assertEquals(3uL, store.state.value.total)
        assertFalse(store.undoState.value.visible)
        assertEquals(
            AndroidTimelineHaptic.Selection,
            withTimeout(1_000) { feedback.await() },
        )
    }

    @Test
    fun scrolloverUndoDoesNotAppearForSmallBurstAndExpiresAfterInactivity() = runBlocking {
        var now = 2_000L
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2), article(3)),
                    total = 3uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 32L },
            scrolloverReadWriter = { _, _ -> },
            monotonicMillis = { now },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))

        store.markReadFromScrollover(listOf(1L, 2L))
        store.completeScrolloverInteraction()
        assertFalse(store.undoState.value.visible)

        now += 500L
        store.markReadFromScrollover(listOf(3L))
        store.completeScrolloverInteraction()
        assertTrue(store.undoState.value.visible)
        val revision = store.undoState.value.revision

        now = store.undoState.value.expiresAtUptimeMillis!! + 1L
        store.expireScrolloverUndo(revision)

        assertFalse(store.undoState.value.visible)
        assertTrue(store.undoState.value.articleIds.isEmpty())
    }

    @Test
    fun scrolloverUndoIsRejectedAfterSessionReplacement() = runBlocking {
        var generation: Long? = 41L
        var unreadWrites = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2), article(3)),
                    total = 3uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { generation },
            scrolloverReadWriter = { _, _ -> },
            scrolloverUnreadWriter = { _, _ -> unreadWrites += 1 },
            monotonicMillis = { 3_000L },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))
        store.markReadFromScrollover(listOf(1L, 2L, 3L))
        store.completeScrolloverInteraction()
        assertTrue(store.undoState.value.visible)

        generation = 42L
        val restored = store.undoScrollover()

        assertTrue(restored.isEmpty())
        assertEquals(0, unreadWrites)
        assertFalse(store.undoState.value.visible)
    }

    @Test
    fun scrolloverWriteFailureRollsBackOptimisticReadStateAndCount() = runBlocking {
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1), article(2)),
                    total = 2uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 12L },
            scrolloverReadWriter = { _, _ -> error("write failed") },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)

        val failed = store.markReadFromScrollover(listOf(1L))

        assertEquals(listOf(1L), failed)
        assertFalse(store.state.value.articles.first { it.id == 1L }.isRead)
        assertEquals(2uL, store.state.value.total)
    }

    @Test
    fun scrolloverWriteIsRejectedWhenSessionGenerationChanged() = runBlocking {
        var generation: Long? = 13L
        var writes = 0
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1)),
                    total = 1uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { generation },
            scrolloverReadWriter = { _, _ -> writes += 1 },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)
        store.reset(selection)
        generation = 14L

        val failed = store.markReadFromScrollover(listOf(1L))

        assertTrue(failed.isEmpty())
        assertEquals(0, writes)
        assertFalse(store.state.value.articles.single().isRead)
        assertEquals(1uL, store.state.value.total)
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
    fun rowLayoutVariantsMatchCurrentSharedPresentationSemantics() {
        val image = "https://example.test/image.jpg"

        assertEquals(
            AndroidArticleRowLayoutVariant.Compact,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.Compact,
                image,
                390,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualPortrait,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.Visual,
                image,
                390,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualLandscape,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.Visual,
                image,
                700,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualCompactNarrow,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.VisualCompact,
                image,
                390,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualCompactWide,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.VisualCompact,
                image,
                700,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualTextOnly,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.Visual,
                null,
                390,
            ),
        )
        assertEquals(
            AndroidArticleRowLayoutVariant.VisualCompactTextOnly,
            AndroidArticleRowPolicy.layoutVariant(
                AndroidArticlePresentationMode.VisualCompact,
                null,
                390,
            ),
        )
    }

    @Test
    fun feedIconsLoadOncePerUniqueFeedAndThemeVariant() = runBlocking {
        val calls = mutableListOf<Pair<List<Long>, FeedIconVariant>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(
                        article(1),
                        article(2).copy(feedId = 10),
                        article(3).copy(feedId = 11),
                    ),
                    total = 3uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 21L },
            feedIconLoader = { ids, variant ->
                calls += ids to variant
                ids.associateWith { byteArrayOf(it.toByte()) }
            },
            testOnly = Unit,
        )
        store.reset(AndroidArticleTimelineSelection(AndroidNewsScope.All))

        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)
        store.ensureFeedIcon(11L, FeedIconVariant.NORMAL)
        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)
        store.ensureFeedIcon(11L, FeedIconVariant.NORMAL)
        store.ensureFeedIcon(10L, FeedIconVariant.DARK)
        store.ensureFeedIcon(11L, FeedIconVariant.DARK)

        assertEquals(
            listOf(
                listOf(10L) to FeedIconVariant.NORMAL,
                listOf(11L) to FeedIconVariant.NORMAL,
                listOf(10L) to FeedIconVariant.DARK,
                listOf(11L) to FeedIconVariant.DARK,
            ),
            calls,
        )
        assertEquals(FeedIconVariant.DARK, store.state.value.feedIconVariant)
        assertEquals(setOf(10L, 11L), store.state.value.feedIconPngByFeedId.keys)
    }

    @Test
    fun feedIconCacheSurvivesTimelineResetWithinSameSession() = runBlocking {
        val calls = mutableListOf<Pair<List<Long>, FeedIconVariant>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1).copy(feedId = 10)),
                    total = 1uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { 31L },
            feedIconLoader = { ids, variant ->
                calls += ids to variant
                ids.associateWith { byteArrayOf(it.toByte()) }
            },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)

        store.reset(selection)
        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)
        store.reset(selection)
        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)

        assertEquals(
            listOf(listOf(10L) to FeedIconVariant.NORMAL),
            calls,
        )
        assertEquals(setOf(10L), store.state.value.feedIconPngByFeedId.keys)
    }

    @Test
    fun feedIconCacheIsClearedWhenCoreSessionChanges() = runBlocking {
        var generation: Long? = 41L
        val calls = mutableListOf<Pair<List<Long>, FeedIconVariant>>()
        val store = AndroidArticleTimelineStore(
            pageLoader = { _, _ ->
                ArticlePage(
                    articles = listOf(article(1).copy(feedId = 10)),
                    total = 1uL,
                    nextCursor = null,
                )
            },
            activeSessionGeneration = { generation },
            feedIconLoader = { ids, variant ->
                calls += ids to variant
                ids.associateWith { byteArrayOf(it.toByte()) }
            },
            testOnly = Unit,
        )
        val selection = AndroidArticleTimelineSelection(AndroidNewsScope.All)

        store.reset(selection)
        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)

        generation = 42L
        store.reset(selection)
        store.ensureFeedIcon(10L, FeedIconVariant.NORMAL)

        assertEquals(
            listOf(
                listOf(10L) to FeedIconVariant.NORMAL,
                listOf(10L) to FeedIconVariant.NORMAL,
            ),
            calls,
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
