# Android localization audit — 2026-10-12

**Status: the documented high-confidence UI literals have been extracted in this PR; wider dynamic/background localization audit remains open. C1 is not yet fully technically Weblate-ready.**

## Scope and methodology

- PR #44 was squashed to `main` as `854a9a1376a5efde8fdf0a398b3a870e05ab7152` after Android CI succeeded on its tip.
- The repository has **71 Kotlin files in `android/app/src/main`**. This audit inspected representative user-facing source files in the merged tree using the same kinds of literal patterns as `android/Build/check-localization.py`, plus manual attention to more complex displayed text.
- The CI now runs `python3 android/Build/check-localization.py --all` **as an informational full source inventory on every Android workflow**, and then enforces `--base` for new literals. The full inventory is currently non-blocking, so the Android CI being green does **not** mean all strings were translated.
- The findings below are **confirmed examples addressed by this follow-up**, not a complete list of all remaining dynamically generated text. Review every inventory result and manually audit string concatenation, state-model messages, workers and user-visible notifications before closing C1.

## Confirmed UI literals addressed in this PR

| Kotlin file | Representative source locations | Outstanding copy |
| --- | --- | --- |
| `AndroidArticleActions.kt` | 202, 222 | Choose audio, Close |
| `AndroidArticleTimelineView.kt` | 349, 356, 425, 481, 506 | Retry, no articles, Undo, new articles |
| `AndroidArticleRow.kt` | 421, 444, 452, 464, 475 | Missing image, audio/comments/star/unread accessibility descriptions |
| `AndroidMiniPlayer.kt` | 168 | Back 15 seconds accessibility description |
| `AndroidSearch.kt` | 844 | More results unavailable |
| `SettingsShell.kt` | 221–224, 278, 339 and elsewhere | Article preference switches, hide-empty feeds, Downloads section, other preferences |
| `AndroidBulkFeedSettingsScreen.kt` | 244, 259, 270, 290, 301 | Feed preference section titles |
| `SupportDiagnosticsScreen.kt` | 66 | Log Viewer heading |

The entries above have been migrated to Android string resources in this PR. A full inventory still needs inspection after CI completes; findings beyond these examples are not yet closed. The pattern scan found no direct matches in the sampled `AndroidArticleReader.kt`, `AndroidListeningListDestination.kt`, `AndroidMediaPlayerSheet.kt`, `AndroidSystemNotifications.kt`, `AndroidWidgetUpdates.kt`, `AndroidFeedCreationDialog.kt` and others; **this is not proof that they have no nonliteral or dynamic user-visible messages**.

## Closeout criteria

1. Review the **full** inventory emitted by the Android CI audit step, classify every finding as translatable, genuinely technical or false positive, and address each translatable item.
2. Remove known literals (including accessibility descriptions and settings labels); use stable resource IDs and `plurals`, and preserve the existing Weblate monolingual base and translator-owned target catalogs.
3. Manually inspect background workers, system notifications, widget `RemoteViews`, Android Auto text, dynamically composed snackbar/errors, relative time/number formatting and non-Compose UI; the regex does not prove completeness.
4. Add tests/targeted checks where practical for format placeholders, quantity agreement and locale fallback.
5. Pass Android CI and verify representative screens on a device/emulator with a changed system language; do not declare the seven language translations finished before translators review them through Weblate.

## Current CI safety net

- `check-localization.py --all`: informational debt inventory, prints matching file/line references on every Android run.
- `check-localization.py --base <git-ref>`: blocking incremental guard for newly added literal UI strings.
- The guard intentionally is heuristic. A valid technical exception needs an in-line `// l10n-ignore: reason`. Do not silently broaden ignores to make CI green.

**Decision:** keep C1 extraction **in progress**, Weblate resource structure **established**, translation catalogs **awaiting reviewed translations**.

## Broader source audit — 2026-10-12 (PR #46 head)

The extended review covered the production Kotlin source tree (71 files), including Compose screens, state models, media sessions, notifications, widget and background subsystems. This is a **source-level audit**, not an emulator/device acceptance test. It inspected additional patterns excluded from the original high-confidence CI guard: immediate snackbar literals, `ifBlank` placeholders, error-state assignments, Media3 labels and non-Compose notifications.

### Confirmed translatable findings still open

