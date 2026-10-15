# Post-Replacement Stabilization and Store-Readiness Plan

> **Status: PLANNED / NOT YET IMPLEMENTED**
>
> **Baseline:** `main` at `9bd6ea9b6b72ea435555e0df74e812d7755c4042` (11 October 2026).
> This is an implementation plan, not a claim that the defects have been reproduced,
> builds have succeeded, or app-store submission has been accepted.
> **C3 scope revised on 12 October 2026:** feature parity is now explicitly
> approved; see MACOS_C3_FEATURE_PARITY_ROADMAP.md for current macOS work packages.
> Other workstreams retain their own implementation/acceptance status.
>
> **Relationship to existing contracts:** `ARCHITECTURE_DECISIONS.md` and the
> frozen Phase B/C/D/E and `MOBILE_PRODUCT_SEMANTICS.md` contracts retain their
> existing authority. This plan records focused post-E9 corrective and product
> follow-up work; it does not reopen accepted Flutter-to-native migrations.
> `RELEASE_DISTRIBUTION.md` remains the authority for release-script interfaces,
> signing and publication.

## 1. Explicit product decision: macOS starts fresh

**FluxNews for macOS has not been released to users.** Existing macOS data are
limited to the developer's local machine. The owner explicitly accepts losing
those local development data when sandbox support is enabled.

Therefore:

- **Do not implement a macOS data migration**, `container-migration.plist`,
  copy from the former unsandboxed `Application Support` directory, or a
  fallback/compatibility storage path.
- A clean sandbox-container initialization is the intended behavior. Treat an
  empty database, cache, download directory and freshly configured credentials
  on the developer machine as acceptable.
- Test a first launch with fresh account setup, sync, media downloads, playback,
  widget sharing and restart persistence *inside* the sandbox.
- Do not preserve developer Keychain entries merely to avoid entering account
  credentials again. Do verify the new sandboxed app can **save and subsequently
  read** credentials reliably.
- Keep the existing production bundle/App Group identifiers as required by
  the release contract unless an explicit signing/provisioning constraint
  requires a separate, reviewed change.
- The existing Developer ID signing/notarization script and the proposed Mac
  App Store export are different distribution paths. Do not assume a Developer
  ID app can be upgraded into the App Store app or that such a migration is
  required before first release.

The no-migration decision is **macOS-specific**. It must not weaken the
already accepted iOS/Android in-place Flutter-to-native upgrade guarantees.

## 2. Planned work order and gates

| ID | Priority | Target | Required outcome | Depends on |
| --- | --- | --- | --- | --- |
| A1 | P0 | iOS + macOS | HTTP-only media/image behavior verified and intentionally handled | — |
| A2 | P0 | Rust + Apple | Event subscriptions released safely on lifecycle changes | — |
| A3 | P0 | Android | Download network-policy changes update pending WorkManager constraints | — |
| A4 | P0 | CI | Native-host Rust fmt/test/clippy checks gate Core changes | — |
| B1 | P0 before Mac App Store release | macOS | Sandboxed app works with fresh developer data | A1/A2 validation as applicable |
| B2 | P0 before F-Droid workflow | Android/F-Droid | Build-system and scanner feasibility proven | A4 recommended |
| C1 | P1 | Android | Seven-language UI localization and locale checks | A3/A4 |
| C2 | P1 | Android | Create feed/category from native UI | A4 |
| C3 | P1 | macOS | Approved cross-platform feature-parity checklist delivered and tested | Feature code independent of B1; signed release acceptance requires B1 |
| C4 | P2 | Shared/clients | Focused tech-debt and lifecycle improvements, backed by evidence | Earlier relevant gates |
| R | Release track | All platforms | Unified store scripts and publication workflows | B1 for macOS; B2 for F-Droid |

P0 denotes work to resolve before the **relevant release**, not an assertion that
all platforms must block each other's releases. Where independent, use
separate focused PRs and run only the affected platform gates plus Rust gates.

## 3. A — Stability, correctness and regression coverage

### A1 — Apple App Transport Security and HTTP-only resources

**Evidence:** iOS/macOS application Info.plists currently contain no ATS policy
exceptions. The apps use different HTTP clients depending on their operation:
URLSession image and download paths and AVFoundation playback.

