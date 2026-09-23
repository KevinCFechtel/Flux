# Phase D — Native iOS/iPadOS

> **Status: D1-D4 BASELINE COMPLETE / UIKIT TIMELINE U1-U5 COMPLETE / TIMELINE ARCHITECTURE FROZEN / AUTHORITATIVE PHASE-D CONTRACT**
>
> Phase A, Phase B, and Phase C are complete and architecture-frozen. Phase D
> replaces the existing Flutter iOS/iPadOS client with a native Swift client:
> a SwiftUI shell and a UIKit Article Timeline over the existing Rust Core and
> UniFFI boundary. The current native macOS implementation is the primary native
> reference. Flutter is only a
> behavioral reference for mobile-only capabilities and the legacy migration
> source; it is not a parity checklist and intentionally removed behavior must
> not be reintroduced without a product decision.
>
> On 2026-09-11, the owner approved replacing the Article Timeline with an owned
> UIKit Timeline and native UIKit cells. The implementation initially used a
> `UICollectionView` baseline and later evolved to the current `UITableView`
> implementation during performance work. The current table-based Timeline is
> the accepted productive UI/UX baseline. U3 performance/correctness and U4
> mutation-worker semantics are complete and accepted. U5 behavior-preserving
> cleanup and final acceptance are also complete. The current UIKit Timeline
> container/rendering architecture is frozen. Fundamental container, layout,
> image-pipeline, Scrollover, or scheduling redesign now requires new reproducible
> device evidence of a concrete regression rather than speculative performance
> work. See [implementation handoff](IOS_UIKIT_TIMELINE_IMPLEMENTATION.md).

## 1. Goal and non-goals

Native FluxNews iOS/iPadOS minimum deployment target: 17.0.

Phase D delivers a first-class native iPhone/iPadOS FluxNews client without
creating a second domain layer in Swift.

The Rust Core remains authoritative for domain models, Miniflux networking,
SQLite persistence, sync/reconciliation, offline mutations, article/Reader
processing, search, notification candidates, widget projection, media domain,
playback progress, download intent/state, policies and retention.

The native Apple client owns SwiftUI/UIKit presentation, navigation, gestures,
visible snapshots, platform settings, Keychain access, browser/share behavior,
BGTaskScheduler execution, URLSession transfers, WidgetKit presentation,
UNUserNotificationCenter delivery, AVPlayer/AVAudioSession execution, Now
Playing/remote commands, CarPlay and ActivityKit.

Phase D does not rewrite existing Core functionality in Swift and does not make
Flutter storage or schemas permanent compatibility APIs.

## 2. Apple repository and sharing strategy

Target layout:

```text
core/
apple/
  shared/
    FluxApple/
  macos/
  ios/
docs/
```

Moving the current `macos/` tree under `apple/macos/` is a mechanical setup
step. macOS behavior must remain unchanged.

`apple/shared/FluxApple/` contains only genuinely reusable Apple integration and
presentation semantics. It must not become a second business/domain layer or a
durable state owner. Shared code is extracted on first real reuse rather than
through a speculative up-front refactor.

Strong reuse candidates already proven by the macOS implementation include
Browser presentation policies, Scrollover state/snapshot policy, Reader routing
semantics, widget snapshot/routing models, playback presentation/orchestration,
Now Playing/remote-command semantics and transfer reconciliation. Platform UI,
window geometry, lifecycle owners, AVAudioSession behavior and concrete transfer
executors remain platform-specific where appropriate.

## 3. Development, migration and release identities

Phase D uses two iOS identities during development:

- **Native Development:** a separate development Bundle ID and separate sandbox,
  allowing the native app and existing Flutter production app to be installed
  side by side on the same device.
- **Production/Upgrade Test:** the existing FluxNews production Bundle ID and
  entitlements, used to exercise the real Flutter-to-native update path.

The production Bundle ID and existing App Store product identity are retained
for the final native replacement. The exact development Bundle ID is an
implementation/configuration choice and must not leak into production data.

Upgrade feasibility is verified in D1 before deep product implementation:
existing production identity, App Group, Keychain access and required legacy
storage must be reachable by a native production-identity test build.

## 4. Legacy migration safety contract

Migration is **copy/import-only**.

The native app may read legacy Flutter data required for migration, but it must
not convert legacy storage in place, use the Flutter database as its operational
Core database, or aggressively delete legacy data. Imported state is written to
new native/Core-owned storage.

Migration must be idempotent and restart-safe. Existing valid native/Core state
wins over legacy state. A migration marker may record completed import work, but
must not make an interrupted migration unrecoverable.

Migrate when semantically compatible and not reconstructable from Miniflux:

- account association and credentials;
- custom HTTP headers;
- compatible native/Core settings;
- compatible feed preferences;
- podcast/download settings that still exist;
- playback progress;
- existing downloaded media with correct enclosure association.

Do not migrate the Flutter article/feed/category cache, widget cache/snapshots,
temporary UI/runtime state, the old explicit Light/Dark choice, or obsolete
Flutter-only preferences. Synchronized read/unread/starred state is rebuilt via
Miniflux/Core rather than copied from Flutter SQLite.

The current Core `FeedPreferences` model is authoritative. Legacy Flutter fields
without a current semantic equivalent do not justify a compatibility layer.

## 5. Adaptive iOS/iPadOS product architecture

Flux is one adaptive iOS/iPadOS application, not separate iPhone and iPad
applications. Available presentation environment and platform capability are
authoritative for layout; device name is not.

### Compact presentation

In compact presentation, the app starts directly in the Article List.
Navigation is transient and opens as a native sheet containing All News,
Starred, Listening List, Categories and Feeds. Selecting a scope closes the
sheet and updates the list.

### Regular presentation

In regular presentation, navigation and the Article List may coexist in a
two-column `NavigationSplitView`:

```text
Navigation | Article List
```

There is no permanent third article/detail column. The existing article-first
behavior remains: a normal article tap tries the configured installed-app deep
link and falls back to the in-app browser. The internal Reader is an explicitly
configured exception and is temporary presentation: an inspector in regular
presentation and a sheet/full-screen presentation in compact presentation.

Presentation may change at runtime as available environment changes. This does
not create a second app hierarchy or replace BrowserScope, article snapshots,
filters, Core session, read/starred state, or Search domain state. iPhone,
iPhone Duo, iPad, and future form factors fall out of this compact/regular model
without dedicated UI implementations.

