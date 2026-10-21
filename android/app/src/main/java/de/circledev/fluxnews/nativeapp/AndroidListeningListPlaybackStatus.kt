package de.circledev.fluxnews.nativeapp

import uniffi.flux_uniffi.ListeningListItem
import uniffi.flux_uniffi.PlaybackStatus

// "Not started" means never played, not necessarily newly published or added.
internal fun isUnplayedListeningListItem(item: ListeningListItem): Boolean =
    item.audioEnclosures.isNotEmpty() && item.audioEnclosures.all { audio ->
        audio.enclosure.remoteMediaProgressionSeconds == 0uL &&
            (audio.playbackState == null ||
                (audio.playbackState.status == PlaybackStatus.NOT_STARTED &&
                    audio.playbackState.positionMs == 0uL))
    }

