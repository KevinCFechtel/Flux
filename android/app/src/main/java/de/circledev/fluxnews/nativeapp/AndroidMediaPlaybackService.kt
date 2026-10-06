package de.circledev.fluxnews.nativeapp

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * E6 Media3 playback container.
 *
 * The service owns the single native Android player. UI/controller wiring, Listening List
 * presentation and E7 system/Android Auto browsing build on this service rather than creating a
 * second player.
 */
class AndroidMediaPlaybackService : MediaSessionService(), AndroidMediaPlaybackHost {
    private lateinit var player: ExoPlayer
    private var mediaSession: MediaSession? = null

    private val mediaRuntime: AndroidMediaRuntime
        get() = (applicationContext as FluxApplication).mediaRuntime

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

        mediaSession = MediaSession.Builder(this, player).build()
        mediaRuntime.attachPlaybackHost(this)
    }

    override fun onGetSession(
        controllerInfo: MediaSession.ControllerInfo,
    ): MediaSession? = mediaSession

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
            }
        }
    }

    override fun onDestroy() {
        mediaRuntime.detachPlaybackHost(this)
        mediaSession?.release()
        mediaSession = null
        if (::player.isInitialized) player.release()
        super.onDestroy()
    }
}
