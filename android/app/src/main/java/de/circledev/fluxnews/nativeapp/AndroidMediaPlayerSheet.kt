package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.MediaArtworkSource
import uniffi.flux_uniffi.MediaChapter
import uniffi.flux_uniffi.ReaderDocument

@Composable
internal fun AndroidMediaPlayerSheet(
    coordinator: AndroidMediaPlaybackCoordinator,
    onDismiss: () -> Unit,
) {
    val playback by coordinator.state.collectAsState()
    val sleepTimer by coordinator.sleepTimer.state.collectAsState()
    val scope = rememberCoroutineScope()
    var rateMenuOpen by remember { mutableStateOf(false) }
    var sleepMenuOpen by remember { mutableStateOf(false) }
    var chaptersExpanded by remember { mutableStateOf(false) }
    var showNotesExpanded by remember { mutableStateOf(false) }
    var showNotesLoading by remember { mutableStateOf(false) }
    var showNotesError by remember { mutableStateOf<String?>(null) }
    var showNotesDocument by remember { mutableStateOf<ReaderDocument?>(null) }
    var seeking by remember { mutableStateOf(false) }
    var seekValue by remember(playback.enclosureId) {
        mutableFloatStateOf(playback.positionMs.toFloat())
    }

    LaunchedEffect(playback.positionMs, seeking) {
        if (!seeking) seekValue = playback.positionMs.toFloat()
    }

    LaunchedEffect(playback.articleId) {
        showNotesExpanded = false
        showNotesLoading = false
        showNotesError = null
        showNotesDocument = null
    }

    val artworkModel by produceState<Any?>(
        initialValue = null,
        key1 = playback.artworkSource,
        key2 = playback.enclosureId,
    ) {
        value = when (val source = playback.artworkSource) {
            is MediaArtworkSource.LocalReference ->
                coordinator.artworkBytes(source.reference)
            is MediaArtworkSource.RemoteUrl ->
                source.url.takeIf(AndroidArticleActionPolicy::validWebUrl)
            null -> null
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.96f)
                .fillMaxHeight(0.92f),
            shape = RoundedCornerShape(28.dp),
            tonalElevation = 8.dp,
            shadowElevation = 12.dp,
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 20.dp, top = 14.dp, end = 12.dp, bottom = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Player",
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    TextButton(onClick = onDismiss) {
                        Text("Done")
                    }
                }
                HorizontalDivider()

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    AndroidMediaArtwork(
                        model = artworkModel,
                        loading = playback.isLoading || playback.isBuffering,
                    )

                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            playback.articleTitle?.ifBlank { "Audio" } ?: "Audio",
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                        playback.feedTitle
                            ?.takeIf { it.isNotBlank() }
                            ?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                    }

                    playback.durationMs?.takeIf { it > 0L }?.let { duration ->
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Slider(
                                value = seekValue.coerceIn(0f, duration.toFloat()),
                                onValueChange = {
                                    seeking = true
                                    seekValue = it
                                },
                                onValueChangeFinished = {
                                    val target = seekValue.toLong().coerceAtLeast(0L)
                                    seeking = false
                                    scope.launch { coordinator.seekTo(target) }
                                },
                                valueRange = 0f..duration.toFloat(),
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    androidPlayerTime(
                                        if (seeking) seekValue.toLong() else playback.positionMs,
                                    ),
                                    style = MaterialTheme.typography.labelMedium,
                                )
                                Text(
                                    androidPlayerTime(duration),
                                    style = MaterialTheme.typography.labelMedium,
                                )
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TextButton(
                            onClick = {
                                scope.launch { coordinator.skipBackward30Seconds() }
                            },
                        ) {
                            Text("−30s")
                        }
                        Button(
                            onClick = {
                                playback.enclosureId?.let { enclosureId ->
                                    scope.launch {
                                        if (
                                            playback.status ==
                                            AndroidMediaPlaybackPresentationStatus.Playing
                                        ) {
                                            coordinator.pause()
                                        } else {
                                            coordinator.play(enclosureId)
                                        }
                                    }
                                }
                            },
                            enabled = playback.enclosureId != null,
                        ) {
                            if (playback.isLoading || playback.isBuffering) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                Text(
                                    if (
                                        playback.status ==
                                        AndroidMediaPlaybackPresentationStatus.Playing
                                    ) {
                                        "Pause"
                                    } else {
                                        "Play"
                                    },
                                )
                            }
                        }
                        TextButton(
                            onClick = {
                                scope.launch { coordinator.skipForward30Seconds() }
                            },
                        ) {
                            Text("+30s")
                        }
                        TextButton(
                            onClick = { scope.launch { coordinator.stop() } },
                            enabled = playback.enclosureId != null,
                        ) {
                            Text("Stop")
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Box(modifier = Modifier.weight(1f)) {
                            OutlinedButton(
                                onClick = { rateMenuOpen = true },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(androidPlaybackRateLabel(playback.playbackRate))
                            }
                            DropdownMenu(
                                expanded = rateMenuOpen,
                                onDismissRequest = { rateMenuOpen = false },
                            ) {
                                listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 2.5f, 3.0f)
                                    .forEach { rate ->
                                        DropdownMenuItem(
                                            text = {
                                                Text(androidPlaybackRateLabel(rate))
                                            },
                                            onClick = {
                                                rateMenuOpen = false
                                                scope.launch {
                                                    coordinator.setPlaybackRate(rate)
                                                }
                                            },
                                        )
                                    }
                            }
                        }

                        Box(modifier = Modifier.weight(1f)) {
                            OutlinedButton(
                                onClick = { sleepMenuOpen = true },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    if (sleepTimer.enabled) {
                                        val seconds = sleepTimer.remainingSeconds
                                        if (seconds != null) {
                                            "Sleep " + androidPlayerTime(seconds * 1_000L)
                                        } else {
                                            "Sleep on"
                                        }
                                    } else {
                                        "Sleep timer"
                                    },
                                )
                            }
                            DropdownMenu(
                                expanded = sleepMenuOpen,
                                onDismissRequest = { sleepMenuOpen = false },
                            ) {
                                if (sleepTimer.enabled) {
                                    DropdownMenuItem(
                                        text = { Text("Turn off") },
                                        onClick = {
                                            sleepMenuOpen = false
                                            coordinator.sleepTimer.disable()
                                        },
                                    )
                                }
                                AndroidMediaSleepTimer.SupportedIntervalsMinutes.forEach { minutes ->
                                    DropdownMenuItem(
                                        text = { Text(minutes.toString() + " minutes") },
                                        onClick = {
                                            sleepMenuOpen = false
                                            coordinator.sleepTimer.setInterval(minutes)
                                            coordinator.sleepTimer.setEnabled(true)
                                        },
                                    )
                                }
                            }
                        }
                    }

                    if (
                        playback.status ==
                        AndroidMediaPlaybackPresentationStatus.Completed &&
                        playback.enclosureId != null
                    ) {
                        OutlinedButton(
                            onClick = {
                                playback.enclosureId?.let { enclosureId ->
                                    scope.launch { coordinator.restart(enclosureId) }
                                }
                            },
                        ) {
                            Text("Restart")
                        }
                    }

                    if (playback.chapters.isNotEmpty()) {
                        AndroidMediaChapterSection(
                            chapters = playback.chapters,
                            positionMs = playback.positionMs,
                            expanded = chaptersExpanded,
                            onToggle = { chaptersExpanded = !chaptersExpanded },
                            onSelect = { startMs ->
                                scope.launch { coordinator.seekTo(startMs) }
                            },
                        )
                    }

                    playback.articleId?.let { articleId ->
                        AndroidMediaShowNotesSection(
                            expanded = showNotesExpanded,
                            loading = showNotesLoading,
                            error = showNotesError,
                            document = showNotesDocument,
                            onToggle = {
                                showNotesExpanded = !showNotesExpanded
                                if (
                                    showNotesExpanded &&
                                    showNotesDocument == null &&
                                    !showNotesLoading
                                ) {
                                    showNotesLoading = true
                                    showNotesError = null
                                    scope.launch {
                                        coordinator.showNotes(articleId).fold(
                                            onSuccess = {
                                                showNotesDocument = it
                                                showNotesLoading = false
                                            },
                                            onFailure = {
                                                showNotesError =
                                                    "Show Notes could not be loaded."
                                                showNotesLoading = false
                                            },
                                        )
                                    }
                                }
                            },
                            onRetry = {
                                showNotesLoading = true
                                showNotesError = null
                                scope.launch {
                                    coordinator.showNotes(articleId).fold(
                                        onSuccess = {
                                            showNotesDocument = it
                                            showNotesLoading = false
                                        },
                                        onFailure = {
                                            showNotesError =
                                                "Show Notes could not be loaded."
                                            showNotesLoading = false
                                        },
                                    )
                                }
                            },
                        )
                    }

                    playback.errorMessage?.let {
                        Text(
                            it,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }

                    Spacer(Modifier.height(12.dp))
                }
            }
        }
    }
}

