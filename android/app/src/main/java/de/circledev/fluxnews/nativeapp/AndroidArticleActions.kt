package de.circledev.fluxnews.nativeapp

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import java.net.URI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.ArticleSummary

internal enum class AndroidSaveToServiceOutcome {
    Saved,
    NoIntegrationConfigured,
}

internal enum class AndroidArticleContextAction {
    ReadUnread,
    StarUnstar,
    OpenOriginal,
    OpenMiniflux,
    Comments,
    CopyLink,
    Share,
    SaveToService,
}

internal data class AndroidResolvedSwipeSide(
    val additional: AndroidArticleSwipeAction?,
    val full: AndroidArticleSwipeAction?,
) {
    val visibleActions: List<AndroidArticleSwipeAction>
        get() = listOfNotNull(additional, full)
}

internal object AndroidArticleActionPolicy {
    fun validWebUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        (uri.scheme.equals("http", ignoreCase = true) || uri.scheme.equals("https", ignoreCase = true)) &&
            !uri.host.isNullOrBlank()
    }.getOrDefault(false)

    fun isSwipeActionAvailable(
        action: AndroidArticleSwipeAction,
        article: ArticleSummary,
        hasAudio: Boolean,
        mediaActionsEnabled: Boolean = false,
    ): Boolean = when (action) {
        AndroidArticleSwipeAction.ReadUnread,
        AndroidArticleSwipeAction.StarUnstar,
        AndroidArticleSwipeAction.OpenMiniflux,
        AndroidArticleSwipeAction.SaveToService,
        -> true

        AndroidArticleSwipeAction.OpenOriginal,
        AndroidArticleSwipeAction.Share,
        -> validWebUrl(article.url)

        AndroidArticleSwipeAction.Comments -> validWebUrl(article.commentsUrl)

        AndroidArticleSwipeAction.ListeningList,
        AndroidArticleSwipeAction.DownloadAudio,
        -> mediaActionsEnabled && hasAudio
    }

    fun resolveSwipeSide(
        configuration: AndroidArticleSwipeConfiguration,
        side: AndroidArticleSwipeSide,
        article: ArticleSummary,
        hasAudio: Boolean,
        mediaActionsEnabled: Boolean = false,
    ): AndroidResolvedSwipeSide {
        fun AndroidArticleSwipeAction?.available(): AndroidArticleSwipeAction? =
            this?.takeIf {
                isSwipeActionAvailable(
                    action = it,
                    article = article,
                    hasAudio = hasAudio,
                    mediaActionsEnabled = mediaActionsEnabled,
                )
            }

        return AndroidResolvedSwipeSide(
            additional = configuration.additionalAction(side).available(),
            full = configuration.fullSwipeAction(side).available(),
        )
    }

    fun contextActions(article: ArticleSummary): List<AndroidArticleContextAction> = buildList {
        add(AndroidArticleContextAction.StarUnstar)
        add(AndroidArticleContextAction.ReadUnread)
        if (validWebUrl(article.url)) add(AndroidArticleContextAction.OpenOriginal)
        add(AndroidArticleContextAction.OpenMiniflux)
        if (validWebUrl(article.commentsUrl)) add(AndroidArticleContextAction.Comments)
        if (validWebUrl(article.url)) {
            add(AndroidArticleContextAction.CopyLink)
            add(AndroidArticleContextAction.Share)
        }
        add(AndroidArticleContextAction.SaveToService)
    }

    fun swipeLabel(action: AndroidArticleSwipeAction, article: ArticleSummary): String = when (action) {
        AndroidArticleSwipeAction.ReadUnread -> if (article.isRead) "Unread" else "Read"
        AndroidArticleSwipeAction.StarUnstar -> if (article.isStarred) "Unstar" else "Star"
        AndroidArticleSwipeAction.OpenOriginal -> "Original"
        AndroidArticleSwipeAction.OpenMiniflux -> "Miniflux"
        AndroidArticleSwipeAction.Comments -> "Comments"
        AndroidArticleSwipeAction.Share -> "Share"
        AndroidArticleSwipeAction.SaveToService -> "Save"
        AndroidArticleSwipeAction.ListeningList -> "Listening"
        AndroidArticleSwipeAction.DownloadAudio -> "Download"
    }

    fun contextLabel(action: AndroidArticleContextAction, article: ArticleSummary): String = when (action) {
        AndroidArticleContextAction.ReadUnread -> if (article.isRead) "Mark as unread" else "Mark as read"
        AndroidArticleContextAction.StarUnstar -> if (article.isStarred) "Unstar" else "Star"
        AndroidArticleContextAction.OpenOriginal -> "Open original"
        AndroidArticleContextAction.OpenMiniflux -> "Open in Miniflux"
        AndroidArticleContextAction.Comments -> "Open comments"
        AndroidArticleContextAction.CopyLink -> "Copy link"
        AndroidArticleContextAction.Share -> "Share"
        AndroidArticleContextAction.SaveToService -> "Save to third-party service"
    }
}

