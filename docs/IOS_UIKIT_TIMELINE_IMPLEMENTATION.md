# iOS UIKit Timeline — Decision and Implementation Handoff

> **Decision accepted: 2026-09-11. Implementation: NOT STARTED by this amendment.**
>
> Build the Article Timeline using an owned `UICollectionView` and native UIKit
> article cells. This is the selected architecture, not a proposal to benchmark
> against the existing SwiftUI `List`. This file explains the amended contracts
> and provides an executable work sequence for a subsequent coding agent.

## 1. Read first: intent and authority

The native iOS/iPadOS app is unpublished. It will replace the existing Flutter
FluxNews app. The owner is deliberately using this period to remove technical
debt and framework limitations. Long-term performance, predictable geometry,
and direct control over updates take priority over preserving current Timeline
code or minimizing the immediate implementation effort.

The decision is **UIKit for the Timeline container and its article cells**.
Do not restart the List-versus-UIKit discussion, require an expensive comparison
study before implementation, or first optimize the old renderer as a gate.
This does not assert that UIKit is automatically faster in every app. Actual
correctness and scrolling quality must be verified on the selected implementation.

Read these files in order before editing code:

1. [AGENTS.md](../AGENTS.md).
2. [ARCHITECTURE_DECISIONS.md](ARCHITECTURE_DECISIONS.md), especially sections
   2, 4, 4.1, and 5; this remains the highest architecture authority.
3. [PHASE_D_NATIVE_IOS_IPADOS.md](PHASE_D_NATIVE_IOS_IPADOS.md), especially the
   UIKit Timeline contract in section 5 and the D4.4 acceptance requirements.
4. This handoff and the current source files named below.

This handoff is subordinate to those contracts. It must not introduce a second
product specification. The older
[Flux_iOS_Scrollover_Analyse.md](Flux_iOS_Scrollover_Analyse.md) is historical
evidence; its conditional migration advice and optional SwiftUI cell hosting
are superseded. Required iOS Scrollover semantics are already decided in Phase D.

Only the iOS Article Timeline renderer, geometry integration, and associated
mutation scheduling are reopened. Core/macOS architecture, UniFFI, iOS 18.0,
existing product capabilities, and the safe Flutter data-upgrade contract remain
binding. An unpublished native app does not authorize deleting or rewriting
the existing Flutter production user's data.

## 2. Concrete architecture

| Responsibility | Required implementation |
|---|---|
| Timeline ownership | One UIKit view controller owning one `UICollectionView`, embedded in the SwiftUI shell through a narrow representable bridge. |
| Cell rendering | Native UIKit labels, image views, and status/accessibility presentation in reusable cells. Use a list configuration and list cells/custom native content to preserve system swipe actions. |
| Structural data | Stable Article IDs in a diffable data source, with presentation content keyed by ID. Apply structural snapshots only for actual snapshot adoption/reset/membership/order changes. |
| Read/starred state | One coherent native presentation overlay over the Core snapshot, keyed by ID. Update only relevant status and actions on a matching cell. |
| Geometry | An owned UIKit coordinator samples resolved cell frames and scroll movement within one layout generation. The detector is non-observable and independent of SwiftUI view updates. |
| Persistence | One serial, account/Core-session-owned executor using existing Core bulk mutations off-main; it outlives Timeline view recreation. |
| Images/icons | Reuse prepared-image, downsampling, caching, and deduplication infrastructure; integrate bounded UIKit prefetch and safe cancellation. |
| Other app surfaces | SwiftUI continues to own the existing navigation, Settings, Reader/Search presentation, sheets, and other surfaces. |

Do not use `UIHostingConfiguration` or a `UIHostingController` per Timeline
article cell. This is a decision to control the rendering path, not a claim that
hosting is universally slow. Do not replace `List` with `LazyVStack`, install a
third-party list framework, override the internal delegate of a SwiftUI control,
or build custom scroll physics. UIKit retains system scrolling, reuse, native
swipes, context menus, and refresh integration.

