package de.circledev.fluxnews.nativeapp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.flux_uniffi.DownloadState
import uniffi.flux_uniffi.ListeningListItem
import uniffi.flux_uniffi.ListeningListSort
import uniffi.flux_uniffi.PlaybackStatus

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AndroidListeningListDestination(
    store: AndroidListeningListStore,
    playbackCoordinator: AndroidMediaPlaybackCoordinator,
    sessionGeneration: Long?,
    onBack: () -> Unit,
) {
    val state by store.state.collectAsState()
    val playback by playbackCoordinator.state.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    var feedMenuOpen by remember { mutableStateOf(false) }
    var sortMenuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(sessionGeneration) {
        store.activateSession(sessionGeneration)
        if (sessionGeneration != null) store.reload()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Listening List") },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text("Back") }
                },
                actions = {
                    TextButton(onClick = { feedMenuOpen = true }) { Text("Feed") }
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

                    TextButton(onClick = { sortMenuOpen = true }) { Text("Sort") }
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
                },
            )
        },
        bottomBar = {
            if (playback.enclosureId != null) {
                AndroidListeningListMiniPlayer(
                    playback = playback,
                    onPlayPause = {
                        coroutineScope.launch {
                            val enclosureId = playback.enclosureId ?: return@launch
                            if (playback.status == AndroidMediaPlaybackPresentationStatus.Playing) {
                                playbackCoordinator.pause()
                            } else {
                                playbackCoordinator.play(enclosureId)
                            }
                        }
                    },
                    onBack30 = {
                        coroutineScope.launch { playbackCoordinator.skipBackward30Seconds() }
                    },
                    onForward30 = {
                        coroutineScope.launch { playbackCoordinator.skipForward30Seconds() }
                    },
                )
            }
        },
    ) { padding ->
        when {
            state.isLoading && state.items.isEmpty() -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(24.dp),
                ) {
                    CircularProgressIndicator()
                }
            }

            state.errorMessage != null && state.items.isEmpty() -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(state.errorMessage.orEmpty(), color = MaterialTheme.colorScheme.error)
                    Button(onClick = { coroutineScope.launch { store.reload() } }) {
                        Text("Retry")
                    }
                }
            }

            state.items.isEmpty() -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Listening List is Empty", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Add audio news to your Listening List to find them here.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            else -> {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                ) {
                    items(state.items, key = { it.articleId }) { item ->
                        AndroidListeningListRow(
                            item = item,
                            playback = playback,
                            onPlay = { enclosureId ->
                                coroutineScope.launch { playbackCoordinator.play(enclosureId) }
                            },
                            onPause = {
                                coroutineScope.launch { playbackCoordinator.pause() }
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
                    }
                }
            }
        }
    }
}

@Composable
private fun AndroidListeningListRow(
    item: ListeningListItem,
    playback: AndroidMediaPlaybackState,
    onPlay: (Long) -> Unit,
    onPause: () -> Unit,
    onRemove: () -> Unit,
    onRequestDownload: (Long) -> Unit,
    onCancelDownload: (Long) -> Unit,
    onRetryDownload: (Long) -> Unit,
    onDeleteDownload: (Long) -> Unit,
) {
    var enclosureMenuOpen by remember { mutableStateOf(false) }
    val selected = item.audioEnclosures.firstOrNull {
        it.enclosure.id == item.activeEnclosureId
    } ?: item.audioEnclosures.firstOrNull()
    val selectedId = selected?.enclosure?.id
    val isPlaying = selectedId != null &&
        playback.enclosureId == selectedId &&
        playback.status == AndroidMediaPlaybackPresentationStatus.Playing

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
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
        )

        selected?.playbackState?.let { progress ->
            AndroidListeningListProgress(
                progress.positionMs.toLong(),
                progress.durationMs?.toLong(),
                progress.status,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (selectedId != null) {
                    Button(
                        onClick = {
                            if (isPlaying) onPause() else onPlay(selectedId)
                        },
                    ) {
                        Text(if (isPlaying) "Pause" else "Play")
                    }
                }
                if (item.audioEnclosures.size > 1) {
                    OutlinedButton(onClick = { enclosureMenuOpen = true }) {
                        Text(item.audioEnclosures.size.toString() + " audio")
                    }
                    DropdownMenu(
                        expanded = enclosureMenuOpen,
                        onDismissRequest = { enclosureMenuOpen = false },
                    ) {
                        item.audioEnclosures.forEachIndexed { index, enclosure ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        enclosure.enclosure.mimeType.ifBlank {
                                            "Audio " + (index + 1)
                                        },
                                    )
                                },
                                onClick = {
                                    enclosureMenuOpen = false
                                    onPlay(enclosure.enclosure.id)
                                },
                            )
                        }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (selectedId != null) {
                    val downloadState = selected.download?.state ?: DownloadState.NOT_DOWNLOADED
                    when (downloadState) {
                        DownloadState.NOT_DOWNLOADED -> {
                            TextButton(onClick = { onRequestDownload(selectedId) }) {
                                Text("Download")
                            }
                        }
                        DownloadState.REQUESTED -> {
                            TextButton(onClick = { onCancelDownload(selectedId) }) {
                                Text("Cancel")
                            }
                        }
                        DownloadState.DOWNLOADED -> {
                            TextButton(onClick = { onDeleteDownload(selectedId) }) {
                                Text("Delete")
                            }
                        }
                        DownloadState.FAILED -> {
                            TextButton(onClick = { onRetryDownload(selectedId) }) {
                                Text("Retry")
                            }
                        }
                        DownloadState.DELETE_REQUESTED -> {
                            Text(
                                "Deleting…",
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                TextButton(onClick = onRemove) {
                    Text("Remove")
                }
            }
        }
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
                progress = { (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f) },
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
private fun AndroidListeningListMiniPlayer(
    playback: AndroidMediaPlaybackState,
    onPlayPause: () -> Unit,
    onBack30: () -> Unit,
    onForward30: () -> Unit,
) {
    Surface(tonalElevation = 3.dp) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                playback.articleTitle.orEmpty(),
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                TextButton(onClick = onBack30) { Text("−30s") }
                Button(onClick = onPlayPause) {
                    Text(
                        if (playback.status == AndroidMediaPlaybackPresentationStatus.Playing) {
                            "Pause"
                        } else {
                            "Play"
                        },
                    )
                }
                TextButton(onClick = onForward30) { Text("+30s") }
            }
        }
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
