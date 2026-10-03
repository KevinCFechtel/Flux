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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
import uniffi.flux_uniffi.SaveToServiceResult
import uniffi.flux_uniffi.StarredFilter
import uniffi.flux_uniffi.SyncReason

private const val ANDROID_ARTICLE_TIMELINE_PAGE_SIZE = 64
private const val ANDROID_ARTICLE_TIMELINE_PREFETCH_DISTANCE = 8
private const val ANDROID_FEED_ICON_RETRY_DELAY_MILLIS = 1_000L
private const val ANDROID_FEED_ICON_MAX_ATTEMPTS = 3
private const val ANDROID_SCROLL_OVER_UNDO_INACTIVITY_MILLIS = 4_000L
private const val ANDROID_SCROLL_OVER_UNDO_MAX_LIFETIME_MILLIS = 15_000L
private const val ANDROID_SCROLL_OVER_UNDO_QUALIFICATION_MILLIS = 1_000L
private const val ANDROID_SCROLL_OVER_UNDO_MIN_READS = 3
private const val ANDROID_SCROLL_OVER_MUTATION_BATCH_SIZE = 32

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

internal sealed interface AndroidScrolloverMutationRequest {
    data class MarkRead(
        val articleIds: List<Long>,
        val queryGeneration: Long? = null,
    ) : AndroidScrolloverMutationRequest

    data class CompleteInteraction(
        val queryGeneration: Long? = null,
    ) : AndroidScrolloverMutationRequest
}

