package de.circledev.fluxnews.nativeapp

import android.os.Build
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.View
import android.text.format.DateUtils
import android.text.format.DateUtils.FORMAT_ABBREV_RELATIVE
import android.text.format.DateUtils.MINUTE_IN_MILLIS
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Date
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.ArticleCursor
import uniffi.flux_uniffi.ArticlePage
import uniffi.flux_uniffi.ArticleQuery
import uniffi.flux_uniffi.ArticleScope
import uniffi.flux_uniffi.ArticleSort
import uniffi.flux_uniffi.ArticleSummary
import uniffi.flux_uniffi.CoreEvent
import uniffi.flux_uniffi.FeedIconVariant
import uniffi.flux_uniffi.MediaKind
import uniffi.flux_uniffi.ReadFilter
import uniffi.flux_uniffi.StarredFilter

private const val ANDROID_ARTICLE_TIMELINE_PAGE_SIZE = 64
private const val ANDROID_ARTICLE_TIMELINE_PREFETCH_DISTANCE = 8
private const val ANDROID_FEED_ICON_RETRY_DELAY_MILLIS = 1_000L
private const val ANDROID_FEED_ICON_MAX_ATTEMPTS = 3
private const val ANDROID_SCROLL_OVER_UNDO_INACTIVITY_MILLIS = 4_000L
private const val ANDROID_SCROLL_OVER_UNDO_MAX_LIFETIME_MILLIS = 15_000L
private const val ANDROID_SCROLL_OVER_UNDO_QUALIFICATION_MILLIS = 1_000L
private const val ANDROID_SCROLL_OVER_UNDO_MIN_READS = 3

internal enum class AndroidArticleReadFilter {
    Unread,
    All,
}

internal enum class AndroidArticleSortOrder {
    OldestFirst,
    NewestFirst,
}

internal enum class AndroidArticleAccessory {
    Unread,
    Star,
    Comments,
    Audio,
}

internal enum class AndroidTimelineHaptic {
    Confirmation,
    Selection,
}

internal data class AndroidScrolloverUndoState(
    val articleIds: List<Long> = emptyList(),
    val revision: Long = 0,
    val expiresAtUptimeMillis: Long? = null,
) {
    val visible: Boolean
        get() = articleIds.size >= ANDROID_SCROLL_OVER_UNDO_MIN_READS
}

internal enum class AndroidArticleRowLayoutVariant {
    Compact,
    VisualTextOnly,
    VisualPortrait,
    VisualLandscape,
    VisualCompactTextOnly,
    VisualCompactNarrow,
    VisualCompactWide,
}

internal object AndroidArticleRowPolicy {
    private const val WIDE_LAYOUT_THRESHOLD_DP = 600

    fun accessories(article: ArticleSummary, hasAudio: Boolean): List<AndroidArticleAccessory> = buildList {
        if (!article.isRead) add(AndroidArticleAccessory.Unread)
        if (article.isStarred) add(AndroidArticleAccessory.Star)
        if (article.commentsUrl.isNotBlank()) add(AndroidArticleAccessory.Comments)
        if (hasAudio) add(AndroidArticleAccessory.Audio)
    }

    fun showsImage(mode: AndroidArticlePresentationMode, imageUrl: String?): Boolean =
        mode != AndroidArticlePresentationMode.Compact && !imageUrl.isNullOrBlank()

    fun layoutVariant(
        mode: AndroidArticlePresentationMode,
        imageUrl: String?,
        availableWidthDp: Int,
    ): AndroidArticleRowLayoutVariant {
        val hasImage = showsImage(mode, imageUrl)
        val wide = availableWidthDp > WIDE_LAYOUT_THRESHOLD_DP
        return when (mode) {
            AndroidArticlePresentationMode.Compact -> AndroidArticleRowLayoutVariant.Compact
            AndroidArticlePresentationMode.Visual -> when {
                !hasImage -> AndroidArticleRowLayoutVariant.VisualTextOnly
                wide -> AndroidArticleRowLayoutVariant.VisualLandscape
                else -> AndroidArticleRowLayoutVariant.VisualPortrait
            }
            AndroidArticlePresentationMode.VisualCompact -> when {
                !hasImage -> AndroidArticleRowLayoutVariant.VisualCompactTextOnly
                wide -> AndroidArticleRowLayoutVariant.VisualCompactWide
                else -> AndroidArticleRowLayoutVariant.VisualCompactNarrow
            }
        }
    }
}

internal fun parseArticlePublishedAtMillis(value: String): Long? =
    runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
        .recoverCatching { Instant.parse(value).toEpochMilli() }
        .getOrNull()

/**
 * Transient Article List selection. Scope comes from the app shell while read/sort remain
 * presentation controls; none of this state is persisted as a second domain truth.
 */
internal data class AndroidArticleTimelineSelection(
    val scope: AndroidNewsScope,
    val readFilter: AndroidArticleReadFilter = AndroidArticleReadFilter.Unread,
    val sort: AndroidArticleSortOrder = AndroidArticleSortOrder.OldestFirst,
) {
    fun coreQuery(cursor: ArticleCursor? = null): ArticleQuery {
        val coreScope = when (scope) {
            AndroidNewsScope.All,
            AndroidNewsScope.Starred,
            -> ArticleScope.All
            is AndroidNewsScope.Category -> ArticleScope.Category(id = scope.id)
            is AndroidNewsScope.Feed -> ArticleScope.Feed(id = scope.id)
        }
        return ArticleQuery(
            scope = coreScope,
            readFilter = when (readFilter) {
                AndroidArticleReadFilter.Unread -> ReadFilter.UNREAD
                AndroidArticleReadFilter.All -> ReadFilter.ALL
            },
            starredFilter = if (scope == AndroidNewsScope.Starred) StarredFilter.STARRED else StarredFilter.ALL,
            sort = when (sort) {
                AndroidArticleSortOrder.OldestFirst -> ArticleSort.OLDEST_FIRST
                AndroidArticleSortOrder.NewestFirst -> ArticleSort.NEWEST_FIRST
            },
            limit = ANDROID_ARTICLE_TIMELINE_PAGE_SIZE.toUInt(),
            cursor = cursor,
        )
    }
}