@Composable
private fun AndroidMediaArtwork(
    model: Any?,
    loading: Boolean,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 360.dp)
            .aspectRatio(1f)
            .clip(RoundedCornerShape(22.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (model != null) {
            AsyncImage(
                model = model,
                contentDescription = "Media artwork",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {}
        }
        if (loading) {
            CircularProgressIndicator()
        }
    }
}

@Composable
private fun AndroidMediaChapterSection(
    chapters: List<MediaChapter>,
    positionMs: Long,
    expanded: Boolean,
    onToggle: () -> Unit,
    onSelect: (Long) -> Unit,
) {
    val activeIndex = androidActiveChapterIndex(positionMs, chapters)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column {
            TextButton(
                onClick = onToggle,
                modifier = Modifier.fillMaxWidth(),
            ) {
                val active = activeIndex?.let { chapters[it] }
                val summary = active?.title
                    ?.takeIf { it.isNotBlank() }
                    ?: activeIndex?.let { "Chapter " + (it + 1) }
                    ?: chapters.size.toString() + " chapters"
                Text(
                    if (expanded) "Hide chapters · " + summary else "Chapters · " + summary,
                    modifier = Modifier.weight(1f),
                )
            }
            if (expanded) {
                HorizontalDivider()
                chapters.forEachIndexed { index, chapter ->
                    TextButton(
                        onClick = { onSelect(chapter.startMs.toLong()) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                chapter.title.takeIf { it.isNotBlank() }
                                    ?: "Chapter " + (index + 1),
                                fontWeight = if (index == activeIndex) {
                                    FontWeight.Bold
                                } else {
                                    FontWeight.Normal
                                },
                            )
                            Text(
                                androidPlayerTime(chapter.startMs.toLong()),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AndroidMediaShowNotesSection(
    expanded: Boolean,
    loading: Boolean,
    error: String?,
    document: ReaderDocument?,
    onToggle: () -> Unit,
    onRetry: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column {
            TextButton(
                onClick = onToggle,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    if (expanded) "Hide Show Notes" else "Show Notes",
                    modifier = Modifier.weight(1f),
                )
            }
            if (expanded) {
                HorizontalDivider()
                when {
                    loading -> {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                    }
                    error != null -> {
                        Column(
                            modifier = Modifier.padding(20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(error, color = MaterialTheme.colorScheme.error)
                            TextButton(onClick = onRetry) {
                                Text("Retry")
                            }
                        }
                    }
                    document != null -> {
                        AndroidReaderDocumentContent(
                            document = document,
                            onOpenOriginal = null,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 520.dp),
                        )
                    }
                }
            }
        }
    }
}

private fun androidActiveChapterIndex(
    positionMs: Long,
    chapters: List<MediaChapter>,
): Int? {
    if (chapters.isEmpty()) return null
    return chapters.indices.lastOrNull { index ->
        val chapter = chapters[index]
        val end = chapter.endMs?.toLong()
            ?: chapters.getOrNull(index + 1)?.startMs?.toLong()
        positionMs >= chapter.startMs.toLong() &&
            (end == null || positionMs < end)
    }
}

private fun androidPlaybackRateLabel(rate: Float): String =
    "%.2f".format(rate).trimEnd('0').trimEnd('.') + "× speed"

private fun androidPlayerTime(milliseconds: Long): String {
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
