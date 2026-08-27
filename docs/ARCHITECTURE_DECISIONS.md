# Flux Architecture Decisions

> **Status: ACTIVE / AUTHORITATIVE TARGET ARCHITECTURE**
>
> This document records explicitly agreed decisions for the shared Flux
> architecture. It describes the target state, not necessarily the
> current implementation. Historical roadmaps and compatibility
> contracts do not override it.

## 1. Target

Flux uses one shared Rust core for business/background responsibilities
and native clients for macOS, iOS, and Android.

The former Go core is retired. No new work should preserve Go
compatibility or build transitional Go/Rust parity unless explicitly
requested for historical investigation.

UniFFI is the selected binding technology for Swift and Kotlin/native
clients.

The shared Rust implementation is organized as a workspace under
`core/`, with platform-native clients alongside it (`macos/`, and later
`ios/` and `android/`). The workspace manifest and lockfile belong to
that shared-core workspace rather than the repository root.

## 2. Responsibility boundary

### Rust core

Owns persistence and durable data state, Miniflux API communication,
sync/reconciliation, durable mutations, article/feed/category domain
data, core settings, content processing, cache/media metadata, queries,
and structured change/error events.

### Native clients

Own UI/presentation state and OS integration: navigation, visible list
snapshots, scroll position, gestures, dialogs, layout/theme,
browser/share behavior, secure credential storage, native
scheduling/background transfer, playback engines, widgets, and OS
notification presentation.

Core APIs express domain intent, never UI mechanisms. A swipe, button,
context menu, pull-to-refresh, or scroll gesture is translated by the
native client into a domain operation.

## 3. Queries, snapshots, counts, and events

The UI can query core data at any time. Core changes also emit
structured events, including changes initiated by the UI itself.

Events inform; they do not force presentation refresh. Visible lists and
counts change only when the native UI chooses to query again.

Article queries support at least:

-   scope: all / category / feed
-   read filter
-   starred filter
-   sort: newest first / oldest first
-   pagination (`limit = 0` means all matching items)

Sorting uses publication time only.

Counts are separate point-in-time core queries and respect the same
scope/read/starred filter semantics as article queries, but do not
require sorting or pagination. They can be refreshed independently from
visible article snapshots, for example after Read-on-Scrollover, without
re-querying the visible list.

Visible article snapshots remain stable according to the snapshot rules
below, but selected status surfaces may intentionally show live core
counts. In particular, the macOS menu-bar unread count reflects the
current global core unread count after each successful sync even when
the currently presented article/navigation snapshot has not yet adopted
new data. Snapshot-relative navigation counts may remain stable until
the UI intentionally refreshes them.

List queries should return compact article summaries; full content is
requested separately for article detail.

## 4. Stable visible list snapshots

A background core change must not unexpectedly rebuild a list the user
is currently using.

With Sync-on-Start enabled:

1.  load and display local state immediately;
2.  run sync in parallel;
3.  if the user has not scrolled or otherwise meaningfully interacted
    with the list by sync completion, the native UI may automatically
    refresh the snapshot;
4.  after interaction, keep the snapshot stable and signal new data
    through an event/badge until the UI intentionally refreshes.

Sync-on-Start is optional. When disabled, app start only loads local
state.

Resume follows the same stable-snapshot rule. Data obtained by a
background sync while the app was suspended is signalled, not pushed
into the visible list.

Deep-link/widget/notification launches prioritize the explicit
target/action. Later resumes return to the normal snapshot rules.

A background-only OS launch builds no UI.

After process restoration, native clients should restore prior
presentation state where supported; core changes still do not force a
presentation rebuild.

On foreground → background, flush transient UI work that must become
durable, currently including pending scrollover batches and playback
checkpoints. This transition does not itself force a sync.

## 5. Mutations and bulk semantics

A mutation is successful for normal offline-first use once it is safely
persisted locally.

Bulk UI actions pass the exact article IDs the user acted on. The core
does not expand a UI-selected set based on newer database contents. The
core deduplicates bulk IDs before processing.

Opening an article always marks it read. Opening an article's comments
URL does **not** mark the article read. Read/unread and starred are
explicit reversible domain states.

Scrollover Undo is native presentation state, not a dedicated core
operation. The native client retains only the most recently flushed
Scrollover batch and may undo it by issuing the normal exact-ID bulk
unread mutation for that batch. There is no multi-batch Undo history in
the core.

