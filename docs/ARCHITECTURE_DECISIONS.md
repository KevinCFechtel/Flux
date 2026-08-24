# Flux Architecture Decisions

> **Status: ACTIVE / AUTHORITATIVE TARGET ARCHITECTURE**
>
> This document records explicitly agreed decisions for the shared Flux architecture. It describes the target state, not necessarily the current implementation. Historical roadmaps and compatibility contracts do not override it.

## 1. Target

Flux uses one shared Rust core for business/background responsibilities and native clients for macOS, iOS, and Android.

The former Go core is retired. No new work should preserve Go compatibility or build transitional Go/Rust parity unless explicitly requested for historical investigation.

UniFFI is the selected binding technology for Swift and Kotlin/native clients.

## 2. Responsibility boundary

### Rust core

Owns persistence and durable data state, Miniflux API communication, sync/reconciliation, durable mutations, article/feed/category domain data, core settings, content processing, cache/media metadata, queries, and structured change/error events.

### Native clients

Own UI/presentation state and OS integration: navigation, visible list snapshots, scroll position, gestures, dialogs, layout/theme, browser/share behavior, secure credential storage, native scheduling/background transfer, playback engines, widgets, and OS notification presentation.

Core APIs express domain intent, never UI mechanisms. A swipe, button, context menu, pull-to-refresh, or scroll gesture is translated by the native client into a domain operation.

## 3. Queries, snapshots, counts, and events

The UI can query core data at any time. Core changes also emit structured events, including changes initiated by the UI itself.

Events inform; they do not force presentation refresh. Visible lists and counts change only when the native UI chooses to query again.

Article queries support at least:

- scope: all / category / feed
- read filter
- starred filter
- sort: newest first / oldest first
- pagination (`limit = 0` means all matching items)

Sorting uses publication time only.

Counts are point-in-time core queries and respect the selected view/filter. Background changes do not silently replace visible counts.

List queries should return compact article summaries; full content is requested separately for article detail.

## 4. Stable visible list snapshots

A background core change must not unexpectedly rebuild a list the user is currently using.

With Sync-on-Start enabled:

1. load and display local state immediately;
2. run sync in parallel;
3. if the user has not scrolled or otherwise meaningfully interacted with the list by sync completion, the native UI may automatically refresh the snapshot;
4. after interaction, keep the snapshot stable and signal new data through an event/badge until the UI intentionally refreshes.

Sync-on-Start is optional. When disabled, app start only loads local state.

Resume follows the same stable-snapshot rule. Data obtained by a background sync while the app was suspended is signalled, not pushed into the visible list.

Deep-link/widget/notification launches prioritize the explicit target/action. Later resumes return to the normal snapshot rules.

A background-only OS launch builds no UI.

After process restoration, native clients should restore prior presentation state where supported; core changes still do not force a presentation rebuild.

On foreground → background, flush transient UI work that must become durable, currently including pending scrollover batches and playback checkpoints. This transition does not itself force a sync.

## 5. Mutations and bulk semantics

A mutation is successful for normal offline-first use once it is safely persisted locally.

Bulk UI actions pass the exact article IDs the user acted on. The core does not expand a UI-selected set based on newer database contents. The core deduplicates bulk IDs before processing.

Opening an article always marks it read. Read/unread and starred are explicit reversible domain states.

### Delivery policy

- **Live:** persist locally, then immediately attempt Miniflux delivery.
- **Deferred:** persist locally and deliver on the next normal sync opportunity.

If Live delivery fails transiently, the mutation remains safely pending, delivery temporarily behaves as Deferred, and the UI receives an event.

## 6. Sync

All ordinary triggers use one operation:

`sync(reason)`

Reasons identify the trigger, e.g. Manual, AppStart, Resume, Background, Widget. They must not become hidden behavior switches.

The normal sync order is:

1. send pending mutations;
2. acknowledge successful mutations;
3. fetch remote data;
4. reconcile;
5. run retention cleanup;
6. update sync state and emit events.