**Implementation:**

1. Establish controlled HTTP-only test endpoints for an article image, podcast
   enclosure download and podcast playback/streaming. Check both iOS and macOS.
2. Record what actually works/fails and which Apple API handles each request.
   Also check redirects where relevant. Distinguish HTTP-only content from
   a plain-HTTP Miniflux server address.
3. Define a narrow, defensible ATS policy. The media-only AVFoundation exception,
   if used, **does not cover URLSession**; do not incorrectly treat
   `NSAllowsArbitraryLoadsForMedia` as a universal fix.
4. Prefer HTTPS when available. If supporting arbitrary HTTP-only feed media is
   necessary, document the scope and privacy/security trade-off of the
   appropriate exception, and test the exact behavior. Preserve the explicit
   unencrypted Miniflux-server warning; do not silently normalize insecure
   account connections.
5. Add practical regression coverage (fixture/integration test or explicit
   device acceptance where an automated test is not possible).

**Done when:** iOS and macOS load or deliberately reject each tested HTTP-only
image, streaming and download case as documented; HTTPS still works; no broad
ATS exception is introduced without an explicit reason.

### A2 — Rust UniFFI EventSubscription and Apple lifecycle

**Evidence:** Rust `EventSubscription` currently exposes `unsubscribe()`
without a `Drop` implementation. Android explicitly unsubscribes and closes
its handle; Apple clients have paths that only set subscriptions to `nil`.
Some Apple event listeners hold a strong reference to the Flux Core.

**Implementation:**

1. Map all macOS/iOS `subscribeEvents` and `eventSubscription` ownership paths,
   including newsreader, media runtime, widgets, account changes and resets.
2. Explicitly call `unsubscribe()` before replacing/releasing the subscription
   on Apple; avoid races with in-flight event callbacks. Consider Rust `Drop`
   as a defensive fallback, with tested idempotence, rather than relying on
   garbage collection or assuming assigning `nil` unregisters listeners.
3. Remove unnecessary strong listener -> Core references and use
   generation/lifecycle guards to discard stale callbacks.
4. Validate account replacement, local rebuild, detach, widget refresh and
   repeated reopen: old listeners stop receiving events and old Core handles
   become releasable. Use memory diagnostics to distinguish a real SQLite
   retention issue from the currently unverified hypothesis.
5. Preserve Android's explicit unsubscribe/close behavior.

**Done when:** lifecycle and repeated-attach tests demonstrate one intended
listener per owner, no stale callbacks, no regressions to sync/widgets/media,
and no retained retired Core session.

### A3 — Android WorkManager constraints when download policy changes

**Evidence:** `AndroidMediaTransferCoordinator.reconcile()` enqueues unique
transfer requests using `ExistingWorkPolicy.KEEP`. Switching from
`UNMETERED_ONLY` to `ANY_NETWORK` does not replace already-enqueued requests
with the old network constraint.

**Implementation:**

1. Add a reproducible test: queue download on unmetered-only; while pending,
   change to any network; verify the download becomes eligible on mobile data.
   Test the reverse policy change too.
2. Reconcile the pending work *when effective constraints change*. Do not
   replace every WorkRequest unconditionally during frequent reconciliations.
   Make sure running downloads are not repeatedly cancelled, duplicated or
   restarted due only to state refresh.
3. Preserve cancellation, progress and Core-owned download state; cover queued,
   running and completed work separately.

**Done when:** policy changes affect pending transfers immediately and
running/completed transfers retain correct semantics on both network types.

### A4 — Dedicated Rust regression gate in CI

**Evidence:** `apple.yml` and `android.yml` compile the Rust bindings as
part of native builds; their current test scripts do not run workspace
`cargo test`, `cargo fmt` or `cargo clippy` as independent CI gates.

**Implementation:**

1. Add one shared, native-host Rust job/workflow triggered by changes to
   `core/**` and its own workflow, and required for relevant PR checks.
2. Run at least:
   - `cargo fmt --manifest-path core/Cargo.toml --all --check`
   - `cargo test --manifest-path core/Cargo.toml --workspace`
   - `cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets`
