package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Article
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Forward30
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.List
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay30
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.style.TextAlign
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
    var overflowOpen by remember { mutableStateOf(false) }
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
            is MediaArtworkSource.LocalReference -> coordinator.artworkBytes(source.reference)
            is MediaArtworkSource.RemoteUrl -> source.url.takeIf(AndroidArticleActionPolicy::validWebUrl)
            null -> null
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.97f)
                .fillMaxHeight(0.94f),
            shape = RoundedCornerShape(28.dp),
            tonalElevation = 6.dp,
            shadowElevation = 10.dp,
        ) {
            Column(Modifier.fillMaxSize()) {
                AndroidMediaPlayerTopBar(
                    completed = playback.status == AndroidMediaPlaybackPresentationStatus.Completed,
                    onRestart = {
                        playback.enclosureId?.let { id ->
                            scope.launch { coordinator.restart(id) }
                        }
                    },
                    onDismiss = onDismiss,
                    overflowOpen = overflowOpen,
                    onOverflowChange = { overflowOpen = it },
                )
                HorizontalDivider()

                BoxWithConstraints(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState()),
                ) {
                    val sideBySide = maxWidth >= 720.dp || maxWidth > maxHeight * 1.25f
                    if (sideBySide) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(28.dp),
                            horizontalArrangement = Arrangement.spacedBy(32.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            AndroidMediaArtwork(
                                model = artworkModel,
                                loading = playback.isLoading || playback.isBuffering,
                                modifier = Modifier
                                    .weight(0.9f)
                                    .widthIn(max = 360.dp),
                            )
                            AndroidMediaPlayerControls(
                                coordinator = coordinator,
                                playback = playback,
                                sleepTimer = sleepTimer,
                                seeking = seeking,
                                seekValue = seekValue,
                                onSeekingChange = {
                                    seeking = true
                                    seekValue = it
                                },
                                onSeekFinished = {
                                    val target = seekValue.toLong().coerceAtLeast(0L)
                                    seeking = false
                                    scope.launch { coordinator.seekTo(target) }
                                },
                                rateMenuOpen = rateMenuOpen,
                                onRateMenuChange = { rateMenuOpen = it },
                                sleepMenuOpen = sleepMenuOpen,
                                onSleepMenuChange = { sleepMenuOpen = it },
                                chaptersExpanded = chaptersExpanded,
                                onChaptersExpandedChange = { chaptersExpanded = it },
                                showNotesExpanded = showNotesExpanded,
                                showNotesLoading = showNotesLoading,
                                showNotesError = showNotesError,
                                showNotesDocument = showNotesDocument,
                                onShowNotesExpandedChange = { expanded ->
                                    showNotesExpanded = expanded
                                    if (expanded && showNotesDocument == null && !showNotesLoading) {
                                        playback.articleId?.let { articleId ->
                                            showNotesLoading = true
                                            showNotesError = null
                                            scope.launch {
                                                coordinator.showNotes(articleId).fold(
                                                    onSuccess = {
                                                        showNotesDocument = it
                                                        showNotesLoading = false
                                                    },
                                                    onFailure = {
                                                        showNotesError = "Show Notes could not be loaded."
                                                        showNotesLoading = false
                                                    },
                                                )
                                            }
                                        }
                                    }
                                },
                                onRetryShowNotes = {
                                    playback.articleId?.let { articleId ->
                                        showNotesLoading = true
                                        showNotesError = null
                                        scope.launch {
                                            coordinator.showNotes(articleId).fold(
                                                onSuccess = {
                                                    showNotesDocument = it
                                                    showNotesLoading = false
                                                },
                                                onFailure = {
                                                    showNotesError = "Show Notes could not be loaded."
                                                    showNotesLoading = false
                                                },
                                            )
                                        }
                                    }
                                },
                                modifier = Modifier.weight(1.15f),
                            )
                        }
                    } else {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp, vertical = 22.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(24.dp),
                        ) {
                            AndroidMediaArtwork(
                                model = artworkModel,
                                loading = playback.isLoading || playback.isBuffering,
                                modifier = Modifier.widthIn(max = 300.dp),
                            )
                            AndroidMediaPlayerControls(
                                coordinator = coordinator,
                                playback = playback,
                                sleepTimer = sleepTimer,
                                seeking = seeking,
                                seekValue = seekValue,
                                onSeekingChange = {
                                    seeking = true
                                    seekValue = it
                                },
                                onSeekFinished = {
                                    val target = seekValue.toLong().coerceAtLeast(0L)
                                    seeking = false
                                    scope.launch { coordinator.seekTo(target) }
                                },
                                rateMenuOpen = rateMenuOpen,
                                onRateMenuChange = { rateMenuOpen = it },
                                sleepMenuOpen = sleepMenuOpen,
                                onSleepMenuChange = { sleepMenuOpen = it },
                                chaptersExpanded = chaptersExpanded,
                                onChaptersExpandedChange = { chaptersExpanded = it },
                                showNotesExpanded = showNotesExpanded,
                                showNotesLoading = showNotesLoading,
                                showNotesError = showNotesError,
                                showNotesDocument = showNotesDocument,
                                onShowNotesExpandedChange = { expanded ->
                                    showNotesExpanded = expanded
                                    if (expanded && showNotesDocument == null && !showNotesLoading) {
                                        playback.articleId?.let { articleId ->
                                            showNotesLoading = true
                                            showNotesError = null
                                            scope.launch {
                                                coordinator.showNotes(articleId).fold(
                                                    onSuccess = {
                                                        showNotesDocument = it
                                                        showNotesLoading = false
                                                    },
                                                    onFailure = {
                                                        showNotesError = "Show Notes could not be loaded."
                                                        showNotesLoading = false
                                                    },
                                                )
                                            }
                                        }
                                    }
                                },
                                onRetryShowNotes = {
                                    playback.articleId?.let { articleId ->
                                        showNotesLoading = true
                                        showNotesError = null
                                        scope.launch {
                                            coordinator.showNotes(articleId).fold(
                                                onSuccess = {
                                                    showNotesDocument = it
                                                    showNotesLoading = false
                                                },
                                                onFailure = {
                                                    showNotesError = "Show Notes could not be loaded."
                                                    showNotesLoading = false
                                                },
                                            )
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AndroidMediaPlayerTopBar(
    completed: Boolean,
    onRestart: () -> Unit,
    onDismiss: () -> Unit,
    overflowOpen: Boolean,
    onOverflowChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, top = 10.dp, end = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "Player",
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
        )
        if (completed) {
            Box {
                IconButton(onClick = { onOverflowChange(true) }) {
                    Icon(Icons.Rounded.MoreVert, contentDescription = "Player actions")
                }
                DropdownMenu(
                    expanded = overflowOpen,
                    onDismissRequest = { onOverflowChange(false) },
                ) {
                    DropdownMenuItem(
                        text = { Text("Restart") },
                        leadingIcon = {
                            Icon(Icons.Rounded.RestartAlt, contentDescription = null)
                        },
                        onClick = {
                            onOverflowChange(false)
                            onRestart()
                        },
                    )
                }
            }
        }
        IconButton(onClick = onDismiss) {
            Icon(Icons.Rounded.Close, contentDescription = "Close player")
        }
    }
}

@Composable
private fun AndroidMediaPlayerControls(
    coordinator: AndroidMediaPlaybackCoordinator,
    playback: AndroidMediaPlaybackState,
    sleepTimer: AndroidMediaSleepTimerState,
    seeking: Boolean,
    seekValue: Float,
    onSeekingChange: (Float) -> Unit,
    onSeekFinished: () -> Unit,
    rateMenuOpen: Boolean,
    onRateMenuChange: (Boolean) -> Unit,
    sleepMenuOpen: Boolean,
    onSleepMenuChange: (Boolean) -> Unit,
    chaptersExpanded: Boolean,
    onChaptersExpandedChange: (Boolean) -> Unit,
    showNotesExpanded: Boolean,
    showNotesLoading: Boolean,
    showNotesError: String?,
    showNotesDocument: ReaderDocument?,
    onShowNotesExpandedChange: (Boolean) -> Unit,
    onRetryShowNotes: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()

    Column(
        modifier = modifier.widthIn(max = 560.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(
                playback.articleTitle?.ifBlank { "Audio" } ?: "Audio",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            playback.feedTitle?.takeIf { it.isNotBlank() }?.let { feed ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Rounded.Headphones,
                        contentDescription = null,
                        modifier = Modifier.size(17.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        feed,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        playback.durationMs?.takeIf { it > 0L }?.let { duration ->
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Slider(
                    value = seekValue.coerceIn(0f, duration.toFloat()),
                    onValueChange = onSeekingChange,
                    onValueChangeFinished = onSeekFinished,
                    valueRange = 0f..duration.toFloat(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        androidPlayerTime(if (seeking) seekValue.toLong() else playback.positionMs),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        androidPlayerTime(duration),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        AndroidMediaTransportControls(
            playback = playback,
            onBack = { scope.launch { coordinator.skipBackward30Seconds() } },
            onPlayPause = {
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
            onForward = { scope.launch { coordinator.skipForward30Seconds() } },
            onStop = { scope.launch { coordinator.stop() } },
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                OutlinedButton(
                    onClick = { onRateMenuChange(true) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(
                        Icons.Rounded.Speed,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Text(androidPlaybackRateLabel(playback.playbackRate))
                }
                DropdownMenu(
                    expanded = rateMenuOpen,
                    onDismissRequest = { onRateMenuChange(false) },
                ) {
                    listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 2.5f, 3.0f).forEach { rate ->
                        DropdownMenuItem(
                            text = { Text(androidPlaybackRateLabel(rate)) },
                            onClick = {
                                onRateMenuChange(false)
                                scope.launch { coordinator.setPlaybackRate(rate) }
                            },
                        )
                    }
                }
            }

            Box(modifier = Modifier.weight(1f)) {
                OutlinedButton(
                    onClick = { onSleepMenuChange(true) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(
                        Icons.Rounded.Bedtime,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Text(
                        if (sleepTimer.enabled) {
                            sleepTimer.remainingSeconds?.let {
                                androidPlayerTime(it * 1_000L)
                            } ?: "On"
                        } else {
                            "Sleep"
                        },
                    )
                }
                DropdownMenu(
                    expanded = sleepMenuOpen,
                    onDismissRequest = { onSleepMenuChange(false) },
                ) {
                    if (sleepTimer.enabled) {
                        DropdownMenuItem(
                            text = { Text("Turn off") },
                            onClick = {
                                onSleepMenuChange(false)
                                coordinator.sleepTimer.disable()
                            },
                        )
                    }
                    AndroidMediaSleepTimer.SupportedIntervalsMinutes.forEach { minutes ->
                        DropdownMenuItem(
                            text = { Text(minutes.toString() + " minutes") },
                            onClick = {
                                onSleepMenuChange(false)
                                coordinator.sleepTimer.setInterval(minutes)
                                coordinator.sleepTimer.setEnabled(true)
                            },
                        )
                    }
                }
            }
        }

        if (playback.chapters.isNotEmpty()) {
            AndroidMediaChapterSection(
                chapters = playback.chapters,
                positionMs = playback.positionMs,
                expanded = chaptersExpanded,
                onToggle = { onChaptersExpandedChange(!chaptersExpanded) },
                onSelect = { start -> scope.launch { coordinator.seekTo(start) } },
            )
        }

        playback.articleId?.let {
            AndroidMediaShowNotesSection(
                expanded = showNotesExpanded,
                loading = showNotesLoading,
                error = showNotesError,
                document = showNotesDocument,
                onToggle = { onShowNotesExpandedChange(!showNotesExpanded) },
                onRetry = onRetryShowNotes,
            )
        }

        playback.errorMessage?.let { error ->
            Text(
                error,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun AndroidMediaTransportControls(
    playback: AndroidMediaPlaybackState,
    onBack: () -> Unit,
    onPlayPause: () -> Unit,
    onForward: () -> Unit,
    onStop: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, enabled = playback.enclosureId != null) {
            Icon(
                Icons.Rounded.Replay30,
                contentDescription = "Back 30 seconds",
                modifier = Modifier.size(30.dp),
            )
        }

        Box(
            modifier = Modifier.size(76.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (playback.isLoading || playback.isBuffering) {
                CircularProgressIndicator(
                    modifier = Modifier.size(72.dp),
                    strokeWidth = 3.dp,
                )
            }
            FilledIconButton(
                onClick = onPlayPause,
                enabled = playback.enclosureId != null,
                modifier = Modifier.size(58.dp),
                shape = CircleShape,
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
                    modifier = Modifier.size(34.dp),
                )
            }
        }

        IconButton(onClick = onForward, enabled = playback.enclosureId != null) {
            Icon(
                Icons.Rounded.Forward30,
                contentDescription = "Forward 30 seconds",
                modifier = Modifier.size(30.dp),
            )
        }

        IconButton(onClick = onStop, enabled = playback.enclosureId != null) {
            Icon(
                Icons.Rounded.Stop,
                contentDescription = "Stop",
                modifier = Modifier.size(28.dp),
            )
        }
    }
}

@Composable
private fun AndroidMediaArtwork(
    model: Any?,
    loading: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .clip(RoundedCornerShape(20.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (model != null) {
            AsyncImage(
                model = model,
                contentDescription = "Media artwork",
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.Rounded.Headphones,
                        contentDescription = null,
                        modifier = Modifier.size(58.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
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
    val active = activeIndex?.let { chapters[it] }
    val summary = active?.title
        ?.takeIf { it.isNotBlank() }
        ?: activeIndex?.let { "Chapter " + (it + 1) }
        ?: chapters.size.toString() + " chapters"

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onToggle),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column {
            Row(
                modifier = Modifier.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    Icons.Rounded.List,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        if (activeIndex != null) {
                            "Chapter " + (activeIndex + 1) + " of " + chapters.size
                        } else {
                            "Chapters"
                        },
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            if (expanded) {
                HorizontalDivider()
                chapters.forEachIndexed { index, chapter ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(chapter.startMs.toLong()) }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                chapter.title.takeIf { it.isNotBlank() }
                                    ?: "Chapter " + (index + 1),
                                fontWeight = if (index == activeIndex) {
                                    FontWeight.SemiBold
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
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onToggle)
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    Icons.Rounded.Article,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        "Show Notes",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        if (expanded) "Tap to collapse" else "Read the article while listening",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (expanded) {
                HorizontalDivider()
                when {
                    loading -> Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(28.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator()
                    }
                    error != null -> Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            error,
                            color = MaterialTheme.colorScheme.error,
                            textAlign = TextAlign.Center,
                        )
                        OutlinedButton(onClick = onRetry) {
                            Text("Retry")
                        }
                    }
                    document != null -> AndroidReaderDocumentContent(
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
    "%.2f".format(rate).trimEnd('0').trimEnd('.') + "×"

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
