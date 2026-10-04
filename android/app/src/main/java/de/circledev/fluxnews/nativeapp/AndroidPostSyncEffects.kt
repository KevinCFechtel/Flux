package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.SyncCompleted

/**
 * Process-scoped handoff for platform effects that happen after a successful Core Sync.
 *
 * Core remains the Sync/domain owner. E5 platform adapters (notifications, widget projection)
 * attach here instead of collecting the single-consumer Core event mailbox independently.
 */
internal class AndroidPostSyncEffects(
    private val activeSessionGeneration: () -> Long?,
    private val effects: List<AndroidPostSyncEffect> = emptyList(),
) {
    private val mutex = Mutex()

    suspend fun handle(sessionGeneration: Long, metadata: SyncCompleted) {
        if (activeSessionGeneration() != sessionGeneration) return

        mutex.withLock {
            if (activeSessionGeneration() != sessionGeneration) return

            for (effect in effects) {
                if (activeSessionGeneration() != sessionGeneration) return
                runCatching { effect.apply(sessionGeneration, metadata) }
            }
        }
    }
}

internal fun interface AndroidPostSyncEffect {
    suspend fun apply(sessionGeneration: Long, metadata: SyncCompleted)
}