Use the smallest durable set of types needed to separate controller/renderer,
geometry detection, and mutation execution. These are presentation and scheduling
objects, not a new durable Swift domain model. Reuse or extract current logic
where it already satisfies the contract; do not run two mutation queues or two
production Timeline implementations in parallel.

## 3. Rules for the performance-sensitive path

### Geometry and read detection

- Use scroll offset, effective viewport/insets, and resolved row frames in a
  common coordinate system. Observe actual user movement and deceleration.
- A normal read candidate was genuinely visible and then crossed completely
  above the effective upper boundary during forward movement. A prefetched,
  prepared, or merely skipped row is not qualified. Cell lifecycle callbacks
  may maintain bookkeeping but are never the sole read signal.
- Evaluate currently visible and just-exited rows from a consistent layout
  generation. Retain enough prior resolved geometry to handle a row that has
  already left the reuse/display set. Retire that geometry when no longer needed.
- Direction reversal must preserve qualification and associate crossings with
  the correct motion. Do not use a stale last-direction flag to discard a
  crossing before the matching geometry is considered. Small valid movements
  must accumulate; a 0.5-point tolerance per callback must not suppress an
  arbitrarily long slow gesture.
- Rebaseline for rotation, Dynamic Type, width/inset changes, snapshot resets,
  and scroll-anchor corrections. Separate baseline validity from the real scroll
  phase so detection resumes during the same gesture once geometry is valid.
- Bottom completion applies only to observed trailing rows at a genuine forward
  arrival. It is tied to that arrival/layout and ends when moving backward,
  leaving the bottom, ending the interaction, or invalidating the layout. An
  initially short list or a programmatic/reset arrival does not mark its rows.
- No per-row timers or debounce delays determine exposure/crossings. Do not
  force a full `layoutIfNeeded()` pass or query Core from `scrollViewDidScroll`.

The sensor's work is proportional to the current/recent viewport, not all 8,000
articles or all rows seen since opening the list. The pending-write collection
and structural ID/content metadata are separate from that geometry
window; do not confuse required snapshot storage with per-scroll iteration.

### Cells, layout, and images

Separate immutable content/layout inputs from mutable read/starred state.
Prepare formatting and reusable layout information outside the scroll callback.
Reuse measurements while content revision, available width, Dynamic Type,
presentation mode, preview-line setting, and other relevant sizing inputs match.
Preserve variable-height articles and accessibility; do not force every row to
a single fixed height to conceal sizing work. Image loading must use fixed slots
for each cell's selected layout and must not change cell height on completion.

For a status-only read/starred change, update the ID-keyed state first. An
offscreen article needs no cell update. A matching visible/prepared/reappearing cell obtains the
latest state during its normal configuration/display lifecycle; update only
its small status and action/accessibility surfaces. Do not reapply the full
diffable snapshot, reload all items, or reconfigure/remeasure article text and
images because one read flag changed.
An explicit manual action that removes a row under the existing Remove When
Read/Starred-scope rules performs a separate structural change. Preserve that
behavior; ordinary Scrollover must never remove rows, including after idle.

Async image results identify an Article ID, content/request identity, and a
current consumer. Never retain a cell/index path and blindly update it after
an await: it may now represent another article. Cancel obsolete prefetch
consumers without canceling a shared request still needed by a visible cell.
Keep prepared-image and auxiliary caches bounded, including after a long scroll.
Prefetch planning reacts to relevant window/size changes and remains available
when Scrollover is disabled. The compact mode must avoid image-planning work.

The SwiftUI bridge receives semantic revisions/inputs, not continuously changing
offsets or per-row positions. SwiftUI updates to navigation, badges, or overlays
must not recreate the controller or reapply an unchanged article snapshot.

### Mutation execution and feedback

Adapt/extract the existing scheduler into one session-owned worker with a
controllable writer seam for tests. A synchronous UniFFI call must execute on
an appropriate background executor; placing it on an actor is not by itself
proof that the main thread or cooperative executor is safe from blocking work.

