package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Sort
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.DownloadState
import uniffi.flux_uniffi.ListeningListEnclosure
import uniffi.flux_uniffi.ListeningListItem
import uniffi.flux_uniffi.ListeningListSort
import uniffi.flux_uniffi.PlaybackStatus

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AndroidListeningListDestination(
    store: AndroidListeningListStore,
    playbackCoordinator: AndroidMediaPlaybackCoordinator,
    transferCoordinator: AndroidMediaTransferCoordinator,
    sessionGeneration: Long?,
    onBack: () -> Unit,
) {
    val state by store.state.collectAsState()
    val playback by playbackCoordinator.state.collectAsState()
    val transferProgress by transferCoordinator.progress.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    var feedMenuOpen by remember { mutableStateOf(false) }
    var sortMenuOpen by remember { mutableStateOf(false) }
    var playerArticleId by remember { mutableStateOf<Long?>(null) }

    LaunchedEffect(sessionGeneration) {
        store.activateSession(sessionGeneration)
        if (sessionGeneration != null) store.reload()
    }
    LaunchedEffect(transferCoordinator, sessionGeneration) {
        transferCoordinator.revision.collect {
            if (sessionGeneration != null) store.reload()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Listening List") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { feedMenuOpen = true }) {
                            Icon(Icons.Rounded.FilterList, contentDescription = "Filter by feed")
                        }
                        DropdownMenu(
                            expanded = feedMenuOpen,
                            onDismissRequest = { feedMenuOpen = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("All Feeds") },
                                onClick = {
                                    feedMenuOpen = false
                                    coroutineScope.launch { store.setFeedId(null) }
                                },
                            )
                            state.feeds.forEach { feed ->
                                DropdownMenuItem(
                                    text = { Text(feed.feedTitle.ifBlank { "Unknown Feed" }) },
                                    onClick = {
                                        feedMenuOpen = false
                                        coroutineScope.launch { store.setFeedId(feed.feedId) }
                                    },
                                )
                            }
                        }
                    }
                    Box {
                        IconButton(onClick = { sortMenuOpen = true }) {
                            Icon(Icons.Rounded.Sort, contentDescription = "Sort Listening List")
                        }
                        DropdownMenu(
                            expanded = sortMenuOpen,
                            onDismissRequest = { sortMenuOpen = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Recently Added") },
                                onClick = {
                                    sortMenuOpen = false
                                    coroutineScope.launch {
                                        store.setSort(ListeningListSort.RECENTLY_ADDED)
                                    }
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Publication Date") },
                                onClick = {
                                    sortMenuOpen = false
                                    coroutineScope.launch {
                                        store.setSort(ListeningListSort.PUBLICATION_DATE)
                                    }
                                },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        when {
            state.isLoading && state.items.isEmpty() -> Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }

            state.errorMessage != null && state.items.isEmpty() -> Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    Icons.Rounded.Headphones,
                    contentDescription = null,
                    modifier = Modifier.size(52.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(16.dp))
                Text(
                    state.errorMessage.orEmpty(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(12.dp))
                Button(onClick = { coroutineScope.launch { store.reload() } }) {
                    Text("Retry")
                }
            }

            state.items.isEmpty() -> Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    Icons.Rounded.Headphones,
                    contentDescription = null,
                    modifier = Modifier.size(56.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(16.dp))
                Text(
                    "Listening List is Empty",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.size(6.dp))
                Text(
                    "Add audio news to your Listening List to find them here.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            else -> LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                items(state.items, key = { it.articleId }) { item ->
                    AndroidListeningListRow(
                        item = item,
                        playback = playback,
                        transferProgress = transferProgress,
                        onPlay = { enclosureId ->
                            coroutineScope.launch { playbackCoordinator.play(enclosureId) }
                        },
                        onPause = {
                            coroutineScope.launch { playbackCoordinator.pause() }
                        },
                        onOpenPlayer = {
                            playerArticleId = item.articleId
                        },
                        onRemove = {
                            coroutineScope.launch {
                                store.removeFromListeningList(item.articleId)
                            }
                        },
                        onRequestDownload = { enclosureId ->
                            coroutineScope.launch { store.requestDownload(enclosureId) }
                        },
                        onCancelDownload = { enclosureId ->
                            coroutineScope.launch { store.cancelDownload(enclosureId) }
                        },
                        onRetryDownload = { enclosureId ->
                            coroutineScope.launch { store.retryDownload(enclosureId) }
                        },
                        onDeleteDownload = { enclosureId ->
                            coroutineScope.launch { store.deleteDownload(enclosureId) }
                        },
                    )
                    HorizontalDivider()
                }
            }
        }
    }

    playerArticleId
        ?.let { articleId -> state.items.firstOrNull { it.articleId == articleId } }
        ?.let { item ->
            AndroidMediaPlayerSheet(
                coordinator = playbackCoordinator,
                previewItem = item,
                onDismiss = { playerArticleId = null },
            )
        }
}