internal object AndroidArticlePlatformActions {
    fun openUrl(context: Context, value: String): Boolean {
        if (!AndroidArticleActionPolicy.validWebUrl(value)) return false
        return start(context, Intent(Intent.ACTION_VIEW, Uri.parse(value)))
    }

    fun copyLink(context: Context, article: ArticleSummary): Boolean {
        if (!AndroidArticleActionPolicy.validWebUrl(article.url)) return false
        context.getSystemService(ClipboardManager::class.java)
            ?.setPrimaryClip(ClipData.newPlainText("Article link", article.url))
            ?: return false
        return true
    }

    fun share(context: Context, article: ArticleSummary): Boolean {
        if (!AndroidArticleActionPolicy.validWebUrl(article.url)) return false
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "${article.title}\n${article.url}")
        }
        return start(context, Intent.createChooser(share, null))
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }
}

private const val ANDROID_ARTICLE_SWIPE_FULL_THRESHOLD = 0.58f

/**
 * Android-native gesture adapter for the shared semantic swipe contract.
 *
 * A partial drag only reveals actions. Tapping a revealed action executes it; a full swipe executes
 * only the configured outer/full slot. If a contextual outer action is unavailable, the inner slot
 * is deliberately not promoted. A gesture that starts while the opposite side is open can only
 * return to neutral; crossing through neutral requires a new gesture.
 */