The adaptive app shell keeps one persistent split/detail hierarchy across these
transitions. Its detail Timeline remains in place while only column visibility
and transient navigation presentation normalize. Entering regular presentation
dismisses transient navigation; Search and Reader retain their request state and
move to the appropriate native presentation without another Core request.

### Scene ownership

The first native iOS/iPadOS release intentionally supports one app scene. The
app-level `CoreBootstrapper` and `NewsreaderStore` own the account/Core session,
Core event subscription, Sync state, and serialized Scrollover mutation worker.
The scene owns its presentation state and Search request state; Timeline
controllers remain view-local. Article-image caching and HTTP loading are
process-global native presentation infrastructure.

Multi-scene support is deferred. It requires an app/account service that owns
the shared Core session, subscriptions, synchronization, mutation coordination,
and future media playback independently of per-scene presentation stores. Do not
enable additional scenes until that boundary exists; a second scene must not
create another Core against the same storage paths or share another scene's
presentation state.

### iOS/iPadOS Article Timeline — UIKit

The target Article Timeline is an owned UIKit view controller containing a
plain `UITableView`, embedded through a narrow bridge in the SwiftUI app shell.
Use stable Article IDs, a diffable table data source, deterministic prepared row
heights, and native reusable UIKit article cells. Compact and visual modes, portrait/landscape image slots,
preview-line choices, Dynamic Type, VoiceOver, and adaptive compact/regular
presentation remain supported. Cell structure and content sizing are reused
when their layout inputs have not changed.

The Timeline must not use SwiftUI `List`, `ScrollView`/`LazyVStack`, or hosted
SwiftUI article cells as its production renderer. Navigation, Settings, Reader,
Search, sheets, and other surfaces may continue using SwiftUI. Use public UIKit
APIs; do not take over the internal delegate of a SwiftUI control through
introspection. Retire the old Timeline path after the replacement is integrated.

Available table-container geometry is the Timeline layout authority; device
identity, screen dimensions, and orientation names are not inputs. A canonical
pixel geometry generation includes the effective table width and the
environment values that affect deterministic item layout. Geometry changes make
visible cells correct immediately and establish a fresh Scrollover baseline, but
coalesce only speculative prepared-layout work for the latest generation. Older
generation results cannot be consumed as current layout. Relayout alone is never
user scrolling and must not mark an article read. Image prefetch retains its
existing canonical target-size bucket across a resize when possible, without
changing visible-first or bounded scheduling behavior.

Timeline actions use system-native swipe actions: leading Read/Unread and
trailing Star/Unstar invoke the existing optimistic mutations and allow the
platform's standard full-swipe behavior. Preserve context menus, pull-to-refresh,
article routing, the accepted native scope-capsule navigation chrome, semantic
scope resets, and persistent split navigation. Actions identify articles by stable ID, never a captured
index path or a cell reference that may have been reused.

Mark-as-Read-on-Scrollover uses actual UIKit scroll movement and resolved cell
frames in one coordinate system, including effective viewport insets and
occlusion. A non-observable detector consumes a coherent layout/movement sample
from the controller. It emits an ID only when an observed visible unread row
becomes completely above the effective upper boundary during a user-originated
forward interaction or deceleration. Preparation/prefetch, `willDisplay`, or
`didEndDisplaying` alone does not prove a valid crossing. Unseen rows skipped by
a fast movement must not be manufactured as read candidates.

Candidate processing is bounded by currently/recently visible rows, not the
complete snapshot or accumulated history. Preserve enough prior resolved
geometry to recognize a just-exited row after reuse. Direction reversals must
not lose qualified crossings through stale callback order; small movements
must accumulate rather than disappear under a per-sample tolerance. No exposure
timers, fixed delays, or SwiftUI row/scroll callback ordering may determine a
read crossing.

Snapshot, layout, size, inset, and reset changes establish a fresh geometric
baseline without emitting reads. Keep actual interaction/deceleration state
separate from baseline validity so a layout change cannot silently disable the
rest of an ongoing gesture. Programmatic movement and scroll-anchor correction
do not qualify reads. A genuine forward arrival at the content bottom may
complete observed visible trailing rows that cannot cross the upper boundary.
This completion belongs only to that arrival and valid layout; leaving the
bottom, reversing direction, ending the interaction, or changing the baseline
disarms it. Initial short lists and initial/reset/backward arrivals do not
complete rows. The layout and viewport used to decide bottom arrival must be
consistent with those used to identify the trailing visible rows.

Remove When Read applies to explicit/manual read actions, including swipe and
context-menu actions. It does not apply to Mark-as-Read-on-Scrollover:
Scrollover updates read state without changing visible article list membership,
including after scrolling becomes idle. The unread/read visual transition keeps
the unread-indicator layout slot present and changes only its visual opacity, so
it does not alter article-card geometry.

iOS Scrollover keeps sensing, detection, cell status, Core scheduling, and Undo
separate. Accept an ID into a deduplicated native intent buffer with a local
status overlay; rendering must not wait for Core. A fully exited row requires
no visible update. A visible/reappearing cell obtains the latest status by ID
and updates only its status, accessibility, and interaction state. Status-only
read/starred changes must not apply a full diffable snapshot, reload the Timeline,
reconfigure all cell content, invalidate text/image layout, or change row height.
An explicit manual action that removes an article under the existing rules is
a separate structural update; it must not turn ordinary Scrollover into removal.

One serialized mutation worker belongs to the account/Core session rather than
the Timeline view or its presentation snapshot. Reuse the current Core bulk
operation, with an actual maximum of 64 IDs per call, deduplication, ordered
continuation, and a bounded maximum wait before attempting to drain a small
buffer. Idle and lifecycle transitions request additional flushes; continuous
scrolling alone must not defer local persistence indefinitely. Batching time
controls persistence scheduling, never exposure qualification. Blocking UniFFI
calls execute off-main without synchronously waiting on the UI thread.

Capture origin presentation generation and per-article read-intent ordering at
enqueue time, and preserve them when splitting/coalescing batches. A scope,
filter, snapshot, or view change preserves accepted writes but invalidates old
presentation feedback. Newer explicit Read/Unread/Undo actions must win over
older automatic writes and completions. An account/session boundary must never
send old IDs to a new Core; session shutdown and foreground-to-background
handling must explicitly account for pending local persistence. Starting a Task
is not proof of a durable flush, and an uncommitted write cannot be guaranteed
after abrupt process termination. Rust remains the only durable state owner.
Explicit Unread/Undo re-arms the affected article for a new genuine qualified
crossing; a status callback or rebaseline alone must not immediately read it again.