| Area | Kotlin source / approximate line on PR #46 | Examples | Required action |
| --- | --- | --- | --- |
| Timeline action failures | `AndroidArticleTimelineView.kt:140` | Invalid Miniflux URL snackbar | Resource and composable-safe resolution |
| Search action failures | `AndroidSearch.kt:662–663, 679` | Invalid web URL; could not open article; Miniflux URL | Resource and configuration-aware message |
| Listening List fallback metadata | `AndroidListeningListDestination.kt:144, 368, 387` | Unknown Feed, Untitled News | Resources instead of English fallbacks |
| Audio player metadata | `AndroidMediaPlayerSheet.kt:491` | Audio fallback title | Resource |
| Per-feed settings | `AndroidFeedSettingsScreen.kt:100–121, 147–221` | Load/save/permission error and five option titles | Resources for state messages and headings |
| Bulk feed operations | `AndroidBulkFeedSettingsScreen.kt:85, 102, 114` | Load/save/notification-permission errors | Resources for errors |
| Core article settings | `CoreArticleSettingsSection.kt:43, 52, 72, 84, 92, 106, 127` | Load/save errors and setting titles | Resource-based state and UI |
| Config backup | `ConfigurationBackupScreen.kt:73` | Cannot write selected location | Localized error |
| Navigation startup | `AdaptiveAppShell.kt:118` | Navigation data could not be loaded | Localized model error |
| Legacy migration status | `AndroidLegacyMigrationNotice.kt:65–68` | Step/status descriptions; skipped items | Resource strings, formatted placeholders |
| Audio enclosure chooser | `AndroidArticleActions.kt:216` | Audio N fallback | Resource with formatted index |
| Android Auto projection compatibility fallback | `AndroidAutoMediaLibrary.kt` | Context-free English defaults retained for helper/test usage | Confirm if any production call lacks context; eliminate English fallback if possible without breaking tests |
| User-configurable action labels | `SettingsShell.kt:264` | `+ ${action.displayName}` (display name may itself be hardcoded) | Trace origin of `displayName` and move user labels to resources |

This is **not a proof of zero undiscovered UI strings**. The reported files/locations are confirmed examples from source inspection; more patterns can appear in the full CI inventory. Symbols such as checkmarks/arrows and clipboard labels are not necessarily translatable prose; review them for accessibility separately.

### Items not requiring UI translation

`AndroidBackgroundSync.kt` retry/exception text, diagnostic-only `AndroidSystemNotifications.kt` exception logging, API identifiers, deep-link IDs and internal media identifiers remain technical. They must not be indiscriminately moved to resources.

### Resource structure

At the audit snapshot the base Android `values/strings.xml` contains approximately **260 string keys** and **3 plurals**, with no duplicate base string key found by the resource inspection. Locale catalogs exist for German, Spanish, Galician, Dutch, Tamil and Turkish, but language-complete translated content is not yet established. Formatting correctness and localization behavior still require targeted CI/runtime verification.

### Audit verdict

**C1 NOT YET TECHNICALLY COMPLETE.** Meaningful untranslated UI text persists in settings, state-driven messages, search/timeline actions and fallback content. PR #46 addresses media and notification surfaces but does not clear these examples. Expand the CI heuristic for future changes, maintain the full informational inventory, resolve the findings, and then perform device/emulator acceptance with another system locale. Do not equate green CI with 100% extraction.

## Android Auto and foreground download follow-up