A failure that undermines the whole run (connectivity/timeout, transient server failure, auth failure, local persistence/integrity failure) may abort early. Isolated entity/data-processing failures should be contained where safe.

Background sync is independently configurable from Live/Deferred mutation delivery and can be disabled completely. When enabled it is a full normal sync, including pending mutations.

`last_successful_sync_at` is persisted and queryable.

### Rebuild

Local reset recovery is a separate operation:

`rebuild_local_state()`

It is not another `sync(reason)` mode. Rebuild and normal sync should reuse low-level API/persistence primitives where sensible but keep separate orchestration.

## 7. Retry and error model

Errors are classified by retry semantics rather than exposing raw HTTP behavior as product logic.

Automatically retryable/backoff candidates include connectivity failures, timeouts, DNS/connection failures, transient 5xx responses, and 429 (respect `Retry-After` where available).

401/403, invalid configuration/requests, and local persistence/storage failures are not automatic retry loops and must be surfaced structurally to the UI.

404/stale entities and conflicts are reconciled according to domain semantics.

Data-processing failures should be isolated where possible; one bad image or metadata record should not unnecessarily fail an entire sync.

Runtime health may distinguish at least Healthy, ConnectivityDegraded, and ServerDegraded.

Backoff is runtime-only and may use failure count plus `next_retry_at`; it need not survive process restart. Manual sync overrides backoff and forces a new attempt.

## 8. Miniflux account and credentials

One Miniflux account per installation is sufficient.

The native secure store permanently owns the API key/secret. It is injected once into core runtime state during initialization, never persisted in the core database, and never logged.

Non-sensitive connection configuration such as the Miniflux base URL may be persisted by the core.

## 9. Article data and content processing

Persist a flexible Miniflux-aligned article model plus centrally processed content.

Keep:

- original Miniflux HTML content;
- canonical processed Markdown/full content;
- cleaned text-only preview.

The core owns HTML sanitization/normalization, HTML → Markdown conversion, common content fixes, and preview generation. Native clients render the resulting content and own typography/theme/styling.

Content processing should support a processing-version concept so stored articles can be reprocessed after pipeline improvements.

The preview has a fixed core maximum of approximately 1000 characters. Per-feed preview and full-text limits are independent and non-destructive: stored complete content is not truncated merely because the UI requests a shorter representation.

## 10. Retention and local article set

Retention is time-based (intended user choices include 30/60/90/180/365 days) and applies only to **read** articles.

Unread articles are retained regardless of age.

Independent retention protections include:

- starred;
- active download;
- existing download.

Removing one protection does not negate another.

Retention cleanup runs only during a normal sync. A very old unread article may therefore remain locally until a later sync after it is marked read.

Initial/rebuilt local state includes at least:

- all unread articles;
- read articles inside retention;
- all starred articles;
- articles required by active/existing downloads.

## 11. Search

Search initially remains Miniflux online full-text search without additional Flux filtering or local FTS.

Remote search results may be displayed without automatic persistence. A remote result becomes durable local data when the user stars it or starts a download.

## 12. Feeds, categories, navigation, and feed preferences

Navigation is category → feed. Categories need ID/name/count. Feeds need ID/category/name/icon/count for normal navigation; URL/error state need not be part of that navigation DTO.

The core owns feed-icon acquisition, cache/processing, and suitable light/dark variants for transparent low-contrast icons. Native UI requests and renders the appropriate variant.

Article image discovery/download/disk cache belongs to the core; native UI triggers lazy loading, decodes/renders images, and may maintain a memory cache. Background sync does not preload article images.

Feed preferences have global defaults plus per-feed overrides. Current intended preferences include independent preview/full-text limits, enclosure-image preference, opening via Miniflux web instead of publisher URL, and text-only behavior.

Feed/category core preferences are device-local and are not automatically synchronized across devices. Device backup and explicit config export/import are separate mechanisms.

Flux may add user-defined feeds. The native UI gathers URL/category/options; the core performs Miniflux communication. Feed discovery is delegated entirely to Miniflux. General feed/category edit/delete remains in the Miniflux web UI for now.

