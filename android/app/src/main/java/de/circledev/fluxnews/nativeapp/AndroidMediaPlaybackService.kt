package de.circledev.fluxnews.nativeapp

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
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

    private suspend fun refreshLibraryForHeadlessBrowser(): AndroidAutoMediaLibrarySnapshot? {
        val bootstrapState = app.accountBootstrap.restoreStoredAccount()
        if (bootstrapState !is AndroidAccountBootstrap.State.Ready) {
            libraryStore.clear()
            return null
        }
        val generation = app.coreRuntime.activeSessionGeneration() ?: return null
        return libraryStore.refresh(generation)
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
