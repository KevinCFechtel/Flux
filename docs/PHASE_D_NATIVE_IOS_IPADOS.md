# Phase D — Native iOS/iPadOS

> **Status: D1-D4 COMPLETE / D4 FOLLOW-UP COMPLETE / D4.5 COMPLETE / D5 COMPLETE & ARCHITECTURE-FROZEN / D6 IMPLEMENTATION STABLE & TESTVALIDATED — UX OBSERVATION WINDOW ACTIVE / D7 READY TO START / UIKIT TIMELINE U1-U5 COMPLETE / TIMELINE ARCHITECTURE FROZEN / AUTHORITATIVE PHASE-D CONTRACT**
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
Starred, Categories and Feeds plus auxiliary Search and Listening List actions.
Selecting a News scope closes the sheet and updates the Article List. Search and
Listening List instead open their own native fly-over sheets without changing
the selected News scope.

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

Timeline actions use system-native swipe actions under the shared mobile interaction contract: each side supports zero, one, or two configured semantic actions in inner-to-outer order, and the outer action is the deliberate full-swipe action. The established defaults remain Read/Unread and Star/Unstar. These actions invoke the existing optimistic mutations and identify articles by stable ID. Preserve context menus, pull-to-refresh,
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

The pre-D4.5 native manual Sync control used the same `arrow.clockwise`
symbol across idle and active Sync while preserving a stable toolbar slot.
D4.5 supersedes only that control-state presentation with an explicit Cancel
action while retaining the same semantic controls. iPhone portrait keeps Sync,
Filter/Sort, and More in the bottom toolbar.
iPhone landscape returns the same action group to the native trailing top toolbar
and the interactive scope capsule to the native leading toolbar. It preserves
the configured current-scope article count in compact numeric form (or the
existing transient `Syncing…` substitution). The Timeline top-edge effect is
disabled specifically for this compact-landscape mode.
Persistent split navigation normally keeps the detached floating action capsule.
On systems where SwiftUI reports a non-`nil` `toolbarVerticalEdge`, the
Sync/Filter/More actions instead return to native top-toolbar items so a vertical
system bar such as iPhone Duo can place them on the appropriate side edge. This
path is compiled behind the `FLUX_HAS_VERTICAL_TOOLBAR_API` capability. The
project enables that capability for SDK 27.1 through 27.9 and later major SDK
families, while deliberately excluding SDK 27.0. This keeps the adaptation
forward-compatible across later 27.x SDKs without making 27.0 builds depend on
an unavailable symbol. A visible sidebar keeps the detail scope-title-free; if that sidebar is hidden, the
wider interactive scope capsule remains horizontal in the independent inset row
so navigation does not depend on the edge-swipe gesture. Category
selection and category expansion remain separate sidebar interactions so a
selected category can still be expanded or collapsed independently;
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

Regular news background refresh uses `BGAppRefreshTask` and the existing
app-owned Core session to call `sync(.background)`. `BGProcessingTask` is
reserved for work that actually requires the longer-processing mechanism; it is
not the default news refresh mechanism. iOS scheduling remains system-controlled
and force-quit limitations are accepted platform boundaries.

Background Sync is not owned by `NewsreaderStore`. The store retains ownership
of user-facing Manual-Sync presentation and the D4.5 Manual-Sync session, while
an app-scoped background execution coordinator owns BGTask lifecycle. Foreground,
manual and background work must converge on the same current account/Core
session; D5 must not initialize a second Core instance against the same storage
paths.

The D4.5 Core-quiescence guarantee becomes account/Core-session-wide once D5
introduces background Core execution. Account replacement, rebuild and removal
must prevent new Core work from entering, request cancellation of cancellable
work where appropriate, and wait for already-started synchronous Core execution
to finish before replacing or destroying that Core session.

