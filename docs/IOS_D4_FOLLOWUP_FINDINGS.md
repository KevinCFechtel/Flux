# iOS D4 follow-up findings

Status: **D4 FOLLOW-UP COMPLETE / canonical iOS test gate passed**

This note records product and contract decisions found during the post-D5 gap
review against the native Phase-D contract and the former Flutter FluxNews
client. D5 is complete and architecture-frozen; these items are not D5 work and
must not reopen the frozen UIKit Timeline container, layout, image pipeline,
Scrollover detector, or mutation-worker architecture without concrete
regression evidence.

Flutter remains a behavioral reference, not a parity checklist. The decisions
below are explicit product decisions for the native iOS/iPadOS client.

## 1. Rebuild Local State — COMPLETE

D4.1 already requires **Rebuild Local State** and **Remove Account** as distinct
operations. Remove Account exists in native iOS; Rebuild Local State is still
missing from the native iOS orchestration and UI even though Core/UniFFI already
provide the operation.

Implementation contract:

- Add **Rebuild Local State** to native iOS Account settings with an explicit
  confirmation step.
- Preserve Miniflux account association, Keychain credentials, global
  Core/native settings, and compatible account/feed preferences.
- Destructively clear reconstructable synchronized local state, pending
  mutations, notification bookkeeping, sync metadata, and regenerable caches as
  defined by the Core contract.
- Invalidate stale widget/cache projections before the rebuild.
- Immediately perform the Core-owned fresh Miniflux rebuild/sync.
- If that fresh sync fails, do not restore the discarded old synchronized
  dataset.
- Use the existing app-wide Core-session quiescence/execution coordination so
  account/session work cannot race the destructive rebuild.
- Do not reinterpret Rebuild Local State as Remove Account or as a general
  Factory Reset.

Implementation status:

- Native iOS Account Settings now exposes the confirmed Rebuild Local State action.
- `CoreBootstrapper` coordinates the operation without replacing the active
  Core or credentials.
- The app-wide Core-session gate enters quiescence first and holds the
  destructive `rebuildLocalState()` call as an exclusive blocking operation.
- Widget and Newsreader projections are invalidated before the rebuild and
  reattached to the same Core afterward, on both success and synchronization
  failure.
- Focused AccountLifecycle tests cover credential/Core preservation, app-wide
  quiescence, and failure recovery.
- 

## 2. Native iOS mutation delivery mode — COMPLETE

The Rust Core already supports `DeliveryMode::Live` and
`DeliveryMode::Deferred`. Native iOS Read/Unread and Star/Unstar mutations,
including Scrollover bulk Read mutations, already use the Core
mutation/pending-delivery path.

Product decision:

- Native iOS defaults to **Live** mutation delivery.
- Add a native Settings switch that allows the user to disable immediate
  delivery. Disabled maps to the existing **Deferred** mode.
- The iOS default must be established at the iOS product boundary; do not change
  the global Rust Core default solely for iOS.
- The chosen value must persist across launches. A one-time iOS initialization
  must not later overwrite an explicit user choice.
- Local persistence remains authoritative and immediate; UI/count/widget
  feedback must not wait for the network.
- Live means attempting delivery of the already-persisted pending mutation to
  Miniflux immediately. It must not start a Full or Delta sync merely to deliver
  the mutation.
- Retryable remote/network failure leaves the mutation durably pending for the
  existing retry/reconciliation path.
- Scrollover keeps the accepted U4 worker contract: session-owned
  serialization, deduplication, maximum 64 IDs per Core bulk call, 500 ms
  bounded drain deadline, ordering/precedence, and failure recovery. Live mode
  must not become one Swift-side network request per crossed article.

This is a D4/U4 contract completion/configuration item, not a new sync
architecture.

Implementation status:

- Native iOS applies `DeliveryMode::Live` once as an iOS product default on the
  first native activation.
- A persisted iOS migration marker ensures later launches never overwrite an
  explicit user choice.
- Articles Settings exposes **Sync article changes immediately**.
- Enabled writes the existing Core `Live` mode; disabled writes `Deferred`.
- Reads and writes go through the existing app-wide Core-session execution gate.
- No Rust Core default was changed and no separate Swift delivery-mode state was
  introduced.
- The existing Core mutation path remains authoritative, so failed immediate
  delivery stays pending and no extra Full/Delta Sync is introduced.
- Focused tests cover first-start Live defaulting, preservation of explicit
  Deferred choice on later startup, and direct Core-backed preference reads and
  writes.
- 

## 3. UIKit Timeline swipe actions — COMPLETE

The fixed one-action-per-side implementation is incomplete relative to the
authoritative mobile interaction contract.

Implement the existing documented contract from `MOBILE_PRODUCT_SEMANTICS.md`:

- zero, one, or two configured semantic actions per side;
- inner-to-outer visual ordering;
- the outer action is the deliberate full-swipe action;
- partial swipe reveals actions without executing them;
- reversing direction crosses the neutral state before the opposite side;
- defaults retain the established Read/Unread and Star/Unstar semantics;
- action execution resolves the article by stable Article ID, never by a
  captured index path/cell.

Expose the configuration through native iOS Settings. This is interaction and
presentation configuration only and does not reopen the frozen Timeline
architecture.

Implementation status:

- Native iOS persists one semantic swipe configuration with zero, one, or two
  actions per side.