### Delivery policy

-   **Live:** persist locally, then immediately attempt Miniflux
    delivery.
-   **Deferred:** persist locally and deliver on the next normal sync
    opportunity.

If Live delivery fails transiently, the mutation remains safely pending,
delivery temporarily behaves as Deferred, and the UI receives an event.

## 6. Sync

All ordinary triggers use one operation:

`sync(reason)`

Reasons identify the trigger, e.g. Manual, AppStart, Resume, Background,
Periodic, Widget. They must not become hidden behavior switches. Native
platforms decide when timer/stale refreshes occur; these use `Periodic`
rather than overloading `Background`.

The normal sync order is:

1.  send pending mutations;
2.  acknowledge successful mutations;
3.  fetch remote data;
4.  reconcile;
5.  run retention cleanup;
6.  update sync state and emit events.

A failure that undermines the whole run (connectivity/timeout, transient
server failure, auth failure, local persistence/integrity failure) may
abort early. Isolated entity/data-processing failures should be
contained where safe.

Background sync is independently configurable from Live/Deferred
mutation delivery and can be disabled completely. When enabled it is a
full normal sync, including pending mutations.

`last_successful_sync_at` is one global persisted/queryable timestamp
for the last fully successful sync, independent of `SyncReason`. The
reason belongs in events/logs rather than separate persisted success
timestamps.

Sync completion events contain coarse domain metadata rather than
snapshots or counts. They may include the reason, numbers of new/updated
articles and delivered mutations, `data_changed`, and
`navigation_changed`. Native clients decide which
article/navigation/count queries to refresh.

Sync failure events include compact phase-oriented partial-progress
metadata where useful (for example mutation delivery completed, remote
fetch started/completed, and small processed-item counts). They do not
contain partial snapshots or a complex progress state.

### Rebuild

Local reset recovery is a separate operation:

`rebuild_local_state()`

It is not another `sync(reason)` mode. Rebuild and normal sync should
reuse low-level API/persistence primitives where sensible but keep
separate orchestration.

## 7. Retry and error model

Errors are classified by retry semantics rather than exposing raw HTTP
behavior as product logic.

Automatically retryable/backoff candidates include connectivity
failures, timeouts, DNS/connection failures, transient 5xx responses,
and 429 (respect `Retry-After` where available).

401/403, invalid configuration/requests, and local persistence/storage
failures are not automatic retry loops and must be surfaced structurally
to the UI.

404/stale entities and conflicts are reconciled according to domain
semantics.

Data-processing failures should be isolated where possible; one bad
image or metadata record should not unnecessarily fail an entire sync.

Runtime health distinguishes at least Healthy, ConnectivityDegraded, and
ServerDegraded and is publicly queryable through the core/UniFFI
boundary, including `next_retry_at` where relevant. It is observable
state, not a UI-controlled retry mechanism.

Backoff is runtime-only and may use failure count plus `next_retry_at`;
it need not survive process restart. Manual sync overrides backoff and
forces a new attempt.

## 8. Miniflux account and credentials

One Miniflux account per installation is sufficient.

The native secure store permanently owns the API key/secret. It is
injected once into core runtime state during initialization, never
persisted in the core database, and never logged.

Non-sensitive connection configuration such as the Miniflux base URL may
be persisted by the core.

The configured Miniflux URL represents the installation base, not an API
URL. A legacy final `/v1` path component is normalized away while an
installation subpath is preserved. The Rust Miniflux adapter owns API
version routing (`/v1`), and Core owns Miniflux Web UI route construction;
native shells must not construct Miniflux API or Web routes. Configuration
URLs reject query strings and fragments because they do not identify a
stable installation base. Candidate credentials are validated without
committing account configuration through an authenticated `GET /v1/version`.
Successful validation returns the canonical installation base and the server
version. That version is runtime metadata, not authoritative persisted
configuration. Credential persistence remains a platform concern; macOS
validates a candidate before committing credentials or configuration, and a
failed validation preserves the working account.

Changing the Miniflux base URL creates a new server context.
Server-bound synchronized data and feed/category preferences are not
carried into that new context. Changing only the API key while keeping
the same base URL retains the existing local server context and
feed/category preferences; the long-lived core is recreated with the new
runtime credential.