D4.5 user cancellation remains specific to user-initiated Manual Sync.
Background Sync has no user-facing cancellation control. BGTask expiration may
reuse the same run-scoped Core `SyncCancellation` / `syncCancellable`
primitive so synchronous Rust work can stop cooperatively when iOS revokes the
task's execution time. That OS-owned expiration path does not give Background
Sync Manual-Sync presentation or user-cancellation semantics.

After a successfully completed background sync the native layer refreshes the
widget snapshot, requests the targeted WidgetKit reloads, processes Core
notification candidates and requests native media-transfer reconciliation.
D5 owns this post-sync transfer-reconciliation trigger/handoff. D6 owns the
actual iOS native transfer executor and its persistent background-`URLSession`
lifecycle. Core-generated download intent therefore survives D5 even before the
D6 executor is present, without introducing a temporary second download stack.

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
section 5 replaced its renderer and Scrollover integration and is also complete.
U1-U5 are closed, U3 was accepted on real devices, the legacy article-image
renderer has been removed, and the productive image path is
ImageIO -> UIImageView/Core Animation. The UIKit Article Timeline is now
architecture-frozen. Fundamental Timeline, Scrollover, layout or image-pipeline
changes require a concrete reproducible regression case; ordinary later Phase-D
work must preserve the frozen Timeline architecture and product behavior.

### D3 — Article Interaction, Reader & Search

Implement existing open routing, in-app browser, temporary Reader presentation,
article actions/share and the dedicated paginated remote Search screen using the
existing Core API.

#### D1-D3 legacy FluxNews gap review — COMPLETE

A post-D5 review compared the completed native D1-D3 scope with the former
Flutter FluxNews client. No additional **open, unassigned** D1-D3 gaps remain.

- **D1** is infrastructure/replacement feasibility rather than UI parity.
  Access to legacy production identity/storage is proven here; actual import of
  compatible Flutter state remains intentionally owned by **D9**.
- **D2** covers the accepted native Newsreader contract: adaptive navigation,
  Visual/Visual Compact/Compact presentation, preview lines, Startup Scope, Hide
  Empty, Remove When Read, pull-to-refresh, Scrollover/Undo, stable snapshots and
  the documented configurable swipe-action contract.
- Legacy Flutter AppBar/FAB/Glass/layout switches and configurable
  tap/long-press behavior are not missing D2 work. They are intentionally
  replaced by the native adaptive presentation and native context-menu model.
  Swipe configuration is the explicit native exception now covered by the
  mobile semantic contract.
- **D3** covers remote Miniflux Search with pagination, ReaderDocument-based
  temporary Reader presentation, article routing and the supported article
  actions (Original, Miniflux, Comments, Copy Link, Share and third-party save).
- Legacy inline article expansion / Split tap modes are intentionally replaced
  by the native Open Link / temporary Reader product model.
- The legacy **Download Audio** article/swipe action is not a D3 gap; it belongs
  to **D6**, where the native iOS media/download executor and handler become
  available.

Therefore D1-D3 are considered complete against the current native product
contract. This does not mean byte-for-byte Flutter behavior parity: explicitly
retired behavior remains retired, D6 owns media actions, and D9 owns legacy
state migration.

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
scope capsule implemented by `ArticleListTitleCapsule`, detached from
`UINavigationBar` and rendered in a normal SwiftUI top `safeAreaInset`.
iPhone portrait uses a centered stacked detached capsule with the optional
descriptive current-scope count and keeps Sync/Filter/More in the native bottom
toolbar. The entire scope capsule remains one semantic `Button`; on iOS 26+
its owned `UIGlassEffect` is interactive, while Reduce Transparency retains the
opaque fallback. The Timeline receives the measured detached-chrome height as an
additional natural-top `contentInset`: the first article therefore starts below
the capsule at the beginning of the list, but that clearance scrolls away with
the content so later articles can still pass beneath the floating glass.
Semantic scope/filter/sort resets and manual-Sync snapshot replacement already
reset to `-adjustedContentInset.top`, so they reuse the same natural start
without a separate scroll-state path. Its native Timeline top-edge effect remains
`.automatic` on iOS/iPadOS 26+.