Counts and Undo publish independently of structural list snapshots and avoid
scroll-frequency work. Ignored Core events must be filtered before creating
main-thread tasks. Feed icons and article images arrive as prepared images;
decoding, network access, and synchronous Core queries are not cell/scroll work.
All detected Scrollover candidates are still marked read, independently of Undo.
Search results use the same UIKit Article Timeline renderer and presentation
settings as the normal Article List, with Search-specific pagination and
Scrollover disabled.
Normal continuous scrolling and small forward jumps do not present Undo. Undo is
an exceptional recovery mechanism: it activates only after at least 3 successful
unread-to-read Scrollover mutations in a rolling one-second window. Visibility
candidates, already-read rows, rejected candidates, failed mutations, and the
former skipped-index qualification do not count. When the third success arrives,
the qualifying burst is retained together for Undo; later successes follow the
existing rolling group. A success extends its 4-second inactivity window without
extending the 15-second maximum group lifetime. Backward movement, initial baseline
establishment, and structural rebaselining emit neither reads nor Undo. macOS
retains its existing platform-specific frame integration.

Visual article images are native iOS presentation infrastructure, not Core or
sync state. They use display-sized ImageIO downsampling, normal HTTP response
caching, and bounded in-memory caching of decoded images. Loading, failure, and
success presentation remain inside the existing fixed portrait or landscape
image slots and must not change article-card geometry. Recreating an article
image view reuses an already-decoded memory-cache image synchronously so
snapshot refreshes do not regress to a placeholder frame.
Reuse this pipeline from UIKit with ID/request-safe completion and bounded,
cancellable prefetching. Planning must respond to changes in the relevant
visible/prefetch window or target size, not rescan visited rows on every pixel
of movement. A prefetch cancellation must not cancel an image still required by
a visible cell or another consumer.

This renderer decision is accepted without requiring a preliminary
SwiftUI-versus-UIKit benchmark or optimization of the old renderer. Focused
device profiling is acceptance of the new implementation. The implementation
sequence and regression matrix are in
[IOS_UIKIT_TIMELINE_IMPLEMENTATION.md](IOS_UIKIT_TIMELINE_IMPLEMENTATION.md).

#### Current UIKit Timeline amendment status — 22 September 2026

U1-U4 are complete. U3 is real-device accepted on iOS 27 with the normal
full-width Visual presentation, stable rotation/chrome/status-bar behavior, and
the single ImageIO -> UIImageView/Core Animation article-image path. The legacy
exact-slot renderer and its diagnostic switches are removed. The canonical
post-retirement XCTest run executed 348 tests with 0 failures.

U4 session-owned mutation-worker semantics remain complete: one active
Core/account-session writer, 64-ID FIFO batches, a 500 ms bounded drain deadline,
explicit-intent precedence, lifecycle coalescing, session-isolated completion,
and deterministic failure recovery.

U5 behavior-preserving cleanup and final acceptance are complete. The
historical SwiftUI/List Scrollover controller and its helper geometry have been
removed; still-relevant regression cases exercise the productive
`IOSUIKitScrolloverGeometryTracker`; productive Scrollover geometry is isolated
in its focused source file; and the UIKit cell consumes prepared
`IOSUIKitArticleLayoutMetrics` directly rather than a redundant cell metrics
wrapper. Focused native full-swipe and article-cell accessibility oracles are
present. Final validation on 22 September 2026 executed 338 iOS tests with
0 failures, `build-app.sh` succeeded, `git diff --check main...HEAD` was clean,
and the focused physical-device smoke test passed. The UIKit Timeline
architecture is now frozen.

The native manual Sync control keeps the same `arrow.clockwise` symbol and
stable toolbar geometry across idle, syncing, success, and failure states.
iPhone portrait keeps Sync, Filter/Sort, and More in the bottom toolbar.
iPhone landscape moves the same action group to the trailing top toolbar and
uses a compact leading interactive scope capsule that preserves the configured
current-scope article count in compact numeric form (or the existing transient
`Syncing…` substitution).
Persistent iPad split navigation also uses the trailing top toolbar and keeps
the detail navigation bar title-free while the sidebar is visible because that
sidebar already communicates the selected scope. If iPadOS temporarily hides the
sidebar, the detail view restores an explicit leading interactive scope capsule
with chevron so navigation does not depend on the edge-swipe gesture. The
leading toolbar slot remains structurally present in both split states; while
the sidebar is visible the capsule is hidden, non-interactive, and excluded
from accessibility instead of being removed, so split-view transitions do not
rebuild navigation chrome or perturb Timeline geometry. Category selection and
category expansion are separate sidebar interactions so a selected category can
still be expanded or collapsed independently;
active manual Sync is indicated by continuous symbol rotation, and successful
manual Sync briefly presents a checkmark before returning to the idle symbol.
Failure returns directly to the idle symbol. This is native transient
presentation state and does not alter Core Sync semantics; Reduce Motion keeps
the symbol stationary.

Appearance follows the system Light/Dark mode. Primary content surfaces use the
system content background, which is true black in Dark Mode. There is no manual
Light/Dark override, True Black setting, persisted theme preference, or separate
theme framework.

## 6. Search, Reader and article actions

Search remains the existing Miniflux online search through
`core.searchArticles`. iOS/iPadOS provides a dedicated native Search screen with
explicit submit, remote results and pagination. Phase D does not replace this
with local scope filtering or local full-text search.

Reader semantics come from `ReaderDocument`. Shared Reader presentation/routing
semantics may live in FluxApple, while actual SwiftUI presentation remains
platform-specific.

Existing article actions are preserved where supported by current Core/native
semantics: open original, open in Miniflux, comments, copy link, native Share
Sheet and save to configured Miniflux third-party service.

## 7. Background sync, notifications and widgets

Regular news background refresh uses `BGAppRefreshTask` to initialize/use Core
and call `sync(.background)`. `BGProcessingTask` is reserved for work that
actually requires the longer-processing mechanism; it is not the default news
refresh mechanism. iOS scheduling remains system-controlled and force-quit
limitations are accepted platform boundaries.

After successful background sync the native layer may refresh the widget
snapshot, request WidgetKit reload, process Core notification candidates and
reconcile native media transfer work. Core-generated download intent must reach
the native transfer executor after sync.

Notifications are local only: Core owns candidate/domain semantics and iOS owns
permission and delivery through `UNUserNotificationCenter`. Phase D adds no APNs
relay or server-side push infrastructure.

Widgets preserve existing FluxNews functionality using native WidgetKit. The
base architecture is:

```text
Core -> App/Background Task -> App Group snapshot -> Widget extension
```