At acceptance, retain Article ID, target read value, account/Core-session
identity, origin presentation generation, and read-intent ordering/revision.
Equivalent representations are fine; the semantics are required. Capture the
origin when enqueuing, not when a delayed batch starts. Mixed-origin batches
must retain their feedback attribution. Enforce the existing 64-ID maximum at
dequeue, continue serially, and deduplicate/coalesce only when ordering and
feedback ownership remain correct.

Do not wait indefinitely for scroll idle: bound the scheduling delay for a small
buffer and additionally drain on idle and lifecycle transitions. This bound
does not imply that a blocked Core operation completes within a fixed time.
Batch timing is separate from read detection and Undo product qualification.
Record persistence parameters centrally and test their behavior; do not add
unrelated user settings or per-article timers.

Explicit Read/Unread and Undo must participate in the relevant per-article
ordering. A newer Unread must win over an older queued automatic Read. If the
older operation is already running, preserve the newer local overlay and ensure
the final persisted state follows the newer intent. Reject stale success/error
feedback by session, origin presentation, and intent revision. A changed view
discards obsolete feedback, not accepted writes. Keep starred/read field
semantics separate when resolving conflicts.
Re-arm an explicitly marked-unread/undone article for a future genuine crossing;
do not immediately read it again because of a status callback or a reset.

An account boundary must never replay old IDs into a new Core. Account removal,
rebuild, and normal session teardown have different existing semantics: handle
pending work explicitly with the original session and preserve their contracts.
Foreground-to-background handling must attempt a real local flush within the
available OS lifecycle; launching an unstructured Task is not a flush result.
Do not claim uncommitted state survives an abrupt process kill or add a Swift
database/Miniflux implementation to make such a claim.

Preserve the current iOS Undo rules: qualification after at least three
successful unread-to-read mutations in the rolling one-second window; one
rolling active group; four-second inactivity expiry and fifteen-second maximum
lifetime. Detected candidates, already-read items, failed/stale operations, and
skipped unseen IDs do not qualify a new group. Do not redefine Undo from batch
size, candidate timing, or a new exposure timer. Preserve normal Core delivery
policy and local-success semantics; remote delivery is not a prerequisite for
rendering a local read intent.

Counts/Undo are separate from the article snapshot. Filter ignored Core events
before scheduling main-thread work, and coalesce nonessential presentation
publication so it does not create scroll-frequency UI work.

## 4. Source map and reuse boundaries

Planning baseline: `b9a58fdf2fd7a44d25617371f81e23060381ac1c`. Inspect the current
HEAD before implementing; this hash documents the reviewed starting point,
not an instruction to reset or overwrite later work.

| Current path | How it relates to the replacement |
|---|---|
| `apple/ios/FluxNews/ArticleListView.swift` | Current List, `IOSScrolloverGeometryController`, prefetch metadata/coordinator, article renderer, Undo overlay. Replace Timeline-only rendering/sensing and reuse product/layout knowledge. |
| `apple/ios/FluxNews/NewsreaderStore.swift` | Stable snapshots, per-row presentation, Core operations, pending writes, generations, Undo/counts. Refactor the existing ownership/scheduling; do not create a second source of truth. |
| `apple/ios/FluxNews/ContentView.swift` | Timeline entry point, iPhone/iPad shell, native navigation host and reset behavior. Preserve the shell's product behavior when embedding the new controller. |
| `apple/ios/FluxNews/ArticleImagePipeline.swift` | Existing ImageIO downsampling, memory cache, request deduplication and prefetch. Adapt consumer lifetime/cancellation as required. |
| `apple/ios/FluxNews/SearchView.swift` | Still calls `ArticlePresentationView` with fallback read/starred state. Keep Search working; move still-used SwiftUI rendering to an appropriate file before deleting Timeline-specific code. |
| `apple/shared/FluxApple/` | Existing shared presentation policies and macOS exposure tracker. Reuse actual shared semantics; do not transplant macOS geometry/timing or broadly refactor macOS. |
| `apple/ios/FluxNewsTests/NewsreaderD23MutationTests.swift` | Current detection and mutation tests. Preserve valid behavior coverage; replace old-sensor tests and fake array-draining helpers with tests of the new productive paths. |
| `apple/ios/FluxNewsTests/NewsreaderPresentationTests.swift` | Presentation, image/prefetch and related regression coverage; inspect current cases and keep relevant guarantees. |
| `core/crates/flux-core/src/lib.rs` | Existing `set_read_state_bulk` domain boundary. Use it; do not add a Scrollover-specific Core API or change frozen delivery behavior as part of a renderer rewrite. |
| `apple/ios/FluxNews.xcodeproj/project.pbxproj` | Register new/moved sources and tests as required by the existing project. |