internal data class AndroidArticleTimelineState(
    val selection: AndroidArticleTimelineSelection? = null,
    val articles: List<ArticleSummary> = emptyList(),
    val audioArticleIds: Set<Long> = emptySet(),
    val feedIconVariant: FeedIconVariant? = null,
    val feedIconPngByFeedId: Map<Long, ByteArray> = emptyMap(),
    val total: ULong? = null,
    val nextCursor: ArticleCursor? = null,
    val initialLoading: Boolean = false,
    val loadingNextPage: Boolean = false,
    val errorMessage: String? = null,
    val queryGeneration: Long = 0,
    val sessionGeneration: Long? = null,
) {
    val empty: Boolean
        get() = !initialLoading && articles.isEmpty() && errorMessage == null
}

/**
 * Owns only the visible Timeline snapshot/paging lifecycle. Article records remain Core read models
 * and all synchronous Core work runs through AndroidCoreRuntime's bounded local lane.
 */
internal class AndroidArticleTimelineStore private constructor(
    private val pageLoader: suspend (ArticleQuery, Boolean) -> ArticlePage,
    private val audioArticleIdsLoader: suspend (List<Long>) -> Set<Long>,
    private val selectionCountLoader: suspend (ArticleQuery) -> ULong,
    private val feedIconLoader: suspend (List<Long>, FeedIconVariant) -> Map<Long, ByteArray>,
    private val scrolloverReadWriter: suspend (Long, List<Long>) -> Unit,
    private val scrolloverUnreadWriter: suspend (Long, List<Long>) -> Unit,
    private val activeSessionGeneration: () -> Long?,
    private val monotonicMillis: () -> Long,
) {
    internal constructor(coreRuntime: AndroidCoreRuntime) : this(
        pageLoader = { query, includeTotal ->
            coreRuntime.local { core -> core.articlePage(query, includeTotal) }
        },
        audioArticleIdsLoader = { articleIds ->
            if (articleIds.isEmpty()) {
                emptySet()
            } else {
                coreRuntime.local { core ->
                    core.articleAudioActionStates(articleIds)
                        .asSequence()
                        .filter { projection ->
                            projection.enclosures.any { enclosure -> enclosure.mediaKind == MediaKind.AUDIO }
                        }
                        .mapTo(mutableSetOf()) { projection -> projection.articleId }
                }
            }
        },
        selectionCountLoader = { query ->
            coreRuntime.local { core -> core.countArticles(query) }
        },
        feedIconLoader = { feedIds, variant ->
            coreRuntime.remote { core ->
                feedIds.distinct().mapNotNull { feedId ->
                    core.feedIcon(feedId = feedId, variant = variant)
                        ?.pngData
                        ?.let { png -> feedId to png }
                }.toMap()
            }
        },
        scrolloverReadWriter = { generation, articleIds ->
            coreRuntime.localForGeneration(generation) { core ->
                core.setReadStateBulk(articleIds = articleIds, read = true)
            }
            Unit
        },
        scrolloverUnreadWriter = { generation, articleIds ->
            coreRuntime.localForGeneration(generation) { core ->
                core.setReadStateBulk(articleIds = articleIds, read = false)
            }
            Unit
        },
        activeSessionGeneration = coreRuntime::activeSessionGeneration,
        monotonicMillis = SystemClock::elapsedRealtime,
    )

    internal constructor(
        pageLoader: suspend (ArticleQuery, Boolean) -> ArticlePage,
        activeSessionGeneration: () -> Long?,
        audioArticleIdsLoader: suspend (List<Long>) -> Set<Long> = { emptySet() },
        selectionCountLoader: suspend (ArticleQuery) -> ULong = { 0uL },
        feedIconLoader: suspend (List<Long>, FeedIconVariant) -> Map<Long, ByteArray> = { _, _ -> emptyMap() },
        scrolloverReadWriter: suspend (Long, List<Long>) -> Unit = { _, _ -> },
        scrolloverUnreadWriter: suspend (Long, List<Long>) -> Unit = { _, _ -> },
        monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(
        pageLoader,
        audioArticleIdsLoader,
        selectionCountLoader,
        feedIconLoader,
        scrolloverReadWriter,
        scrolloverUnreadWriter,
        activeSessionGeneration,
        monotonicMillis,
    )

    private val mutableState = MutableStateFlow(AndroidArticleTimelineState())
    private val mutableFeedback = MutableSharedFlow<AndroidTimelineHaptic>(extraBufferCapacity = 8)
    private val mutableUndoState = MutableStateFlow(AndroidScrolloverUndoState())
    private val scrolloverRetainedReadIds = mutableSetOf<Long>()
    private val scrolloverFeedbackSuppressedReadIds = mutableSetOf<Long>()
    private val undoFeedbackSuppressedUnreadIds = mutableSetOf<Long>()
    private val pendingSuccessfulScrolloverUndoIds = mutableListOf<Long>()
    private val recentSuccessfulScrolloverReads = mutableListOf<Pair<Long, Long>>()
    private var scrolloverUndoOpenedAtUptimeMillis: Long? = null
    private var scrolloverUndoLastSuccessAtUptimeMillis: Long? = null
    private var scrolloverConfirmationPending = false
    private val feedIconCacheByVariant = mutableMapOf<FeedIconVariant, MutableMap<Long, ByteArray>>()
    private val unavailableFeedIconsByVariant = mutableMapOf<FeedIconVariant, MutableSet<Long>>()
    private val feedIconRequestsInFlight = mutableSetOf<Pair<Long, FeedIconVariant>>()
    private var requestGeneration = 0L

    val state = mutableState.asStateFlow()
    val feedback = mutableFeedback.asSharedFlow()
    val undoState = mutableUndoState.asStateFlow()

    suspend fun reset(selection: AndroidArticleTimelineSelection) {
        scrolloverRetainedReadIds.clear()
        scrolloverFeedbackSuppressedReadIds.clear()
        undoFeedbackSuppressedUnreadIds.clear()
        pendingSuccessfulScrolloverUndoIds.clear()
        recentSuccessfulScrolloverReads.clear()
        clearScrolloverUndoGroup()
        scrolloverConfirmationPending = false
        val generation = ++requestGeneration
        val sessionGeneration = activeSessionGeneration()
        val previous = mutableState.value
        val sameSession = previous.sessionGeneration == null || previous.sessionGeneration == sessionGeneration
        if (!sameSession) {
            feedIconCacheByVariant.clear()
            unavailableFeedIconsByVariant.clear()
            feedIconRequestsInFlight.clear()
        }
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            feedIconVariant = previous.feedIconVariant.takeIf { sameSession },
            feedIconPngByFeedId = previous.feedIconPngByFeedId.takeIf { sameSession }.orEmpty(),
            initialLoading = true,
            queryGeneration = generation,
            sessionGeneration = sessionGeneration,
        )

        if (sessionGeneration == null) {
            failInitialIfOwned(generation, selection, null)
            return
        }

        val page = try {
            pageLoader(selection.coreQuery(), true)
        } catch (_: Exception) {
            failInitialIfOwned(generation, selection, sessionGeneration)
            return
        }

        if (!owns(generation, selection, sessionGeneration)) return
        val articles = page.articles.distinctBy { it.id }
        val audioArticleIds = loadAudioArticleIds(articles.map { it.id })

        if (!owns(generation, selection, sessionGeneration)) return
        val iconState = mutableState.value
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            articles = articles,
            audioArticleIds = audioArticleIds,
            feedIconVariant = iconState.feedIconVariant,
            feedIconPngByFeedId = iconState.feedIconPngByFeedId,
            total = page.total,
            nextCursor = page.nextCursor.takeIf { articles.isNotEmpty() },
            initialLoading = false,
            queryGeneration = generation,
            sessionGeneration = sessionGeneration,
        )
    }

    suspend fun handleCoreEvent(runtimeEvent: AndroidCoreRuntimeEvent) {
        val current = mutableState.value
        val selection = current.selection ?: return
        if (runtimeEvent.generation != current.sessionGeneration || runtimeEvent.generation != activeSessionGeneration()) {
            return
        }

        when (val event = runtimeEvent.event) {
            is CoreEvent.ArticleReadStateChanged -> {
                val suppressFeedback = if (event.read) {
                    scrolloverFeedbackSuppressedReadIds.remove(event.articleId)
                } else {
                    undoFeedbackSuppressedUnreadIds.remove(event.articleId)
                }
                if (!event.read) scrolloverFeedbackSuppressedReadIds.remove(event.articleId)
                applyReadStateChanged(selection, event.articleId, event.read)
                if (!suppressFeedback) mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            }
            is CoreEvent.ArticleStarredStateChanged -> {
                applyStarredStateChanged(selection, event.articleId, event.starred)
                mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            }
            is CoreEvent.SyncDidComplete -> {
                if (event.metadata.navigationChanged) {
                    unavailableFeedIconsByVariant.clear()
                }
                if (event.metadata.dataChanged) reset(selection)
            }
            else -> Unit
        }
    }

    private suspend fun applyReadStateChanged(
        selection: AndroidArticleTimelineSelection,
        articleId: Long,
        read: Boolean,
    ) {
        if (!read) scrolloverRetainedReadIds.remove(articleId)

        val current = mutableState.value
        val index = current.articles.indexOfFirst { it.id == articleId }
        val retainScrolloverRow = read && articleId in scrolloverRetainedReadIds

        if (selection.readFilter == AndroidArticleReadFilter.Unread && !read && index < 0) {
            reset(selection)
            return
        }

        if (index >= 0) mutableState.update { state ->
            if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
            val currentIndex = state.articles.indexOfFirst { it.id == articleId }
            if (currentIndex < 0) return@update state

            if (selection.readFilter == AndroidArticleReadFilter.Unread && read && !retainScrolloverRow) {
                state.copy(
                    articles = state.articles.filterNot { it.id == articleId },
                    audioArticleIds = state.audioArticleIds - articleId,
                )
            } else {
                val articles = state.articles.toMutableList()
                articles[currentIndex] = articles[currentIndex].copy(isRead = read)
                state.copy(articles = articles)
            }
        }

        if (
            selection.readFilter == AndroidArticleReadFilter.Unread &&
            read &&
            !retainScrolloverRow
        ) {
            refreshSelectionTotal(selection, current.queryGeneration, current.sessionGeneration)
        }
    }

    suspend fun markReadFromScrollover(articleIds: List<Long>): List<Long> {
        if (articleIds.isEmpty()) return emptyList()

        val current = mutableState.value
        val selection = current.selection ?: return emptyList()
        val sessionGeneration = current.sessionGeneration ?: return emptyList()
        if (activeSessionGeneration() != sessionGeneration) return emptyList()

        val byId = current.articles.associateBy { it.id }
        val accepted = articleIds.asSequence()
            .distinct()
            .filter { id -> byId[id]?.isRead == false }
            .toList()
        if (accepted.isEmpty()) return emptyList()

        scrolloverRetainedReadIds.addAll(accepted)
        scrolloverFeedbackSuppressedReadIds.addAll(accepted)
        mutableState.update { state ->
            if (
                state.queryGeneration != current.queryGeneration ||
                state.selection != selection ||
                state.sessionGeneration != sessionGeneration
            ) {
                return@update state
            }
            val acceptedSet = accepted.toHashSet()
            state.copy(
                articles = state.articles.map { article ->
                    if (article.id in acceptedSet) article.copy(isRead = true) else article
                },
                total = if (selection.readFilter == AndroidArticleReadFilter.Unread) {
                    state.total?.let { total ->
                        val delta = accepted.size.toULong().coerceAtMost(total)
                        total - delta
                    }
                } else {
                    state.total
                },
            )
        }

        return try {
            scrolloverReadWriter(sessionGeneration, accepted)
            pendingSuccessfulScrolloverUndoIds += accepted
            scrolloverConfirmationPending = true
            emptyList()
        } catch (_: Exception) {
            scrolloverRetainedReadIds.removeAll(accepted.toSet())
            scrolloverFeedbackSuppressedReadIds.removeAll(accepted.toSet())
            if (owns(current.queryGeneration, selection, sessionGeneration)) {
                val acceptedSet = accepted.toHashSet()
                mutableState.update { state ->
                    state.copy(
                        articles = state.articles.map { article ->
                            if (article.id in acceptedSet) article.copy(isRead = false) else article
                        },
                        total = if (selection.readFilter == AndroidArticleReadFilter.Unread) {
                            state.total?.plus(accepted.size.toULong())
                        } else {
                            state.total
                        },
                    )
                }
            }
            accepted
        }
    }

    fun completeScrolloverInteraction() {
        if (pendingSuccessfulScrolloverUndoIds.isNotEmpty()) {
            recordSuccessfulScrolloverUndo(
                pendingSuccessfulScrolloverUndoIds.distinct(),
                monotonicMillis(),
            )
            pendingSuccessfulScrolloverUndoIds.clear()
        }
        if (!scrolloverConfirmationPending) return
        scrolloverConfirmationPending = false
        mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
    }

    fun expireScrolloverUndo(revision: Long) {
        val current = mutableUndoState.value
        if (current.revision != revision || !current.visible) return
        val expiresAt = current.expiresAtUptimeMillis ?: return
        if (monotonicMillis() >= expiresAt) clearScrolloverUndoGroup()
    }

    suspend fun undoScrollover(): List<Long> {
        val currentUndo = mutableUndoState.value
        val ids = currentUndo.articleIds.distinct()
        if (!currentUndo.visible || ids.isEmpty()) return emptyList()

        val current = mutableState.value
        val selection = current.selection ?: return emptyList()
        val sessionGeneration = current.sessionGeneration ?: return emptyList()
        if (activeSessionGeneration() != sessionGeneration) {
            clearScrolloverUndoGroup()
            return emptyList()
        }

        undoFeedbackSuppressedUnreadIds.addAll(ids)
        return try {
            scrolloverUnreadWriter(sessionGeneration, ids)
            scrolloverRetainedReadIds.removeAll(ids.toSet())
            scrolloverFeedbackSuppressedReadIds.removeAll(ids.toSet())
            mutableState.update { state ->
                if (
                    state.selection != selection ||
                    state.sessionGeneration != sessionGeneration
                ) {
                    return@update state
                }
                val idSet = ids.toHashSet()
                val restoredCount = state.articles.count { it.id in idSet && it.isRead }
                state.copy(
                    articles = state.articles.map { article ->
                        if (article.id in idSet) article.copy(isRead = false) else article
                    },
                    total = if (selection.readFilter == AndroidArticleReadFilter.Unread) {
                        state.total?.plus(restoredCount.toULong())
                    } else {
                        state.total
                    },
                    errorMessage = null,
                )
            }
            refreshSelectionTotal(selection, current.queryGeneration, sessionGeneration)
            clearScrolloverUndoGroup()
            mutableFeedback.tryEmit(AndroidTimelineHaptic.Selection)
            ids
        } catch (_: Exception) {
            undoFeedbackSuppressedUnreadIds.removeAll(ids.toSet())
            mutableState.update { state ->
                if (state.selection == selection && state.sessionGeneration == sessionGeneration) {
                    state.copy(errorMessage = "Articles could not be marked unread.")
                } else {
                    state
                }
            }
            emptyList()
        }
    }

    private fun recordSuccessfulScrolloverUndo(ids: List<Long>, now: Long) {
        if (ids.isEmpty()) return

        val currentUndo = mutableUndoState.value
        val openedAt = scrolloverUndoOpenedAtUptimeMillis
        val lastSuccessAt = scrolloverUndoLastSuccessAtUptimeMillis
        val existingGroupExpired =
            openedAt != null &&
                lastSuccessAt != null &&
                (now - lastSuccessAt >= ANDROID_SCROLL_OVER_UNDO_INACTIVITY_MILLIS ||
                    now - openedAt >= ANDROID_SCROLL_OVER_UNDO_MAX_LIFETIME_MILLIS)

        if (existingGroupExpired) clearScrolloverUndoGroup()

        if (mutableUndoState.value.visible) {
            appendScrolloverUndo(ids, now)
            return
        }

        recentSuccessfulScrolloverReads += ids.map { it to now }
        recentSuccessfulScrolloverReads.removeAll {
            now - it.second > ANDROID_SCROLL_OVER_UNDO_QUALIFICATION_MILLIS
        }
        val burstIds = recentSuccessfulScrolloverReads.map { it.first }.distinct()
        if (burstIds.size < ANDROID_SCROLL_OVER_UNDO_MIN_READS) return

        recentSuccessfulScrolloverReads.clear()
        scrolloverUndoOpenedAtUptimeMillis = now
        appendScrolloverUndo(burstIds, now)
    }

    private fun appendScrolloverUndo(ids: List<Long>, now: Long) {
        val existing = mutableUndoState.value.articleIds.toMutableList()
        val seen = existing.toMutableSet()
        ids.forEach { if (seen.add(it)) existing += it }
        if (existing.isEmpty()) return

        if (scrolloverUndoOpenedAtUptimeMillis == null) {
            scrolloverUndoOpenedAtUptimeMillis = now
        }
        scrolloverUndoLastSuccessAtUptimeMillis = now
        val openedAt = scrolloverUndoOpenedAtUptimeMillis ?: now
        val expiresAt = minOf(
            now + ANDROID_SCROLL_OVER_UNDO_INACTIVITY_MILLIS,
            openedAt + ANDROID_SCROLL_OVER_UNDO_MAX_LIFETIME_MILLIS,
        )
        val previous = mutableUndoState.value
        mutableUndoState.value = AndroidScrolloverUndoState(
            articleIds = existing,
            revision = previous.revision + 1,
            expiresAtUptimeMillis = expiresAt,
        )
    }

    private fun clearScrolloverUndoGroup() {
        val previous = mutableUndoState.value
        if (previous.articleIds.isNotEmpty() || previous.expiresAtUptimeMillis != null) {
            mutableUndoState.value = AndroidScrolloverUndoState(revision = previous.revision + 1)
        }
        scrolloverUndoOpenedAtUptimeMillis = null
        scrolloverUndoLastSuccessAtUptimeMillis = null
        recentSuccessfulScrolloverReads.clear()
    }

    private suspend fun applyStarredStateChanged(
        selection: AndroidArticleTimelineSelection,
        articleId: Long,
        starred: Boolean,
    ) {
        val current = mutableState.value
        val index = current.articles.indexOfFirst { it.id == articleId }
        val starredScope = selection.scope == AndroidNewsScope.Starred

        if (starredScope && starred && index < 0) {
            reset(selection)
            return
        }

        if (index >= 0) mutableState.update { state ->
            if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
            val currentIndex = state.articles.indexOfFirst { it.id == articleId }
            if (currentIndex < 0) return@update state

            if (starredScope && !starred) {
                state.copy(
                    articles = state.articles.filterNot { it.id == articleId },
                    audioArticleIds = state.audioArticleIds - articleId,
                )
            } else {
                val articles = state.articles.toMutableList()
                articles[currentIndex] = articles[currentIndex].copy(isStarred = starred)
                state.copy(articles = articles)
            }
        }

        if (starredScope && !starred) {
            refreshSelectionTotal(selection, current.queryGeneration, current.sessionGeneration)
        }
    }

    private suspend fun refreshSelectionTotal(
        selection: AndroidArticleTimelineSelection,
        generation: Long,
        sessionGeneration: Long?,
    ) {
        val ownedSession = sessionGeneration ?: return
        val total = try {
            selectionCountLoader(selection.coreQuery())
        } catch (_: Exception) {
            return
        }
        if (!owns(generation, selection, ownedSession)) return
        mutableState.update { state ->
            if (
                state.queryGeneration == generation &&
                state.selection == selection &&
                state.sessionGeneration == ownedSession
            ) {
                state.copy(total = total)
            } else {
                state
            }
        }
    }

    suspend fun ensureFeedIcon(feedId: Long, variant: FeedIconVariant) {
        ensureFeedIcons(listOf(feedId), variant)
    }

    suspend fun ensureFeedIcons(feedIds: List<Long>, variant: FeedIconVariant) {
        if (feedIds.isEmpty()) return

        val current = mutableState.value
        val selection = current.selection ?: return
        val sessionGeneration = current.sessionGeneration ?: return
        if (activeSessionGeneration() != sessionGeneration) return

        val cache = feedIconCacheByVariant.getOrPut(variant) { mutableMapOf() }
        val unavailable = unavailableFeedIconsByVariant.getOrPut(variant) { mutableSetOf() }
        val requested = feedIds.asSequence()
            .distinct()
            .filterNot { it in cache || it in unavailable }
            .filter { feedIconRequestsInFlight.add(it to variant) }
            .toList()

        if (requested.isEmpty()) {
            if (cache.isNotEmpty()) {
                publishFeedIconCache(
                    generation = current.queryGeneration,
                    selection = selection,
                    sessionGeneration = sessionGeneration,
                    variant = variant,
                    cache = cache,
                )
            }
            return
        }

        try {
            repeat(ANDROID_FEED_ICON_MAX_ATTEMPTS) { attempt ->
                val loaded = try {
                    feedIconLoader(requested, variant)
                } catch (_: Exception) {
                    if (attempt + 1 < ANDROID_FEED_ICON_MAX_ATTEMPTS) {
                        delay(ANDROID_FEED_ICON_RETRY_DELAY_MILLIS * (attempt + 1))
                    }
                    return@repeat
                }

                if (!owns(current.queryGeneration, selection, sessionGeneration)) return

                requested.forEach { feedId ->
                    val png = loaded[feedId]
                    if (png == null) {
                        unavailable += feedId
                    } else {
                        cache[feedId] = png
                    }
                }
                publishFeedIconCache(
                    generation = current.queryGeneration,
                    selection = selection,
                    sessionGeneration = sessionGeneration,
                    variant = variant,
                    cache = cache,
                )
                return
            }
        } finally {
            requested.forEach { feedIconRequestsInFlight.remove(it to variant) }
        }
    }

    private fun publishFeedIconCache(
        generation: Long,
        selection: AndroidArticleTimelineSelection,
        sessionGeneration: Long,
        variant: FeedIconVariant,
        cache: Map<Long, ByteArray>,
    ) {
        mutableState.update { state ->
            if (
                state.queryGeneration != generation ||
                state.selection != selection ||
                state.sessionGeneration != sessionGeneration
            ) {
                return@update state
            }
            state.copy(
                feedIconVariant = variant,
                feedIconPngByFeedId = cache.toMap(),
            )
        }
    }

    suspend fun loadNextPage() {
        val current = mutableState.value
        val selection = current.selection ?: return
        val cursor = current.nextCursor ?: return
        if (current.initialLoading || current.loadingNextPage) return

        val currentSessionGeneration = activeSessionGeneration()
        if (currentSessionGeneration == null || currentSessionGeneration != current.sessionGeneration) {
            reset(selection)
            return
        }

        val generation = current.queryGeneration
        mutableState.update { state ->
            if (state.queryGeneration == generation && state.selection == selection) {
                state.copy(loadingNextPage = true, errorMessage = null)
            } else {
                state
            }
        }

        val page = try {
            pageLoader(selection.coreQuery(cursor), false)
        } catch (_: Exception) {
            if (owns(generation, selection, currentSessionGeneration)) {
                mutableState.update { state ->
                    if (state.queryGeneration == generation && state.selection == selection) {
                        state.copy(loadingNextPage = false, errorMessage = "More articles could not be loaded.")
                    } else {
                        state
                    }
                }
            }
            return
        }

        if (!owns(generation, selection, currentSessionGeneration)) return
        val existingIDs = current.articles.asSequence().map { it.id }.toHashSet()
        val appended = page.articles.filter { existingIDs.add(it.id) }
        val appendedAudioArticleIds = loadAudioArticleIds(appended.map { it.id })

        if (!owns(generation, selection, currentSessionGeneration)) return
        mutableState.update { state ->
            if (state.queryGeneration != generation || state.selection != selection) return@update state

            val stateIDs = state.articles.asSequence().map { it.id }.toHashSet()
            val currentAppend = appended.filter { stateIDs.add(it.id) }
            val madeProgress = currentAppend.isNotEmpty()
            val nextCursor = page.nextCursor.takeIf { madeProgress && it != cursor }

            state.copy(
                articles = state.articles + currentAppend,
                audioArticleIds = state.audioArticleIds + appendedAudioArticleIds,
                nextCursor = nextCursor,
                loadingNextPage = false,
                errorMessage = null,
            )
        }
    }

    private suspend fun loadAudioArticleIds(articleIds: List<Long>): Set<Long> =
        try {
            audioArticleIdsLoader(articleIds)
        } catch (_: Exception) {
            emptySet()
        }

    private fun owns(
        generation: Long,
        selection: AndroidArticleTimelineSelection,
        sessionGeneration: Long,
    ): Boolean =
        requestGeneration == generation &&
            mutableState.value.selection == selection &&
            activeSessionGeneration() == sessionGeneration

    private fun failInitialIfOwned(
        generation: Long,
        selection: AndroidArticleTimelineSelection,
        sessionGeneration: Long?,
    ) {
        if (
            requestGeneration != generation ||
            mutableState.value.selection != selection ||
            activeSessionGeneration() != sessionGeneration
        ) {
            return
        }
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            initialLoading = false,
            errorMessage = "Articles could not be loaded.",
            queryGeneration = generation,
            sessionGeneration = sessionGeneration,
        )
    }
}