Compact iPhone landscape intentionally uses native top navigation chrome instead:
the compact two-line scope capsule is `.topBarLeading` and Sync/Filter/More are
`.topBarTrailing`. The capsule reserves the alternate second-line width so
transitions between the count and `Syncing…` do not make the chrome breathe
horizontally. The Timeline top-edge effect is disabled in this mode because the
compact-landscape presentation has no visible status-bar glyph band to protect.

Persistent split navigation retains detached floating action chrome while the
system keeps bars horizontal. When SwiftUI's `toolbarVerticalEdge` reports a
vertical system-bar context, Sync/Filter/More become native trailing toolbar
items and therefore participate in the system's vertical bar instead. A visible
sidebar still suppresses the scope capsule; when the sidebar is hidden, the wider
inline scope capsule stays horizontal in the detached inset row. The action-axis
change does not alter the regular-mode Timeline edge policy: `.automatic`
remains enabled on iOS/iPadOS 26+. Detached capsules use `.regularMaterial` on
17-25 and own one
`UIGlassEffect(style: .regular)` layer on 26+. The compact-landscape toolbar
instead relies on system Liquid Glass on 26+ to avoid a double layer. During Sync the
capsule's count presentation temporarily shows `Syncing…`. The capsule remains
the authoritative visible title/header presentation and carries the accessibility
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

D4.5 is a separately accepted **completed** extension and is not covered by the
earlier D4.1-D4.4 completion/freeze statement. Its cancellable manual-Sync
contract, user-facing wording, English/German localization, automated regression
coverage, and focused physical-device acceptance are complete as of
23 September 2026.

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

**Status: COMPLETE as of 23 September 2026.** The prerequisite owner
acceptance of the current UIKit Timeline/presentation device changes was
satisfied on 22 September 2026, and U5 cleanup/final acceptance is complete. The
current UIKit Timeline architecture remains frozen. D4.5 is a separately scoped
Newsreader/Core feature and did not reopen the Timeline container, Scrollover
detector, or fundamental image/layout pipeline.

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

**D4.5-F — presentation, localization, and final acceptance is COMPLETE.**
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

D4.5-F automated validation on 23 September 2026 is **COMPLETE**. The final
post-presentation `./apple/ios/Build/test.sh` run executed **349 native iOS
tests with 0 failures**, including
`testSyncButtonPresentationMakesRunningSyncAnExplicitCancelAction`, and ended
with `TEST SUCCEEDED`. `./apple/ios/Build/build-app.sh` also completed
successfully.

D4.5-F, and therefore D4.5 as a whole, remains open for focused physical
device acceptance. The first cancellation acceptance pass on 23 September 2026
successfully exercised cancellation several times, but a later run combined
cancellation with a large "mark all as read" structural Timeline change and
exposed a UIKit diffable-data-source abort on iOS 27. The crash stack terminates
in `__UIDiffableDataSource tableView:cellForRowAtIndexPath:`, reached from
`IOSUIKitArticleTimelineController.requestFeedIconsForVisibleCells()`.

The failure is a Timeline presentation ordering bug rather than a Rust/Core
cancellation failure. During a structural update, `itemsByID` intentionally
moves to the new model before the diffable table has necessarily finished
publishing that snapshot. Calling `tableView.visibleCells` in the feed-icon
retry path can force UIKit to materialize a cell in that short interval; an old
identifier that has already been removed from `itemsByID` then makes the cell
provider return nil and UIKit asserts. Update-side feed-icon/reconfiguration
paths now enumerate only already-materialized cells through
`indexPathsForVisibleRows` + `cellForRow(at:)`, which does not request new
cells from the data source. Focused regression coverage combines a visible
Timeline, structural removal, and a feed-icon request revision.