Keeping a SwiftUI renderer used by the separate Search screen is not keeping
two Timeline implementations. Remove genuinely unused Timeline types only after
checking all call sites. Keep English/German localization and existing actions.

## 5. Ordered implementation packages

These packages build one permanent replacement. They are not competing renderer
experiments. Each implementation package includes its relevant tests/build;
do not defer correctness until the final package.

| Package | Scope and completion gate | Status at this amendment |
|---|---|---|
| U1 — Contract | Record UIKit container/native cells, rationale, boundaries, behavior, and this handoff. | COMPLETE — documentation only |
| U2 — Native Timeline | Implement the owned controller, bridge, native reusable cells, stable ID snapshots, sizing, image consumers, system swipes/context menus/refresh, and existing shell integration. Register sources and preserve Search dependencies. | PENDING |
| U3 — Geometry and status | Implement the coherent UIKit detector and targeted status path. Connect it to existing mutation entry points; cover the geometry regression cases below and stable heights/membership. | PENDING |
| U4 — Session mutation worker | Complete queue lifetime, origin attribution, bounded drains, explicit-action ordering, lifecycle and failure handling using a controllably blocked real writer path in tests. | PENDING |
| U5 — Cleanup and acceptance | Remove superseded Timeline code, verify complete interaction/localization/accessibility behavior, run native checks and focused device traces, record actual remaining limitations. | PENDING |

The selected architecture already includes U2-U4; no new architecture approval
is required simply because UIKit replaces the old implementation. If the user
requests one package, implement that package and its validation without silently
expanding to unrelated phases. Temporary work-in-progress on a branch is not a
supported production fallback. Do not mark the amendment complete until the
replacement and required acceptance are complete.

## 6. Required regression cases

The first six rows preserve concrete findings from the reviewed geometry/queue
implementation. These are expected outcomes, not a requirement to port its bugs
or exact internal types.

