package de.circledev.fluxnews.nativeapp

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import uniffi.flux_uniffi.ListeningListEnclosure
import uniffi.flux_uniffi.ListeningListFeed
import uniffi.flux_uniffi.ListeningListItem
import uniffi.flux_uniffi.ListeningListSort

/**
 * Android Auto / system-media browse projection over the Core-owned Listening List.
 *
 * The automotive root is the Listening List itself: its direct children are playable episodes.
 * Feeds are retained only as filter metadata for the later E7 filter interaction and never become
 * browse nodes.
 */
internal object AndroidAutoMediaLibraryProjection {
    const val ROOT_MEDIA_ID = "flux:listening-list"

    fun rootItem(): MediaItem =
        MediaItem.Builder()
            .setMediaId(ROOT_MEDIA_ID)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Listening List")
                    .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_NEWS)
                    .setIsBrowsable(true)
                    .setIsPlayable(false)
                    .build(),
            )
            .build()

    fun selectedEnclosure(item: ListeningListItem): ListeningListEnclosure? =
        item.activeEnclosureId
            ?.let { activeId ->
                item.audioEnclosures.firstOrNull { it.enclosure.id == activeId }
            }
            ?: item.audioEnclosures.firstOrNull()

    fun matchesSearch(item: MediaItem, query: String): Boolean {
        val normalized = query.trim()
        if (normalized.isEmpty()) return false
        return item.mediaMetadata.title
            ?.toString()
            ?.contains(normalized, ignoreCase = true) == true ||
            item.mediaMetadata.artist
                ?.toString()
                ?.contains(normalized, ignoreCase = true) == true
    }

    fun mediaItem(item: ListeningListItem): MediaItem? {
        val selected = selectedEnclosure(item) ?: return null
        return MediaItem.Builder()
            // Keep the canonical enclosure ID as Media3 identity. E6 checkpointing already reads
            // this ID from the player, and later E7 playback dispatch can therefore reuse it.
            .setMediaId(selected.enclosure.id.toString())
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(item.title.ifBlank { "Untitled News" })
                    .setArtist(item.feedTitle.ifBlank { "Unknown Feed" })
                    .setAlbumTitle(item.feedTitle.ifBlank { "Unknown Feed" })
                    .setMediaType(MediaMetadata.MEDIA_TYPE_NEWS)
                    .setIsBrowsable(false)
                    .setIsPlayable(true)
                    .build(),
            )
            .build()
    }
}

internal data class AndroidAutoMediaLibrarySnapshot(
    val sessionGeneration: Long? = null,
    val selectedFeedId: Long? = null,
    val items: List<MediaItem> = emptyList(),
    val itemsByMediaId: Map<String, MediaItem> = emptyMap(),
    val feeds: List<ListeningListFeed> = emptyList(),
)

/**
 * Small process-runtime projection for MediaLibrarySession callbacks.
 *
 * MediaLibrary callbacks are deliberately served from an already prepared in-memory snapshot.
 * Synchronous UniFFI/Core reads stay on AndroidCoreRuntime's local dispatcher rather than running
 * on the Media3/application thread. The snapshot is disposable and can always be rebuilt from
 * Core after process death.
 */
internal class AndroidAutoMediaLibraryStore(
    private val coreRuntime: AndroidCoreRuntime,
    private val diagnostics: AndroidAppDiagnostics,
) {
    @Volatile
    private var currentSnapshot = AndroidAutoMediaLibrarySnapshot()

    fun snapshot(): AndroidAutoMediaLibrarySnapshot = currentSnapshot

    fun clear() {
        currentSnapshot = AndroidAutoMediaLibrarySnapshot()
    }

    suspend fun refresh(
        generation: Long,
        feedId: Long? = null,
    ): AndroidAutoMediaLibrarySnapshot {
        val projected = runCatching {
            coreRuntime.localForGeneration(generation) { core ->
                val feeds = core.listeningListFeeds()
                val validFeedId = feedId?.takeIf { candidate ->
                    feeds.any { it.feedId == candidate }
                }
                val items = core.listeningList(
                    feedId = validFeedId,
                    sort = ListeningListSort.RECENTLY_ADDED,
                )
                val mediaItems = items.mapNotNull(AndroidAutoMediaLibraryProjection::mediaItem)
                AndroidAutoMediaLibrarySnapshot(
                    sessionGeneration = generation,
                    selectedFeedId = validFeedId,
                    items = mediaItems,
                    itemsByMediaId = mediaItems.associateBy(MediaItem::mediaId),
                    feeds = feeds,
                )
            }
        }.getOrElse { failure ->
            if (coreRuntime.activeSessionGeneration() == generation) {
                diagnostics.record(
                    AndroidAppLogLevel.Warning,
                    "android-auto",
                    "Listening List projection failed: ${failure.javaClass.simpleName}",
                )
            }
            return snapshot()
        }

        if (coreRuntime.activeSessionGeneration() != generation) {
            return snapshot()
        }

        currentSnapshot = projected
        return projected
    }
}