Miniflux is authoritative for the synchronized feed/category catalog.
When a feed is absent from a complete authoritative remote catalog, Flux
removes the local feed and its articles and feed-bound preferences. Feed
deletion is reconciled before category deletion. If the same feed ID
later reappears, its feed preferences start from their defaults.
Categories absent from the complete remote catalog are removed after
stale feeds; empty categories that still exist remotely remain.

## 9. Article data, previews, and Reader content

Persist a flexible Miniflux-aligned article model. The original Miniflux
HTML content is the durable local source of truth for full article
content.

List presentation uses separately persisted, regenerable derivatives:

-   cleaned text-only `preview_text`;
-   discovered preview `image_url`.

The preview has a fixed Core maximum of **600 characters**. This is a
technical processing limit, not a user setting. Native clients control
only the number of visible preview lines. The agreed choices are **2
(Compact), 3 (Standard), and 5 (Extended)** lines, with **3 lines as the
default**.

### Semantic Reader document

The full Reader does not persist a second Markdown/full-content shadow
representation. When a Reader document is requested, the Rust Core
parses the stored HTML and builds a semantic internal `ArticleDocument`.
That document is then projected according to Reader/feed settings into a
public `ReaderDocument` returned through UniFFI.

The initial semantic model supports at least:

-   Paragraph;
-   Heading;
-   Image, including optional alt text and an optional surrounding link;
-   List, including ordered/unordered and nested content;
-   Quote;
-   CodeBlock;
-   HorizontalRule;
-   ExternalContent fallback.

Textual blocks support inline semantics for plain text, bold, italic,
inline code, and links.

Semantics belong to the Core; typography, spacing, colors, and other
visual styling belong to the native client. Unknown container elements
are processed recursively so useful descendant content survives.
Non-content elements such as scripts, styles, empty wrappers, and
tracking content are discarded.

V1 intentionally does **not** attempt browser-equivalent HTML/CSS
rendering. Complex tables are flattened into readable semantic content
while preserving useful text and links rather than reproducing their
layout. Unsupported embeds may become `ExternalContent` links. Native
tables, embedded WebViews, native video/audio embeds, syntax
highlighting, complex CSS layout, and image lightboxes are not required
for V1.

If relevant content had to be simplified, `ReaderDocument` exposes this
fact (for example `has_simplified_content`). Native clients show only a
decent secondary note such as "Some content was simplified · Open
Original"; ordinary ignored wrappers/styles/tracking must not trigger
that notice.

### Rendered and Text Only

Reader mode is a per-feed Core preference:

-   **Rendered** --- default; preserves supported semantic formatting,
    links, and images for native rendering.
-   **Text Only** --- projects the same parsed document into a
    text-focused representation. Images are omitted; visible link text
    remains. Image alt text is not automatically inserted into the
    reading flow.

Both modes derive from the same semantic parsing pipeline rather than
separate HTML processors.

### Detail truncation

Detail truncation is non-destructive. Complete original HTML remains
stored.

A global Core setting stores the actual character limit. User-facing
choices are **5,000 / 10,000 / 20,000 characters**, with **10,000 as the
default**. The limit applies only to feeds whose per-feed **Truncate
Detail** preference is enabled; there is no separate Unlimited choice
and no free-form numeric input.

Truncation is applied after semantic parsing and the Rendered/Text Only
projection. The limit counts displayed text, not images. Natural block
boundaries are preferred; an unusually large individual block may be cut
at a sensible word/sentence boundary rather than allowing an unbounded
overshoot. Images before the resulting cut remain; content after it does
not.

`ReaderDocument` exposes whether truncation actually occurred (for
example `was_truncated`). Native clients show a subtle end-of-content
note with an Open Original action. If content was both truncated and
simplified, the UI combines those states into one unobtrusive notice
rather than stacking warnings.

### Reader persistence and caching

`ArticleDocument` and `ReaderDocument` are generated on demand from the
stored original HTML and are **not persisted in SQLite**. Parser
improvements therefore apply automatically the next time an existing
article is opened and do not require a Reader-document data migration.

A regenerable in-memory cache may be added later if measurement shows a
need, but persistent Reader-document caching is not part of the data
model.

## 10. Retention and local article set