The widget extension does not run an independent full Core/SQLite lifecycle.
No new interactive mark-read or mini-reader widget functionality is required in
Phase D.

## 8. Media, downloads and Apple system integration

Phase D reuses the Phase-B/C media domain and the existing native Apple playback
architecture. Rust remains authoritative for durable media/listening/download
state. Native Apple code owns the running AVPlayer, runtime transfer execution,
AVAudioSession and OS integrations.

iOS uses a true background `URLSession` transfer executor so eligible downloads
can continue under iOS background/process rules. Shared transfer reconciliation
and Core callbacks should be reused where semantics are common; the iOS
background-session lifecycle is iOS-specific.

AVAudioSession integration must cover background audio, interruptions, route
changes, Bluetooth/AirPlay and appropriate resume behavior.

`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` use the same playback state
as the in-app player. CarPlay is another native presentation over this same
playback stack, not a second player or legacy download cache. Required CarPlay
scope includes browsing playable/listening items, selecting an episode,
play/pause, skip forward/back and current playback state.

**CarPlay is release-blocking for the native replacement.**

Live Activities/Dynamic Island are tied to active podcast/audio playback. A
native ActivityKit coordinator consumes the same runtime playback state and
presents title, feed/podcast, artwork, play/pause state, position and duration.
Progress should not require explicit per-second ActivityKit updates. No
ActivityKit push/APNs infrastructure is introduced.

**Live Activities/Dynamic Island are release-blocking for the native
replacement.**

## 9. Phase roadmap

### D1 — Apple Foundation & Replacement Feasibility

- mechanically establish `apple/macos`, `apple/shared/FluxApple` and `apple/ios`;
- keep macOS building and behaving as before;
- package UniFFI/Rust Core for macOS plus iOS device and simulator, preferably
  through a clean XCFramework-style Apple distribution;
- create the minimal common iPhone/iPad app shell and initialize Core;
- establish Core/cache/media paths and Keychain integration boundaries;
- configure separate native-development and production-upgrade identities;
- prove access to the production identity, App Group, Keychain and required
  legacy Flutter storage without mutating it.

D1 is complete when native Flux runs on a real iPhone and iPad/simulator against
Rust Core, the development app can coexist with Flutter, the future production
upgrade path is technically proven, and macOS remains green.

### D2 — Native Newsreader Foundation

Implement compact article-first navigation, regular two-column navigation,
Article List, Row/Card presentation, preview-line choices, Startup Scope, Hide Empty,
Remove When Read, pull-to-refresh, native swipe actions, Scrollover/Undo and
stable snapshot/pending-new-data behavior. Extract proven shared Apple code only
where this creates actual reuse.

The original D2 baseline is complete. The accepted UIKit Timeline amendment in
section 5 replaces its renderer and Scrollover integration and is actively in
progress. A native UIKit Timeline baseline, UIKit Scrollover geometry, targeted
status presentation, deterministic sizing, incremental pagination/update work,
and substantial performance hardening are already implemented. This does **not**
close the amendment or freeze its current internal structure: ongoing
physical-device performance investigation may still change fundamental Timeline
layout, cell, image-presentation, preparation, or scheduling structures. D2
product behavior remains preserved by that work.

### D3 — Article Interaction, Reader & Search

Implement existing open routing, in-app browser, temporary Reader presentation,
article actions/share and the dedicated paginated remote Search screen using the
existing Core API.

### D4 — Settings & Native Presentation Quality

D4 is subdivided into D4.1-D4.5. D4.1 introduces the independent native
account/credential startup lifecycle. D4.2 is the full native Settings redesign,
D4.3 covers presentation quality, D4.4 performs combined real-device D2-D4
validation and polish, and D4.5 adds user-cancellable foreground/manual Sync as
an accepted post-baseline extension.

#### D4.1 — Production-Style Startup & Native Account/Credentials

- start without developer environment credentials;
- store the native account, API key, and custom HTTP headers in the native
  Keychain namespace;
- validate and reconfigure accounts through the existing Core/UniFFI contract;
- keep account-required and recoverable-startup-error states separate from
  Developer Diagnostics;
- support Rebuild Local State and Remove Account with distinct semantics.

Remove Account removes native credentials, account-bound Core state, feed
preferences, and account media while preserving global application/display
preferences. Rebuild Local State preserves the account and preferences while
rebuilding reconstructable synchronized state. There is no general FluxNews
Factory Reset product action.

Flutter credentials, settings, SQLite state, downloads, and playback are not
read, imported, rewritten, or deleted by D4.1. Flutter-to-native migration
remains entirely in D9.

#### D4.2 — Native Settings

Implement a conventional native Settings hierarchy with Settings entries for
Account, Articles, Navigation, and Developer Diagnostics. D4.2 exposes only
currently functional native/Core settings and reuses the frozen D4.1 account
lifecycle. Transient article-list filters such as Unread Only and Newest First
remain list controls rather than persistent Settings.

D4.2 does not add Appearance or True Black settings, future media/notification/
background/widget settings, or a factory reset action. Those concerns remain in
D4.3 or their later feature phases.

#### D4.3 — Native Presentation Quality

Complete native presentation quality work across system-controlled appearance,
flat content surfaces, Dynamic Type, VoiceOver, context-menu presentation,
semantic sensory feedback, and iPad input behavior. FluxNews has no Appearance
screen or True Black setting. Dark Mode content surfaces are true black by
design; Light Mode may retain subtle native background differentiation for
structured UI, while sheets, menus, popovers, and controls retain system
elevation.

The Newsreader navigation scope title is stable and never embeds the live
article count into the title string itself. The accepted native chrome is the
scope capsule implemented by `ArticleListTitleCapsule`: iPhone portrait uses a
stacked capsule in the principal toolbar position with the optional descriptive
current-scope count; iPhone landscape uses a compact two-line leading capsule
with the scope title above the compact count. Its compact-height typography and
zero extra vertical padding fit the landscape navigation bar without allowing
SwiftUI to vertically compress the text away. The leading item reserves a modest
minimum text width and prefers the complete one-line scope title whenever the
available toolbar space permits it; only unusually long titles yield and truncate
before displacing the trailing action group. The landscape capsule reserves the
alternate second-line width so transitions between the count and `Syncing…` do
not make the chrome breathe horizontally, while remaining substantially narrower
than the former one-line title-plus-count presentation. Persistent iPad split
navigation keeps the inline leading capsule: it is hidden while the sidebar is
visible but retains its toolbar slot; when the sidebar collapses, that capsule
becomes visible and interactive. On iOS/iPadOS 17-25, every article-list action group that lives in the top
navigation bar is grouped over one native `.regularMaterial` capsule for contrast
against scrolling article text. This covers iPhone landscape as well as iPad
split/collapsed-split chrome. iPhone portrait remains on the native bottom bar
without an extra app-owned capsule. iOS 26+ keeps the system Liquid Glass toolbar
treatment without an additional app-owned material layer. During Sync the capsule's count presentation
temporarily shows `Syncing…`. The capsule is the
authoritative visible title/header presentation and carries the accessibility
header role; do not reintroduce a separate Large-Title or native-subtitle product
presentation over it.