internal suspend fun consumeAndroidScrolloverMutationRequests(
    requests: ReceiveChannel<AndroidScrolloverMutationRequest>,
    markRead: suspend (List<Long>) -> List<Long>,
    rearm: (Collection<Long>) -> Unit,
    completeInteraction: () -> Unit,
) {
    for (request in requests) {
        when (request) {
            is AndroidScrolloverMutationRequest.MarkRead -> {
                val failed = markRead(request.articleIds)
                if (failed.isNotEmpty()) rearm(failed)
            }
            is AndroidScrolloverMutationRequest.CompleteInteraction -> completeInteraction()
        }
    }
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
    fun selectingScope(scope: AndroidNewsScope): AndroidArticleTimelineSelection =
        copy(scope = scope)

    fun togglingReadFilter(): AndroidArticleTimelineSelection =
        if (scope == AndroidNewsScope.Starred) {
            this
        } else {
            copy(
                readFilter = when (readFilter) {
                    AndroidArticleReadFilter.Unread -> AndroidArticleReadFilter.All
                    AndroidArticleReadFilter.All -> AndroidArticleReadFilter.Unread
                },
            )
        }

    fun togglingSortOrder(): AndroidArticleTimelineSelection =
        copy(
            sort = when (sort) {
                AndroidArticleSortOrder.OldestFirst -> AndroidArticleSortOrder.NewestFirst
                AndroidArticleSortOrder.NewestFirst -> AndroidArticleSortOrder.OldestFirst
            },
        )

    fun markAllReadQuery(): ArticleQuery {
        val base = coreQuery()
        return ArticleQuery(
            scope = base.scope,
            readFilter = ReadFilter.UNREAD,
            starredFilter = StarredFilter.ALL,
            sort = ArticleSort.NEWEST_FIRST,
            limit = 0u,
            cursor = null,
        )
    }

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
            readFilter = if (scope == AndroidNewsScope.Starred) {
                ReadFilter.ALL
            } else {
                when (readFilter) {
                    AndroidArticleReadFilter.Unread -> ReadFilter.UNREAD
                    AndroidArticleReadFilter.All -> ReadFilter.ALL
                }
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

internal data class AndroidArticleRowPresentation(
    val isRead: Boolean,
    val isStarred: Boolean,
    val revision: Long = 0L,
)

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
    val pendingNewFeedIds: Set<Long> = emptySet(),
    val hasUnscopedNewDataSignal: Boolean = false,
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
    private val explicitReadWriter: suspend (Long, Long, Boolean) -> Unit,
    private val explicitStarredWriter: suspend (Long, Long, Boolean) -> Unit,
    private val scopeUnreadIdsLoader: suspend (Long, ArticleQuery) -> List<Long>,
    private val scopeReadWriter: suspend (Long, List<Long>) -> Unit,
    private val minifluxEntryUrlLoader: suspend (Long, Long) -> String,
    private val saveToServiceWriter: suspend (Long, Long) -> AndroidSaveToServiceOutcome,
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
        explicitReadWriter = { generation, articleId, read ->
            coreRuntime.localForGeneration(generation) { core ->
                core.setReadState(articleId = articleId, read = read)
            }
            Unit
        },
        explicitStarredWriter = { generation, articleId, starred ->
            coreRuntime.localForGeneration(generation) { core ->
                core.setStarredState(articleId = articleId, starred = starred)
            }
            Unit
        },
        scopeUnreadIdsLoader = { generation, query ->
            coreRuntime.localForGeneration(generation) { core ->
                core.queryArticles(query).map { it.id }
            }
        },
        scopeReadWriter = { generation, articleIds ->
            coreRuntime.localForGeneration(generation) { core ->
                core.setReadStateBulk(articleIds = articleIds, read = true)
            }
            Unit
        },
        minifluxEntryUrlLoader = { generation, articleId ->
            coreRuntime.localForGeneration(generation) { core ->
                core.minifluxEntryUrl(articleId = articleId)
            }
        },
        saveToServiceWriter = { generation, articleId ->
            when (
                coreRuntime.remoteForGeneration(generation) { core ->
                    core.saveToService(articleId = articleId)
                }
            ) {
                SaveToServiceResult.SAVED -> AndroidSaveToServiceOutcome.Saved
                SaveToServiceResult.NO_INTEGRATION_CONFIGURED -> AndroidSaveToServiceOutcome.NoIntegrationConfigured
            }
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
        explicitReadWriter: suspend (Long, Long, Boolean) -> Unit = { _, _, _ -> },
        explicitStarredWriter: suspend (Long, Long, Boolean) -> Unit = { _, _, _ -> },
        scopeUnreadIdsLoader: suspend (Long, ArticleQuery) -> List<Long> = { _, _ -> emptyList() },
        scopeReadWriter: suspend (Long, List<Long>) -> Unit = { _, _ -> },
        minifluxEntryUrlLoader: suspend (Long, Long) -> String = { _, articleId ->
            "https://example.test/miniflux/entry/$articleId"
        },
        saveToServiceWriter: suspend (Long, Long) -> AndroidSaveToServiceOutcome = { _, _ ->
            AndroidSaveToServiceOutcome.Saved
        },
        monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(
        pageLoader,
        audioArticleIdsLoader,
        selectionCountLoader,
        feedIconLoader,
        scrolloverReadWriter,
        scrolloverUnreadWriter,
        explicitReadWriter,
        explicitStarredWriter,
        scopeUnreadIdsLoader,
        scopeReadWriter,
        minifluxEntryUrlLoader,
        saveToServiceWriter,
        activeSessionGeneration,
        monotonicMillis,
    )

    private val mutableState = MutableStateFlow(AndroidArticleTimelineState())
    private val mutableFeedback = MutableSharedFlow<AndroidTimelineHaptic>(extraBufferCapacity = 8)
    private val mutableActionMessages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    private val mutableScrollResetRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val mutableScrolloverRearmRequests = MutableSharedFlow<List<Long>>(extraBufferCapacity = 8)
    private val mutableUndoState = MutableStateFlow(AndroidScrolloverUndoState())
    private val explicitActionScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val scrolloverMutationScope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default.limitedParallelism(1),
    )
    private val scrolloverMutationRequests = Channel<AndroidScrolloverMutationRequest>(capacity = Channel.UNLIMITED)
    private val articleIndexById = ConcurrentHashMap<Long, Int>()
    private val rowPresentationById = ConcurrentHashMap<Long, MutableStateFlow<AndroidArticleRowPresentation>>()
    private val explicitMutationMutex = Mutex()
    private val nextExplicitMutationToken = AtomicLong(0)
    private val explicitReadMutationTokens = ConcurrentHashMap<Long, Long>()
    private val explicitStarredMutationTokens = ConcurrentHashMap<Long, Long>()
    private val expectedReadEvents = ConcurrentHashMap<Long, ConcurrentLinkedQueue<Boolean>>()
    private val expectedStarredEvents = ConcurrentHashMap<Long, ConcurrentLinkedQueue<Boolean>>()
    private val expectedBulkReadEventIds = ConcurrentHashMap.newKeySet<Long>()
    private val scrolloverRetainedReadIds = ConcurrentHashMap.newKeySet<Long>()
    private val scrolloverFeedbackSuppressedReadIds = ConcurrentHashMap.newKeySet<Long>()
    private val undoFeedbackSuppressedUnreadIds = ConcurrentHashMap.newKeySet<Long>()
    private val pendingSuccessfulScrolloverUndoIds = mutableListOf<Long>()
    private val recentSuccessfulScrolloverReads = mutableListOf<Pair<Long, Long>>()
    private var scrolloverUndoOpenedAtUptimeMillis: Long? = null
    private var scrolloverUndoLastSuccessAtUptimeMillis: Long? = null
    private var scrolloverConfirmationPending = false
    private val feedIconCacheByVariant = mutableMapOf<FeedIconVariant, MutableMap<Long, ByteArray>>()
    private val unavailableFeedIconsByVariant = mutableMapOf<FeedIconVariant, MutableSet<Long>>()
    private val feedIconRequestsInFlight = mutableSetOf<Pair<Long, FeedIconVariant>>()
    private var requestGeneration = 0L

    init {
        scrolloverMutationScope.launch {
            for (request in scrolloverMutationRequests) {
                when (request) {
                    is AndroidScrolloverMutationRequest.MarkRead -> {
                        val currentGeneration = mutableState.value.queryGeneration
                        if (
                            request.queryGeneration != null &&
                            request.queryGeneration != currentGeneration
                        ) {
                            continue
                        }

                        val combined = linkedSetOf<Long>()
                        combined.addAll(request.articleIds)
                        var completeInteraction = false
                        while (combined.size < ANDROID_SCROLL_OVER_MUTATION_BATCH_SIZE) {
                            val next = scrolloverMutationRequests.tryReceive().getOrNull() ?: break
                            when (next) {
                                is AndroidScrolloverMutationRequest.MarkRead -> {
                                    if (
                                        next.queryGeneration == null ||
                                        next.queryGeneration == currentGeneration
                                    ) {
                                        combined.addAll(next.articleIds)
                                    }
                                }
                                is AndroidScrolloverMutationRequest.CompleteInteraction -> {
                                    if (
                                        next.queryGeneration == null ||
                                        next.queryGeneration == currentGeneration
                                    ) {
                                        completeInteraction = true
                                    }
                                    break
                                }
                            }
                        }

                        val failed = markReadFromScrollover(combined.toList())
                        if (failed.isNotEmpty()) mutableScrolloverRearmRequests.tryEmit(failed)
                        if (completeInteraction) completeScrolloverInteraction()
                    }
                    is AndroidScrolloverMutationRequest.CompleteInteraction -> {
                        if (
                            request.queryGeneration == null ||
                            request.queryGeneration == mutableState.value.queryGeneration
                        ) {
                            completeScrolloverInteraction()
                        }
                    }
                }
            }
        }
    }

    val state = mutableState.asStateFlow()
    val feedback = mutableFeedback.asSharedFlow()
    val actionMessages = mutableActionMessages.asSharedFlow()
    val scrollResetRequests = mutableScrollResetRequests.asSharedFlow()
    val scrolloverRearmRequests = mutableScrolloverRearmRequests.asSharedFlow()
    val undoState = mutableUndoState.asStateFlow()

    fun rowPresentationState(article: ArticleSummary) =
        rowPresentationById.computeIfAbsent(article.id) {
            MutableStateFlow(
                AndroidArticleRowPresentation(
                    isRead = article.isRead,
                    isStarred = article.isStarred,
                ),
            )
        }.asStateFlow()

    internal fun rowPresentationForTesting(articleId: Long): AndroidArticleRowPresentation? =
        rowPresentationById[articleId]?.value

    fun enqueueScrolloverCandidates(articleIds: List<Long>) {
        if (articleIds.isEmpty()) return
        scrolloverMutationRequests.trySend(
            AndroidScrolloverMutationRequest.MarkRead(
                articleIds = articleIds,
                queryGeneration = mutableState.value.queryGeneration,
            ),
        )
    }

    fun enqueueScrolloverInteractionComplete() {
        scrolloverMutationRequests.trySend(
            AndroidScrolloverMutationRequest.CompleteInteraction(
                queryGeneration = mutableState.value.queryGeneration,
            ),
        )
    }

    fun retainedSelectionForSession(sessionGeneration: Long?): AndroidArticleTimelineSelection? =
        mutableState.value
            .takeIf { it.sessionGeneration == sessionGeneration }
            ?.selection

    fun requestSetRead(
        articleId: Long,
        read: Boolean,
        removeWhenRead: Boolean,
        providesFeedback: Boolean = true,
    ) {
        explicitActionScope.launch {
            setReadExplicit(
                articleId = articleId,
                read = read,
                removeWhenRead = removeWhenRead,
                providesFeedback = providesFeedback,
            )
        }
    }

    internal suspend fun setReadExplicit(
        articleId: Long,
        read: Boolean,
        removeWhenRead: Boolean,
        providesFeedback: Boolean = true,
    ): Boolean {
        val current = mutableState.value
        val selection = current.selection ?: return false
        val sessionGeneration = current.sessionGeneration ?: return false
        if (activeSessionGeneration() != sessionGeneration) return false
        val articleIndex = articleIndexById[articleId] ?: return false
        if (current.articles.getOrNull(articleIndex)?.id != articleId) return false
        val previous = rowPresentationById[articleId]?.value?.isRead ?: return false
        if (previous == read) return true

        val token = nextExplicitMutationToken.incrementAndGet()
        explicitReadMutationTokens[articleId] = token
        expectedReadEvents.computeIfAbsent(articleId) { ConcurrentLinkedQueue() }.add(read)
        val generation = current.queryGeneration
        setRowRead(articleId, read)
        mutableState.update { state ->
            if (
                state.queryGeneration != generation ||
                state.selection != selection ||
                state.sessionGeneration != sessionGeneration
            ) {
                return@update state
            }
            state.copy(
                total = adjustedReadTotal(
                    total = state.total,
                    selection = selection,
                    previous = previous,
                    requested = read,
                ),
            )
        }

        val result = runCatching {
            explicitMutationMutex.withLock {
                explicitReadWriter(sessionGeneration, articleId, read)
            }
        }
        if (result.isFailure) {
            discardExpectedEvent(expectedReadEvents, articleId, read)
        }
        if (activeSessionGeneration() != sessionGeneration) return result.isSuccess
        if (explicitReadMutationTokens[articleId] != token) return result.isSuccess
        explicitReadMutationTokens.remove(articleId, token)
        if (!owns(generation, selection, sessionGeneration)) return result.isSuccess

        if (result.isSuccess) {
            if (
                read &&
                removeWhenRead &&
                selection.readFilter == AndroidArticleReadFilter.Unread
            ) {
                mutableState.update { state ->
                    if (
                        state.queryGeneration == generation &&
                        state.selection == selection &&
                        state.sessionGeneration == sessionGeneration
                    ) {
                        val filtered = state.articles.filterNot { it.id == articleId }
                        rebuildArticleIndex(filtered)
                        state.copy(
                            articles = filtered,
                            audioArticleIds = state.audioArticleIds - articleId,
                        )
                    } else {
                        state
                    }
                }
            }
            refreshSelectionTotal(selection, generation, sessionGeneration)
            if (previous && !read) {
                mutableScrolloverRearmRequests.tryEmit(listOf(articleId))
            }
            if (providesFeedback && !previous && read) {
                mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            }
            return true
        }

        if (owns(generation, selection, sessionGeneration)) {
            val presentation = rowPresentationById[articleId]?.value
            if (presentation?.isRead == read) setRowRead(articleId, previous)
        }
        refreshSelectionTotal(selection, generation, sessionGeneration)
        mutableActionMessages.emit(
            if (read) "Article could not be marked as read." else "Article could not be marked as unread.",
        )
        return false
    }

    fun requestSetStarred(articleId: Long, starred: Boolean) {
        explicitActionScope.launch { setStarredExplicit(articleId, starred) }
    }

    internal suspend fun setStarredExplicit(articleId: Long, starred: Boolean): Boolean {
        val current = mutableState.value
        val selection = current.selection ?: return false
        val sessionGeneration = current.sessionGeneration ?: return false
        if (activeSessionGeneration() != sessionGeneration) return false
        val articleIndex = articleIndexById[articleId] ?: return false
        if (current.articles.getOrNull(articleIndex)?.id != articleId) return false
        val previous = rowPresentationById[articleId]?.value?.isStarred ?: return false
        if (previous == starred) return true

        val token = nextExplicitMutationToken.incrementAndGet()
        explicitStarredMutationTokens[articleId] = token
        expectedStarredEvents.computeIfAbsent(articleId) { ConcurrentLinkedQueue() }.add(starred)
        val generation = current.queryGeneration
        setRowStarred(articleId, starred)
        mutableState.update { state ->
            if (
                state.queryGeneration != generation ||
                state.selection != selection ||
                state.sessionGeneration != sessionGeneration
            ) {
                return@update state
            }
            state.copy(
                total = adjustedStarredTotal(
                    total = state.total,
                    selection = selection,
                    previous = previous,
                    requested = starred,
                ),
            )
        }

        val result = runCatching {
            explicitMutationMutex.withLock {
                explicitStarredWriter(sessionGeneration, articleId, starred)
            }
        }
        if (result.isFailure) {
            discardExpectedEvent(expectedStarredEvents, articleId, starred)
        }
        if (activeSessionGeneration() != sessionGeneration) return result.isSuccess
        if (explicitStarredMutationTokens[articleId] != token) return result.isSuccess
        explicitStarredMutationTokens.remove(articleId, token)
        if (!owns(generation, selection, sessionGeneration)) return result.isSuccess

        if (result.isSuccess) {
            if (!starred && selection.scope == AndroidNewsScope.Starred) {
                mutableState.update { state ->
                    if (
                        state.queryGeneration == generation &&
                        state.selection == selection &&
                        state.sessionGeneration == sessionGeneration
                    ) {
                        val filtered = state.articles.filterNot { it.id == articleId }
                        rebuildArticleIndex(filtered)
                        state.copy(
                            articles = filtered,
                            audioArticleIds = state.audioArticleIds - articleId,
                        )
                    } else {
                        state
                    }
                }
            }
            if (selection.scope == AndroidNewsScope.Starred) {
                refreshSelectionTotal(selection, generation, sessionGeneration)
            }
            mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            return true
        }

        if (owns(generation, selection, sessionGeneration)) {
            val presentation = rowPresentationById[articleId]?.value
            if (presentation?.isStarred == starred) setRowStarred(articleId, previous)
        }
        if (selection.scope == AndroidNewsScope.Starred) {
            refreshSelectionTotal(selection, generation, sessionGeneration)
        }
        mutableActionMessages.emit(
            if (starred) "Article could not be starred." else "Article could not be unstarred.",
        )
        return false
    }

    suspend fun markCurrentScopeAsRead(reloadCurrentScope: Boolean = true): Boolean {
        val current = mutableState.value
        val selection = current.selection ?: return false
        if (
            selection.scope != AndroidNewsScope.All &&
            selection.scope !is AndroidNewsScope.Category &&
            selection.scope !is AndroidNewsScope.Feed
        ) {
            return false
        }
        val sessionGeneration = current.sessionGeneration ?: return false
        if (activeSessionGeneration() != sessionGeneration) return false
        val generation = current.queryGeneration

        val ids = try {
            scopeUnreadIdsLoader(sessionGeneration, selection.markAllReadQuery()).distinct()
        } catch (_: Exception) {
            if (owns(generation, selection, sessionGeneration)) {
                mutableActionMessages.emit("Unread articles could not be loaded.")
            }
            return false
        }
        if (!owns(generation, selection, sessionGeneration)) return false
        if (ids.isEmpty()) return true

        expectedBulkReadEventIds.addAll(ids)
        val mutation = runCatching {
            explicitMutationMutex.withLock {
                scopeReadWriter(sessionGeneration, ids)
            }
        }
        if (mutation.isFailure) {
            expectedBulkReadEventIds.removeAll(ids.toSet())
        }
        if (!owns(generation, selection, sessionGeneration)) return false

        if (mutation.isFailure) {
            mutableActionMessages.emit("Articles could not be marked as read.")
            return false
        }

        if (reloadCurrentScope) {
            reset(selection)
            mutableScrollResetRequests.tryEmit(Unit)
        }
        mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
        mutableActionMessages.emit("All unread articles in this scope were marked as read.")
        return true
    }

    suspend fun resolveMinifluxEntryUrl(articleId: Long): String? {
        val generation = activeSessionGeneration() ?: return null
        val result = runCatching { minifluxEntryUrlLoader(generation, articleId) }.getOrNull()
        return result?.takeIf { activeSessionGeneration() == generation }
    }

    fun requestSaveToService(articleId: Long) {
        val generation = activeSessionGeneration() ?: return
        explicitActionScope.launch {
            val result = runCatching { saveToServiceWriter(generation, articleId) }
            if (activeSessionGeneration() != generation) return@launch
            result.fold(
                onSuccess = { outcome ->
                    when (outcome) {
                        AndroidSaveToServiceOutcome.Saved -> {
                            mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
                            mutableActionMessages.emit("Saved to third-party service.")
                        }
                        AndroidSaveToServiceOutcome.NoIntegrationConfigured -> {
                            mutableActionMessages.emit("No third-party integration is configured.")
                        }
                    }
                },
                onFailure = {
                    mutableActionMessages.emit("Article could not be saved to the third-party service.")
                },
            )
        }
    }

    private fun consumeExpectedEvent(
        events: ConcurrentHashMap<Long, ConcurrentLinkedQueue<Boolean>>,
        articleId: Long,
        value: Boolean,
    ): Boolean {
        val queue = events[articleId] ?: return false
        val expected = queue.peek() ?: return false
        if (expected != value) return false
        queue.poll()
        if (queue.isEmpty()) events.remove(articleId, queue)
        return true
    }

    private fun discardExpectedEvent(
        events: ConcurrentHashMap<Long, ConcurrentLinkedQueue<Boolean>>,
        articleId: Long,
        value: Boolean,
    ) {
        val queue = events[articleId] ?: return
        queue.remove(value)
        if (queue.isEmpty()) events.remove(articleId, queue)
    }

    private fun adjustedReadTotal(
        total: ULong?,
        selection: AndroidArticleTimelineSelection,
        previous: Boolean,
        requested: Boolean,
    ): ULong? {
        if (total == null || selection.readFilter != AndroidArticleReadFilter.Unread || previous == requested) {
            return total
        }
        return if (!previous && requested) {
            total - 1uL.coerceAtMost(total)
        } else {
            total + 1uL
        }
    }

    private fun adjustedStarredTotal(
        total: ULong?,
        selection: AndroidArticleTimelineSelection,
        previous: Boolean,
        requested: Boolean,
    ): ULong? {
        if (total == null || selection.scope != AndroidNewsScope.Starred || previous == requested) {
            return total
        }
        return if (previous && !requested) {
            total - 1uL.coerceAtMost(total)
        } else {
            total + 1uL
        }
    }

    suspend fun reset(selection: AndroidArticleTimelineSelection) {
        explicitReadMutationTokens.clear()
        explicitStarredMutationTokens.clear()
        expectedReadEvents.clear()
        expectedStarredEvents.clear()
        scrolloverRetainedReadIds.clear()
        scrolloverFeedbackSuppressedReadIds.clear()
        undoFeedbackSuppressedUnreadIds.clear()
        pendingSuccessfulScrolloverUndoIds.clear()
        recentSuccessfulScrolloverReads.clear()
        clearScrolloverUndoGroup()
        scrolloverConfirmationPending = false
        articleIndexById.clear()
        rowPresentationById.clear()
        while (scrolloverMutationRequests.tryReceive().isSuccess) {
            // A semantic Timeline reset starts a new Scrollover generation.
        }
        val generation = ++requestGeneration
        val sessionGeneration = activeSessionGeneration()
        val previous = mutableState.value
        val sameSession = previous.sessionGeneration == null || previous.sessionGeneration == sessionGeneration
        if (!sameSession) {
            expectedBulkReadEventIds.clear()
            feedIconCacheByVariant.clear()
            unavailableFeedIconsByVariant.clear()
            feedIconRequestsInFlight.clear()
        }
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            feedIconVariant = previous.feedIconVariant.takeIf { sameSession },
            feedIconPngByFeedId = previous.feedIconPngByFeedId.takeIf { sameSession }.orEmpty(),
            pendingNewFeedIds = previous.pendingNewFeedIds.takeIf { sameSession }.orEmpty(),
            hasUnscopedNewDataSignal = sameSession && previous.hasUnscopedNewDataSignal,
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
        rebuildArticleIndex(articles)
        reconcileRowPresentations(articles, replace = true)
        val iconState = mutableState.value
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            articles = articles,
            audioArticleIds = audioArticleIds,
            feedIconVariant = iconState.feedIconVariant,
            feedIconPngByFeedId = iconState.feedIconPngByFeedId,
            pendingNewFeedIds = iconState.pendingNewFeedIds,
            hasUnscopedNewDataSignal = iconState.hasUnscopedNewDataSignal,
            total = page.total,
            nextCursor = page.nextCursor.takeIf { articles.isNotEmpty() },
            initialLoading = false,
            queryGeneration = generation,
            sessionGeneration = sessionGeneration,
        )
    }

    fun hasPendingNewDataForScope(
        scope: AndroidNewsScope,
        categoryFeedIds: Set<Long> = emptySet(),
    ): Boolean {
        val current = mutableState.value
        if (current.hasUnscopedNewDataSignal) return true
        return when (scope) {
            AndroidNewsScope.All,
            AndroidNewsScope.Starred,
            -> current.pendingNewFeedIds.isNotEmpty()
            is AndroidNewsScope.Category -> current.pendingNewFeedIds.any { it in categoryFeedIds }
            is AndroidNewsScope.Feed -> scope.id in current.pendingNewFeedIds
        }
    }

    fun acknowledgePendingNewDataForScope(
        scope: AndroidNewsScope,
        categoryFeedIds: Set<Long> = emptySet(),
    ) {
        mutableState.update { state ->
            val remainingFeedIds = when (scope) {
                AndroidNewsScope.All,
                AndroidNewsScope.Starred,
                -> emptySet()
                is AndroidNewsScope.Category -> state.pendingNewFeedIds - categoryFeedIds
                is AndroidNewsScope.Feed -> state.pendingNewFeedIds - scope.id
            }
            state.copy(
                pendingNewFeedIds = remainingFeedIds,
                hasUnscopedNewDataSignal = false,
            )
        }
    }

    suspend fun adoptPendingNewData(
        selection: AndroidArticleTimelineSelection,
        categoryFeedIds: Set<Long> = emptySet(),
    ) {
        acknowledgePendingNewDataForScope(selection.scope, categoryFeedIds)
        reset(selection)
        mutableScrollResetRequests.tryEmit(Unit)
    }

    private fun clearPendingNewData() {
        mutableState.update {
            it.copy(
                pendingNewFeedIds = emptySet(),
                hasUnscopedNewDataSignal = false,
            )
        }
    }

    suspend fun handleCoreEvent(runtimeEvent: AndroidCoreRuntimeEvent) {
        val current = mutableState.value
        val selection = current.selection ?: return
        if (runtimeEvent.generation != current.sessionGeneration || runtimeEvent.generation != activeSessionGeneration()) {
            return
        }

        when (val event = runtimeEvent.event) {
            is CoreEvent.ArticleReadStateChanged -> {
                if (event.read && expectedBulkReadEventIds.remove(event.articleId)) return
                if (consumeExpectedEvent(expectedReadEvents, event.articleId, event.read)) return
                val suppressFeedback = if (event.read) {
                    scrolloverFeedbackSuppressedReadIds.remove(event.articleId)
                } else {
                    undoFeedbackSuppressedUnreadIds.remove(event.articleId)
                }
                if (!event.read) scrolloverFeedbackSuppressedReadIds.remove(event.articleId)
                applyReadStateChanged(selection, event.articleId, event.read)
                if (!event.read) {
                    mutableScrolloverRearmRequests.tryEmit(listOf(event.articleId))
                }
                if (!suppressFeedback) mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            }
            is CoreEvent.ArticleStarredStateChanged -> {
                if (consumeExpectedEvent(expectedStarredEvents, event.articleId, event.starred)) return
                applyStarredStateChanged(selection, event.articleId, event.starred)
                mutableFeedback.tryEmit(AndroidTimelineHaptic.Confirmation)
            }
            is CoreEvent.SyncDidComplete -> {
                val metadata = event.metadata
                if (metadata.navigationChanged) {
                    unavailableFeedIconsByVariant.clear()
                }

                if (metadata.reason == SyncReason.MANUAL) {
                    clearPendingNewData()
                    reset(selection)
                    mutableScrollResetRequests.tryEmit(Unit)
                } else if (metadata.dataChanged) {
                    val newFeedIds = metadata.newArticlesByFeed
                        .asSequence()
                        .filter { it.count > 0u }
                        .mapTo(mutableSetOf()) { it.feedId }
                    mutableState.update { state ->
                        state.copy(
                            pendingNewFeedIds = state.pendingNewFeedIds + newFeedIds,
                            hasUnscopedNewDataSignal =
                                state.hasUnscopedNewDataSignal || newFeedIds.isEmpty(),
                        )
                    }
                    refreshSelectionTotal(
                        selection = selection,
                        generation = current.queryGeneration,
                        sessionGeneration = current.sessionGeneration,
                    )
                }
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
        val index = articleIndexById[articleId] ?: -1
        val retainScrolloverRow = read && articleId in scrolloverRetainedReadIds

        if (selection.readFilter == AndroidArticleReadFilter.Unread && !read && index < 0) {
            reset(selection)
            return
        }

        if (index >= 0) {
            val currentIndex = articleIndexById[articleId]
            if (
                currentIndex != null &&
                currentIndex in current.articles.indices &&
                current.articles[currentIndex].id == articleId
            ) {
                if (selection.readFilter == AndroidArticleReadFilter.Unread && read && !retainScrolloverRow) {
                    mutableState.update { state ->
                        if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
                        val filtered = state.articles.filterNot { it.id == articleId }
                        rebuildArticleIndex(filtered)
                        rowPresentationById.remove(articleId)
                        state.copy(
                            articles = filtered,
                            audioArticleIds = state.audioArticleIds - articleId,
                        )
                    }
                } else {
                    setRowRead(articleId, read)
                }
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

        val accepted = articleIds.asSequence()
            .distinct()
            .filter { id ->
                val index = articleIndexById[id] ?: return@filter false
                current.articles.getOrNull(index)?.takeIf { it.id == id } ?: return@filter false
                rowPresentationById[id]?.value?.isRead == false
            }
            .toList()
        if (accepted.isEmpty()) return emptyList()

        scrolloverRetainedReadIds.addAll(accepted)
        expectedBulkReadEventIds.addAll(accepted)
        accepted.forEach { setRowRead(it, true) }
        mutableState.update { state ->
            if (
                state.queryGeneration != current.queryGeneration ||
                state.selection != selection ||
                state.sessionGeneration != sessionGeneration
            ) {
                return@update state
            }
            state.copy(
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
            if (!owns(current.queryGeneration, selection, sessionGeneration)) return emptyList()
            pendingSuccessfulScrolloverUndoIds += accepted
            scrolloverConfirmationPending = true
            emptyList()
        } catch (_: Exception) {
            expectedBulkReadEventIds.removeAll(accepted.toSet())
            scrolloverRetainedReadIds.removeAll(accepted.toSet())
            if (owns(current.queryGeneration, selection, sessionGeneration)) {
                accepted.forEach { id ->
                    if (rowPresentationById[id]?.value?.isRead == true) setRowRead(id, false)
                }
                mutableState.update { state ->
                    state.copy(
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
            val restoredCount = ids.count { rowPresentationById[it]?.value?.isRead == true }
            ids.forEach { setRowRead(it, false) }
            mutableState.update { state ->
                if (
                    state.selection != selection ||
                    state.sessionGeneration != sessionGeneration
                ) {
                    return@update state
                }
                state.copy(
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
        val index = articleIndexById[articleId] ?: -1
        val starredScope = selection.scope == AndroidNewsScope.Starred

        if (starredScope && starred && index < 0) {
            reset(selection)
            return
        }

        if (index >= 0) {
            val currentIndex = articleIndexById[articleId]
            if (
                currentIndex != null &&
                currentIndex in current.articles.indices &&
                current.articles[currentIndex].id == articleId
            ) {
                if (starredScope && !starred) {
                    mutableState.update { state ->
                        if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
                        val filtered = state.articles.filterNot { it.id == articleId }
                        rebuildArticleIndex(filtered)
                        rowPresentationById.remove(articleId)
                        state.copy(
                            articles = filtered,
                            audioArticleIds = state.audioArticleIds - articleId,
                        )
                    }
                } else {
                    setRowStarred(articleId, starred)
                }
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
        val appended = page.articles.filter { !articleIndexById.containsKey(it.id) }
        val appendedAudioArticleIds = loadAudioArticleIds(appended.map { it.id })

        if (!owns(generation, selection, currentSessionGeneration)) return
        mutableState.update { state ->
            if (state.queryGeneration != generation || state.selection != selection) return@update state

            val currentAppend = appended.filter { !articleIndexById.containsKey(it.id) }
            val madeProgress = currentAppend.isNotEmpty()
            val nextCursor = page.nextCursor.takeIf { madeProgress && it != cursor }

            currentAppend.forEachIndexed { offset, article ->
                articleIndexById[article.id] = state.articles.size + offset
            }
            reconcileRowPresentations(currentAppend, replace = false)
            state.copy(
                articles = state.articles + currentAppend,
                audioArticleIds = state.audioArticleIds + appendedAudioArticleIds,
                nextCursor = nextCursor,
                loadingNextPage = false,
                errorMessage = null,
            )
        }
    }

    private fun rebuildArticleIndex(articles: List<ArticleSummary>) {
        articleIndexById.clear()
        articles.forEachIndexed { index, article -> articleIndexById[article.id] = index }
    }

    private fun reconcileRowPresentations(
        articles: List<ArticleSummary>,
        replace: Boolean,
    ) {
        if (replace) {
            val retainedIds = articles.asSequence().map { it.id }.toHashSet()
            rowPresentationById.keys.removeIf { it !in retainedIds }
        }
        articles.forEach { article ->
            val state = rowPresentationById[article.id]
            if (state == null) {
                rowPresentationById[article.id] = MutableStateFlow(
                    AndroidArticleRowPresentation(
                        isRead = article.isRead,
                        isStarred = article.isStarred,
                    ),
                )
            } else {
                val current = state.value
                if (current.isRead != article.isRead || current.isStarred != article.isStarred) {
                    state.value = current.copy(
                        isRead = article.isRead,
                        isStarred = article.isStarred,
                        revision = current.revision + 1L,
                    )
                }
            }
        }
    }

    private fun setRowRead(articleId: Long, read: Boolean): Boolean {
        val state = rowPresentationById[articleId] ?: return false
        val current = state.value
        if (current.isRead == read) return false
        state.value = current.copy(isRead = read, revision = current.revision + 1L)
        return true
    }

    private fun setRowStarred(articleId: Long, starred: Boolean): Boolean {
        val state = rowPresentationById[articleId] ?: return false
        val current = state.value
        if (current.isStarred == starred) return false
        state.value = current.copy(isStarred = starred, revision = current.revision + 1L)
        return true
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
        val current = mutableState.value
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            initialLoading = false,
            errorMessage = "Articles could not be loaded.",
            queryGeneration = generation,
            sessionGeneration = sessionGeneration,
            pendingNewFeedIds = current.pendingNewFeedIds,
            hasUnscopedNewDataSignal = current.hasUnscopedNewDataSignal,
        )
    }
}

@Composable
internal fun AndroidArticleTimeline(
    store: AndroidArticleTimelineStore,
    selection: AndroidArticleTimelineSelection,
    sessionGeneration: Long?,
    accountKey: String,
    onOpenArticle: (ArticleSummary) -> Unit,
    onOpenReader: (ArticleSummary) -> Unit,
    categoryFeedIds: Set<Long> = emptySet(),
    topContentPadding: Dp = 0.dp,
    bottomOverlayPadding: Dp = 0.dp,
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    val undoState by store.undoState.collectAsState()
    val articlePreferences by LocalAndroidArticlePreferences.current.state.collectAsState(
        initial = AndroidArticlePreferenceState(),
    )
    val errorMessage = state.errorMessage
    val pendingNewDataForCurrentScope = store.hasPendingNewDataForScope(
        scope = selection.scope,
        categoryFeedIds = categoryFeedIds,
    )
    val listState = rememberLazyListState()
    val scrolloverTracker = remember { AndroidScrolloverTracker() }
    val actionScope = rememberCoroutineScope()
    val actionSnackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
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

    fun showActionMessage(message: String) {
        actionScope.launch { actionSnackbar.showSnackbar(message) }
    }

    fun performSwipeAction(article: ArticleSummary, action: AndroidArticleSwipeAction) {
        when (action) {
            AndroidArticleSwipeAction.ReadUnread -> {
                store.requestSetRead(
                    articleId = article.id,
                    read = !article.isRead,
                    removeWhenRead = articlePreferences.removeArticlesWhenRead,
                )
            }
            AndroidArticleSwipeAction.StarUnstar -> {
                store.requestSetStarred(article.id, !article.isStarred)
            }
            AndroidArticleSwipeAction.OpenOriginal -> {
                store.requestSetRead(
                    articleId = article.id,
                    read = true,
                    removeWhenRead = articlePreferences.removeArticlesWhenRead,
                    providesFeedback = false,
                )
                if (!AndroidArticlePlatformActions.openUrl(context, article.url)) {
                    showActionMessage("The article does not have a valid web URL.")
                }
            }
            AndroidArticleSwipeAction.OpenMiniflux -> {
                store.requestSetRead(
                    articleId = article.id,
                    read = true,
                    removeWhenRead = articlePreferences.removeArticlesWhenRead,
                    providesFeedback = false,
                )
                actionScope.launch {
                    val url = store.resolveMinifluxEntryUrl(article.id)
                    if (url == null || !AndroidArticlePlatformActions.openUrl(context, url)) {
                        actionSnackbar.showSnackbar("Flux could not resolve a valid Miniflux entry URL.")
                    }
                }
            }
            AndroidArticleSwipeAction.Comments -> {
                if (!AndroidArticlePlatformActions.openUrl(context, article.commentsUrl)) {
                    showActionMessage("The article does not have a valid comments URL.")
                }
            }
            AndroidArticleSwipeAction.Share -> {
                if (!AndroidArticlePlatformActions.share(context, article)) {
                    showActionMessage("The article could not be shared.")
                }
            }
            AndroidArticleSwipeAction.SaveToService -> {
                store.requestSaveToService(article.id)
            }
            AndroidArticleSwipeAction.ListeningList,
            AndroidArticleSwipeAction.DownloadAudio,
            -> Unit
        }
    }

    fun performContextAction(article: ArticleSummary, action: AndroidArticleContextAction) {
        when (action) {
            AndroidArticleContextAction.ReadUnread ->
                performSwipeAction(article, AndroidArticleSwipeAction.ReadUnread)
            AndroidArticleContextAction.StarUnstar ->
                performSwipeAction(article, AndroidArticleSwipeAction.StarUnstar)
            AndroidArticleContextAction.OpenOriginal ->
                performSwipeAction(article, AndroidArticleSwipeAction.OpenOriginal)
            AndroidArticleContextAction.Reader -> {
                store.requestSetRead(
                    articleId = article.id,
                    read = true,
                    removeWhenRead = articlePreferences.removeArticlesWhenRead,
                    providesFeedback = false,
                )
                onOpenReader(article)
            }
            AndroidArticleContextAction.OpenMiniflux ->
                performSwipeAction(article, AndroidArticleSwipeAction.OpenMiniflux)
            AndroidArticleContextAction.Comments ->
                performSwipeAction(article, AndroidArticleSwipeAction.Comments)
            AndroidArticleContextAction.CopyLink -> {
                if (AndroidArticlePlatformActions.copyLink(context, article)) {
                    showActionMessage("Link copied.")
                } else {
                    showActionMessage("The article does not have a valid web URL.")
                }
            }
            AndroidArticleContextAction.Share ->
                performSwipeAction(article, AndroidArticleSwipeAction.Share)
            AndroidArticleContextAction.SaveToService ->
                performSwipeAction(article, AndroidArticleSwipeAction.SaveToService)
        }
    }

    LaunchedEffect(store, actionSnackbar) {
        store.actionMessages.collect { message ->
            actionSnackbar.showSnackbar(message)
        }
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

    DisposableEffect(store, state.queryGeneration) {
        onDispose {
            store.enqueueScrolloverInteractionComplete()
        }
    }

    LaunchedEffect(store, listState) {
        store.scrollResetRequests.collect {
            if (listState.layoutInfo.totalItemsCount > 0) {
                listState.scrollToItem(0)
            }
        }
    }

    LaunchedEffect(store, scrolloverTracker) {
        store.scrolloverRearmRequests.collect { articleIds ->
            scrolloverTracker.rearm(articleIds)
        }
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
                        val candidates = scrolloverTracker.beginUserScroll(
                            sample = listState.scrolloverGeometrySample(),
                            enabled = articlePreferences.markReadOnScrollover,
                        )
                        store.enqueueScrolloverCandidates(candidates)
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
                store.enqueueScrolloverCandidates(candidates)
                if (!scrolling) {
                    scrolloverTracker.endUserScroll()
                    store.enqueueScrolloverInteractionComplete()
                }
            }
    }

    LaunchedEffect(selection, sessionGeneration, accountKey) {
        val current = store.state.value
        val sameContext =
            current.selection == selection &&
                current.sessionGeneration == sessionGeneration
        if (sameContext) return@LaunchedEffect

        if (listState.firstVisibleItemIndex != 0 || listState.firstVisibleItemScrollOffset != 0) {
            listState.scrollToItem(0)
        }
        store.acknowledgePendingNewDataForScope(selection.scope, categoryFeedIds)
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
                contentPadding = PaddingValues(top = topContentPadding, bottom = bottomOverlayPadding),
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
                    val hasAudio = article.id in state.audioArticleIds
                    AndroidArticleSwipeContainer(
                        article = article,
                        hasAudio = hasAudio,
                        configuration = articlePreferences.swipeConfiguration,
                        rowWidth = maxWidth,
                        onOpen = { onOpenArticle(article) },
                        onSwipeAction = { action -> performSwipeAction(article, action) },
                        onContextAction = { action -> performContextAction(article, action) },
                    ) {
                        AndroidArticleTimelineRow(
                            article = article,
                            hasAudio = hasAudio,
                            preferences = articlePreferences,
                            publicationReferenceMillis = publicationReferenceMillis,
                            feedIconPng = state.feedIconPngByFeedId[article.feedId],
                            feedIconVariant = feedIconVariant,
                            availableWidth = availableWidth,
                            onRequestFeedIcon = store::ensureFeedIcon,
                        )
                    }
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

    val supplementalOverlayVisible = undoState.visible || pendingNewDataForCurrentScope
    SnackbarHost(
        hostState = actionSnackbar,
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .padding(
                start = 16.dp,
                end = 16.dp,
                bottom = bottomOverlayPadding + (if (supplementalOverlayVisible) 88.dp else 20.dp),
            ),
    )

    if (undoState.visible) {
        Snackbar(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(
                    start = 16.dp,
                    end = 16.dp,
                    top = 20.dp,
                    bottom = bottomOverlayPadding + 20.dp,
                ),
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
    } else if (pendingNewDataForCurrentScope) {
        Button(
            onClick = {
                actionScope.launch {
                    store.adoptPendingNewData(selection, categoryFeedIds)
                }
            },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(
                    start = 16.dp,
                    end = 16.dp,
                    top = 20.dp,
                    bottom = bottomOverlayPadding + 20.dp,
                ),
        ) {
            Text("New articles available")
        }
    }
    }
}

internal fun View.performFluxConfirmationHaptic() {
    val feedbackConstant = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        HapticFeedbackConstants.CONFIRM
    } else {
        HapticFeedbackConstants.VIRTUAL_KEY
    }
    performHapticFeedback(feedbackConstant)
}

internal fun View.performFluxSelectionHaptic() {
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
internal fun AndroidArticleTimelineRow(
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
                hasAudio = hasAudio,
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
}

@Composable
private fun ArticleMetadataRow(
    article: ArticleSummary,
    hasAudio: Boolean,
    feedIconPng: ByteArray?,
    feedIconVariant: FeedIconVariant,
    onRequestFeedIcon: suspend (Long, FeedIconVariant) -> Unit,
    requestIfMissing: Boolean = true,
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
            requestIfMissing = requestIfMissing,
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
    hasAudio: Boolean,
    preferences: AndroidArticlePreferenceState,
    publicationReferenceMillis: Long,
) {
    val supportingColor = MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (preferences.showRelativePublicationTime) {
            Icon(
                painter = painterResource(R.drawable.ic_relative_time),
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = supportingColor,
            )
        }
        Text(
            publicationLabel(
                article = article,
                relative = preferences.showRelativePublicationTime,
                referenceMillis = publicationReferenceMillis,
            ),
            style = MaterialTheme.typography.labelSmall,
            color = supportingColor,
        )
        if (article.readingTimeMinutes > 0u) {
            Text(
                "·",
                style = MaterialTheme.typography.labelSmall,
                color = supportingColor,
            )
            Icon(
                painter = painterResource(
                    if (hasAudio) R.drawable.ic_headphones else R.drawable.ic_reading_time,
                ),
                contentDescription = if (hasAudio) "Audio duration" else "Reading time",
                modifier = Modifier.size(13.dp),
                tint = supportingColor,
            )
            Text(
                "${article.readingTimeMinutes} min",
                style = MaterialTheme.typography.labelSmall,
                color = supportingColor,
            )
        }
    }
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
    return publication
}

private enum class AndroidArticleImageLoadState {
    Loading,
    Success,
    Error,
}

@Composable
private fun ArticleImage(
    imageUrl: String,
    modifier: Modifier = Modifier,
) {
    var loadState by remember(imageUrl) {
        mutableStateOf(AndroidArticleImageLoadState.Loading)
    }

    Box(
        modifier = modifier
            .clip(MaterialTheme.shapes.medium)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        AsyncImage(
            model = imageUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            onLoading = {
                loadState = AndroidArticleImageLoadState.Loading
            },
            onSuccess = {
                loadState = AndroidArticleImageLoadState.Success
            },
            onError = {
                loadState = AndroidArticleImageLoadState.Error
            },
            modifier = Modifier.fillMaxSize(),
        )

        when (loadState) {
            AndroidArticleImageLoadState.Loading -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            AndroidArticleImageLoadState.Error -> {
                Icon(
                    painter = painterResource(R.drawable.ic_news),
                    contentDescription = "Image could not be loaded",
                    modifier = Modifier.size(32.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            AndroidArticleImageLoadState.Success -> Unit
        }
    }
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