Retention is time-based (intended user choices include 30/60/90/180/365
days) and applies only to **read** articles.

Unread articles are retained regardless of age.

Independent retention protections include:

-   starred;
-   active download;
-   existing download.

Removing one protection does not negate another.

Retention cleanup runs only during a normal sync. A very old unread
article may therefore remain locally until a later sync after it is
marked read.

Initial/rebuilt local state includes at least:

-   all unread articles;
-   read articles inside retention;
-   all starred articles;
-   articles required by active/existing downloads.

## 11. Search

Search initially remains Miniflux online full-text search without
additional Flux filtering or local FTS.

Remote search results may be displayed without automatic persistence. A
remote result becomes durable local data when the user stars it or
starts a download.

## 12. Feeds, categories, navigation, and feed preferences

Navigation is category → feed. The core maintains/query-exposes the
complete category/feed catalog independently of whether entries
currently have matching articles. Categories need ID/name/count. Feeds
need ID/category/name/icon/count for normal navigation; URL/error state
need not be part of that navigation DTO.

FluxNews supports a presentation option for showing empty
feeds/categories. It defaults to enabled. When disabled, "empty" is
relative to the currently active article filters: a feed/category whose
relevant filtered count is `0` is hidden even if it would contain
articles under another filter. The underlying catalog entry and
preferences remain intact.

The core owns feed-icon acquisition, cache/processing, and suitable
light/dark variants for transparent low-contrast icons. Native UI
requests and renders the appropriate variant.

Adaptive feed icons: If a feed-provided SVG contains author-defined
light/dark appearance variants, Flux should prefer and render those
variants for the corresponding appearance. Automatic contrast correction
is only a fallback when the source icon does not provide a suitable
adaptive appearance. This behavior is automatic and has no user-facing
setting.

Article image discovery/download/disk cache belongs to the core; native
UI triggers lazy loading, decodes/renders images, and may maintain a
memory cache. Background sync does not preload article images.

Feed-domain preferences are represented as one typed per-feed preference
model rather than separate preference tables for every feature. The
current intended `FeedPreferences` include:

-   System Notifications enabled/disabled (default off);
-   Detail Rendering: Rendered / Text Only (default Rendered);
-   Truncate Detail enabled/disabled (default off);
-   Open in Miniflux enabled/disabled (default off).

The persistence model should use typed columns/constraints rather than a
generic feed key/value table. Notification delivery/candidate state
remains separate operational state and is not part of `FeedPreferences`.
Public mutation APIs may remain field-specific so updating one control
cannot accidentally overwrite another preference from a stale snapshot.

FeedPreferences are user configuration keyed solely by Miniflux feed ID,
not relationally owned by a locally cached `feeds` row. The
`feed_preferences.feed_id` storage key intentionally has no foreign key or
cascade to `feeds`, so temporary orphan preferences are valid. Normal remote
reconciliation explicitly removes preferences only for feeds confirmed absent
from Miniflux; Rebuild Local State will preserve them, while account/server
replacement and Full Reset will remove them. There is no feed URL or title
matching. This schema ownership correction is required by the agreed Rebuild
semantics.

Feed/category core preferences are device-local and are not
automatically synchronized across devices. Device backup and explicit
config export/import are separate mechanisms.

Flux may add user-defined feeds. The native UI gathers
URL/category/options; the core performs Miniflux communication. Feed
discovery is delegated entirely to Miniflux. General feed/category
edit/delete remains in the Miniflux web UI for now.

Curated feeds remain a static repository-maintained list and may be
extended through repository change requests/PRs.

Miniflux Save/third-party integration is a core-wrapped Miniflux API
operation, not a duplicated service implementation.

## 13. Storage and settings

The native platform supplies semantic storage roots to the core, at
least:

-   persistent data;
-   regenerable cache;
-   media.

The core does not guess OS sandbox paths and owns organization/lifecycle
inside the supplied roots.

Core-domain settings are persisted by the core. Pure presentation
preferences remain native. Secrets remain in native secure storage.
Technical ownership must not dictate the eventual Settings UI grouping;
native Settings screens should group options by user-facing concepts
rather than by Core/Native/Secure-Store implementation boundaries.

The shared Core settings foundation contains:

-   read-article retention with intended choices 30/60/90/180/365 days;
-   mutation delivery mode: Live / Deferred;
-   background sync enabled / disabled;
-   global Reader detail character limit: 5,000 / 10,000 / 20,000,
    default 10,000.