Post-fix automated validation on 23 September 2026 executed **351 native iOS
tests with 0 failures** and ended with `TEST SUCCEEDED`. The run includes both
`testFeedIconRetryDuringStructuralRemovalDoesNotForceDiffableCellMaterialization`
and
`testTimelineFeedIconRetryDoesNotUseMaterializingVisibleCellsAccessor`.
`./apple/ios/Build/build-app.sh` also completed successfully.

Final physical-device acceptance passed on 23 September 2026 after the diffable
fix. The owner re-exercised manual Sync cancellation, including the previously
crashing large mark-all-read scenario, and accepted the result. The accepted
behavior covers start -> cancel -> immediate restart, coherent scope
count/`Syncing…` presentation, no cancellation error alert, no stale success
checkmark or snapshot/count publication from the cancelled generation, and no
recurrence of the UIKit diffable-data-source crash. D4.5 is therefore closed.

### D5 — Background Sync, Local Notifications & Widgets

**D5-A — Core-Session Execution Foundation is COMPLETE.**
The canonical iOS test suite passes after the D5-A integration and
`./apple/ios/Build/build-app.sh` completes successfully. The native iOS app now has one app-wide `IOSCoreSessionExecutionCoordinator`
owned by `CoreBootstrapper`. It admits synchronous Core work only for the
current Core session, tracks admitted work until the underlying
`AppleCoreExecution` call has actually returned, blocks new admission during
quiescence, and can forward cooperative cancellation to cancellable runs.
`NewsreaderStore` and `IOSSearchStore` share this coordinator with the
bootstrapper; Manual Sync retains its D4.5 presentation/session lifecycle while
also holding a Core-session lease. Account replacement/removal/deactivation
quiesce the app-wide Core session before replacing or destroying it. This is
foundation only: BGTask scheduling, cold-launch readiness, notification delivery
and WidgetKit work have not started.

**D5-B — Cold-Launch Readiness & Credential Accessibility is COMPLETE.**
The canonical iOS test suite passes after the D5-B integration and
`./apple/ios/Build/build-app.sh` completes successfully. `CoreBootstrapper.ensureStarted()` is the
idempotent readiness entry point for foreground and future headless/background
callers. Concurrent callers await one in-flight bootstrap, while retry,
reconfiguration, account removal and deactivation retain generation-based stale
completion suppression. A background launch that occurs before protected
credentials are available leaves startup retryable rather than converting the
account into a permanent configuration failure; returning to the active app
reuses the same readiness path.

Native iOS Miniflux credentials now use
`kSecAttrAccessibleAfterFirstUnlock`. Newly saved items receive that
accessibility class, and readable credentials created by earlier native builds
are migrated on load from their previous accessibility class. This deliberately
uses the migratable AfterFirstUnlock variant rather than a
`ThisDeviceOnly` class so existing encrypted backup/device-migration semantics
are not narrowed merely to enable background access. No BGTask registration or
background Sync execution is part of D5-B.

**D5-C — BGAppRefresh Scheduling & Execution is COMPLETE.**
The canonical iOS test suite passes after the D5-C integration and
`./apple/ios/Build/build-app.sh` completes successfully. Native iOS registers one `BGAppRefreshTask` identifier
during application launch through a small `UIApplicationDelegate` bridge. The
production/upgrade identity retains
`dev.kevincfechtel.fluxNews.backgroundSync`; the parallel native-development
identity uses `dev.kevincfechtel.fluxNews.nativeDev.backgroundSync`. The app
declares only the `fetch` background mode for regular news refresh; no
`BGProcessingTask` or remote-notification mode is introduced.