@Composable
private fun AndroidListeningListRow(
    item: ListeningListItem,
    playback: AndroidMediaPlaybackState,
    transferProgress: Map<Long, AndroidMediaTransferProgress>,
    onPlay: (Long) -> Unit,
    onPause: () -> Unit,
    onOpenPlayer: () -> Unit,
    onRemove: () -> Unit,
    onRequestDownload: (Long) -> Unit,
    onCancelDownload: (Long) -> Unit,
    onRetryDownload: (Long) -> Unit,
    onDeleteDownload: (Long) -> Unit,
) {
    var actionsOpen by remember { mutableStateOf(false) }
    val nowPlayingEnclosure = playback.enclosureId?.let { loadedId ->
        item.audioEnclosures.firstOrNull { it.enclosure.id == loadedId }
    }
    val selected = nowPlayingEnclosure
        ?: item.audioEnclosures.firstOrNull { it.enclosure.id == item.activeEnclosureId }
        ?: item.audioEnclosures.firstOrNull()
    val selectedId = selected?.enclosure?.id
    val isNowPlaying = nowPlayingEnclosure != null &&
        playback.status != AndroidMediaPlaybackPresentationStatus.Stopped
    val isPlaying = isNowPlaying &&
        playback.status == AndroidMediaPlaybackPresentationStatus.Playing

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = selectedId != null, onClick = onOpenPlayer)
            .padding(horizontal = 18.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(
                    item.title.ifBlank { "Untitled News" },
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    item.feedTitle.ifBlank { "Unknown Feed" },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (isNowPlaying) {
                    Text(
                        "Now Playing",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            Box {
                IconButton(onClick = { actionsOpen = true }) {
                    Icon(Icons.Rounded.MoreVert, contentDescription = "Listening List actions")
                }
                AndroidListeningListItemMenu(
                    expanded = actionsOpen,
                    item = item,
                    playback = playback,
                    onDismiss = { actionsOpen = false },
                    onPlay = onPlay,
                    onPause = onPause,
                    onRequestDownload = onRequestDownload,
                    onCancelDownload = onCancelDownload,
                    onRetryDownload = onRetryDownload,
                    onDeleteDownload = onDeleteDownload,
                    onRemove = onRemove,
                )
            }
        }

        selected?.playbackState?.let { progress ->
            AndroidListeningListProgress(
                positionMs = if (playback.enclosureId == selectedId) {
                    playback.positionMs
                } else {
                    progress.positionMs.toLong()
                },
                durationMs = if (playback.enclosureId == selectedId) {
                    playback.durationMs ?: progress.durationMs?.toLong()
                } else {
                    progress.durationMs?.toLong()
                },
                status = if (playback.enclosureId == selectedId) {
                    when (playback.status) {
                        AndroidMediaPlaybackPresentationStatus.Completed -> PlaybackStatus.COMPLETED
                        AndroidMediaPlaybackPresentationStatus.Playing,
                        AndroidMediaPlaybackPresentationStatus.Paused,
                        AndroidMediaPlaybackPresentationStatus.Stopped,
                        -> PlaybackStatus.IN_PROGRESS
                        AndroidMediaPlaybackPresentationStatus.Idle -> progress.status
                    }
                } else {
                    progress.status
                },
            )
        }

        selectedId?.let { enclosureId ->
            transferProgress[enclosureId]?.let { progress ->
                AndroidListeningListTransferProgress(progress)
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AndroidMediaMetric(
                    icon = {
                        Icon(
                            Icons.Rounded.Headphones,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                    },
                    text = if (item.audioEnclosures.size == 1) {
                        "1 audio"
                    } else {
                        item.audioEnclosures.size.toString() + " audio"
                    },
                )
                selected?.download?.state?.let { state ->
                    when (state) {
                        DownloadState.DOWNLOADED -> AndroidMediaMetric(
                            icon = {
                                Icon(
                                    Icons.Rounded.Download,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                            },
                            text = "Downloaded",
                        )
                        DownloadState.REQUESTED -> AndroidMediaMetric(
                            icon = {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    strokeWidth = 2.dp,
                                )
                            },
                            text = "Pending",
                        )
                        DownloadState.FAILED -> AndroidMediaMetric(
                            icon = {
                                Icon(
                                    Icons.Rounded.RestartAlt,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                            },
                            text = "Retry",
                        )
                        else -> Unit
                    }
                }
            }

            FilledIconButton(
                onClick = {
                    if (selectedId != null) {
                        if (isPlaying) onPause() else onPlay(selectedId)
                    }
                },
                enabled = selectedId != null,
            ) {
                Icon(
                    if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                )
            }
        }
    }
}

@Composable
private fun AndroidListeningListItemMenu(
    expanded: Boolean,
    item: ListeningListItem,
    playback: AndroidMediaPlaybackState,
    onDismiss: () -> Unit,
    onPlay: (Long) -> Unit,
    onPause: () -> Unit,
    onRequestDownload: (Long) -> Unit,
    onCancelDownload: (Long) -> Unit,
    onRetryDownload: (Long) -> Unit,
    onDeleteDownload: (Long) -> Unit,
    onRemove: () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
    ) {
        item.audioEnclosures.forEachIndexed { index, enclosure ->
            val id = enclosure.enclosure.id
            val active = playback.enclosureId == id &&
                playback.status == AndroidMediaPlaybackPresentationStatus.Playing
            val label = enclosure.enclosure.mimeType.ifBlank {
                "Audio " + (index + 1)
            }

            DropdownMenuItem(
                text = {
                    Text(
                        (if (active) "Pause · " else "Play · ") + label,
                    )
                },
                leadingIcon = {
                    Icon(
                        if (active) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = null,
                    )
                },
                onClick = {
                    onDismiss()
                    if (active) onPause() else onPlay(id)
                },
            )

            AndroidListeningListDownloadMenuItem(
                enclosure = enclosure,
                onDismiss = onDismiss,
                onRequestDownload = onRequestDownload,
                onCancelDownload = onCancelDownload,
                onRetryDownload = onRetryDownload,
                onDeleteDownload = onDeleteDownload,
            )

            if (index != item.audioEnclosures.lastIndex) {
                HorizontalDivider()
            }
        }

        if (item.audioEnclosures.isNotEmpty()) {
            HorizontalDivider()
        }
        DropdownMenuItem(
            text = { Text("Remove from Listening List") },
            leadingIcon = {
                Icon(Icons.Rounded.Close, contentDescription = null)
            },
            onClick = {
                onDismiss()
                onRemove()
            },
        )
    }
}

@Composable
private fun AndroidListeningListDownloadMenuItem(
    enclosure: ListeningListEnclosure,
    onDismiss: () -> Unit,
    onRequestDownload: (Long) -> Unit,
    onCancelDownload: (Long) -> Unit,
    onRetryDownload: (Long) -> Unit,
    onDeleteDownload: (Long) -> Unit,
) {
    val id = enclosure.enclosure.id
    when (enclosure.download?.state ?: DownloadState.NOT_DOWNLOADED) {
        DownloadState.NOT_DOWNLOADED -> DropdownMenuItem(
            text = { Text("Download") },
            leadingIcon = { Icon(Icons.Rounded.Download, contentDescription = null) },
            onClick = {
                onDismiss()
                onRequestDownload(id)
            },
        )
        DownloadState.REQUESTED -> DropdownMenuItem(
            text = { Text("Cancel download") },
            leadingIcon = { Icon(Icons.Rounded.Close, contentDescription = null) },
            onClick = {
                onDismiss()
                onCancelDownload(id)
            },
        )
        DownloadState.DOWNLOADED -> DropdownMenuItem(
            text = { Text("Delete download") },
            leadingIcon = { Icon(Icons.Rounded.Delete, contentDescription = null) },
            onClick = {
                onDismiss()
                onDeleteDownload(id)
            },
        )
        DownloadState.FAILED -> DropdownMenuItem(
            text = { Text("Retry download") },
            leadingIcon = { Icon(Icons.Rounded.RestartAlt, contentDescription = null) },
            onClick = {
                onDismiss()
                onRetryDownload(id)
            },
        )
        DownloadState.DELETE_REQUESTED -> DropdownMenuItem(
            text = { Text("Deletion pending") },
            enabled = false,
            onClick = {},
        )
    }
}

@Composable
private fun AndroidListeningListProgress(
    positionMs: Long,
    durationMs: Long?,
    status: PlaybackStatus,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (durationMs != null && durationMs > 0L) {
            LinearProgressIndicator(
                progress = {
                    (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        val durationLabel = durationMs?.let { " / " + androidMediaTime(it) }.orEmpty()
        val statusLabel = when (status) {
            PlaybackStatus.NOT_STARTED -> "Not started"
            PlaybackStatus.IN_PROGRESS -> "In progress"
            PlaybackStatus.COMPLETED -> "Completed"
        }
        Text(
            androidMediaTime(positionMs) + durationLabel + " · " + statusLabel,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AndroidListeningListTransferProgress(
    progress: AndroidMediaTransferProgress,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        progress.fraction?.let { fraction ->
            LinearProgressIndicator(
                progress = { fraction },
                modifier = Modifier.fillMaxWidth(),
            )
        } ?: LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        Text(
            buildString {
                append("Downloading · ")
                append(androidMediaBytes(progress.bytesDownloaded))
                progress.totalBytes?.let { total ->
                    append(" / ")
                    append(androidMediaBytes(total))
                }
            },
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AndroidMediaMetric(
    icon: @Composable () -> Unit,
    text: String,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon()
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun androidMediaBytes(bytes: Long): String {
    val safe = bytes.coerceAtLeast(0L).toDouble()
    return when {
        safe >= 1024.0 * 1024.0 * 1024.0 ->
            "%.1f GB".format(safe / (1024.0 * 1024.0 * 1024.0))
        safe >= 1024.0 * 1024.0 ->
            "%.1f MB".format(safe / (1024.0 * 1024.0))
        safe >= 1024.0 ->
            "%.1f KB".format(safe / 1024.0)
        else -> safe.toLong().toString() + " B"
    }
}

private fun androidMediaTime(milliseconds: Long): String {
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