Additional domain settings are added only with the feature that needs
them rather than being modeled speculatively. Later examples include
notification configuration, media rules, and feed-specific domain
preferences.

Native presentation/OS preferences remain platform-local. Current
examples include Sync on Start, Mark as Read on Scrollover, global
shortcut, Launch at Login, startup destination, presentation filters,
hiding empty navigation entries, removing read items from the visible
snapshot, Preview Lines, and Click on News.

On macOS, Preview Lines offers 2 (Compact), 3 (Standard), and 5
(Extended), default 3. `Click on News` offers **Open Link** (default) or
**Open Detail View**. Mobile may later define additional native
interaction modes without changing the Core contract.

On macOS, Feed Settings are reached from a context menu on an individual
feed. `Preview Lines` is presentation state only and does not affect
Reader content processing. Per-feed `Open in Miniflux` changes the normal
Open destination between the publisher URL and the Miniflux entry URL;
explicit Open Original and Open in Miniflux actions remain available.

Appearance follows the native platform without a Flux Light/Dark/System
setting; iOS Liquid Glass behavior is likewise platform-owned without a
Flux setting.

Feed icons are always shown where the product design calls for them.
Automatic icon contrast handling is implementation behavior, not a user
preference, and there is no per-feed icon-contrast override.

The following FluxNews legacy concepts are intentionally not carried
into the shared Flux settings model: fixed stored-article/starred
limits, configurable sync/search result-count limits, legacy read-sync
day windows superseded by retention, preview character-truncation
controls, legacy HTML/truncation workarounds, and
Flutter/mobile-specific AppBar/FAB/Glass interaction settings.
Tap/long-press/swipe customization is not part of the current shared
settings target and may only be reconsidered later as platform-native
presentation behavior.

Secrets and potentially secret-bearing configuration never enter
ordinary core settings persistence. The Miniflux API key and custom HTTP
headers are stored in the native secure store (Keychain/Keystore or
platform equivalent), injected into runtime behavior as needed, and
never logged.

Regenerable icons/images are cache. Downloaded media is separate and
should normally not be included in device backup; durable metadata
remains persistent.

## 14. Config export/import and local reset

Flux Config Backup is a versioned, platform-specific configuration backup,
not a cross-platform interchange format. Its format version is independent
of the SQLite schema, application version, and Miniflux version. A backup
contains complete configurable state for its originating platform, including
the canonical Miniflux installation base, credentials, CoreSettings,
FeedPreferences, and a versioned native-platform settings payload.

Backups are always password-encrypted; Flux neither stores nor recovers the
password. V1 derives an encryption key with Argon2id (64 MiB, three passes,
one lane) and uses AES-256-GCM authenticated encryption. Only the format,
platform, and crypto/KDF metadata remain cleartext; credentials and all
settings remain encrypted.

FeedPreferences use Miniflux feed ID only. There is no URL/title matching.
Imports intentionally accept orphan feed IDs without server lookup; normal
later reconciliation removes preferences for feeds absent from the
authoritative catalog. Synchronized articles, cache/media, pending mutations,
notification/runtime state, and presentation state are excluded.

Backup parsing validates and returns a restore model without mutating core or
native state. A later native restore phase validates candidate Miniflux
credentials and performs the transactional replacement. Native settings remain
owned by their platform even while carried in that platform's backup.

`rebuild_local_state()` destructively clears synchronized local state,
pending mutations, notification bookkeeping, sync metadata, and regenerable
Core caches, then immediately performs a fresh Miniflux sync. It preserves
the canonical account association, CoreSettings, FeedPreferences, native
settings, and platform credentials. If that immediate sync fails, the old
local dataset is not restored. Schema-v7 orphan preferences make this
preservation possible; normal authoritative reconciliation removes preferences
for feed IDs absent from the returned catalog.
Cache cleanup is best-effort after the authoritative database clear: a cleanup
failure is diagnostic only and never restores discarded synchronized state.

`reset_core_state()` restores all Core-owned persisted state to fresh-install
semantics: synchronized data, CoreSettings customizations, FeedPreferences,
base-url association, sync metadata, and regenerable caches are removed or
reset. It does not contact Miniflux and does not manipulate Keychain,
UserDefaults, or native OS registrations. The media root is currently
unaffected because durable download/media state is not implemented yet.

