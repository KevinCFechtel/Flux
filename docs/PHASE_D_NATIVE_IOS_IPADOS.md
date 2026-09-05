# Phase D — Native iOS/iPadOS

> **Status: D1-D3 COMPLETE / D4.1-D4.2 COMPLETE / D4.3 IN PROGRESS / AUTHORITATIVE PHASE-D CONTRACT**
>
> Phase A, Phase B, and Phase C are complete and architecture-frozen. Phase D
> replaces the existing Flutter iOS/iPadOS client with a native Swift/SwiftUI
> client over the existing Rust Core and UniFFI boundary. The current native
> macOS implementation is the primary native reference. Flutter is only a
> behavioral reference for mobile-only capabilities and the legacy migration
> source; it is not a parity checklist and intentionally removed behavior must
> not be reintroduced without a product decision.

## 1. Goal and non-goals

Native FluxNews iOS/iPadOS minimum deployment target: 18.0.

Phase D delivers a first-class native iPhone/iPadOS FluxNews client without
creating a second domain layer in Swift.

The Rust Core remains authoritative for domain models, Miniflux networking,
SQLite persistence, sync/reconciliation, offline mutations, article/Reader
processing, search, notification candidates, widget projection, media domain,
playback progress, download intent/state, policies and retention.

The native Apple client owns SwiftUI presentation, navigation, gestures,
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

Native swipe actions and Mark-as-Read-on-Scrollover are retained. iOS uses the
iOS 18 `scrollTargetLayout`, scroll phase, and target-visibility APIs rather
than row geometry: the leading visible Article ID is compared against the
current ordered article snapshot, and the forward crossed ID range is marked
read. This remains correct when fast scrolling skips intermediate visibility
reports. Initial visibility and snapshot replacement establish a baseline only;
backward movement emits nothing. A 15% target-visibility threshold is used only
to reliably identify a leading target for variable-height cards, including cards
too tall to become 50% visible. It is not a read-exposure threshold.

Remove When Read applies to explicit/manual read actions, including swipe and
context-menu actions. It does not apply to Mark-as-Read-on-Scrollover:
Scrollover updates read state without changing visible article list membership,
including after scrolling becomes idle. The unread/read visual transition keeps
the unread-indicator layout slot present and changes only its visual opacity, so
it does not alter article-card geometry.

iOS Scrollover keeps detection, Core mutation scheduling, and Undo separate.
Detection is ID/order-only, with no geometry, exposure duration, or per-row
timer. Candidates enter one serialized, deduplicating Core bulk-mutation queue.
The ordered detection snapshot rebases only when visible membership or ordering
changes; a Scrollover read-state presentation update is not structural.
Only successful writes join a rolling Undo group: a success extends its 4-second
inactivity window without extending the 15-second maximum group lifetime. macOS
retains its existing platform-specific frame integration.

Visual article images are native iOS presentation infrastructure, not Core or
sync state. They use display-sized ImageIO downsampling, normal HTTP response
caching, and bounded in-memory caching of decoded images. Loading, failure, and
success presentation remain inside the existing fixed portrait or landscape
image slots and must not change article-card geometry.

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

#### D4.4 — Real-Device Validation & Polish

Perform combined real-device D2-D4 validation and polish on representative
iPhone and iPad devices.

For iOS Scrollover, D4.4 still requires real-device coverage of slow drags,
fast flicks that skip rows, reverse-then-forward movement, Remove When Read,
Dynamic Type, rotation/safe-area changes, and the rolling Undo window on both
iPhone and iPad.

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
