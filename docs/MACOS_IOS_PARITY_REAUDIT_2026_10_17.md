# macOS ↔ iOS feature-gap re-audit (17 October 2026)

Baseline: `main` at `ea99c5f`, plus proposed macOS Listening List follow-ups in PR #61. This is a **source review**, not proof of real-device runtime behavior. It supplements the C3 roadmap and does not reopen completed C3.1–C3.7 work.

## Remaining implementation / behavior differences

| Priority | Area | iOS reference | macOS evidence / remaining action |
| --- | --- | --- | --- |
| P0 (PR #61) | Embedded audio artwork via HTTP Range | `NewsreaderStore.requestMediaArtworkProbe` and `IOSSearchStore.requestMediaArtworkProbe` call Rust `probeMediaArtwork` after adding to Listening List; Android does likewise | `BrowserStore.addToListeningList` on current main does **not** call `probeMediaArtwork`. PR #61 adds a serialized, session-bounded queue and on-demand backfill when an artwork source is missing. Listen/Player cover revision refresh is included. Device-verify MP3 ID3, MP4/M4A, server range support, existing entries, and no full media download. |
| P0 (PR #61) | Deleting a locally loaded episode | iOS media transfer coordinates deletions with media-in-use policy | macOS `MediaTransferCoordinator.executeDeletions` skips files in use; `MediaPlaybackCoordinator.isUsing` remains true after pause/stop. PR #61 explicitly unloads/checkpoints the **target** on requested deletion, leaving unrelated playback untouched. Verify on device, including deletion after pause/stop and pending-state completion. |
| P1 | **Automatic** delete-after-playback and deferred deletion | Core policy available on both; iOS media runtime reconciles deferred work | macOS `handleNaturalEnd` calls reconciliation, but `isUsing` still matches the loaded enclosure, so the transfer coordinator can defer deletion indefinitely until another enclosure is prepared. Explicit/manual deletion is handled by PR #61, not this separate automatic completion path. Confirm on device; if reproducible, release the completed media safely before cleanup. |
| P1 | Chapter preview for an episode not yet loaded | `IOSMediaPlayerView.loadPreviewChapters` fetches chapters for inactive Listening List preview | macOS `PlayerView.chapters` renders only `state.chapters` from current playback, not the preview enclosure. Add a preview-specific chapter load and selection policy without starting audio. |
| P1 | Open Original from Listening List Show Notes | iOS keeps the episode/article context for the Reader action | macOS `PlayerView.openOriginal` resolves only `store.articles.first(where: ...)`; the target often is absent from the current article timeline while viewing Listening List. Need Core article URL lookup or a reader-document-provided target; do not silently no-op. |
| P2 / UX | Mini player outside full player | `IOSMiniPlayerView` has compact cover, title, open and play/pause across mobile placements | macOS has a player navigation button in popover and macOS system Now Playing controls, but no equivalent in-popover compact cover/title/play-pause. Desktop-specific compact control optional, depending on acceptance. |
| P2 / performance | Near-viewport article-image prefetch | `IOSUIKitArticleTimelineController` prepares up to two upcoming image-bearing articles; separate `ArticleImagePipeline` deduplicates and caches | macOS article/listening images use visibility-driven loading and caches; Listening List cover waits 90ms. This is a performance optimization gap, **not** an absent core feature. Measure on real Mac before adding predictive prefetch. |
| P1 / acceptance | C3.8 functional checks | iOS features already tested on devices in Phase D | macOS C3.1–C3.7 landed, and M1/M2 landed in #59; full account/sync, read, star, scope bulk read/next, feed bulk settings, search, reader, media, widgets, notifications, diagnostics, backup, Weblate fallback and accessibility still require real-Mac functional sign-off. |
| Release gate | B1 sandbox acceptance | iOS distribution follows different provisioning/runtime model | macOS development-signed Sandbox verifier/installer exists; fresh-account/fresh-container runtime and denial checks are still open before store distribution. |

## Capabilities already present on macOS — NOT gaps

- `BrowserStore`, `PopoverNavigationViews`: All/Unread within Starred, scope-level **Mark All as Read**, **Mark All as Read & Next**, feed/category scopes, search, native shortcuts/context actions.
- `SettingsView` and feed management: searchable bulk feed settings, per-feed settings, article/list/navigation configuration, download policy/retention, downloaded-data overview/delete all, encrypted configuration backup, diagnostics, About and plain-HTTP warning.
- `SearchResultsView`: paginated Miniflux search (50-item pages and incremental load).
- `MediaPlaybackCoordinator`, `PlayerView`, `ListeningListViews`: playback with 15s/30s skip, chapters **for loaded media**, variable speed, manual downloads/cancel/delete, progress, album cover, Show Notes with retry. Full implementation exists; confirm behavior and exceptions noted above.
- `SystemNotificationManager`, widgets, `AppDelegate`: system notifications, widgets/App Intents, periodic/recovery sync with network/wake lifecycle.
- `ReaderWindow`, `SearchResultsView`, `ArticleRowView`: reader, open original/Miniflux, share, star/read, search, image presentation and keyboard or contextual alternatives to touch gestures.

## Intentional platform differences (NOT parity defects)

- iOS has CarPlay and iOS-specific BackgroundTasks/Lock-Screen widgets; macOS has a menu-bar app, global keyboard shortcut, login item, native desktop system media controls and macOS widgets.
- iOS/Android have native Flutter-app upgrade migrations. The unreleased macOS app intentionally starts fresh; **do not add a macOS legacy-data migration**.
- Mobile Action Bar/gestures have desktop keyboard/menu/context-menu alternatives; visual identity need not match if workflows do.
- iOS-specific `Action Bar` settings, UI navigation/portrait layouts, and mobile media presentation are platform-specific.

## Device acceptance for PR #61

1. Add remote MP3 episode with embedded ID3 artwork but no external cover. Confirm artwork appears in Listening List and Player without a full MP3 download.
2. Try M4A/MP4 embedded artwork; server can reject byte ranges or store metadata at inaccessible offsets, in which case the fallback is expected. Verify no entire file is downloaded.
3. Inspect an older Listening List item without a recorded artwork source: opening/scrolling to its row should enqueue at most one probe per enclosure/account session.
4. Switch account during an in-flight probe. No previous-account artwork should be delivered.
5. Delete a downloaded episode during playback and after Pause/Stop: progress is checkpointed, player releases the file, deletion completes; deleting another episode does not stop current audio.
6. Check Download and Remove controls are adjacent; verify bulk/feed actions, background cleanup and current artwork remain stable.
7. Run macOS and iOS Apple CI, then sign and test macOS Sandbox installation separately (B1).