3. Pin the intended toolchain and cache safely. Check whether strict Clippy
   warning-as-error can be enabled without unrelated baseline cleanup; do not
   silently enable a gate that fails on existing warnings.
4. Keep native Apple/Android regression workflows as separate platform gates.
   Avoid re-running identical host-Rust tests in each Apple and Android job.

**Done when:** a PR that changes Rust fails on a Rust regression in CI
independently of UniFFI compilation, while native tests remain intact.

## 4. B — Prerequisites for distribution

### B1 — Enable the macOS App Sandbox before App Store export

**Evidence:** `apple/macos/FluxNews/FluxNews.entitlements` contains the App
Group entitlement, but not `com.apple.security.app-sandbox`. The existing
`apple/macos/Build/release.sh` signs/notarizes via Developer ID. The widget
already uses its own sandbox entitlement.

**Implementation:**

1. Enable sandbox for the macOS **host app** and verify it is present in the
   final signed entitlement set; preserve/verify the widget sandbox and the
   existing application-group capability.
2. Add the required outbound `com.apple.security.network.client` entitlement
   for Miniflux, images, podcasts and downloads. Review any other capabilities
   against actual native operations rather than adding permissions speculatively.
3. Audit configuration backup export/import, user-selected file dialogs,
   temporary files, downloads, app support/cache, file permissions and
   App Group/widget data exchange. Add the narrow user-selected file
   read/write entitlements if testing shows they are needed.
4. Verify provisioning/signing matches the App Group for Mac App Store
   distribution. **Do not equate Developer ID with Mac App Store signing.**
   Retain the existing Developer ID path until intentionally changed, and
   test its sandbox-compatible behavior independently if it remains supported.
5. Start the sandboxed app from a **fresh account**; initialize all Core
   persistent/cache/media directories in the sandbox, sign in again, sync,
   download, play, use widget, export/import a backup and restart.
6. Document deliberate loss of the developer machine's old unsandboxed data.
   **No migration, `container-migration.plist`, file-copy shim or backwards
   compatibility path is in scope.**
7. Only after sandbox acceptance, implement macOS archive/export/Transporter
   scripts according to `RELEASE_DISTRIBUTION.md`.

**Done when:** fresh sandbox install and relaunch function end-to-end, Core
state and credentials persist within the container, file dialogs work, the
widget shares data correctly, and the correctly entitled/provisioned Mac App
Store artifact can be exported and validated. The absence of an old-data
migration is not a failure.

### B2 — F-Droid reproducibility/scanner feasibility before publishing

**Evidence:** Android resolves the pinned
`rustls-platform-verifier-android` Maven AAR by calling `cargo metadata`
during Gradle settings evaluation; JNA is also used as an AAR. These are
risks to audit, **not proof** of F-Droid scanner rejection.

**Implementation:**

1. Review current F-Droid policy, build-server toolchain and source/repo
   requirements against pinned Android Gradle, Rust, Cargo/NDK, JNA and
   rustls-platform-verifier components.
2. Run a representative source build and F-Droid scanner/metadata validation
   using the intended build environment, recording exact failures.
3. Ensure all required Cargo and Gradle dependencies are resolved by an
   approved, reproducible path. Test `cargo metadata` under restricted/offline
   build conditions after dependency preparation. Use vendoring only if
   needed and compatible with the final distribution model.
4. Verify provenance/allowability of both included AAR/native components and
   whether any prebuilt library must be compiled from source.
5. Preserve the existing F-Droid package identity, signing/update guarantees
   and source metadata. Verify a signed update over the Flutter F-Droid app;
   do not reuse Play signing by assumption.
6. **Only after passing this feasibility gate**, implement the native F-Droid
   prepare + build/verify + separately triggered publish workflow using the
   shared release scripts.

**Done when:** repeatable F-Droid-style build and scanner pass, dependencies
and source requirements are documented, and Flutter-to-native signed update
compatibility is demonstrated before publication automation replaces legacy.

## 5. C — Product parity and quality improvements

### C1 — Android localization

Extract user-visible Android text into resources (including settings, readers,
navigation, download UI, notifications and widgets). Cover the **seven target
languages specified by the mobile product contract**, with locale-sensitive
pluralization, dates and accessibility labels. Resolve translation ownership
and review; do not present unreviewed machine translations as finished.