`IOSAppRuntime` owns the same `CoreBootstrapper` used by SwiftUI and
`IOSBackgroundSyncCoordinator`, so a headless BGAppRefresh launch cannot
construct a second Core. The coordinator reads persisted Core
`backgroundSyncEnabled`, submits the next refresh with a preferred
30-minute earliest-begin date, runs `syncCancellable(.background)` through the
D5-A Core-session execution gate, and completes the OS task exactly once.
BGTask expiration owns a dedicated run-scoped `SyncCancellation` and Swift
task cancellation; it has no D4.5 Manual-Sync presentation or user-cancellation
semantics. Disabled Background Sync cancels pending refresh requests and does
not enter Core Sync. Successful completion exposes a post-sync hook for later
D5 notification/widget/media-reconciliation fan-out, but D5-C does not implement
that fan-out itself.

The app foreground attachment path also adopts a Core that may already have
been initialized by the background runtime before SwiftUI installed its
`onCoreChanged` callback. Focused tests cover one-time registration,
enabled scheduling, disabled cancellation, successful completion and OS
expiration/cooperative cancellation.

**D5-C.1 — Lightweight Delta Sync and Resume Full-Reconcile Policy is COMPLETE.**
Validation is complete across the shared Core and native iOS integration:
`cargo fmt --check` passes; `cargo test --workspace` passes with
220 `flux-core` tests and 6 `flux-uniffi` tests; the canonical iOS test gate
passes with 364 tests and 0 failures; and `./apple/ios/Build/build-app.sh`
succeeds. Regular iOS Background Sync no
longer requires the Full unread+starred snapshot once a Full Sync has
established a Delta baseline. The Rust Core owns the plan decision:

- `.background` is Delta-only. It delivers pending mutations first, then uses
  Miniflux `changed_after` to fetch changed Entries. It never escalates into a
  Full Sync inside `BGAppRefreshTask`.
- `.resume` is requested whenever the app becomes active, but the Core returns
  a no-op when Background Sync is disabled or the latest successful Sync is
  younger than 30 minutes and no Full reconciliation is due.
- Resume performs Full Sync when `full_sync_required` is set, when no valid
  Delta baseline exists, or when the last Full Sync is at least 24 hours old.
  Otherwise stale Resume uses Delta.
- `.manual`, `.appStart`, `.periodic`, and `.widget` retain Full-Sync
  semantics for now.

A successful Full Sync captures a Miniflux changed-entry high-water mark before
the Full remote snapshot begins and commits that value as the next Delta
baseline only after the Full reconciliation succeeds. This ordering allows
changes racing the Full fetch to be observed again by the next Delta instead of
being skipped. Delta requests use a small overlap window around the persisted
cursor so equal/near-boundary `changed_at` values are safely re-read.

Delta Sync does not fetch or reconcile the Feed/Category catalog. A changed
Entry whose `feed_id` is unknown locally is skipped, while all Entries from
known Feeds continue to reconcile normally. The successful Delta cursor is
still advanced and `full_sync_required` is persisted. The later Full Sync is
independent of the Delta cursor and restores the structural Feed/Category truth.
Because system-notification preferences exist only for known local Feeds,
skipped unknown-Feed Entries cannot create notification candidates.

Pending article/media mutations retain their established ordering and safety:
delivery and durable acknowledgement happen before the Core chooses or executes
the remote Delta/Full plan. A failed pending delivery still aborts remote fetch;
successful writes remain durable even if a later Delta step is cancelled.
Delta reconciliation updates only returned Entries and their enclosures. It
never applies the Full-Snapshot rule that an Entry absent from the response is
implicitly read and unstarred.

**D5-D — Mobile Background-Sync Preference & Resume Integration is COMPLETE.**
Validation is complete across the shared Core and native iOS integration:
`cargo fmt --check` passes; `cargo test --workspace` passes with
221 `flux-core` tests and 6 `flux-uniffi` tests; and the canonical iOS
`./apple/ios/Build/test.sh` gate passes after the D5-D preference integration. D5-C.1 already established the Core-owned Resume
freshness and Delta-vs-Full policy, so D5-D does not introduce another Swift
freshness clock or synchronization algorithm.

