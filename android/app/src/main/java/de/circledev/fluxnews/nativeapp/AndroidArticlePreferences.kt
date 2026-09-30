package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

internal enum class AndroidArticleOpenPreference(
    val storedValue: String,
    val displayName: String,
) {
    OriginalLink("original", "Original link"),
    Reader("reader", "Reader"),
    ;

    companion object {
        fun fromStoredValue(value: String): AndroidArticleOpenPreference =
            entries.firstOrNull { it.storedValue == value } ?: OriginalLink
    }
}

internal enum class AndroidArticlePresentationMode(
    val storedValue: String,
    val displayName: String,
) {
    Compact("compact", "Compact"),
    Visual("visual", "Visual"),
    VisualCompact("visualCompact", "Visual Compact"),
    ;

    companion object {
        fun fromStoredValue(value: String): AndroidArticlePresentationMode =
            entries.firstOrNull { it.storedValue == value } ?: Visual
    }
}

internal enum class AndroidArticlePreviewLines(
    val lineCount: Int,
    val displayName: String,
) {
    Compact(2, "2 lines"),
    Standard(3, "3 lines"),
    Extended(5, "5 lines"),
    ;

    companion object {
        fun fromStoredValue(value: Int): AndroidArticlePreviewLines =
            entries.firstOrNull { it.lineCount == value } ?: Standard
    }
}

internal data class AndroidArticlePreferenceState(
    val openArticle: AndroidArticleOpenPreference = AndroidArticleOpenPreference.OriginalLink,
    val presentationMode: AndroidArticlePresentationMode = AndroidArticlePresentationMode.Visual,
    val previewLines: AndroidArticlePreviewLines = AndroidArticlePreviewLines.Standard,
    val showArticleCount: Boolean = true,
    val showRelativePublicationTime: Boolean = false,
    val removeArticlesWhenRead: Boolean = false,
    val markReadOnScrollover: Boolean = true,
)

/**
 * Platform-local Article presentation preferences. These are presentation/routing choices only;
 * Core-owned retention, delivery, Reader limits and feed preferences stay in Core.
 */
internal class AndroidArticlePreferences(
    private val store: AndroidPreferenceStore,
) {
    private val openArticleKey = AndroidPreferenceKey.string("articles-open")
    private val presentationModeKey = AndroidPreferenceKey.string("articles-presentation-mode")
    private val previewLinesKey = AndroidPreferenceKey.int("articles-preview-lines")
    private val showArticleCountKey = AndroidPreferenceKey.boolean("articles-show-count")
    private val relativePublicationTimeKey = AndroidPreferenceKey.boolean("articles-relative-publication-time")
    private val removeWhenReadKey = AndroidPreferenceKey.boolean("articles-remove-when-read")
    private val scrolloverKey = AndroidPreferenceKey.boolean("articles-mark-read-on-scrollover")

    private val routingAndPresentation = combine(
        store.observe(openArticleKey, AndroidArticleOpenPreference.OriginalLink.storedValue),
        store.observe(presentationModeKey, AndroidArticlePresentationMode.Visual.storedValue),
        store.observe(previewLinesKey, AndroidArticlePreviewLines.Standard.lineCount),
        store.observe(showArticleCountKey, true),
    ) { openArticle, presentationMode, previewLines, showArticleCount ->
        PartialState(
            openArticle = AndroidArticleOpenPreference.fromStoredValue(openArticle),
            presentationMode = AndroidArticlePresentationMode.fromStoredValue(presentationMode),
            previewLines = AndroidArticlePreviewLines.fromStoredValue(previewLines),
            showArticleCount = showArticleCount,
        )
    }

    val state: Flow<AndroidArticlePreferenceState> = combine(
        routingAndPresentation,
        store.observe(relativePublicationTimeKey, false),
        store.observe(removeWhenReadKey, false),
        store.observe(scrolloverKey, true),
    ) { partial, relativePublicationTime, removeWhenRead, scrollover ->
        AndroidArticlePreferenceState(
            openArticle = partial.openArticle,
            presentationMode = partial.presentationMode,
            previewLines = partial.previewLines,
            showArticleCount = partial.showArticleCount,
            showRelativePublicationTime = relativePublicationTime,
            removeArticlesWhenRead = removeWhenRead,
            markReadOnScrollover = scrollover,
        )
    }.distinctUntilChanged()

    suspend fun setOpenArticle(value: AndroidArticleOpenPreference) {
        store.write(openArticleKey, value.storedValue)
    }

    suspend fun setPresentationMode(value: AndroidArticlePresentationMode) {
        store.write(presentationModeKey, value.storedValue)
    }

    suspend fun setPreviewLines(value: AndroidArticlePreviewLines) {
        store.write(previewLinesKey, value.lineCount)
    }

    suspend fun setShowArticleCount(value: Boolean) {
        store.write(showArticleCountKey, value)
    }

    suspend fun setShowRelativePublicationTime(value: Boolean) {
        store.write(relativePublicationTimeKey, value)
    }

    suspend fun setRemoveArticlesWhenRead(value: Boolean) {
        store.write(removeWhenReadKey, value)
    }

    suspend fun setMarkReadOnScrollover(value: Boolean) {
        store.write(scrolloverKey, value)
    }

    private data class PartialState(
        val openArticle: AndroidArticleOpenPreference,
        val presentationMode: AndroidArticlePresentationMode,
        val previewLines: AndroidArticlePreviewLines,
        val showArticleCount: Boolean,
    )
}