Account/server replacement, Rebuild, and Full Reset intentionally have
different FeedPreferences policies: account replacement and Full Reset remove
them; Rebuild preserves them. Backup Import remains a separate future
transactional configuration-replace operation.

## 15. Media and podcasts

The core persists enclosure/download metadata, durable download state,
article↔download association, playback progress, cleanup rules, and
downloaded-file metadata analysis.

Actual long-running background file transfer is native so each OS can
use its supported background facilities. Native transfer reports
completion/result back to the core; the core validates/analyzes the file
and emits state changes.

Downloaded files may be inspected for chapters, artwork, and embedded
metadata because enclosure metadata can be sparse.

Playback itself is native: audio engine/session, play/pause/seek, Now
Playing/lockscreen, CarPlay/Android Auto. The core persists playback
progress. Native players write periodic checkpoints (roughly 15--30s)
and event checkpoints such as pause/stop/seek/lifecycle transitions.

Downloaded/active media protects the associated article from normal
retention.

## 16. Notifications

Flux distinguishes **System Notifications** from **In-App New Data**.
They have different lifecycles and acknowledgement semantics and must
not clear each other implicitly.

### System Notifications

System Notifications are OS-facing notifications and are off by default.
They are configurable **per feed**, not per category, under the native
Settings area "System Notifications".

For each enabled feed, an eligible background/automatic sync produces at
most one aggregated System Notification for that feed when the sync has
discovered articles that have not previously been successfully handed
off as System Notifications. Flux does not create one OS notification
per article.

The core durably tracks which discovered articles have already been
system-notified so later sync runs do not notify them again. If a later
sync discovers additional not-yet-notified articles for the same feed, a
new aggregated notification may be produced for that new set.

The core produces typed System Notification candidates. The native
client performs the actual OS notification handoff and acknowledges the
candidate only after successful handoff. System-notification delivery
state is therefore independent from whether the corresponding articles
have been adopted into an in-app visible snapshot.

The design does not require Firebase/FCM or a custom push service.

### In-App New Data

In-App New Data represents articles discovered by background/automatic
sync while the current UI snapshot is intentionally kept stable. It is
not controlled by the System Notifications feed settings and does not
require OS notification permission.

The UI tracks pending newly discovered article counts per feed relative
to the currently adopted presentation snapshots. These counts accumulate
across multiple background syncs until the relevant new data is adopted.
For example, if one sync adds three articles to a feed and a later sync
adds two more before the UI refreshes that scope, the feed's pending
New-Data badge shows five.

On macOS, affected feeds use the platform-native navigation badge to
show the pending New-Data count. The badge should use native system
styling; Flux does not require a custom badge color.

The macOS menu-bar item exposes two distinct signals:

-   the existing numeric title shows the **current global unread count
    from the core** and is refreshed after every successful sync, even
    when the visible article snapshot remains unchanged;
-   a small notification dot on the FluxNews status-item icon indicates
    that at least one feed still has pending In-App New Data that has
    not yet been adopted into the relevant UI snapshot.

The dot is an aggregate signal only; the per-feed native badges provide
the detailed counts. The dot remains visible across multiple background
syncs and disappears only when no pending per-feed In-App New Data
remains.

In-App New Data is acknowledged by **snapshot adoption**, not merely by
opening the sidebar or selecting a navigation entry. When a newly
queried snapshot is intentionally or policy-permittedly adopted,
acknowledgement follows that snapshot's scope:

-   adopting **All News** clears all pending per-feed In-App New Data;
-   adopting a **Category** clears pending In-App New Data for feeds in
    that category;
-   adopting a **Feed** clears pending In-App New Data only for that
    feed.

The same rule applies when the existing New Data/Refresh action adopts a
new snapshot. A feed does not need to be individually opened if a
broader adopted snapshot already includes its new articles.

System Notification acknowledgement and In-App New Data acknowledgement
are separate. Successfully handing an OS notification to the system does
not clear an in-app badge or menu-bar dot, and adopting a UI snapshot
does not mark an article as system-notified.

## 17. Widgets

Each native widget instance owns its own presentation/configuration
state.

