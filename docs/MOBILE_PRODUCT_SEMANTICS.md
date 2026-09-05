# Shared Native Mobile Product Semantics

> **Scope:** Product and behavior contract shared by future native iOS/iPadOS and Android clients.
>
> This document captures mobile semantics that must not be rediscovered independently per platform. It does **not** prescribe SwiftUI/UIKit, Jetpack Compose/Android View, lifecycle, gesture-recognizer, browser, scheduler, credential-store, or media-framework implementation details. Platform-native presentation remains preferred.

## 1. Architecture boundary

The Rust Core remains authoritative for domain models, Miniflux networking, SQLite persistence, sync/reconciliation, offline mutations, article/Reader processing, search, feed preferences, notification candidates, widget projections, media/listening/download domain state, playback progress, policies, and retention.

Native mobile clients own platform presentation and navigation, gestures, visible snapshots, lifecycle integration, credential storage, browser/share presentation, background execution, notification delivery, widgets, runtime media playback/transfers, automotive UI, and other OS integrations.

Do not create a parallel Swift/Kotlin Miniflux or durable domain layer around Core functionality.

Platform-specific networking integration must preserve the platform's native trust decisions. The Apple implementation uses platform trust through the Rust TLS integration. A native Android implementation must explicitly validate equivalent Android system/user trust behavior rather than copying the Apple mechanism or introducing a second Kotlin Miniflux client.

## 2. Account and local-state lifecycle

Account credentials and custom HTTP headers are stored in the platform-native credential facility and used to configure/validate the existing Core contract.

The following actions have distinct semantics:

- **Rebuild Local State:** preserve account credentials, global preferences, and compatible account/feed preferences while rebuilding reconstructable synchronized Core state.
- **Remove Account:** remove credentials, account-bound Core state, account/feed preferences, and account media while preserving global application/display preferences.

There is no general FluxNews Factory Reset product action.

Legacy Flutter migration is copy/import-only and must not become an ongoing dependency. After migration, the native client operates solely on native/Core-owned state.

## 3. Background Sync semantics

`Background Sync` is the single user-facing preference controlling ongoing non-manual automatic synchronization on native mobile clients.

When **off**:

- no scheduled background news sync;
- no automatic foreground/resume sync;
- manual sync remains available.

When **on**:

- the platform may schedule appropriate background refresh work;
- foreground/resume may perform a fallback/complementary sync when freshness policy says it is needed;
- do not start a duplicate sync when one is already running or a sufficiently recent background sync already succeeded.

The mandatory initial/bootstrap sync after account setup is independent of this preference.

There is no separate mobile `Sync on Start` preference.

The scheduling mechanism is platform-specific: for example BGTaskScheduler on Apple platforms and an appropriate Android scheduler/lifecycle mechanism on Android.

## 4. Navigation and list state

`BrowserScope`/the equivalent Core-backed scope selection is the source of truth for the selected All News, Starred, Category, or Feed scope. Platform UI must not create a second durable selected-feed/category truth.

Expansion state, drawer/sheet visibility, and similar presentation state remain platform-local.

`Unread Only` and article sort direction are transient Article List presentation controls, not persistent global Settings.

A semantic list reset caused by scope/filter/sort or another explicitly defined reset event returns the Article List to its natural starting position. The mechanism is platform-specific. iOS may recreate presentation identity to restore native Large Title state; Android must use its own native list/navigation semantics rather than copying that implementation.

Feed icons, including available normal/dark variants from Core, should be used by native clients rather than independently deriving another icon model.

## 5. Article routing and Reader

Link/Reader choice and feed-specific detail-rendering preferences are shared product semantics. The native platform chooses the appropriate browser presentation.

Supported article actions should preserve current Core/native semantics where available, including open original, explicit Reader, comments, open in Miniflux, copy link, native share, and configured Miniflux third-party-service actions.

Do not copy an Apple browser implementation to Android or vice versa; preserve the routing behavior and use the native platform facility.

## 6. Mark as Read on Scrollover

Scrollover is a product behavior, not an Apple-specific gesture implementation.

The intended semantic rule is:

> An unread article that has satisfied the exposure/qualification requirement and is then genuinely moved completely past the upper Scrollover boundary by user-initiated forward scrolling is marked as read.

Required invariants:

- sufficient exposure/qualification is required; merely jumping past an unseen article must not mark it read;
- qualification survives a scroll-direction reversal;
- crossing geometry is rebased across direction reversals so stale motion does not cause missed or false crossings;
- reverse movement must not mark an article read;
- a valid forward crossing emits the read action exactly once;
- programmatic list movement, scope resets, layout changes, and structural row removal must not count as Scrollover;
- fast movement may process multiple genuinely crossed, already-qualified articles but must not qualify unseen articles merely because they were skipped;
- Undo semantics remain available where the native client exposes Scrollover.

Each platform should implement these semantics using its native scroll/geometry facilities. SwiftUI/UIKit tracker details are not part of the Android contract.

## 7. Swipe actions

Swipe behavior is represented as semantic article actions rather than hard-coded UI positions.

The mobile contract supports zero, one, or two configured actions per side. Visual order is inner-to-outer; the outer action is the Full Swipe action.

Interaction semantics:

- a normal/partial swipe reveals available action controls and performs no mutation by itself;
- tapping a revealed action executes it;
- a deliberate Full Swipe executes the outer action directly;
- reversing an open swipe first closes/crosses the neutral position before revealing the opposite side;
- platform implementations should use native-feeling thresholds, animation, and feedback.

Current default actions are Read/Unread and Star/Unstar on their established sides. Future configuration must preserve the semantic action model rather than storing platform widget details.

## 8. Scope-level Mark as Read

`Mark All as Read` is a mutation action and is not part of Filter/Sort presentation controls.

`Mark All as Read & Next` is an explicit workflow action, not the default behavior of Mark All as Read.

Its semantics are:

- Feed scope: mark the current Feed read, then navigate to the next Feed in visible navigation order;
- Category scope: mark the current Category read, then navigate to the next Category in visible navigation order;
- All News, Starred, Search, and Listening List do not invent a `Next` target;
- there is no wrap-around at the end;
- if no next sibling exists, the `& Next` action is unavailable;
- mutation must succeed before navigation occurs;
- plain `Mark All as Read` never changes scope.

## 9. Semantic mobile actions and overflow

Mobile UI actions should have stable semantic identities independent of where a platform presents them. Current/future examples include:

- `sync`;
- `filterAndSort`;
- `search`;
- `listeningList`;
- `markAllRead`;
- `markAllReadAndNext`;
- `settings`;
- `more`.

The default iOS Bottom Action Bar currently uses Sync, Filter/Sort, and More. This exact layout is not an Android requirement.

Future toolbar/action configurability may promote supported semantic actions into direct slots. An always-available overflow path must preserve access to actions that are not shown directly. Do not persist concrete SwiftUI/Compose control identities as the configuration model.

Listening List functionality itself belongs to the media phase; representing its semantic action does not move media implementation into an earlier phase.

## 10. Platform-native implementation rule

Shared semantics define **what the user-visible behavior means**. Platform implementations define **how that behavior is expressed natively**.

Examples that remain Apple-specific and must not become Android architecture requirements include:

- `IOSArticleNavigationHost` and Large Navigation Title identity repair;
- `UINavigationController` lifecycle details;
- custom `UIPanGestureRecognizer` implementation;
- SwiftUI observation/per-row invalidation mechanics;
- Apple-specific ScrollView geometry integration.

Likewise, future Android/Compose-specific workarounds must not become requirements for the Apple client unless they reveal a genuine shared product/Core semantic.