Native iOS now exposes one `Background Sync` Settings destination backed directly
by the persisted Core `backgroundSyncEnabled` value. There is no separate mobile
Sync-on-Start preference. Reading and writing the preference use the app-wide
`IOSCoreSessionExecutionCoordinator`, preserving the current Core-session and
quiescence contract.

Turning Background Sync off persists the Core setting and cancels the pending
`BGAppRefreshTask` request. It does not reinterpret the setting change as
D4.5-style user cancellation of already-running automatic work. Turning the
setting on persists the Core value, submits the next refresh request, and asks
the existing Core-owned Resume path to evaluate whether immediate catch-up work
is actually needed. The Core still decides no-op vs Delta vs Full using the
D5-C.1 policy.

The normal app-active lifecycle continues to request `.resume` through
`IOSBackgroundSyncCoordinator`; Core serialization and post-gate freshness
evaluation prevent duplicate automatic work after a recent or concurrently
finishing background/manual Sync. Focused tests cover persisted preference reads,
disable/cancel scheduling behavior, enable/reschedule behavior, and the
dedicated Resume trigger.

**D5-E — Native Local Notifications is COMPLETE.** Validation is complete across the native iOS integration and the shared Apple presentation extraction: the canonical iOS `./apple/ios/Build/test.sh` gate passes with 371 tests and 0 failures after the D5-E integration, the new MainActor default-argument warnings have been removed, and `bash apple/macos/Build/build-app.sh` succeeds after moving `SystemNotificationPresentation` into `apple/shared/FluxApple`.
The existing Core notification-candidate contract remains authoritative; D5-E
adds no Rust/UniFFI notification-domain logic and no APNs/push infrastructure.

Native iOS now owns local delivery through `UNUserNotificationCenter`.
Feed Settings expose the existing Core `systemNotificationsEnabled` preference.
Enabling the preference first resolves native notification authorization; denied
authorization leaves the Core feed preference disabled and presents a localized
error. Disabling the preference requires no authorization interaction.

A successful Background Sync hands Core-generated
`SystemNotificationCandidate` values to `IOSSystemNotificationManager`.
The BGAppRefresh success fanout is asynchronous and awaited before the OS task is
completed, so iOS cannot suspend the process merely because Sync finished before
notification submission. For each candidate the native manager submits one
immediate local notification and only then acknowledges the candidate through
the current app-wide Core session. Failed native submission is not acknowledged,
preserving the existing durable retry semantics.

Notification title/body presentation is shared with macOS through
`apple/shared/FluxApple/SystemNotificationPresentation.swift`; the former
macOS-local duplicate has been removed. Foreground notifications use banner/list
presentation. A notification tap routes to its Core feed ID. Because the first
native release intentionally owns one scene, an early/cold-launch tap is buffered
until the app's `NewsreaderStore` presentation handler is attached, then
consumed exactly once.

Focused native tests cover authorization, denied permission, successful
delivery-before-ACK, failed-delivery/no-ACK, buffered feed routing, and the
requirement that BGTask completion waits for post-Sync fanout.

**D5-F — Apple-shared Widget Contract Extraction is COMPLETE.** Validation
covers the canonical native iOS test gate and a warning-free native macOS
Universal build after the shared WidgetKit extraction. The existing macOS WidgetKit contract has been moved mechanically
into `apple/shared/FluxApple`: `WidgetSnapshotV1`, `WidgetSnapshotStore`,
`WidgetAction`, `WidgetContentModel`, the widget-family presentation policy
and `WidgetSnapshotWriter`. macOS now references those shared sources instead
of maintaining private copies.

The durable widget contract remains intentionally separate from UniFFI records,
Core persistence and account credentials. App/Background execution asks Core for
the existing compact `WidgetData` projection, serializes the versioned snapshot
into the configured App Group and asks WidgetKit to reload the two stable widget
kinds. The extension remains read-only over that snapshot and never opens Core,
SQLite, Keychain or Miniflux itself.

