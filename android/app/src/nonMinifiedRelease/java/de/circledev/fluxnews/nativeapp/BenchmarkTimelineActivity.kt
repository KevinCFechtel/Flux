package de.circledev.fluxnews.nativeapp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import uniffi.flux_uniffi.ArticleSummary
import uniffi.flux_uniffi.FeedIconVariant

/**
 * Benchmark-only deterministic Timeline fixture.
 *
 * This source set is absent from developmentRelease and productionRelease. It deliberately bypasses
 * account/Core bootstrap so Baseline Profile generation never depends on credentials, Miniflux,
 * network latency, or mutable user data while still exercising productive Timeline row/swipe UI.
 */
class BenchmarkTimelineActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            FluxNewsTheme {
                BenchmarkTimeline()
            }
        }
    }
}

@Composable
private fun BenchmarkTimeline() {
    val articles = remember { benchmarkArticles() }
    val preferences = remember {
        AndroidArticlePreferenceState(
            presentationMode = AndroidArticlePresentationMode.Visual,
            previewLines = AndroidArticlePreviewLines.Standard,
            showRelativePublicationTime = true,
            swipeConfiguration = AndroidArticleSwipeConfiguration.Default,
        )
    }
    val publicationReferenceMillis = remember { 1791100800000L }
    val feedIconVariant = if (isSystemInDarkTheme()) FeedIconVariant.DARK else FeedIconVariant.NORMAL

    Surface(modifier = Modifier.fillMaxSize()) {
        BoxWithConstraints {
            val rowWidth = maxWidth
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .semantics { contentDescription = "Benchmark article timeline" },
            ) {
                items(
                    items = articles,
                    key = { it.id },
                    contentType = { article ->
                        AndroidArticleRowPolicy.layoutVariant(
                            mode = preferences.presentationMode,
                            imageUrl = article.imageUrl,
                            availableWidthDp = rowWidth.value.toInt(),
                        )
                    },
                ) { article ->
                    val hasAudio = article.id % 7L == 0L
                    AndroidArticleSwipeContainer(
                        article = article,
                        hasAudio = hasAudio,
                        configuration = preferences.swipeConfiguration,
                        rowWidth = rowWidth,
                        onSwipeAction = {},
                        onContextAction = {},
                    ) {
                        AndroidArticleTimelineRow(
                            article = article,
                            hasAudio = hasAudio,
                            preferences = preferences,
                            publicationReferenceMillis = publicationReferenceMillis,
                            feedIconPng = null,
                            feedIconVariant = feedIconVariant,
                            availableWidth = rowWidth,
                            onRequestFeedIcon = { _, _ -> },
                        )
                    }
                }
            }
        }
    }
}

private fun benchmarkArticles(): List<ArticleSummary> =
    (1L..96L).map { id ->
        val feedIndex = ((id - 1L) % 6L).toInt()
        val withImage = id % 4L != 0L
        ArticleSummary(
            id = id,
            feedId = 100L + feedIndex,
            categoryId = 200L + (feedIndex % 3),
            feedTitle = BENCHMARK_FEEDS[feedIndex],
            title = when (id % 4L) {
                0L -> "A concise benchmark headline #$id"
                1L -> "A longer FluxNews benchmark headline that exercises realistic wrapping behavior #$id"
                2L -> "Native Android timeline rendering with deterministic article content #$id"
                else -> "Release performance fixture with stable Compose geometry #$id"
            },
            url = "https://benchmark.invalid/articles/$id",
            commentsUrl = if (id % 5L == 0L) "https://benchmark.invalid/comments/$id" else "",
            publishedAt = "2026-10-${((id - 1L) % 3L + 1L).toString().padStart(2, '0')}T12:00:00Z",
            isRead = id % 5L == 0L,
            isStarred = id % 9L == 0L,
            readingTimeMinutes = ((id % 11L) + 1L).toUInt(),
            preview = BENCHMARK_PREVIEWS[(id % BENCHMARK_PREVIEWS.size).toInt()],
            imageUrl = if (withImage) BENCHMARK_IMAGE_URL else null,
        )
    }

private val BENCHMARK_FEEDS = listOf(
    "Development",
    "Technology",
    "Science",
    "Design",
    "World News",
    "Long Feed Name for Layout Coverage",
)

private val BENCHMARK_PREVIEWS = listOf(
    "A short deterministic preview used for stable release profiling.",
    "This fixture intentionally includes a somewhat longer preview so text measurement, line wrapping, and ellipsis behavior follow the same productive code path as normal articles.",
    "Compose, image loading, metadata, publication time, and article accessories are all exercised without depending on network responses.",
    "Baseline Profile data should be repeatable, so this content never changes between runs.",
)

private const val BENCHMARK_IMAGE_URL =
    "android.resource://de.circle_dev.flux_news.native.dev.benchmark/drawable/benchmark_article_image"