Navigation metadata and navigation counts are consumed as one shared Rust Core
projection. Swift selects unread-only or all-entry navigation semantics but
does not derive or incrementally cache category/feed counts; the selected
Timeline/query `selectionTotal` remains separate. Scrollover keeps its existing
idle-refresh policy and may defer consuming a fresh projection until idle, but
never derives optimistic navigation counts.

The local UIKit Timeline uses bounded Core keyset pages, ordered by
`(published_at, article_id)`, rather than reading an unbounded selected
dataset. A first page obtains the authoritative selection total and replaces the
Timeline; later pages omit that repeated aggregate and append prepared immutable
row content. Targeted structural removals preserve unaffected presentation state
and pagination state. Loaded pages remain retained for the current semantic
query. This is separate from targeted read/starred/Scrollover presentation
updates and from Search's remote pagination. Hard Timeline windowing is deferred
unless future profiling justifies it.

Incremental structural changes are deliberately narrower than a semantic
replacement: page append adds only new Diffable identifiers and prepares only
new immutable layout inputs; targeted removal deletes only affected identifiers
and cancels only their article-image requests. Existing visible cells, valid
prefetch, and prepared layout metrics are retained. Full replacement or a real
geometry change remains responsible for broader cancellation and layout
invalidation. A synchronous prepared-metrics miss is retained in the same
generation-safe cache, so it does not cause a second equivalent asynchronous
measurement. The frame-headroom hardening pass keeps append/removal from
fanning out into unrelated visible-cell configuration, prefetch cancellation,
or broad layout invalidation. Feed-icon PNGs retain their existing prepared-raster path. Article images use
display-sized ImageIO decoding off-main, while UIImageView/Core Animation owns
the final aspect-fill crop and rounded clipping. The former exact-slot article
CGContext renderer, its Developer Diagnostics switch, backdrop/P3 cache state,
and renderer-mode plumbing were retired on 22 September 2026 after device
acceptance showed no product-relevant advantage. The Timeline table surface remains explicitly
opaque over the system background. The existing native cell uses stable
registrations for compact/text-only, portrait, and landscape constraint variants
to avoid ordinary reuse switching between those graphs. The article-image
pipeline prioritizes visible work over prefetch, allows up to two concurrent
fetch operations, serializes the CPU-heavy ImageIO transform stage to avoid
overlapping decode/raster peaks, and keeps a deterministic cost-bounded 128 MiB
LRU of decoded display-sized images for warm/back-scroll reuse. The LRU retains entries
strongly until its byte budget requires least-recently-used eviction, instead of
relying on opportunistic NSCache residency, and releases all retained rasters on
an iOS memory-pressure warning. Scrollover's
per-scroll geometry state uses bounded ordered frame slots, scalar previous
geometry, and a private bounded previous-frame copy. It no longer retains a
sample dictionary that shares the mutable frame-store buffer, avoiding the
per-scroll copy-on-write of resolved frames; stale-ID storage is allocated only
when pruning is actually needed. Archive Release builds enable
whole-module Swift compilation through the archive script only; normal simulator
execution remains Debug and performance diagnostics remain dynamically injected
by the diagnostics build command. Diagnostics builds are instrumented and are
not assumed bit-identical to the shipped archive. U3.7.5 manual cell layout
remains deferred pending device evidence; this pass does not claim a new
physical-device result.

#### Article-image renderer decision — 20 September 2026

A new physical-device A/B comparison was run after the presentation scheduler,
offscreen-image-prefetch removal, obsolete-work cancellation, and serialized
image-transform changes. On the iPhone 15, both paths still showed very rare
residual hitches, but the ImageIO -> UIImageView/Core Animation path was
subjectively somewhat smoother than the additional exact-slot CGContext
prerasterization path.

Production therefore has one article-image renderer: display-sized ImageIO
decode followed by UIImageView/Core Animation aspect-fill and rounded clipping.
The former exact-slot display-ready path is no longer compiled into the article
image pipeline, and Developer Diagnostics no longer exposes a renderer switch.
Git history preserves the experiment if future OS evidence warrants revisiting
it.

#### Article-image performance diagnostics — historical conclusion

The temporary article-image experiments described during the September 2026
performance investigation are concluded and their source-level diagnostic
switches were removed on 18 September 2026. In particular, neither presenting a
roughly @3x decoded thumbnail without exact-slot prerasterization nor reducing the
exact-slot raster to 2x produced a meaningful physical-device improvement. Those
individual experiments did not identify a root cause; the broader U3
performance/correctness investigation was subsequently closed by the accepted
iOS 27 device baseline and final 22 September validation described below.

The detailed experiment record, cleanup audit, retained production invariants,
and the resulting `Visual compact` product decision live in
[IOS_TIMELINE_PERFORMANCE_DIAGNOSTIC_CLEANUP.md](IOS_TIMELINE_PERFORMANCE_DIAGNOSTIC_CLEANUP.md).

Article-row accessories use one stable semantic order: **Unread → Star → Comments → Audio**, measured outermost-to-innermost for horizontal groups. Optional listening duration belongs to the Audio accessory. The iOS 27 real-device comparison showed that the normal full-width Visual portrait image scrolls smoothly, so the temporary reduced-width image/info-rail experiment and its Developer Diagnostics switch have been removed rather than retained as product architecture. Standard Visual portrait now has one production geometry: **100% content-width 16:9 image → metadata → title → publication row + optional trailing reading time → preview**. Every productive article layout uses the same semantic text order **metadata → title → publication row → preview**, including Compact, image-less Visual, Visual landscape, and all Visual compact variants. The Articles setting may render the publication row either as the absolute localized date/time or as the localized abbreviated relative publication age. Relative age reuses the system `RelativeDateTimeFormatter` with numeric abbreviated units, begins with `clock.arrow.circlepath`, and is frozen against one result-generation reference date: later keyset Timeline pages and later pages of the same Search request reuse their respective reference date, and visible rows never advance from a timer. A structural Timeline replacement establishes a fresh reference date and refreshes the prepared temporal row content even when the underlying article fields are otherwise unchanged. Miniflux `reading_time` remains a persisted Core article field (schema v18) projected through `ArticleSummary`/UniFFI; the iOS Timeline never calculates reading duration itself. All article variants project Miniflux reading time, when available, inline immediately after the publication value, separated by a centered dot and rendered as `doc.text` + duration in that same publication row; both the optional leading relative-time icon and inline reading-time block are horizontal-only additions and must not increase deterministic text-row height. The current Timeline projection already supplies unread/star/comments; Audio must join through a batched article-level Timeline/media projection before its slot becomes productive. Do not introduce visible-cell enclosure lookups or other per-row Core calls to populate Audio or duration.
Do not re-enable removed performance experiments merely because older commits
describe them as a next step. New performance work should start from the current
production architecture and current physical-device evidence.