Curated feeds remain a static repository-maintained list and may be extended through repository change requests/PRs.

Miniflux Save/third-party integration is a core-wrapped Miniflux API operation, not a duplicated service implementation.

## 13. Storage and settings

The native platform supplies semantic storage roots to the core, at least:

- persistent data;
- regenerable cache;
- media.

The core does not guess OS sandbox paths and owns organization/lifecycle inside the supplied roots.

Core-domain settings are persisted by the core. Pure presentation preferences remain native. Secrets remain in native secure storage.

Regenerable icons/images are cache. Downloaded media is separate and should normally not be included in device backup; durable metadata remains persistent.

## 14. Config export/import and local reset

Configuration export contains configuration, not article/media/cache data.

The user can export without secrets or include secrets only in a strongly encrypted password-protected export.

A local core-data reset removes synchronized core data and regenerable caches but preserves settings/preferences, native UI preferences, credentials, and downloaded media.

`rebuild_local_state()` then restores the required local article set, including starred articles and article records needed for preserved downloads.

## 15. Media and podcasts

The core persists enclosure/download metadata, durable download state, article↔download association, playback progress, cleanup rules, and downloaded-file metadata analysis.

Actual long-running background file transfer is native so each OS can use its supported background facilities. Native transfer reports completion/result back to the core; the core validates/analyzes the file and emits state changes.

Downloaded files may be inspected for chapters, artwork, and embedded metadata because enclosure metadata can be sparse.

Playback itself is native: audio engine/session, play/pause/seek, Now Playing/lockscreen, CarPlay/Android Auto. The core persists playback progress. Native players write periodic checkpoints (roughly 15–30s) and event checkpoints such as pause/stop/seek/lifecycle transitions.

Downloaded/active media protects the associated article from normal retention.

## 16. Notifications

OS notifications are off by default and can be enabled explicitly per category for background sync.

For each enabled category, a background sync produces at most one notification with the count of articles newly discovered by that sync. Already-notified articles must not be counted again.

The core produces notification candidates; the native client posts the OS notification and acknowledges successful handoff before the core marks it delivered.

The design does not require Firebase/FCM or a custom push service.

## 17. Widgets

Each native widget instance owns its own presentation/configuration state.

Supported data scopes include All, Starred, Category, and Feed. Widget queries support pagination; `limit = 0` allows the complete matching list where the platform can display it.

Widgets call the same standardized core operations and may trigger `sync(reason = Widget)`. If direct mutation/sync execution is unsuitable on a platform, the widget may open the main app with the required intent and let the normal app/core path execute it.

## 18. Opening and sharing articles

When opening a publisher link, native code first tries an appropriate installed app/deep-link association. If unavailable and supported by the platform, a native user preference chooses in-app browser or external/default browser.

Widgets follow the same opening policy.

Sharing is entirely native; the core supplies article data such as title/URL.

## 19. Localization

All user-facing localization is native and managed through Weblate across platforms.

The core emits stable structured error/event codes and English technical diagnostic messages, not localized UI strings.

## 20. Logging and diagnostics

Normal structured logs have limited detail and roughly seven-day retention. An explicit debug mode may collect more detail with a shorter retention of roughly two to three days.

Core and native logs should be combinable for diagnostics/support export.

Secrets (API keys, authorization headers, tokens, passwords, credentials) are never logged. Prefer preventing sensitive fields from reaching logging APIs rather than relying only on redaction.

## 21. Decisions intentionally still open

These should be decided when they materially affect durable implementation, not through broad speculative analysis:

- concrete SQLite schema;
- concrete Rust HTML/Markdown/sanitization libraries;
- exact backoff timings;
- exact encrypted config container/KDF/AEAD choices;
- logging library;
- final DTO/API names;
- detailed media cleanup options;
- exact UI defaults;
- remaining feature-gap details found while implementing against FluxNews/FluxBar reference evidence.

## 22. Working principle

Prefer durable implementation over possibility analysis.

Before commissioning a PoC, compatibility study, or broad audit, identify the concrete decision it will unblock. If no current implementation decision depends on the answer, defer the analysis.