@Composable
internal fun AndroidArticleTimeline(
    store: AndroidArticleTimelineStore,
    selection: AndroidArticleTimelineSelection,
    sessionGeneration: Long?,
    accountKey: String,
    topContentPadding: Dp = 0.dp,
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    val undoState by store.undoState.collectAsState()
    val articlePreferences by LocalAndroidArticlePreferences.current.state.collectAsState(
        initial = AndroidArticlePreferenceState(),
    )
    val errorMessage = state.errorMessage
    val listState = rememberLazyListState()
    val scrolloverTracker = remember { AndroidScrolloverTracker() }
    val actionScope = rememberCoroutineScope()
    val view = LocalView.current
    val publicationReferenceMillis = remember(state.queryGeneration) { System.currentTimeMillis() }
    val articleIds = remember(state.queryGeneration, state.articles.size) {
        state.articles.map { it.id }
    }
    val articleFeedIds = remember(state.queryGeneration, state.articles.size) {
        state.articles.map { it.feedId }.distinct()
    }
    val feedIconVariant = if (isSystemInDarkTheme()) {
        FeedIconVariant.DARK
    } else {
        FeedIconVariant.NORMAL
    }

    LaunchedEffect(store, view) {
        store.feedback.collect { feedback ->
            when (feedback) {
                AndroidTimelineHaptic.Confirmation -> view.performFluxConfirmationHaptic()
                AndroidTimelineHaptic.Selection -> view.performFluxSelectionHaptic()
            }
        }
    }

    LaunchedEffect(undoState.revision, undoState.expiresAtUptimeMillis) {
        val expiresAt = undoState.expiresAtUptimeMillis ?: return@LaunchedEffect
        val delayMillis = (expiresAt - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
        delay(delayMillis)
        store.expireScrolloverUndo(undoState.revision)
    }

    LaunchedEffect(articleIds) {
        scrolloverTracker.updateSnapshot(articleIds)
    }

    LaunchedEffect(articleFeedIds, feedIconVariant) {
        store.ensureFeedIcons(articleFeedIds, feedIconVariant)
    }

    LaunchedEffect(listState, scrolloverTracker, articlePreferences.markReadOnScrollover) {
        if (!articlePreferences.markReadOnScrollover) {
            scrolloverTracker.endUserScroll()
            return@LaunchedEffect
        }
        listState.interactionSource.interactions
            .filterIsInstance<DragInteraction>()
            .collect { interaction ->
                when (interaction) {
                    is DragInteraction.Start -> {
                        scrolloverTracker.beginUserScroll(
                            sample = listState.scrolloverGeometrySample(),
                            enabled = articlePreferences.markReadOnScrollover,
                        )
                    }
                    is DragInteraction.Stop,
                    is DragInteraction.Cancel,
                    -> Unit
                }
            }
    }

    LaunchedEffect(
        listState,
        scrolloverTracker,
        articlePreferences.markReadOnScrollover,
        state.queryGeneration,
    ) {
        if (!articlePreferences.markReadOnScrollover) {
            scrolloverTracker.endUserScroll()
            return@LaunchedEffect
        }
        snapshotFlow {
            listState.scrolloverGeometrySample() to listState.isScrollInProgress
        }
            .collect { (sample, scrolling) ->
                val candidates = scrolloverTracker.receive(
                    sample = sample,
                    enabled = articlePreferences.markReadOnScrollover,
                )
                if (candidates.isNotEmpty()) {
                    val failed = store.markReadFromScrollover(candidates)
                    if (failed.isNotEmpty()) scrolloverTracker.rearm(failed)
                }
                if (!scrolling) {
                    scrolloverTracker.endUserScroll()
                    store.completeScrolloverInteraction()
                }
            }
    }

    LaunchedEffect(selection, sessionGeneration, accountKey) {
        val current = store.state.value
        val sameContext =
            current.selection == selection &&
                current.sessionGeneration == sessionGeneration &&
                current.selection != null
        if (sameContext) return@LaunchedEffect

        if (listState.firstVisibleItemIndex != 0 || listState.firstVisibleItemScrollOffset != 0) {
            listState.scrollToItem(0)
        }
        store.reset(selection)
    }

    LaunchedEffect(
        listState,
        state.queryGeneration,
        state.articles.size,
        state.nextCursor != null,
    ) {
        if (state.articles.isEmpty() || state.nextCursor == null) return@LaunchedEffect
        snapshotFlow {
            val lastVisibleIndex = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            val threshold = (state.articles.lastIndex - ANDROID_ARTICLE_TIMELINE_PREFETCH_DISTANCE).coerceAtLeast(0)
            lastVisibleIndex >= threshold
        }
            .distinctUntilChanged()
            .collect { approachingEnd ->
                if (approachingEnd) store.loadNextPage()
            }
    }

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
    val availableWidth = (maxWidth - 32.dp).coerceAtLeast(0.dp)
    val availableWidthDp = availableWidth.value.toInt()
    when {
        state.initialLoading && state.articles.isEmpty() -> {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
        errorMessage != null && state.articles.isEmpty() -> {
            TimelineMessage(
                message = errorMessage,
                actionLabel = "Retry",
                onAction = { actionScope.launch { store.reset(selection) } },
                modifier = Modifier.fillMaxSize(),
            )
        }
        state.empty -> {
            TimelineMessage(
                message = "No articles in this view.",
                modifier = Modifier.fillMaxSize(),
            )
        }
        else -> {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = topContentPadding),
            ) {
                items(
                    items = state.articles,
                    key = { article -> article.id },
                    contentType = { article ->
                        AndroidArticleRowPolicy.layoutVariant(
                            mode = articlePreferences.presentationMode,
                            imageUrl = article.imageUrl,
                            availableWidthDp = availableWidthDp,
                        )
                    },
                ) { article ->
                    AndroidArticleTimelineRow(
                        article = article,
                        hasAudio = article.id in state.audioArticleIds,
                        preferences = articlePreferences,
                        publicationReferenceMillis = publicationReferenceMillis,
                        feedIconPng = state.feedIconPngByFeedId[article.feedId],
                        feedIconVariant = feedIconVariant,
                        availableWidth = availableWidth,
                        onRequestFeedIcon = store::ensureFeedIcon,
                    )
                }

                if (state.loadingNextPage) {
                    item(key = "timeline-loading-more") {
                        Box(
                            Modifier.fillMaxWidth().padding(20.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                    }
                } else if (errorMessage != null) {
                    item(key = "timeline-page-error") {
                        TimelineMessage(
                            message = errorMessage,
                            actionLabel = "Retry",
                            onAction = { actionScope.launch { store.loadNextPage() } },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }

    if (undoState.visible) {
        Snackbar(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp, vertical = 20.dp),
            action = {
                TextButton(
                    onClick = {
                        actionScope.launch {
                            val restoredIds = store.undoScrollover()
                            if (restoredIds.isNotEmpty()) scrolloverTracker.rearm(restoredIds)
                        }
                    },
                ) {
                    Text("Undo")
                }
            },
        ) {
            val count = undoState.articleIds.size
            Text(
                if (count == 1) "1 article marked as read" else "$count articles marked as read",
            )
        }
    }
    }
}

private fun View.performFluxConfirmationHaptic() {
    val feedbackConstant = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        HapticFeedbackConstants.CONFIRM
    } else {
        HapticFeedbackConstants.VIRTUAL_KEY
    }
    performHapticFeedback(feedbackConstant)
}

private fun View.performFluxSelectionHaptic() {
    performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
}

private fun androidx.compose.foundation.lazy.LazyListState.scrolloverGeometrySample(): AndroidScrolloverGeometrySample {
    val layout = layoutInfo
    return AndroidScrolloverGeometrySample(
        firstVisibleIndex = firstVisibleItemIndex,
        firstVisibleScrollOffset = firstVisibleItemScrollOffset,
        viewportStartOffset = layout.viewportStartOffset,
        viewportEndOffset = layout.viewportEndOffset,
        visibleRows = layout.visibleItemsInfo.mapNotNull { item ->
            val articleId = item.key as? Long ?: return@mapNotNull null
            AndroidScrolloverVisibleRow(
                articleId = articleId,
                index = item.index,
                offset = item.offset,
                size = item.size,
            )
        },
    )
}

@Composable
private fun AndroidArticleTimelineRow(
    article: ArticleSummary,
    hasAudio: Boolean,
    preferences: AndroidArticlePreferenceState,
    publicationReferenceMillis: Long,
    feedIconPng: ByteArray?,
    feedIconVariant: FeedIconVariant,
    availableWidth: Dp,
    onRequestFeedIcon: suspend (Long, FeedIconVariant) -> Unit,
) {
    Box(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        val layoutVariant = AndroidArticleRowPolicy.layoutVariant(
            mode = preferences.presentationMode,
            imageUrl = article.imageUrl,
            availableWidthDp = availableWidth.value.toInt(),
        )
        val metadata: @Composable () -> Unit = {
            ArticleMetadataRow(
                article = article,
                hasAudio = hasAudio,
                feedIconPng = feedIconPng,
                feedIconVariant = feedIconVariant,
                onRequestFeedIcon = onRequestFeedIcon,
                requestIfMissing = false,
            )
        }
        val title: @Composable () -> Unit = {
            ArticleTitle(article)
        }
        val publication: @Composable () -> Unit = {
            ArticlePublicationRow(
                article = article,
                preferences = preferences,
                publicationReferenceMillis = publicationReferenceMillis,
            )
        }
        val preview: @Composable () -> Unit = {
            ArticlePreview(article = article, preferences = preferences)
        }

        when (layoutVariant) {
            AndroidArticleRowLayoutVariant.Compact,
            AndroidArticleRowLayoutVariant.VisualTextOnly,
            AndroidArticleRowLayoutVariant.VisualCompactTextOnly,
            -> {
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    metadata()
                    title()
                    publication()
                    preview()
                }
            }

            AndroidArticleRowLayoutVariant.VisualPortrait -> {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ArticleImage(
                        imageUrl = article.imageUrl!!,
                        modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                    )
                    metadata()
                    title()
                    publication()
                    preview()
                }
            }

            AndroidArticleRowLayoutVariant.VisualLandscape -> {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    ArticleImage(
                        imageUrl = article.imageUrl!!,
                        modifier = Modifier.weight(0.48f).aspectRatio(16f / 9f),
                    )
                    Column(
                        modifier = Modifier.weight(0.52f),
                        verticalArrangement = Arrangement.spacedBy(7.dp),
                    ) {
                        metadata()
                        title()
                        publication()
                        preview()
                    }
                }
            }

            AndroidArticleRowLayoutVariant.VisualCompactNarrow -> {
                val imageWidth = availableWidth * 0.32f
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    metadata()
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(7.dp),
                        ) {
                            title()
                            publication()
                        }
                        ArticleImage(
                            imageUrl = article.imageUrl!!,
                            modifier = Modifier.width(imageWidth).aspectRatio(4f / 3f),
                        )
                    }
                    preview()
                }
            }

            AndroidArticleRowLayoutVariant.VisualCompactWide -> {
                val imageWidth = availableWidth * 0.32f
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    metadata()
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(7.dp),
                        ) {
                            title()
                            publication()
                            preview()
                        }
                        ArticleImage(
                            imageUrl = article.imageUrl!!,
                            modifier = Modifier.width(imageWidth).aspectRatio(4f / 3f),
                        )
                    }
                }
            }
        }
    }
    HorizontalDivider()
}

