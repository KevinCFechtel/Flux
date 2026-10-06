package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay30
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.MediaArtworkSource

@Composable
internal fun AndroidArticleListBottomDock(
    coordinator: AndroidMediaPlaybackCoordinator,
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
    actions: @Composable () -> Unit,
) {
    val playback by coordinator.state.collectAsState()
    val showMiniPlayer = playback.enclosureId != null &&
        playback.status != AndroidMediaPlaybackPresentationStatus.Stopped

    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(26.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Column {
            if (showMiniPlayer) {
                AndroidCompactMiniPlayer(
                    playback = playback,
                    coordinator = coordinator,
                    onOpenPlayer = onOpenPlayer,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                )
                HorizontalDivider(modifier = Modifier.padding(horizontal = 10.dp))
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                actions()
            }
        }
    }
}

@Composable
internal fun AndroidCompactMiniPlayer(
    playback: AndroidMediaPlaybackState,
    coordinator: AndroidMediaPlaybackCoordinator,
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val artworkModel by produceState<Any?>(
        initialValue = null,
        key1 = playback.artworkSource,
        key2 = playback.enclosureId,
    ) {
        value = when (val source = playback.artworkSource) {
            is MediaArtworkSource.LocalReference -> coordinator.artworkBytes(source.reference)
            is MediaArtworkSource.RemoteUrl ->
                source.url.takeIf(AndroidArticleActionPolicy::validWebUrl)
            null -> null
        }
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onOpenPlayer),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(RoundedCornerShape(9.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    if (artworkModel != null) {
                        AsyncImage(
                            model = artworkModel,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Image(
                            painter = painterResource(R.drawable.fallback_artwork),
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }

                Column(Modifier.weight(1f)) {
                    Text(
                        playback.articleTitle?.ifBlank { "Audio" } ?: "Audio",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    playback.feedTitle?.takeIf { it.isNotBlank() }?.let { feed ->
                        Text(
                            feed,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            IconButton(
                onClick = { scope.launch { coordinator.skipBackward30Seconds() } },
            ) {
                Icon(Icons.Rounded.Replay30, contentDescription = "Back 30 seconds")
            }

            FilledIconButton(
                onClick = {
                    playback.enclosureId?.let { id ->
                        scope.launch {
                            if (playback.status == AndroidMediaPlaybackPresentationStatus.Playing) {
                                coordinator.pause()
                            } else {
                                coordinator.play(id)
                            }
                        }
                    }
                },
            ) {
                Icon(
                    if (playback.status == AndroidMediaPlaybackPresentationStatus.Playing) {
                        Icons.Rounded.Pause
                    } else {
                        Icons.Rounded.PlayArrow
                    },
                    contentDescription = if (
                        playback.status == AndroidMediaPlaybackPresentationStatus.Playing
                    ) {
                        "Pause"
                    } else {
                        "Play"
                    },
                )
            }
        }

        playback.durationMs?.takeIf { it > 0L }?.let { duration ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                LinearProgressIndicator(
                    progress = {
                        (playback.positionMs.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
                    },
                    modifier = Modifier.weight(1f),
                )
                Text(
                    androidCompactMediaTime(playback.positionMs) + " / " +
                        androidCompactMediaTime(duration),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

private fun androidCompactMediaTime(milliseconds: Long): String {
    val totalSeconds = milliseconds.coerceAtLeast(0L) / 1_000L
    val hours = totalSeconds / 3_600L
    val minutes = (totalSeconds % 3_600L) / 60L
    val seconds = totalSeconds % 60L
    return if (hours > 0L) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%d:%02d".format(minutes, seconds)
    }
}