Widget identity is configuration-driven so the parallel native-development app
does not collide with the production/Flutter identity. Native Dev uses
`group.dev.kevincfechtel.fluxNews.nativeDev` and the
`fluxnews-native-dev` widget URL scheme; Upgrade Test/production retains
`group.dev.kevincfechtel.fluxNews` and `fluxnews`.

**D5-G — Native iOS WidgetKit, including Lock Screen widgets, is COMPLETE / REAL-DEVICE ACCEPTED.** The canonical iOS test gate passes after
the WidgetKit integration. A signed NativeDev device archive also succeeds with
separate host/widget provisioning profiles and the shared
`group.dev.kevincfechtel.fluxNews.nativeDev` App Group. The archive script now
supports both NativeDev Release and production-identity Upgrade Test archives
and verifies the archived host Bundle ID, widget Bundle ID, shared App Group
entitlements and signatures. The production-identity Upgrade Test archive has also been validated
successfully. Final D5-G acceptance now requires only the physical-device
widget/deep-link smoke pass after the final widget presentation polish. The iOS application now embeds a native
`FluxNewsWidgets` extension using the shared snapshot/presentation contract.
The Headlines widget supports Home Screen `systemMedium`, `systemLarge` and
iPad `systemExtraLarge`; the small Headlines family is intentionally not
offered because a single-headline layout does not provide useful value. The
Status widget supports Home Screen `systemSmall`/`systemMedium` and the Lock
Screen families `accessoryInline`, `accessoryCircular` and
`accessoryRectangular`. Widget branding uses the existing FluxNews book logo
(`FluxNewsTemplate`) rather than a generic news glyph. The rectangular Lock
Screen status presents the selected scope and its authoritative count without a
truncated article teaser. Last-sync presentation continues to use the one global
Core `last_successful_sync_at` value independent of SyncReason and accepts the
persisted SQLite UTC timestamp format as well as ISO-8601 snapshots.

All families consume the same configured content scopes
(All News/Bookmarks/Category/Feed) and the same snapshot counts/articles. Lock
Screen presentation is deliberately reduced rather than shrinking the Home
Screen article card: inline shows the FluxNews/count summary, circular presents
the count in an accessory gauge, and rectangular shows scope/count plus the
leading article when available.

Native iOS owns snapshot freshness through `IOSWidgetSnapshotCoordinator`.
The coordinator subscribes to the active Core session and refreshes the App Group
snapshot after article read/star state events and completed Sync events.
Successful BGAppRefresh fanout additionally awaits a snapshot refresh before the
OS task completes. Account/Core detachment invalidates the snapshot and reloads
WidgetKit.

Widget URLs reuse the shared stable `WidgetAction` contract. iOS registers its
configuration-specific URL scheme and routes scope actions into
`NewsreaderStore`, article IDs through Core back into the existing article-open
policy, and widget Sync through `sync(.widget)` without borrowing the D4.5
Manual-Sync presentation lifecycle. Focused tests cover snapshot round-trip,
scope projection, URL action round-trip and the exact three Lock Screen families.

Integrate BGTaskScheduler, local notifications and the native iOS WidgetKit
presentation using the shared snapshot contract. Background execution shares
the existing account/Core session, participates in app-wide Core quiescence and
uses OS-owned cooperative cancellation only for BGTask expiration. It does not
reuse the D4.5 Manual-Sync presentation lifecycle or expose user cancellation.

Successful background sync updates the App Group widget projection, requests
targeted WidgetKit reloads, hands Core notification candidates to the native
notification layer and requests native media-transfer reconciliation. The D5
transfer-reconciliation trigger/handoff is now implemented through
`IOSMediaTransferReconciliationHandoff`. A request is buffered when no native
executor is installed yet and is delivered when D6 attaches that executor;
multiple pre-install requests coalesce into one reconciliation request. The
post-Sync fanout requests this handoff independently of whether notification
candidates exist and still awaits all D5 fanout before BGTask completion. The
actual persistent iOS transfer executor remains D6 work.