- Settings expose a **Full Swipe** slot and an optional **Additional Action**
  slot for leading and trailing sides.
- Stored order remains semantic inner-to-outer; the UIKit adapter reverses that
  order only at the native API boundary so the configured outer action is
  UIKit's first/full-swipe action.
- The established defaults remain leading Read/Unread and trailing Star/Unstar.
- Currently selectable actions are Read/Unread, Star/Unstar, Open Original,
  Open in Miniflux, Open Comments, Share, and Save to Third-Party Service.
- Open Comments is omitted for an individual row when that article has no valid
  comments URL.
- Search results consume the same persisted swipe configuration as the normal
  Article Timeline.
- The legacy **Download Audio** swipe action is intentionally not exposed yet:
  native iOS does not have the D6 media/download handler at this phase. D6 may
  add that semantic action to the existing configuration without changing the
  swipe architecture. No placeholder/no-op action is permitted.
- Focused tests cover 0-2 action normalization, duplicate suppression,
  persistence, outer/full-swipe mapping, and conditional action omission.
- 

## 4. Missing Core-backed article/settings controls — COMPLETE

Native iOS Settings must also expose the already-supported Core settings:

- **Read Article Retention**: 30 / 60 / 90 / 180 / 365 days.
- **Reader detail/truncation character limit**: 5,000 / 10,000 / 20,000
  characters, retaining the Core default of 10,000 unless the user chooses
  otherwise.

These are Settings-surface completions over existing Core capabilities; do not
duplicate the values in a second Swift domain model.

Implementation status:

- Native iOS Articles Settings now exposes Read Article Retention with the
  existing Core values 30 / 60 / 90 / 180 / 365 days.
- Native iOS Articles Settings now exposes the Reader detail/truncation limit
  with the existing Core values 5,000 / 10,000 / 20,000 characters.
- Both preferences are read directly from `coreSettings()` and written through
  the existing Core setters behind the app-wide Core-session execution gate.
- No duplicate Swift persistence/domain setting was introduced.
- The Core defaults remain authoritative when the user has not changed either
  value.
- Focused tests cover reading and writing both settings against the real Core.
- 

## 5. Configuration backup/restore — PHASE D, DEFERRED UNTIL SETTINGS STABILIZE

Configuration backup/restore remains required native iOS product capability
inside **Phase D**, but it does not need to block the current D4 follow-up
implementation.

The Rust Core/UniFFI backup contract already supports iOS. Native iOS UI and
platform orchestration are intentionally deferred to a late Phase-D completion
step after the Settings surface has largely stabilized and before D10 final
replacement validation. This avoids repeatedly revising export/restore mapping
while D6-D8 and the remaining settings work still add product configuration.

The eventual implementation must use the existing versioned Core backup format
rather than inventing an iOS-only backup schema.

## 6. Diagnostics, debug logging, and export — REQUIRED LATE PHASE-D CAPABILITY

Native iOS must provide a support-oriented diagnostics export and an explicit
**Debug Logging** switch.

Existing foundations:

- Rust Core diagnostics already emit `Trace`, `Debug`, `Info`, `Warn`,
  and `Error` records.
- Native iOS already uses Apple's unified `Logger` in several runtime
  components.

Target contract:

- Normal operation records bounded, privacy-safe support diagnostics at
  Info/Warn/Error severity.
- **Debug Logging** is OFF by default and persisted when explicitly enabled.
  Enabling it adds Debug/Trace-level diagnostic detail for Core and native iOS
  integration paths.
- Provide **Export Diagnostics** from Developer Diagnostics/Support UI.
- Export combines native and Core diagnostic records with useful support
  metadata such as app/build version and OS version.
- The support export must remain bounded and useful across a reproducing
  relaunch; do not rely solely on reading the current process's unified log.
- A bounded/rotating app-owned support log may be used as the export source
  while continuing to mirror appropriate events to Apple's unified logging.
- API keys, credential material, custom-header values, authorization data, and
  other secrets must never be written to or exported in logs.
- Provide a Clear Diagnostics action.

This capability may be implemented later in Phase D, but must exist before D10
replacement validation so real-device/support failures can be exported.

## 7. Curated feed onboarding — RETIRED

The former Flutter curated/suggested feed onboarding is intentionally removed.

Product decision:

- Do not implement a curated repository-maintained feed list in native iOS.
- Do not add it to macOS, Android, or future Flux clients.
- Feed creation/discovery remains based on the existing Miniflux/native feed
  management flow.
- Treat the legacy Flutter curated-feed surface as retired behavior, not an open
  parity gap.

## D4 follow-up acceptance

The immediate D4 follow-up implementation set is complete and accepted:

1. Rebuild Local State.
2. Live-by-default mutation delivery plus the user switch.
3. Full documented mobile swipe-action configuration contract.
4. Read-retention and Reader detail-limit Settings.

The canonical native iOS `./apple/ios/Build/test.sh` gate passed after the
combined implementation and the iOS-17 SwiftUI Section compatibility fix.

Configuration backup/restore and diagnostics export remain explicit **late
Phase-D** completion items rather than D4 blockers. Curated feed onboarding is
closed as intentionally removed.

## Scope guard

D5 Background Sync / Notifications / Widgets is complete and
architecture-frozen. None of these decisions reopen D5. A later implementation
chat must re-read the authoritative `docs/PHASE_D_NATIVE_IOS_IPADOS.md`,
current `main`, and this note before changing behavior.
