# Phase B8 - Native Media Execution

Phase B8 adds macOS execution for the media operations exposed by the B7
UniFFI boundary. The native client owns OS playback and transfer facilities;
Core remains authoritative for durable state and policy.

## Playback

`MediaPlaybackCoordinator` uses `AVPlayer` and accepts only Core-owned
`PlaybackPreparation` data. It prefers a validated local media file, falls
back to the Core-resolved remote URL, restores the Core position for in-progress
items, and does not implicitly restart completed items. Position checkpoints
are written on pause, seek, lifecycle transitions, and a periodic 20-second
cadence. Natural completion calls `playback_completed` once and records the
observed duration through Core.

The coordinator also publishes duration, chapters, artwork, and Now Playing
metadata to the macOS media session. It does not mark articles read or mutate
playback state outside the Core API.

## Transfers

`MediaTransferCoordinator` consumes Core transfer and deletion work. It uses
`URLSession` for downloads, applies Core's network policy, writes only beneath
the configured media root, and reports finished or failed work back to Core.
Temporary files are moved into deterministic Core-provided destinations only
after a successful transfer. Deletion work is completed only after the local
file is absent. Duplicate active tasks are suppressed and cancellation is
best-effort through URLSession.

Automatic scheduling, background transfer policy, and optional Saved Media
Sync remain outside this coordinator. The local playback and transfer paths
do not depend on Saved Media Sync.

## Integration And Tests

Both coordinators are application-scoped and configured from the existing
`BrowserStore` Core instance. `MediaCoordinatorTests` covers Core-authoritative
resume, explicit restart, natural completion idempotence, checkpoint behavior,
and media-root path containment.

Generated UniFFI bindings remain build artifacts. The macOS test target hosts
the app so it can test app-internal coordinator types.

## Deferred

User-facing media controls, richer queue UX, OS background scheduling,
download progress presentation, and Phase B9 reconciliation/retention work are
deferred. No iOS or Android client is introduced in this step.