D5 is COMPLETE / architecture-frozen. Final physical-device widget/deep-link smoke validation and the production-identity Upgrade Test archive succeeded; the authoritative closure record is `docs/IOS_D5_FINAL_ACCEPTANCE.md`.

### Phase-D late settings portability & diagnostics completion

The late native iOS diagnostics commitment is now implemented: bounded
privacy-safe Core/native support logs persist across relaunch, Debug Logging is
an explicit persisted opt-in, and Developer Diagnostics provides export/share
and clear actions. The detailed contract and implementation status are recorded
in [IOS_D4_FOLLOWUP_FINDINGS.md](IOS_D4_FOLLOWUP_FINDINGS.md).

The remaining late Phase-D settings-portability capability is native iOS
configuration backup/restore using the existing versioned Core/UniFFI backup
format. It remains scheduled after the Settings surface has stabilized and
before D10 replacement validation.

### D6 — Native Media & Background Downloads

**Entry status — 25 September 2026:** D1-D5 and the immediate D4 follow-up set
are closed. The canonical native iOS test gate passed again after the final
post-D4 presentation/sync polish, including compact swipe-action labels,
navigation-localization repair, scope-aware pending-new-data presentation for
feed/category scopes, and global pending-new-data acknowledgement after a
successful Manual Sync. No additional D1-D5 implementation work is a prerequisite
for starting D6.

Bring the existing Listening List/player/download experience to iOS/iPadOS,
including chapters, artwork, progress, policies, AVAudioSession, background
audio and true background URLSession downloads. D6 supplies the iOS native
transfer executor consumed by the transfer-reconciliation handoff established
in D5. Reuse/refactor Phase-C Apple media code only where needed for actual
cross-platform use.

D6 starts from an existing Core/UniFFI media contract and a completed macOS
reference implementation. The repository-first readiness review and concrete
execution/work-package contract are maintained in
[`IOS_D6_NATIVE_MEDIA_IMPLEMENTATION.md`](IOS_D6_NATIVE_MEDIA_IMPLEMENTATION.md).
D6-0 through D6-F are implemented and testvalidated. The 25 September
native-media UX follow-ups reorganized Player controls, moved the native iOS
Listening List from a detail scope to a Search-style fly-over, added read-only
chapter preview for inactive items, unified long-form playback time formatting,
refined remote buffering presentation, and corrected cross-device Miniflux
playback-progress reconciliation while preserving the shared/Core ownership
contract. The current validation baseline is green: `cargo fmt --check`, the
full Rust workspace suite (226 `flux-core` + 6 `flux-uniffi`, 0 failures),
and the canonical iOS gate (459 tests, 0 failures, `TEST SUCCEEDED`).

D6 is now **implementation-stable and testvalidated** and enters an explicit
real-device **UX observation window**. During this window, presentation-only
Player/Listening-List refinements may continue without reopening the stable
playback/runtime ownership contract. D6 is deliberately not yet marked
architecture-frozen: the remaining D6-G real-device/process-boundary matrix is
retained as the final closure/freeze gate. D7 may start in parallel because it
consumes the app-wide playback runtime rather than the mutable SwiftUI Player
layout. The D6-G evidence matrix is maintained in
[`IOS_D6_FINAL_ACCEPTANCE.md`](IOS_D6_FINAL_ACCEPTANCE.md).
The D5 `IOSMediaTransferReconciliationHandoff` remains the authoritative
bridge from successful background Sync into the D6 transfer runtime. D6 now
installs the native transfer executor and backs `BrowserScope.listeningList`
plus the iOS Listening List article/context/swipe actions with the same Core
media domain. The native Listening List, AVPlayer/AVAudioSession runtime and
persistent background URLSession executor are implemented; D6-G is limited to
their remaining real-device/process-boundary acceptance evidence.

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