After the audited Compose cleanup (#45, merge `1b729995ee9059ae6cfd3057fecba0df6c582b7b`), this follow-up moves the confirmed Android Auto browse root/filter labels, missing feed/article titles, media command display labels and MediaTransfer foreground-notification channel/title/body into Android string resources. Android Auto feed-count subtitles now use Android plural forms. The production Media3 session supplies its Android `Context` to browse projections; helper calls without a context retain their old English fallback for compatibility with call sites/tests.

This is **not** an assertion that every user-facing dynamic message has been localized. The regex-based guard is intentionally not a complete program analysis; check generated error text, relative dates, dynamically composed summaries, non-Compose and runtime locale behavior before declaring C1 complete. Review the new Android CI and on-device Android Auto + notification surfaces.

## Expanded re-audit after cleanup — 2026-10-12

**Repository scope:** Reviewed **all 71 production Kotlin files** under `android/app/src/main` using an expanded source pattern review (direct Compose labels, state-assigned errors, snackbar calls, fallback metadata, enum display names, system/media/notification labels, and contextual actions). The earlier findings list above documents the baseline, not necessarily the current state. This section is the newer assessment.

**Code changes now covered by PR #47:** Feed and bulk-feed error states and option headings; core article settings error states; media/download settings error states; configuration backup completion/errors; search and timeline direct action snackbar labels; Listening List/media title fallbacks and progress; article chooser/media actions/swipe accessibility; app startup, background-sync controls and help; navigation, migration step/overview display; article Reader notices; Settings selection/display names, timeline action menu and scope counts. PR #46 already handles Android Auto and foreground media-download notifications and has been merged to `main` (`deecb8c`).

**Resources:** 431 `<string>`/`<plurals>` entries in the current base values XML at this snapshot. No duplicate names were found. All resource references in the 17 changed Kotlin source files resolve to keys in the base strings XML. Six target locale directories remain in place; actual translated catalog content has not been verified.

### Residual findings after the second source scan

The following production state/model layers **still construct English message text**. These require attention at the data-to-presentation boundary, not `stringResource()` called directly in background workers:

| Source | Remaining message category | Status |
| --- | --- | --- |
| `AndroidAccountBootstrap.kt`, `AndroidAccountPresentation.kt` | Account activation, validation and migration failures | Open |
| `AndroidArticleTimeline.kt` | List loading, pagination and bulk-read failures | Open |
| `AndroidListeningList.kt` | Listening List loading failure | Open |
| `AndroidMediaPlaybackCoordinator.kt` | Playback-completion save failure | Open |
| `AndroidSearch.kt` | Store-generated paging, read/star, download and integration feedback; direct UI snackbar errors were extracted | Open |
| `AndroidSyncCoordinator.kt` | Offline-data fallback sync banner text | Open |
| `AndroidWidgetContract.kt` | Default/Bookmarks label origins | Review non-Compose widget presentation |
| `AndroidLegacyMigrationNotice.kt` | Raw legacy step identifiers and externally persisted status fragments; display step titles/known defaults now use resources | Review remaining dynamic status details |
| `AndroidAutoMediaLibrary.kt` | English fallbacks for **context-free helper/test calls**; real service passes Android Context | Nonproduction fallback, retained deliberately |
| `AndroidArticleActions.kt`, preferences enums | Original English label properties retained for API/test compatibility; reviewed production menus and options use localized presentation wrappers | Compatibility, not an unlocalized UI path |
| `AndroidArticleReader.kt` | Raw internal read-error message retained; Reader view translates the displayed error | Internal status translated at presentation |

**Verdict: C1 is still open.** The original list of static UI literals has been substantially cleaned, and expanded CI catches more future regressions. The second full-source pattern scan found the model-generated messages above; it does **not** certify that every possible string-flow is localized. The final closeout still needs explicit treatment of the open runtime-display paths and an emulator/device locale acceptance run. Logs, protocol identifiers and fixture articles are excluded intentionally.

### CI validation

The Android workflow runs the expanded `check-localization.py --all` inventory as informational output and `--base` as an incremental block. Successful execution of these checks confirms the scanner runs, not zero English messages. A fully green Android build/lint/test result is additionally required before merging this cleanup PR.


## Follow-up extraction — 2026-10-12 (`51afc42`)

A focused third pass confirmed additional **directly displayed** literals overlooked by the previous scanner, including account-section headings and HTTP warning, article row time/accessibility labels, Reader pane and image accessibility, player sleep timer, chapter and show-notes text, Listening List empty/now-playing/download status, timeline filter labels, and pending migration dialog copy. These are extracted to **37 base Android string resources** in `51afc42` (no translated locale catalogs added). The changes are source-only; no emulator acceptance is implied.

**Still open:** runtime strings in `AndroidAccountBootstrap`, `AndroidAccountPresentation`, `AndroidArticleTimeline`, `AndroidListeningList`, `AndroidMediaPlaybackCoordinator`, `AndroidSearch`, `AndroidSyncCoordinator`, and `AndroidWidgetContract`. Inspect additional dynamic content and migration persisted status flows. Context-free Android Auto helper fallback and compatibility-only labels remain separately classified. An expanded incremental scanner now detects more accessibility, conditional display and feedback patterns; it is heuristic and does not replace a runtime string-flow review. **C1 remains open** until these paths are localized, the expanded complete source review is recorded, tests/CI pass and locale behavior is validated on device/emulator.