The agreed Timeline completion sequence is recorded in
[IOS_UIKIT_TIMELINE_IMPLEMENTATION.md](IOS_UIKIT_TIMELINE_IMPLEMENTATION.md#8-agreed-u3u4-stabilization-and-architecture-freeze-plan).
In short: **U3 and U4 are complete.** U3 real-device acceptance on iOS 27
includes smooth scrolling through more than 200 articles with the normal
full-width Visual geometry, accepted rotation/chrome/status-bar behavior, and
the single production article-image path. The legacy article-image renderer and
its diagnostics have been removed. Post-retirement
`./apple/ios/Build/test.sh` validation after renderer retirement on
22 September 2026 executed **348 tests with 0 failures**. U5 then removed
redundant historical Scrollover coverage and completed the freeze suite; its
final canonical run executed **338 tests with 0 failures**, `build-app.sh`
succeeded, `git diff --check main...HEAD` was clean, and focused device
acceptance passed. The historical iOS 26 full-width-image behavior remains an
accepted OS/rendering-sensitive limitation rather than a reason to retain a
second renderer.

On iOS, a semantic scope/filter/sort reset stays within the existing UIKit
Timeline controller: it resets the table view to its natural top position and
rebaselines Scrollover geometry without re-identifying the adaptive detail
subtree. Portrait/landscape chrome changes are presentation-only: the
`ArticleListView`/UIKit Timeline subtree remains structurally stable while only
its toolbar items change, so rotation must preserve the current article/viewport
anchor rather than recreate the Timeline at the top. Device acceptance must verify a populated Timeline before and after each
scope, filter, and sort reset: the Timeline returns to its natural start, the
scope-capsule chrome remains stable, there is no Timeline teardown/flicker, and
subsequent Scrollover remains correct.
Sync activity is communicated by the normal Newsreader UI; an empty scope shows
`News syncing…` while Sync is active and `No News` after it completes, without
an additional custom splash screen.
`No News` is a confirmed-empty state, never an intermediate Sync or local
snapshot-loading transition. Existing article content remains visible during
snapshot refreshes without a generic loading overlay. The stable, count-free
navigation scope title is unchanged; the separately presented current-scope
count can be disabled through the native iOS article presentation settings.

#### D4.4 — Real-Device Validation & Polish

Perform combined real-device D2-D4 validation and polish across representative
compact and regular presentation environments, including runtime resize,
rotation, and multitasking transitions where supported.

Before D4.4 completion, establish consistent native user-facing error
presentation for Sync/network, account/credential, and user-action failures.
Raw Rust/UniFFI/internal errors must not be exposed directly to users.
Loading, empty, syncing, and error states remain semantically distinct.

The D4.4 error-presentation work is complete: native iOS error contexts now map
technical failures to stable safe English messages, while typed account-validation
messages remain preserved. Technical causes are restricted to diagnostics, and
optional feed-icon and article-image failures remain silent. The D4.4 English
user-facing wording freeze is complete.

Localization is the final D4.4 presentation step after user-facing wording and
error messages are stable. The native iOS/iPadOS app provides complete English
and German localization through the native iOS String Catalog at
`apple/ios/FluxNews/Localizable.xcstrings`. Shared terminology aligns with the
native macOS application, including Feed, Category, API-Schlüssel, and the
article/read/starred vocabulary. Release-visible errors, Settings,
Newsreader/navigation, Reader, Search, and accessibility presentation are
localized. User-facing dynamic counts use native localized substitutions and
plural forms rather than concatenated fragments. Developer Diagnostics remains
reachable in the release UI and its presentation labels and explanation are
localized; paths, URLs, raw status values, revisions, and technical diagnostics
remain unchanged by design.

The English wording freeze is preserved, the English/German localization pass is
complete, and the final localization audit found no unintended release-visible
English-only strings. The original D4.1-D4.4 baseline is **COMPLETE /
architecture-frozen**. A later accepted Article Timeline presentation amendment
narrowly extended the Articles presentation settings and English/German
localization with the absolute/relative publication-time choice. That extension
is now part of the accepted D4 UI baseline and does not reopen unrelated
Settings, wording, localization architecture, or other phase architecture. The
UIKit Timeline amendment otherwise remains limited to renderer/integration and
its relevant D4.4 validation.

D4.5 is a separately accepted **planned** extension and is not covered by the
earlier D4.1-D4.4 completion/freeze statement. Its user-facing wording and
English/German localization must be added before D4.5 itself is marked complete.

The UIKit Timeline amendment's D4.4/U3 real-device acceptance is complete. The
owner accepted the exercised slow/fast Scrollover behavior, rotation and
safe-area/chrome handling, current compact/regular presentation, long-feed
scrolling and reuse behavior, and the current Undo/haptic/status presentation.
Future changes must preserve those accepted semantics; new device work is
required only for a new reproducible regression or a materially changed
presentation path.

### U3.8.5 — Adaptive Device Matrix & Runtime Acceptance

The automated U3.8.5 acceptance baseline runs on the available compact iPhone
simulator and covers semantic compact/regular transitions, deterministic widths,
display scales, Dynamic Type including accessibility XXXL, and LTR/RTL. It
verifies persistent adaptive shell state, no structural Timeline snapshot for
presentation/geometry-only changes, canonical geometry and deterministic
UIKit-cell height agreement, Search request generation preservation, Reader
request preservation, Scrollover rebaselining, image request canonicalization,
bounded image work, and the single-scene hosted app manifest. The available
regular iPad simulator was booted and its test run began, but did not complete
within the six-minute acceptance timeout; it is not counted as completed iPad
acceptance.

Timeline diagnostics now report geometry identity changes, geometry layout
invalidations, prepared-window replacements, and superseded prepared-window
generations alongside the existing preparation, deterministic fallback, image,
structural-snapshot, and cell-work counters. A controller-level same-runloop
resize regression executes three canonical width changes and records one
prepared-window replacement with at least two superseded generations and no
structural reconciliation or snapshot application. This proves `Task.yield()`
coalesces a burst before speculative window replacement; it is not a substitute
for a sustained live-resize trace. No coalescing strategy change is justified
without a runtime trace showing expensive measurement churn rather than cheap
generation replacement.

Automated Scrollover coverage confirms that structural/geometry rebaselining,
layout-generation changes, Dynamic Type/RTL layout keys, and stale completion
paths cannot synthesize crossings or publish stale presentation. Image tests
confirm compatible canonical requests are retained, visible work is prioritized,
concurrency remains bounded, and stale image arrivals do not affect geometry.
The deterministic path performs no production Auto Layout sizing; the current
evidence does not justify U3.7.5 manual cell layout.

U3.8/U3.8.5 manual runtime acceptance is **COMPLETE as of 22 September 2026**.
The available simulator matrix remains a useful automated baseline, but the
closure decision is based on the completed physical-device checks rather than on
forcing every optional simulator combination. The owner explicitly accepted the
current UIKit Timeline/presentation behavior, including rotation-anchor
preservation, compact/regular chrome, article metadata and reading time, haptic
feedback and Undo, status-bar protection, the compact-landscape capsule, and the
iOS 27 renderer/performance baseline. No geometry-only Scrollover regression or
unresolved device-performance issue remains open in U3.

The final post-renderer-retirement `./apple/ios/Build/test.sh` run executed 348
tests with 0 failures. Optional future simulator/device matrices such as an
iPhone Duo runtime are additive regression coverage only; their absence does not
keep U3 open and must not introduce device-specific product behavior.

#### D4.5 — Cancellable Manual Sync

**Status: IN PROGRESS.** The prerequisite owner acceptance of the current
UIKit Timeline/presentation device changes was satisfied on 22 September 2026,
and U5 cleanup/final acceptance is complete. The current UIKit Timeline
architecture is frozen. D4.5 is a separately scoped Newsreader/Core feature and
must not reopen the Timeline container, Scrollover detector, or fundamental
image/layout pipeline.

D4.5-A establishes the additive Core cancellation contract: a run-scoped,
monotonic `SyncCancellation` signal, a non-error `SyncOutcome::Cancelled`
terminal outcome, and a separate cancellable Sync entry point. The existing
`sync(reason)` API retains its established behavior for existing callers.

D4.5-B is **COMPLETE**. It threads the cancellation signal through the
productive Rust Sync orchestration. Pending article/media mutations stop only
between safe remote-write/local-ack units; the Miniflux starred-state
read/conditional-write pair observes cancellation between its HTTP requests;
initial and SavedMedia entry pagination check between HTTP pages; protected
media fetches stop between bounded requests; reconciliation remains one unsplit
SQLite transaction with checks immediately before and after; SavedMedia
replication, retention/media cleanup, notification preparation, and the final
successful-Sync commit have explicit safe checkpoints. A cancelled run emits
neither normal Sync completion nor Sync failure. Once `mark_sync_success()`
begins after the final checkpoint, that run is considered committed rather than
retroactively cancelled.

D4.5-B validation on 23 September 2026 completed with `cargo fmt --check`
clean and `cargo test --workspace` green: 216 `flux-core` tests and 5
`flux-uniffi` tests passed with 0 failures, plus all workspace doc-tests.
During that gate, two pre-existing reading-time baseline defects were corrected:
`materialize_saved_media` now supplies the persisted
`reading_time_minutes` SQL parameter, and the versioned-database test now
expects the current schema version 18.

Manual foreground Sync must become explicitly cancellable by the user. This is
a Newsreader interaction and therefore remains in D4 rather than being deferred
to D5 background scheduling.

The product contract is:

- when idle, the Sync control starts a manual Sync;
- while manual Sync is running, that control changes into a clear Cancel/Stop
  action rather than becoming disabled;
- the scope capsule continues to present `Syncing…` while the Sync is active;
- cancellation returns the capsule to the current count and does not present the
  normal successful-Sync confirmation;
- user cancellation is a normal outcome, not a Sync/network failure, and must
  not surface an error alert;
- accessibility label/value/action state must track Start Sync versus Cancel Sync;
- already committed durable work remains valid; cancellation must not roll back
  successfully delivered mutations or otherwise corrupt local/Core state;
- completion from a cancelled or superseded Sync must not publish stale success,
  counts, snapshot replacement, notifications, or other presentation into a newer
  Sync generation;
- background Sync remains separately governed by D5 and is not made
  user-cancellable merely by implementing this foreground control.

A real cancellation requires a cooperative Rust/Core boundary. Cancelling only
the Swift task is insufficient because the current Apple execution contract can
prevent queued Core work from starting but cannot interrupt synchronous Rust
network I/O once it is running. The Core Sync path therefore needs a
session/run-scoped cancellation signal checked at safe phase and bounded-work
boundaries. Network operations that cannot be interrupted mid-call may finish
their current bounded request, but no further cancellable Sync work should begin
after cancellation is observed.

Tests must cover cancellation before Core work starts, cancellation during each
safe Sync phase, a late completion racing a cancelled generation, immediate
restart after cancellation, failure-versus-cancellation presentation, and
preservation of already durable mutations/state. Real-device acceptance must
verify that cancelling and immediately restarting Sync leaves the Timeline,
scope count, capsule, and Sync control coherent.

D4.5 implementation began only after the UIKit Timeline/presentation change
set was accepted on device and U5 was closed. D4.5-A, D4.5-B, and D4.5-C are
complete.

**D4.5-C — UniFFI + AppleCoreExecution is COMPLETE.** The UniFFI layer exports
a run-scoped `SyncCancellation` object, explicit
`SyncOutcome::Completed/Cancelled`, and an additive cancellable Sync entry
point while preserving the existing `sync(reason)` API. `AppleCoreExecution`
adds a blocking cancellable lane operation: cancellation before execution still
prevents queued Core work from starting; cancellation after execution begins
invokes the supplied cooperative cancellation callback exactly once and does not
release the OperationQueue worker until the synchronous Core closure actually
returns. Focused tests cover both queued and running cancellation semantics.

D4.5-C validation on 23 September 2026 completed with `cargo fmt --check`
clean and `cargo test --workspace` green: 216 `flux-core` tests and 6
`flux-uniffi` tests passed with 0 failures, plus all workspace doc-tests.
The native iOS gate then executed 340 tests with 0 failures and
`./apple/ios/Build/build-app.sh` completed with `BUILD SUCCEEDED`.

**D4.5-D — session-owned Manual Sync lifecycle in NewsreaderStore is
COMPLETE.** NewsreaderStore owns one current manual run, its UniFFI
`SyncCancellation` handle, and the Swift task that submits it through
`AppleCoreExecution.blockingCancellableResult`. Manual Sync state is explicit
(`idle/running/cancelling`); cancellation signals both the Core handle and the
Swift task so queued work is prevented from starting while running work remains
cooperatively cancellable. Run/session generations reject late completion,
cancellation suppresses normal success/error presentation, and cancelling a run
immediately supersedes its presentation generation so a fresh manual Sync may
start even while the old synchronous Core call is still cooperatively winding
down. Detach likewise cancels and invalidates the old run without accepting stale
publication. The Core event listener captures the attached Core session so an
already-enqueued old-session automatic/background completion cannot publish after
detach/reattach.

D4.5-D validation on 23 September 2026 executed **345 native iOS tests with
0 failures**, including the queued/running cooperative cancellation and central
Core-execution-boundary coverage, and `./apple/ios/Build/build-app.sh`
completed successfully.

**D4.5-E — account/Core quiescence barrier is COMPLETE.** NewsreaderStore
keeps every manual-Sync execution registered until its synchronous Core call has
actually returned, including user-cancelled runs that were already superseded
for presentation so immediate restart remains possible. A Core replacement
barrier prevents new manual runs, signals every still-winding cancellation
handle/Swift task, and awaits all registered executions before the old Core may
be replaced or its account state removed.

CoreBootstrapper invokes that barrier before creating a replacement Core,
removing account state, or explicitly deactivating an active Core. A failed
replacement resumes the existing store session; successful replacement releases
the quiescence gate when the new Core is attached. Generation guards remain
authoritative when concurrent bootstrap/account operations supersede an older
transition. The normal scene inactive/background path still only requests the
existing Scrollover persistence flush and does **not** cancel or quiesce manual
Sync.

D4.5-E validation on 23 September 2026 executed **348 native iOS tests with
0 failures**, including account-edit and account-removal quiescence ordering,
and `./apple/ios/Build/build-app.sh` completed successfully.

**D4.5-F — presentation, localization, and final acceptance is IN PROGRESS.**
The manual Sync control now resolves directly from the store-owned manual-Sync
state: idle starts Sync, running presents an explicit `xmark` Cancel action,
and cancelling returns the control to the Sync/restart action while the scope
capsule and empty-state presentation continue to report `Syncing…` until the
cancelled execution actually returns. Starting again during that cancelling
window supersedes the old cancellation presentation and starts a fresh
generation immediately. Normal cancellation advances the presentation
generation so the cancelled run cannot publish the success checkmark.

Accessibility follows the action rather than the icon: the running state is
labelled `Cancel sync` with value `Syncing`; cancelling exposes the restart
action with value `Cancelling`. The new English source strings
`Cancel sync` and `Cancelling` have German translations
`Synchronisierung abbrechen` and `Synchronisierung wird abgebrochen`.
The fixed 24-point toolbar slot and existing capsule geometry are preserved; the
frozen UIKit Timeline renderer, Scrollover, image, and layout architecture are
unchanged.

D4.5-F remains open until the native test/build gates pass and focused physical
device acceptance verifies start -> cancel -> immediate restart, coherent scope
count/`Syncing…` presentation, no cancellation error alert, and no stale
success checkmark or snapshot/count publication from the cancelled generation.

### D5 — Background Sync, Local Notifications & Widgets

Integrate BGTaskScheduler, local notifications and the native iOS WidgetKit
presentation using the shared snapshot contract. Successful background sync
also triggers the required native transfer reconciliation.

### D6 — Native Media & Background Downloads

Bring the existing Listening List/player/download experience to iOS/iPadOS,
including chapters, artwork, progress, policies, AVAudioSession, background
audio and true background URLSession downloads. Reuse/refactor Phase-C Apple
media code only where needed for actual cross-platform use.

### D7 — Now Playing & CarPlay

Complete Now Playing/remote-command integration and the required CarPlay
experience over the common playback stack. CarPlay is a completion gate.

### D8 — Live Activities & Dynamic Island

Implement ActivityKit/Dynamic Island over the common runtime playback state.
This is a completion gate.

### D9 — Full Flutter-to-Native Migration

Implement the copy/import-only migration against the now-stable native/Core
target structures. Cover credentials/custom headers, compatible settings/feed
preferences, playback progress and existing downloads. Exercise interrupted and
repeated migration safely.

### D10 — Replacement Validation & Release Readiness

Run the real production-identity upgrade path from representative Flutter state
to the native app and validate Newsreader, sync, widgets, notifications, media,
downloads, CarPlay and ActivityKit across foreground/background/offline/restart
conditions and representative compact/regular presentation environments. Quality and regression tests
must already run throughout D1-D9; D10 is integration/replacement validation,
not a deferred testing phase.

## 10. Implementation rules for Phase D

1. Do not reopen frozen Core/macOS architecture without concrete evidence that
   an iOS requirement cannot be expressed through the current boundary.
2. Inspect current Rust Core and native macOS behavior before treating a Flutter
   feature as missing.
3. Flutter is consulted for mobile-only capability and migration evidence, not
   as a source of architecture.
4. Extract Apple-shared Swift code on first real reuse; do not front-load a
   broad macOS refactor.
5. Each D subphase includes its own tests/build validation. Do not postpone
   correctness to D10.
6. Do not add a second durable Swift domain model or direct native SQLite/
   Miniflux access around Core.
7. Required capabilities may be isolated into implementation work packages, but
   CarPlay, Live Activities/Dynamic Island and the production migration path
   cannot be dropped from Phase D completion.
8. Potentially blocking Rust Core work must not execute on `MainActor` or a
   Swift cooperative executor. `MainActor` owns native presentation inputs,
   request lifecycle, and state publication; a bounded Apple worker policy owns
   synchronous Core/UniFFI closure execution. Separate responsive/local and
   blocking/remote lanes prevent network work from head-of-line blocking local
   reads and mutations. Existing request/session generations still decide whether
   results publish. Swift cancellation may prevent queued work from starting, but
   does not cancel already-running synchronous Rust network I/O. CPU-only
   detached image/layout work is outside this policy; Timeline bounded-query and
   pagination work remains separate.