Supported data scopes include All, Starred, Category, and Feed. Widget
queries support pagination; `limit = 0` allows the complete matching
list where the platform can display it.

Widgets call the same standardized core operations and may trigger
`sync(reason = Widget)`. If direct mutation/sync execution is unsuitable
on a platform, the widget may open the main app with the required intent
and let the normal app/core path execute it.

## 18. Opening, Reader navigation, and sharing articles

The normal **Open** action is distinct from the Flux Reader.

By default, Open targets the publisher/original article URL. A per-feed
**Open in Miniflux** preference replaces that normal Open destination
with the corresponding Miniflux web entry for that feed. It changes only
the Open action; it does not disable the Flux Reader. Native code
performs the actual URL/deep-link/browser opening.

Native clients may expose explicit **Open Original** and **Open in
Miniflux** actions independently of the configured normal Open
destination. Open in Miniflux may be placed less prominently, such as in
an overflow/submenu.

### macOS Detail Preview navigation

macOS has one reusable native Detail Preview Panel. It is an interactive,
resizable Quick Look-style NSPanel used for temporary article inspection,
not a persistent Reader document window. It moves to the active Space when
shown and is not tied to the lifetime of the menu-bar popover.

The native `Click on News` preference determines the normal row-click
behavior:

-   **Open Link** (default) → perform the feed's normal Open action;
-   **Open Detail View** → open the article in the Flux Detail Preview Panel.

macOS does not require the mobile split-click mode where image and text
perform different actions; that remains a possible mobile-specific
interaction decision.

Pressing **Space** for the selected article always opens that article in
the Flux Detail Preview Panel, independent of `Click on News` and
independent of the feed's Open in Miniflux preference. If the panel is
already showing that article, Space hides it; Space on another article
reuses the panel with replacement content. An explicit **Open Detail View**
article action shows or reuses the panel without toggling it.

Only one Detail Preview Panel exists. If it is already open, opening
another article replaces its current article and brings the existing panel
forward rather than creating another preview.

Opening an article in the Detail Preview marks it read. The preview uses the
feed's Rendered/Text Only and Truncate Detail preferences. It does not
provide an image lightbox/zoom feature; users can open the original site
when they need the publisher's full media experience.

The Reader and menu-bar UI use the same Core article state and mutation
operations; the Reader does not own a second read/star state. Background
sync must not replace the article currently shown in the Reader.

When opening a publisher link, native code first tries an appropriate
installed app/deep-link association. If unavailable and supported by the
platform, a native user preference chooses in-app browser or
external/default browser. Widgets follow the same opening policy.

App Intents, Spotlight, and equivalent OS integrations are native
responsibilities. The core exposes stable feed/category IDs, titles, and
relationships through the navigation catalog; native clients project
those domain records into platform-specific entities/indexes.

An optional `comments_url` is part of the public article data contract.
Native clients offer an Open Comments action only when it is present and
perform the actual browser/deep-link opening. Opening comments does not
mark the article read.

Sharing is entirely native; the core supplies article data such as
title/URL.

## 19. Localization

All user-facing localization is native and managed through Weblate
across platforms.

The core emits stable structured error/event codes and English technical
diagnostic messages, not localized UI strings.

## 20. Logging and diagnostics

Normal structured logs have limited detail and roughly seven-day
retention. An explicit debug mode may collect more detail with a shorter
retention of roughly two to three days.

Core and native logs should be combinable for diagnostics/support
export.

Secrets (API keys, authorization headers, tokens, passwords,
credentials) are never logged. Prefer preventing sensitive fields from
reaching logging APIs rather than relying only on redaction.

## 21. Decisions intentionally still open

These should be decided when they materially affect durable
implementation, not through broad speculative analysis:

-   concrete SQLite schema;
-   concrete Rust HTML parsing/sanitization libraries used to build the
    semantic Reader document;
-   exact backoff timings;
-   logging library;
-   final DTO/API names;
-   detailed media cleanup options;
-   exact System Notification wording/content;
-   exact action/deep-link destination when the user activates a System
    Notification;
-   remaining feature-gap details found while implementing against
    FluxNews/FluxBar reference evidence.

## 22. Working principle

Prefer durable implementation over possibility analysis.

Before commissioning a PoC, compatibility study, or broad audit,
identify the concrete decision it will unblock. If no current
implementation decision depends on the answer, defer the analysis.