@Composable
internal fun AndroidArticleSwipeContainer(
    article: ArticleSummary,
    hasAudio: Boolean,
    configuration: AndroidArticleSwipeConfiguration,
    onSwipeAction: (AndroidArticleSwipeAction) -> Unit,
    onContextAction: (AndroidArticleContextAction) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val leading = remember(configuration, article, hasAudio) {
        AndroidArticleActionPolicy.resolveSwipeSide(
            configuration = configuration,
            side = AndroidArticleSwipeSide.Leading,
            article = article,
            hasAudio = hasAudio,
        )
    }
    val trailing = remember(configuration, article, hasAudio) {
        AndroidArticleActionPolicy.resolveSwipeSide(
            configuration = configuration,
            side = AndroidArticleSwipeSide.Trailing,
            article = article,
            hasAudio = hasAudio,
        )
    }
    var offsetPx by remember(article.id) { mutableFloatStateOf(0f) }
    var gestureSide by remember(article.id) { mutableStateOf<AndroidArticleSwipeSide?>(null) }
    var gestureStartOffset by remember(article.id) { mutableFloatStateOf(0f) }
    var contextExpanded by remember(article.id) { mutableStateOf(false) }
    val actionWidth = 78.dp
    val actionWidthPx = with(density) { actionWidth.toPx() }

    suspend fun animateOffset(target: Float) {
        val animation = Animatable(offsetPx)
        animation.animateTo(target, animationSpec = tween(durationMillis = 150)) {
            offsetPx = value
        }
        offsetPx = target
    }

    BoxWithConstraints(modifier.fillMaxWidth()) {
        val rowWidthPx = with(density) { maxWidth.toPx() }.coerceAtLeast(1f)

        SwipeActionBackground(
            side = AndroidArticleSwipeSide.Leading,
            resolved = leading,
            article = article,
            actionWidth = actionWidth,
            onAction = { action ->
                scope.launch {
                    animateOffset(0f)
                    onSwipeAction(action)
                }
            },
            modifier = Modifier.align(Alignment.CenterStart),
        )
        SwipeActionBackground(
            side = AndroidArticleSwipeSide.Trailing,
            resolved = trailing,
            article = article,
            actionWidth = actionWidth,
            onAction = { action ->
                scope.launch {
                    animateOffset(0f)
                    onSwipeAction(action)
                }
            },
            modifier = Modifier.align(Alignment.CenterEnd),
        )

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(offsetPx.roundToInt(), 0) }
                .background(MaterialTheme.colorScheme.background)
                .pointerInput(article.id, leading, trailing, rowWidthPx) {
                    detectHorizontalDragGestures(
                        onDragStart = {
                            gestureStartOffset = offsetPx
                            gestureSide = when {
                                offsetPx > 0f -> AndroidArticleSwipeSide.Leading
                                offsetPx < 0f -> AndroidArticleSwipeSide.Trailing
                                else -> null
                            }
                        },
                        onHorizontalDrag = { change, dragAmount ->
                            if (gestureSide == null && dragAmount != 0f) {
                                gestureSide = if (dragAmount > 0f) {
                                    AndroidArticleSwipeSide.Leading
                                } else {
                                    AndroidArticleSwipeSide.Trailing
                                }
                            }
                            val side = gestureSide ?: return@detectHorizontalDragGestures
                            val resolved = if (side == AndroidArticleSwipeSide.Leading) leading else trailing
                            if (resolved.visibleActions.isEmpty()) {
                                offsetPx = 0f
                                return@detectHorizontalDragGestures
                            }
                            val revealWidth = actionWidthPx * resolved.visibleActions.size
                            val maximum = if (resolved.full != null) rowWidthPx else revealWidth
                            offsetPx = if (side == AndroidArticleSwipeSide.Leading) {
                                (offsetPx + dragAmount).coerceIn(0f, maximum)
                            } else {
                                (offsetPx + dragAmount).coerceIn(-maximum, 0f)
                            }
                        },
                        onDragCancel = {
                            val target = gestureStartOffset
                            gestureSide = null
                            scope.launch { animateOffset(target) }
                        },
                        onDragEnd = {
                            val side = gestureSide
                            gestureSide = null
                            if (side == null) return@detectHorizontalDragGestures
                            val resolved = if (side == AndroidArticleSwipeSide.Leading) leading else trailing
                            val direction = if (side == AndroidArticleSwipeSide.Leading) 1f else -1f
                            val fullAction = resolved.full
                            if (
                                fullAction != null &&
                                abs(offsetPx) >= rowWidthPx * ANDROID_ARTICLE_SWIPE_FULL_THRESHOLD
                            ) {
                                scope.launch {
                                    animateOffset(direction * rowWidthPx)
                                    onSwipeAction(fullAction)
                                    offsetPx = 0f
                                }
                            } else {
                                val revealWidth = actionWidthPx * resolved.visibleActions.size
                                val shouldReveal = revealWidth > 0f && abs(offsetPx) >= actionWidthPx * 0.4f
                                scope.launch {
                                    animateOffset(if (shouldReveal) direction * revealWidth else 0f)
                                }
                            }
                        },
                    )
                }
                .pointerInput(article.id) {
                    detectTapGestures(
                        onLongPress = { contextExpanded = true },
                    )
                }
                .semantics {
                    customActions = listOf(
                        CustomAccessibilityAction("Article actions") {
                            contextExpanded = true
                            true
                        },
                    )
                },
        ) {
            content()
        }

        DropdownMenu(
            expanded = contextExpanded,
            onDismissRequest = { contextExpanded = false },
        ) {
            AndroidArticleActionPolicy.contextActions(article).forEach { action ->
                DropdownMenuItem(
                    text = { Text(AndroidArticleActionPolicy.contextLabel(action, article)) },
                    onClick = {
                        contextExpanded = false
                        offsetPx = 0f
                        onContextAction(action)
                    },
                )
            }
        }
    }
}

@Composable
private fun SwipeActionBackground(
    side: AndroidArticleSwipeSide,
    resolved: AndroidResolvedSwipeSide,
    article: ArticleSummary,
    actionWidth: androidx.compose.ui.unit.Dp,
    onAction: (AndroidArticleSwipeAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val actions = if (side == AndroidArticleSwipeSide.Leading) {
        resolved.visibleActions.reversed()
    } else {
        resolved.visibleActions
    }
    if (actions.isEmpty()) return

    Row(
        modifier = modifier
            .width(actionWidth * actions.size.toFloat())
            .fillMaxHeight(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        actions.forEach { action ->
            Box(
                modifier = Modifier
                    .width(actionWidth)
                    .fillMaxHeight()
                    .background(MaterialTheme.colorScheme.secondaryContainer)
                    .clickable { onAction(action) }
                    .padding(horizontal = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = AndroidArticleActionPolicy.swipeLabel(action, article),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                )
            }
        }
    }
}