**Done when:** all supported languages are selectable by Android locale,
there are no substantive untranslated/hard-coded UI surfaces and targeted
locale/UI tests pass.

### C2 — Android feed and category creation

Expose native add-feed/add-category flows using existing Core/UniFFI domain
APIs, including input validation, errors, categories and navigation refresh.
Do not duplicate Miniflux API/persistence in Kotlin. Follow the product
contract and existing native Android navigation patterns.

**Done when:** feeds/categories can be created from the Android UI, appear in
navigation after success and survive sync/restart; failure and duplicate
cases are handled.

### C3 — macOS feature-parity completion (approved scope)

**Decision (12 October 2026):** Functional parity with iOS/Android is the
default; macOS retains native menu-bar/window controls rather than copying
mobile UI layouts. **Bulk feed preferences, scope-wide Mark All as Read and
Mark All as Read & Next are explicitly in scope**, not optional follow-ups.

The controlled source-based inventory, order of work, per-PR quality gates and
real-Mac acceptance checklist are in
[MACOS_C3_FEATURE_PARITY_ROADMAP.md](MACOS_C3_FEATURE_PARITY_ROADMAP.md).
Work packages cover: scope bulk-read and Starred filter; multi-feed editing;
download totals, cancellation, policy and retention; diagnostics/redaction;
HTTP account warning, About and player 15/30-second controls; background-sync
recovery; locale/accessibility and functional acceptance.

**Dependency clarification:** C3 feature code can be developed/tested before
B1. **B1 signed fresh-sandbox acceptance remains mandatory before Mac App
Store distribution**, not before beginning C3. Do not add a macOS migration.

**Done when:** accepted C3 features are tested and merged, current macOS
Apple CI is green, real-Mac functional acceptance is recorded, Core remains
authoritative, and any explicit deferrals are documented.

### C4 — Focused follow-up technical debt (not release blockers by default)

- Audit `REMOTE_WORKERS = 1` and unbounded event mailboxes with actual latency/
  memory evidence; don't increase concurrency blindly or drop correctness events.
- Consider a download-worker shared OkHttp client, resumable transfers and
  better foreground notification behavior only if separately justified.
- Track Swift 6 strict concurrency migration as its own measured effort.
- Review `SavedMedia` UniFFI callers and the Phase-B frozen domain semantics.
  Removing unused outward-facing functions must not remove needed Core
  persistence/retention/optional sync behavior without a deliberate contract
  decision.
- Reconcile outdated article-image loading and Android network-client statements
  in architecture/phase docs, and remove obsolete workflow branch filters.
- Treat deprecation warnings as maintenance unless the target SDK or runtime
  demonstrates an actual break. Do not reopen the completed file-splitting work.

## 6. Validation and delivery discipline

Each focused PR must identify its baseline, affected contracts, changed files,
validation actually run and known remaining risks. Prefer targeted unit and
integration coverage before UI/device gates; never infer success merely from
code inspection. For cross-platform changes run the Rust checks and relevant
Apple/Android checks. For network, playback, storage, app signing and sandbox
changes include real-device or signed-artifact acceptance as appropriate.

**Sequencing with release work:**

- A1/A2/A3/A4: correctness and baseline CI first.
- B1 must finish **before** the macOS App Store build/export deliverable
  described in `RELEASE_DISTRIBUTION.md` section 7.
- B2 must finish **before** the native F-Droid publication workflow described
  in `RELEASE_DISTRIBUTION.md` section 5.
- Existing iOS/Android migration acceptance remains closed; no additional
  Flutter migration project is created.
- C1/C2 are explicit post-E9 Android product work, not claims that the
  historical E9 replacement-acceptance decision was never completed.
- No release script or workflow may publish by default.

## 7. Plan completion

This follow-up is complete only when P0 fixes are tested and merged, the macOS
sandbox passes a fresh-install acceptance without a migration, F-Droid build
feasibility is demonstrated, and the accepted C1/C2/C3 items are either
implemented with tests or explicitly deferred as separate decisions.
The separate release/distribution acceptance criteria still live in
`RELEASE_DISTRIBUTION.md`.