| Case | Required result |
|---|---|
| Reach bottom, reverse away, then move forward without ending the gesture; a previously unread row becomes visible far from bottom. | No read merely from visibility; bottom completion is disarmed. |
| Visit 8,000 rows, with only a few currently/recently visible; repeat scroll samples, including compact mode. | Geometry/prefetch processing does not traverse all visited rows; relevant windows and caches remain bounded. |
| A visible row crosses above after backward-to-forward reversal; deliver the equivalent lifecycle/layout notifications in different orders. | One identical qualified read for the same coherent movement, without duplicates or losses. |
| Repeated forward increments of 0.25 or 0.5 points eventually cross a row. | Movement accumulates and produces one read; no need for a later large delta or another row callback. |
| A row/container size changes during interaction or deceleration, then movement continues without an artificial new phase transition. | Resize emits no read; fresh valid geometry permits subsequent real crossings in that same interaction. |
| Batch A runs, B waits, the view/scope resets, then A and B finish. | Both accepted batches persist in their original session; neither publishes obsolete Undo/errors into the new presentation. |
| Initial/short list, reset/programmatic bottom arrival, backward movement, unseen rows skipped in a fast flick. | No invented exposure or automatic reads. Preserve the narrow genuine-forward terminal exception. |
| Content/insets change while an article straddles the boundary; immediately reverse, scroll again, or rotate. | No false crossings, stale terminal state, lost scroll phase, or invalid anchor movement. |
| Status-only read/starred changes and Scrollover on visible and reused/offscreen cells. | Correct ID/state/accessibility and stable height/membership; no whole-snapshot or full-content reconfiguration. Explicit manual removal follows its separate existing structural rule. |
| Auto-Read is queued/running, then explicit Unread or Undo occurs; resolve older success/failure afterward. | Newer intent wins in both local presentation and final persisted state. |
| More than 128 accepted IDs, including duplicates and different origin generations. | Serial batches of at most 64, ordered continuation, no dropped tail, correct attribution. |
| Continuous slow scrolling with fewer than 64 pending IDs; then background/view recreation. | Bounded drain attempt and lifecycle flush; no dependency on an idle event to begin persistence. |
| Old-session completion after a new account/Core attaches. | No old IDs sent to the new Core, no feedback into the new session, and no unexplained loss during normal view recreation. |
| Async image completion after cell reuse or prefetch cancellation, including another consumer of the same request. | Correct article/request image, no canceled visible consumer, no height jump or unbounded cache/history. |
| Core events, counts and Undo updates while scrolling. | Ignored events are filtered before main-thread dispatch; no structural article reload from ordinary feedback. |
| Native swipes/full swipe, menus, refresh, routing, Large Titles, iPad split view, Dynamic Type, VoiceOver, Reduce Motion and localization. | Existing product behavior remains usable and correct across compact/visual layouts. |

Queue tests must exercise the actual running flag/serialization and asynchronous
continuation through an injectable, controllably blocked writer. Calling a
`ForTesting` helper that merely pops an ID array is insufficient. Test callback
and intent ordering, not only happy-path helper outputs. Add assertions/counters
where useful to detect full-snapshot work and unbounded geometry iteration;
avoid fragile wall-clock microbenchmarks as substitutes for behavior tests.

## 7. Validation and completion report

Use the existing Apple packaging/build path and `apple/ios/Build/test.sh` on a
Mac with the required toolchains. That script invokes the canonical UniFFI
packaging script and runs the Debug XCTest scheme; it is not a Release-device
performance measurement. Select an available simulator with the script's
existing `DESTINATION` mechanism when necessary. Run `git diff --check`.

For acceptance, exercise an optimized Release build on representative iPhone
and iPad hardware with long feeds, compact/visual modes, warm/cold image caches,
slow crossings, fast flicks, reversals, rotation and background/foreground work.
Use the available device/OS Instruments tools for short traces of actual hitches,
main-thread work, and memory behavior. Include 60-Hz and 120-Hz hardware when
available. The relevant goals are bounded scroll work, no repeated
Scrollover-caused frame misses in the exercised cases, stable geometry, and
correct durable mutations. Do not promise every frame at maximum refresh based
only on unit tests or on the choice of UIKit.

No preliminary benchmark of the retired renderer is required. Measurement here
verifies and guides corrections to the selected implementation. If hardware or
Xcode is unavailable, report exactly which build/device checks remain pending;
do not substitute a Python model or simulator for completed real-device evidence.

After each requested package, report the changed files and resulting behavior,
tests actually executed, unresolved regressions, and the next incomplete
package. The docs-only U1 commit does not fix the current app's scrolling.

## 8. Apple references

- [Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/): stable identities, cell lifecycle, preparation, prefetch, image handling and targeted updates.
- [Lists in UICollectionView](https://developer.apple.com/videos/play/wwdc2020/10026/): list configurations, native cell content and system swipe integration.
- [Use SwiftUI with UIKit](https://developer.apple.com/videos/play/wwdc2022/10072/): hosting and self-sizing background; useful context for the deliberate native-cell decision, not an instruction to host Timeline cells.
