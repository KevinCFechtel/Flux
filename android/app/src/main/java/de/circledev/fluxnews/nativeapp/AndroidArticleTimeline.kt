package de.circledev.fluxnews.nativeapp

import android.text.format.DateUtils
import android.text.format.DateUtils.FORMAT_ABBREV_RELATIVE
import android.text.format.DateUtils.MINUTE_IN_MILLIS
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import coil3.compose.AsyncImage
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
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
import uniffi.flux_uniffi.MediaKind
import uniffi.flux_uniffi.ReadFilter
import uniffi.flux_uniffi.StarredFilter

private const val ANDROID_ARTICLE_TIMELINE_PAGE_SIZE = 64
private const val ANDROID_ARTICLE_TIMELINE_PREFETCH_DISTANCE = 8

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

internal object AndroidArticleRowPolicy {
    fun accessories(article: ArticleSummary, hasAudio: Boolean): List<AndroidArticleAccessory> = buildList {
        if (!article.isRead) add(AndroidArticleAccessory.Unread)
        if (article.isStarred) add(AndroidArticleAccessory.Star)
        if (article.commentsUrl.isNotBlank()) add(AndroidArticleAccessory.Comments)
        if (hasAudio) add(AndroidArticleAccessory.Audio)
    }

    fun showsImage(mode: AndroidArticlePresentationMode, imageUrl: String?): Boolean =
        mode != AndroidArticlePresentationMode.Compact && !imageUrl.isNullOrBlank()
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
    private val activeSessionGeneration: () -> Long?,
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
        activeSessionGeneration = coreRuntime::activeSessionGeneration,
    )

    internal constructor(
        pageLoader: suspend (ArticleQuery, Boolean) -> ArticlePage,
        activeSessionGeneration: () -> Long?,
        audioArticleIdsLoader: suspend (List<Long>) -> Set<Long> = { emptySet() },
        @Suppress("UNUSED_PARAMETER") testOnly: Unit,
    ) : this(pageLoader, audioArticleIdsLoader, activeSessionGeneration)

    private val mutableState = MutableStateFlow(AndroidArticleTimelineState())
    private var requestGeneration = 0L

    val state = mutableState.asStateFlow()

    suspend fun reset(selection: AndroidArticleTimelineSelection) {
        val generation = ++requestGeneration
        val sessionGeneration = activeSessionGeneration()
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
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
        mutableState.value = AndroidArticleTimelineState(
            selection = selection,
            articles = articles,
            audioArticleIds = audioArticleIds,
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
                applyReadStateChanged(selection, event.articleId, event.read)
            }
            is CoreEvent.ArticleStarredStateChanged -> {
                applyStarredStateChanged(selection, event.articleId, event.starred)
            }
            is CoreEvent.SyncDidComplete -> {
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
        val current = mutableState.value
        val index = current.articles.indexOfFirst { it.id == articleId }

        if (selection.readFilter == AndroidArticleReadFilter.Unread && !read && index < 0) {
            reset(selection)
            return
        }

        if (index < 0) return

        mutableState.update { state ->
            if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
            val currentIndex = state.articles.indexOfFirst { it.id == articleId }
            if (currentIndex < 0) return@update state

            if (selection.readFilter == AndroidArticleReadFilter.Unread && read) {
                state.copy(
                    articles = state.articles.filterNot { it.id == articleId },
                    audioArticleIds = state.audioArticleIds - articleId,
                    total = state.total?.let { if (it > 0uL) it - 1uL else 0uL },
                )
            } else {
                val articles = state.articles.toMutableList()
                articles[currentIndex] = articles[currentIndex].copy(isRead = read)
                state.copy(articles = articles)
            }
        }
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

        if (index < 0) return

        mutableState.update { state ->
            if (state.selection != selection || state.sessionGeneration != current.sessionGeneration) return@update state
            val currentIndex = state.articles.indexOfFirst { it.id == articleId }
            if (currentIndex < 0) return@update state

            if (starredScope && !starred) {
                state.copy(
                    articles = state.articles.filterNot { it.id == articleId },
                    audioArticleIds = state.audioArticleIds - articleId,
                    total = state.total?.let { if (it > 0uL) it - 1uL else 0uL },
                )
            } else {
                val articles = state.articles.toMutableList()
                articles[currentIndex] = articles[currentIndex].copy(isStarred = starred)
                state.copy(articles = articles)
            }
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
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    val articlePreferences by LocalAndroidArticlePreferences.current.state.collectAsState(
        initial = AndroidArticlePreferenceState(),
    )
    val errorMessage = state.errorMessage
    val listState = rememberLazyListState()
    val actionScope = rememberCoroutineScope()
    val publicationReferenceMillis = remember(state.queryGeneration) { System.currentTimeMillis() }

    LaunchedEffect(selection, sessionGeneration, accountKey) {
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

    when {
        state.initialLoading && state.articles.isEmpty() -> {
            Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
        errorMessage != null && state.articles.isEmpty() -> {
            TimelineMessage(
                message = errorMessage,
                actionLabel = "Retry",
                onAction = { actionScope.launch { store.reset(selection) } },
                modifier = modifier,
            )
        }
        state.empty -> {
            TimelineMessage(
                message = "No articles in this view.",
                modifier = modifier,
            )
        }
        else -> {
            LazyColumn(
                state = listState,
                modifier = modifier.fillMaxSize(),
            ) {
                items(
                    items = state.articles,
                    key = { article -> article.id },
                ) { article ->
                    AndroidArticleTimelineRow(
                        article = article,
                        hasAudio = article.id in state.audioArticleIds,
                        preferences = articlePreferences,
                        publicationReferenceMillis = publicationReferenceMillis,
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
}

@Composable
private fun AndroidArticleTimelineRow(
    article: ArticleSummary,
    hasAudio: Boolean,
    preferences: AndroidArticlePreferenceState,
    publicationReferenceMillis: Long,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            article.feedTitle,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
        )

        when (preferences.presentationMode) {
            AndroidArticlePresentationMode.Compact -> {
                ArticleTextContent(
                    article = article,
                    preferences = preferences,
                    publicationReferenceMillis = publicationReferenceMillis,
                )
            }
            AndroidArticlePresentationMode.Visual -> {
                ArticleTextContent(
                    article = article,
                    preferences = preferences,
                    publicationReferenceMillis = publicationReferenceMillis,
                )
                if (AndroidArticleRowPolicy.showsImage(preferences.presentationMode, article.imageUrl)) {
                    ArticleImage(
                        imageUrl = article.imageUrl!!,
                        modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                    )
                }
            }
            AndroidArticlePresentationMode.VisualCompact -> {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        ArticleTextContent(
                            article = article,
                            preferences = preferences,
                            publicationReferenceMillis = publicationReferenceMillis,
                        )
                    }
                    if (AndroidArticleRowPolicy.showsImage(preferences.presentationMode, article.imageUrl)) {
                        ArticleImage(
                            imageUrl = article.imageUrl!!,
                            modifier = Modifier.width(112.dp).height(84.dp),
                        )
                    }
                }
            }
        }

        ArticleAccessories(
            accessories = AndroidArticleRowPolicy.accessories(article, hasAudio),
        )
    }
    HorizontalDivider()
}

@Composable
private fun ArticleTextContent(
    article: ArticleSummary,
    preferences: AndroidArticlePreferenceState,
    publicationReferenceMillis: Long,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            article.title,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = if (article.isRead) FontWeight.Normal else FontWeight.SemiBold,
            color = if (article.isRead) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        )
        Text(
            publicationLabel(
                article = article,
                relative = preferences.showRelativePublicationTime,
                referenceMillis = publicationReferenceMillis,
            ),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val preview = article.preview.trim()
        if (preview.isNotEmpty()) {
            Text(
                preview,
                maxLines = preferences.previewLines.lineCount,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun publicationLabel(
    article: ArticleSummary,
    relative: Boolean,
    referenceMillis: Long,
): String {
    val context = LocalContext.current
    val locales = LocalConfiguration.current.locales
    val publishedMillis = parseArticlePublishedAtMillis(article.publishedAt)
    val publication = remember(article.publishedAt, relative, referenceMillis, locales) {
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
private fun ArticleAccessories(accessories: List<AndroidArticleAccessory>) {
    if (accessories.isEmpty()) return
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        accessories.forEach { accessory ->
            when (accessory) {
                AndroidArticleAccessory.Unread -> Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary),
                )
                AndroidArticleAccessory.Star -> Icon(
                    painter = painterResource(R.drawable.ic_star),
                    contentDescription = "Starred",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
                AndroidArticleAccessory.Comments -> Icon(
                    painter = painterResource(R.drawable.ic_comment),
                    contentDescription = "Comments",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                AndroidArticleAccessory.Audio -> Icon(
                    painter = painterResource(R.drawable.ic_headphones),
                    contentDescription = "Audio",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
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
