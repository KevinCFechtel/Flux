# Phase D — Native iOS/iPadOS

> **Status: D1-D4 BASELINE COMPLETE / UIKIT TIMELINE AMENDMENT ACCEPTED, IMPLEMENTATION PENDING / AUTHORITATIVE PHASE-D CONTRACT**
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
> `UICollectionView` and native UIKit cells. Only the previous Timeline renderer,
> geometry integration, and associated mutation scheduling are reopened. The
> remaining completed architecture and product rules stay frozen. The contract
> amendment is complete; its implementation and device acceptance are not.
> See [implementation handoff](IOS_UIKIT_TIMELINE_IMPLEMENTATION.md).

## 1. Goal and non-goals

Native FluxNews iOS/iPadOS minimum deployment target: 18.0.

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

## 5. iPhone and iPad product architecture

There is one common iOS/iPadOS app target, not separate iPhone and iPad apps.

### iPhone

The app starts directly in the Article List. Navigation is optional and opens as
a native sheet containing All News, Starred, Listening List, Categories and
Feeds. Selecting a scope closes the sheet and updates the list.

### iPad

The primary layout is a two-column `NavigationSplitView`:

```text
Navigation | Article List
```

There is no permanent third article/detail column. The existing article-first
behavior remains: a normal article tap tries the configured installed-app deep
link and falls back to the in-app browser. The internal Reader is an explicitly
configured exception and is temporary presentation, preferably an inspector on
regular-width iPad and a sheet/full-screen presentation on compact width/iPhone.

### iOS/iPadOS Article Timeline — UIKit

The target Article Timeline is an owned UIKit view controller containing a
`UICollectionView`, embedded through a narrow bridge in the SwiftUI app shell.
Use stable Article IDs and a collection-view list configuration with native
UIKit article cells. Compact and visual modes, portrait/landscape image slots,
preview-line choices, Dynamic Type, VoiceOver, and the current iPhone/iPad
presentation remain supported. Cell structure and content sizing are reused
when their layout inputs have not changed.

The Timeline must not use SwiftUI `List`, `ScrollView`/`LazyVStack`, or hosted
SwiftUI article cells as its production renderer. Navigation, Settings, Reader,
Search, sheets, and other surfaces may continue using SwiftUI. Use public UIKit
APIs; do not take over the internal delegate of a SwiftUI control through
introspection. Retire the old Timeline path after the replacement is integrated.

Timeline actions use system-native swipe actions: leading Read/Unread and
trailing Star/Unstar invoke the existing optimistic mutations and allow the
platform's standard full-swipe behavior. Preserve context menus, pull-to-refresh,
article routing, native Large Title/scroll-edge behavior, semantic scope resets,
and iPad navigation. Actions identify articles by stable ID, never a captured
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
Existing SwiftUI fallback presentation outside this Timeline retains correct
read/starred equality and updates, including Search results.
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

The native bottom Sync control keeps the same `arrow.clockwise` symbol and
stable toolbar geometry across idle, syncing, success, and failure states;
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

Implement iPhone article-first navigation, iPad two-column navigation, Article
List, Row/Card presentation, preview-line choices, Startup Scope, Hide Empty,
Remove When Read, pull-to-refresh, native swipe actions, Scrollover/Undo and
stable snapshot/pending-new-data behavior. Extract proven shared Apple code only
where this creates actual reuse.

The original D2 baseline is complete. The accepted UIKit Timeline amendment in
section 5 replaces its renderer and Scrollover integration; implementation is
pending and tracked separately in the implementation handoff. D2 product
behavior is preserved by that work.

### D3 — Article Interaction, Reader & Search

Implement existing open routing, in-app browser, temporary Reader presentation,
article actions/share and the dedicated paginated remote Search screen using the
existing Core API.

### D4 — Settings & Native Presentation Quality

D4 is subdivided into D4.1-D4.4. D4.1 introduces the independent native
account/credential startup lifecycle. D4.2 is the full native Settings redesign,
D4.3 covers presentation quality, and D4.4 performs combined real-device
D2-D4 validation and polish.

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

Implement a conventional native Settings hierarchy with dedicated Account,
Articles, Navigation, and Developer Diagnostics destinations. D4.2 exposes only
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
article count. Where supported, iOS uses the native navigation subtitle for the
optional current-scope count; older supported iOS versions retain the native
trailing-counter fallback. System Large Title and collapsed navigation behavior
is authoritative and is not recreated through custom scroll tracking.
Sync activity is communicated by the normal Newsreader UI; an empty scope shows
`News syncing…` while Sync is active and `No News` after it completes, without
an additional custom splash screen.
`No News` is a confirmed-empty state, never an intermediate Sync or local
snapshot-loading transition. Existing article content remains visible during
snapshot refreshes without a generic loading overlay. The stable, count-free
navigation scope title is unchanged; the separately presented current-scope
count can be disabled through the native iOS article presentation settings.

#### D4.4 — Real-Device Validation & Polish

Perform combined real-device D2-D4 validation and polish on representative
iPhone and iPad devices.

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
English-only strings. The original D4 baseline is **COMPLETE / architecture-frozen**;
the accepted UIKit Timeline amendment reopens only the renderer/integration and
its relevant D4.4 validation. It does not reopen Settings, wording, localization,
or unrelated phase architecture.

For iOS Scrollover, D4.4 still requires real-device coverage of slow drags,
fast flicks that skip rows, reverse-then-forward movement, Remove When Read,
Dynamic Type, rotation/safe-area changes, and the rolling Undo window on both
iPhone and iPad. Run these cases on the new UIKit Timeline, including long feeds
and cell reuse. Record actual correctness and device-performance evidence before
marking the amendment complete; documentation approval is not runtime acceptance.

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
conditions and representative iPhone/iPad layouts. Quality and regression tests
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
8. Potentially blocking Rust Core work must not execute on `MainActor`.
   `MainActor` owns native presentation inputs, request lifecycle, and state
   publication; Core reads and result construction execute off-main and may only
   publish while their presentation request remains current.
