package de.circledev.fluxnews.nativeapp

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Single Media3 playback and browse container for E6/E7.
 *
 * The service continues to own the one native Android player introduced in E6. E7 extends that
 * same service with a MediaLibrarySession so Android Auto and other media browsers see a
 * Core-backed Listening List without introducing a second player, queue, database or cache.
 */
class AndroidMediaPlaybackService : MediaLibraryService(), AndroidMediaPlaybackHost {
    private lateinit var player: ExoPlayer
    private var mediaSession: MediaLibrarySession? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val app: FluxApplication
        get() = applicationContext as FluxApplication

    private val mediaRuntime: AndroidMediaRuntime
        get() = app.mediaRuntime

    private val libraryStore: AndroidAutoMediaLibraryStore
        get() = app.autoMediaLibraryStore

    private val libraryCallback = object : MediaLibrarySession.Callback {
        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            com.google.common.util.concurrent.Futures.immediateFuture(
                LibraryResult.ofItem(AndroidAutoMediaLibraryProjection.rootItem(), params),
            )

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            if (parentId != AndroidAutoMediaLibraryProjection.ROOT_MEDIA_ID) {
                return com.google.common.util.concurrent.Futures.immediateFuture(
                    LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE, params),
                )
            }

            return libraryResultFuture {
                val snapshot = refreshLibraryForHeadlessBrowser()
                    ?: return@libraryResultFuture LibraryResult.ofItemList(emptyList(), params)
                val from = (page.toLong() * pageSize.toLong())
                    .coerceAtMost(snapshot.items.size.toLong())
                    .toInt()
                val to = (from + pageSize).coerceAtMost(snapshot.items.size)
                LibraryResult.ofItemList(snapshot.items.subList(from, to), params)
            }
        }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            libraryResultFuture {
                val cached = libraryStore.snapshot().itemsByMediaId[mediaId]
                val item = cached ?: refreshLibraryForHeadlessBrowser()
                    ?.itemsByMediaId
                    ?.get(mediaId)
                item?.let { LibraryResult.ofItem(it, null) }
                    ?: LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)
            }


        override fun onSearch(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> =
            libraryResultFuture {
                val results = searchLibrary(query)
                session.notifySearchResultChanged(
                    browser,
                    query,
                    results.size,
                    params,
                )
                LibraryResult.ofVoid(params)
            }

        override fun onGetSearchResult(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> =
            libraryResultFuture {
                val results = searchLibrary(query)
                val from = (page.toLong() * pageSize.toLong())
                    .coerceAtMost(results.size.toLong())
                    .toInt()
                val to = (from + pageSize).coerceAtMost(results.size)
                LibraryResult.ofItemList(results.subList(from, to), params)
            }


        /**
         * Resolve Android Auto / legacy MediaBrowser selections through Core. The in-app
         * coordinator already supplies a fully resolved URI, so its own MediaController commands
         * pass through unchanged and cannot recursively re-enter Core preparation.
         */
        @UnstableApi
        override fun onSetMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: List<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            if (mediaItems.size != 1) {
                return Futures.immediateFailedFuture(
                    UnsupportedOperationException("FluxNews does not expose a durable media queue."),
                )
            }

            val requested = mediaItems.single()
            if (
                controller.packageName == packageName &&
                requested.localConfiguration != null
            ) {
                return Futures.immediateFuture(
                    MediaSession.MediaItemsWithStartPosition(
                        mediaItems,
                        startIndex,
                        startPositionMs,
                    ),
                )
            }

            val enclosureId = requested.mediaId.toLongOrNull()?.takeIf { it > 0L }
                ?: return Futures.immediateFailedFuture(
                    IllegalArgumentException("Unknown FluxNews media item."),
                )

            return mediaSessionItemsFuture {
                val snapshot = refreshLibraryForHeadlessBrowser()
                    ?: throw IllegalStateException("FluxNews media library is unavailable.")
                if (snapshot.itemsByMediaId[requested.mediaId] == null) {
                    throw IllegalArgumentException("Media item is not in the Listening List.")
                }

                val resolved = app.mediaPlaybackCoordinator.prepareForMediaSession(enclosureId)
                val requestedStart = startPositionMs
                    .takeIf { it != C.TIME_UNSET && it >= 0L }
                    ?: resolved.startPositionMs

                MediaSession.MediaItemsWithStartPosition(
                    listOf(resolved.mediaItem),
                    0,
                    requestedStart,
                )
            }
        }

        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: List<MediaItem>,
        ): ListenableFuture<List<MediaItem>> =
            Futures.immediateFailedFuture(
                UnsupportedOperationException("FluxNews does not expose a durable media queue."),
            )

        @UnstableApi
        override fun onPlayerInteractionFinished(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            playerCommands: Player.Commands,
        ) {
            if (playerCommands.contains(Player.COMMAND_STOP)) {
                serviceScope.launch {
                    app.mediaPlaybackCoordinator.handleExternalStop()
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
            .build()

        player = ExoPlayer.Builder(this)
            .setAudioAttributes(audioAttributes, true)
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(30_000L)
            .setSeekForwardIncrementMs(30_000L)
            .build()

        mediaSession = MediaLibrarySession.Builder(this, player, libraryCallback).build()
        mediaRuntime.attachPlaybackHost(this)
    }

    override fun onGetSession(
        controllerInfo: MediaSession.ControllerInfo,
    ): MediaLibrarySession? = mediaSession

    override suspend fun checkpoint(): AndroidMediaPlaybackCheckpoint? =
        withContext(Dispatchers.Main.immediate) {
            if (!::player.isInitialized) return@withContext null
            val enclosureId = player.currentMediaItem
                ?.mediaId
                ?.toLongOrNull()
                ?.takeIf { it > 0L }
                ?: return@withContext null
            val duration = player.duration
                .takeIf { it != C.TIME_UNSET && it > 0L }

            AndroidMediaPlaybackCheckpoint(
                enclosureId = enclosureId,
                positionMs = player.currentPosition.coerceAtLeast(0L),
                durationMs = duration,
            )
        }

    override suspend fun quiesce(clearPlayback: Boolean) {
        withContext(Dispatchers.Main.immediate) {
            if (!::player.isInitialized) return@withContext
            player.pause()
            if (clearPlayback) {
                player.stop()
                player.clearMediaItems()
                libraryStore.clear()
            }
        }
    }

    private suspend fun searchLibrary(query: String): List<MediaItem> {
        val normalized = query.trim()
        if (normalized.isEmpty()) return emptyList()
        val snapshot = refreshLibraryForHeadlessBrowser() ?: return emptyList()
        return snapshot.items.filter { item ->
            AndroidAutoMediaLibraryProjection.matchesSearch(item, normalized)
        }
    }

    private suspend fun refreshLibraryForHeadlessBrowser(): AndroidAutoMediaLibrarySnapshot? {
        val bootstrapState = app.accountBootstrap.restoreStoredAccount()
        if (bootstrapState !is AndroidAccountBootstrap.State.Ready) {
            libraryStore.clear()
            return null
        }
        val generation = app.coreRuntime.activeSessionGeneration() ?: return null
        return libraryStore.refresh(generation)
    }

    private fun mediaSessionItemsFuture(
        block: suspend () -> MediaSession.MediaItemsWithStartPosition,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
        val future = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
        serviceScope.launch {
            try {
                future.set(block())
            } catch (failure: Throwable) {
                app.diagnostics.record(
                    AndroidAppLogLevel.Warning,
                    "android-auto",
                    "Playback selection failed: ${failure.javaClass.simpleName}",
                )
                future.setException(failure)
            }
        }
        return future
    }

    private fun <T> libraryResultFuture(
        block: suspend () -> LibraryResult<T>,
    ): ListenableFuture<LibraryResult<T>> {
        val future = SettableFuture.create<LibraryResult<T>>()
        serviceScope.launch {
            try {
                future.set(block())
            } catch (failure: Throwable) {
                app.diagnostics.record(
                    AndroidAppLogLevel.Warning,
                    "android-auto",
                    "Media library request failed: ${failure.javaClass.simpleName}",
                )
                future.set(LibraryResult.ofError(LibraryResult.RESULT_ERROR_UNKNOWN))
            }
        }
        return future
    }

    override fun onDestroy() {
        mediaRuntime.detachPlaybackHost(this)
        serviceScope.cancel()
        libraryStore.clear()
        mediaSession?.release()
        mediaSession = null
        if (::player.isInitialized) player.release()
        super.onDestroy()
    }
}
