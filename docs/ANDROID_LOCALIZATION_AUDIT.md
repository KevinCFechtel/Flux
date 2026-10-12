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