@Composable
private fun ArticleMetadataRow(
    article: ArticleSummary,
    hasAudio: Boolean,
    feedIconPng: ByteArray?,
    feedIconVariant: FeedIconVariant,
    onRequestFeedIcon: suspend (Long, FeedIconVariant) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FeedIcon(
            feedId = article.feedId,
            title = article.feedTitle,
            pngData = feedIconPng,
            variant = feedIconVariant,
            onRequest = onRequestFeedIcon,
        )
        Text(
            article.feedTitle,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        ArticleAccessories(
            article = article,
            hasAudio = hasAudio,
        )
    }
}

@Composable
internal fun FeedIcon(
    feedId: Long,
    title: String,
    pngData: ByteArray?,
    variant: FeedIconVariant,
    onRequest: suspend (Long, FeedIconVariant) -> Unit,
    requestIfMissing: Boolean = true,
) {
    LaunchedEffect(feedId, variant, pngData == null, requestIfMissing) {
        if (requestIfMissing && pngData == null) onRequest(feedId, variant)
    }
    val context = LocalContext.current
    val imageRequest = remember(context, feedId, variant, pngData) {
        pngData?.let { bytes ->
            ImageRequest.Builder(context)
                .data(bytes)
                .memoryCacheKey("feed-icon:$feedId:$variant:${pngData.contentHashCode()}")
                .build()
        }
    }
    if (imageRequest != null) {
        AsyncImage(
            model = imageRequest,
            contentDescription = null,
            modifier = Modifier.size(22.dp).clip(CircleShape),
        )
    } else {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clearAndSetSemantics { }
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                title.trim().firstOrNull()?.uppercase() ?: "•",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onPrimary,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun ArticleTitle(article: ArticleSummary) {
    Text(
        article.title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = if (article.isRead) FontWeight.Normal else FontWeight.SemiBold,
        color = if (article.isRead) {
            MaterialTheme.colorScheme.onSurfaceVariant
        } else {
            MaterialTheme.colorScheme.onSurface
        },
    )
}

@Composable
private fun ArticlePublicationRow(
    article: ArticleSummary,
    preferences: AndroidArticlePreferenceState,
    publicationReferenceMillis: Long,
) {
    Text(
        publicationLabel(
            article = article,
            relative = preferences.showRelativePublicationTime,
            referenceMillis = publicationReferenceMillis,
        ),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ArticlePreview(
    article: ArticleSummary,
    preferences: AndroidArticlePreferenceState,
) {
    val preview = article.preview.trim()
    if (preview.isEmpty()) return
    Text(
        preview,
        maxLines = preferences.previewLines.lineCount,
        overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun publicationLabel(
    article: ArticleSummary,
    relative: Boolean,
    referenceMillis: Long,
): String {
    val context = LocalContext.current
    val locales = LocalConfiguration.current.locales
    val publishedMillis = remember(article.publishedAt) {
        parseArticlePublishedAtMillis(article.publishedAt)
    }
    val publication = remember(article.publishedAt, publishedMillis, relative, referenceMillis, locales) {
        if (publishedMillis == null) {
            article.publishedAt
        } else if (relative) {
            DateUtils.getRelativeTimeSpanString(
                publishedMillis,
                referenceMillis,
                MINUTE_IN_MILLIS,
                FORMAT_ABBREV_RELATIVE,
            ).toString()
        } else {
            val published = Date(publishedMillis)
            val date = DateFormat.getMediumDateFormat(context).format(published)
            val time = DateFormat.getTimeFormat(context).format(published)
            "$date · $time"
        }
    }
    return if (article.readingTimeMinutes > 0u) {
        "$publication · ${article.readingTimeMinutes} min"
    } else {
        publication
    }
}

@Composable
private fun ArticleImage(imageUrl: String, modifier: Modifier = Modifier) {
    AsyncImage(
        model = imageUrl,
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = modifier
            .clip(MaterialTheme.shapes.medium)
            .background(MaterialTheme.colorScheme.surfaceVariant),
    )
}

@Composable
private fun ArticleAccessories(
    article: ArticleSummary,
    hasAudio: Boolean,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (hasAudio) {
            Icon(
                painter = painterResource(R.drawable.ic_headphones),
                contentDescription = "Audio",
                modifier = Modifier.size(16.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (article.commentsUrl.isNotBlank()) {
            Icon(
                painter = painterResource(R.drawable.ic_comment),
                contentDescription = "Comments",
                modifier = Modifier.size(16.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Star and unread keep fixed slots so status-only mutations do not move
        // the feed title or the immutable comments/audio accessories.
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            if (article.isStarred) {
                Icon(
                    painter = painterResource(R.drawable.ic_star),
                    contentDescription = "Starred",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            if (!article.isRead) {
                Box(
                    Modifier
                        .size(8.dp)
                        .semantics { contentDescription = "Unread" }
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary),
                )
            }
        }
    }
}

@Composable
private fun TimelineMessage(
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                message,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (actionLabel != null && onAction != null) {
                Button(onClick = onAction) {
                    Text(actionLabel)
                }
            }
        }
    }
}
