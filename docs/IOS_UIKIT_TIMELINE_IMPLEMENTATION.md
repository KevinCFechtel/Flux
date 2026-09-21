# iOS UIKit Timeline — Decision and Implementation Handoff

> **Decision accepted: 2026-09-11. U1-U2 COMPLETE. U3 IN PROGRESS. U4 COMPLETE. U5 IN PROGRESS / OPEN.**
>
> Build the Article Timeline using the owned UIKit `UITableView` Timeline and
> native UIKit article cells. This is the selected architecture, not a proposal to benchmark
> against the existing SwiftUI `List`. This file records the amended contracts
> and the remaining completion sequence. The current UIKit implementation is not
> architecture-frozen: unresolved physical-device performance work may still
> justify fundamental changes to Timeline layout, cell construction, image
> presentation, preparation/scheduling, or adjacent UIKit integration while
> preserving the frozen product semantics.

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
mutation scheduling are reopened. Core/macOS architecture, UniFFI, iOS 17.0,
existing product capabilities, and the safe Flutter data-upgrade contract remain
binding. An unpublished native app does not authorize deleting or rewriting
the existing Flutter production user's data.

## 2. Concrete architecture

| Responsibility | Required implementation |
|---|---|
| Timeline ownership | One UIKit view controller owning one plain `UITableView`, embedded in the SwiftUI shell through a narrow representable bridge. |
| Cell rendering | Native UIKit labels, image views, and status/accessibility presentation in reusable table cells. Preserve native table swipe actions, context menus, refresh, and reuse. |
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

### Local Timeline pagination

The local iOS Timeline reads bounded Core-owned keyset pages. The cursor is the
shared `(published_at, article_id)` ordering contract. A first page includes the
authoritative full selected-scope total and replaces the Timeline; later pages
omit the repeated total and append only new stable IDs and immutable row content.
Targeted removals likewise publish only deleted IDs, retaining unaffected row
presentation objects and content. Prepared row content, including date and link
derivation, is made off-main before the MainActor validates the page generation
and publishes the small structural delta.

Loaded pages remain retained for the lifetime of the current Timeline query.
Hard windowing/eviction is deliberately deferred until profiling demonstrates a
need. Paging requests are generation-owned, so stale work cannot block or clear
a newer query's request. Targeted read/starred/Scrollover presentation mutations
remain separate from structural pagination. Remote Search keeps its own
offset-pagination contract rather than using the local article cursor.

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
| `apple/ios/FluxNews/ArticleListView.swift` | Productive `UITableView` Timeline controller, native reusable article cells, deterministic prepared layout, Scrollover geometry, image/prefetch integration, and Undo overlay. This is the current implementation baseline. |
| `apple/ios/FluxNews/NewsreaderStore.swift` | Stable snapshots, per-row presentation, Core operations, pending writes, generations, Undo/counts. Refactor the existing ownership/scheduling; do not create a second source of truth. |
| `apple/ios/FluxNews/ContentView.swift` | Timeline entry point, iPhone/iPad shell, native navigation host and reset behavior. Preserve the shell's product behavior when embedding the new controller. |
| `apple/ios/FluxNews/ArticleImagePipeline.swift` | Existing ImageIO downsampling, memory cache, request deduplication and prefetch. Adapt consumer lifetime/cancellation as required. |
| `apple/ios/FluxNews/SearchView.swift` | Uses the same `IOSUIKitArticleTimelineView` renderer as the Article List, with Search-owned pagination/mutation state and Scrollover disabled. Keep presentation settings aligned with the main Timeline. |
| `apple/shared/FluxApple/` | Existing shared presentation policies and macOS exposure tracker. Reuse actual shared semantics; do not transplant macOS geometry/timing or broadly refactor macOS. |
| `apple/ios/FluxNewsTests/NewsreaderD23MutationTests.swift` | Current detection and mutation tests. Preserve valid behavior coverage; replace old-sensor tests and fake array-draining helpers with tests of the new productive paths. |
| `apple/ios/FluxNewsTests/NewsreaderPresentationTests.swift` | Presentation, image/prefetch and related regression coverage; inspect current cases and keep relevant guarantees. |
| `core/crates/flux-core/src/lib.rs` | Existing `set_read_state_bulk` domain boundary. Use it; do not add a Scrollover-specific Core API or change frozen delivery behavior as part of a renderer rewrite. |
| `apple/ios/FluxNews.xcodeproj/project.pbxproj` | Register new/moved sources and tests as required by the existing project. |

Search uses the same UIKit Timeline renderer as the normal Article List. The old
SwiftUI article-row chain was removed after its last production caller
disappeared; `FeedIconView` remains because the navigation sidebar uses it. The
source map above describes the current implementation rather than the old planning
baseline.

## 5. Ordered implementation packages

These packages build one permanent replacement. They are not competing renderer
experiments. Each implementation package includes its relevant tests/build;
do not defer correctness until the final package.

| Package | Scope and completion gate | Current status — 21 September 2026 |
|---|---|---|
| U1 — Contract | Record UIKit container/native cells, rationale, boundaries, behavior, and this handoff. | **COMPLETE** — documentation contract established. |
| U2 — Native Timeline | Implement the owned controller, bridge, native reusable cells, stable ID snapshots, sizing, image consumers, system swipes/context menus/refresh, and existing shell integration. Register sources and preserve Search dependencies. | **COMPLETE as the native Timeline baseline.** The owned UIKit controller/cells and structural/status split are productive. Search now also uses the UIKit Timeline. Completion of U2 does not freeze later performance-sensitive internals. |
| U3 — Geometry, status and performance-sensitive renderer work | Implement coherent UIKit Scrollover geometry and targeted status presentation; establish stable/bounded layout, image and update behavior and close the required performance/correctness regressions. | **IN PROGRESS.** Productive UIKit Scrollover geometry, targeted status updates, deterministic sizing/prepared metrics, incremental pagination/updates and substantial image/layout hardening exist. Physical-device performance remains unresolved enough that fundamental renderer/layout/cell/image/scheduling changes are still permitted. U3 is therefore not merely waiting for acceptance. |
| U4 — Session mutation worker | Complete queue lifetime, origin attribution, bounded drains, explicit-action ordering, lifecycle and failure handling using a controllably blocked real writer path in tests. | **COMPLETE.** The session-owned worker has a 500 ms bounded drain deadline, 64-ID FIFO batches, one writer chain per session, explicit-intent precedence, lifecycle coalescing, session-isolated completion, deterministic failure recovery, and blocked-writer regression coverage through the productive drain path. Canonical validation passed on 2026-09-21: 343 iOS tests with 0 failures, `build-app.sh` succeeded, and `git diff --check HEAD^ HEAD` was clean. |
| U5 — Cleanup and acceptance | Remove superseded Timeline code, verify complete interaction/localization/accessibility behavior, run native checks and focused device traces, record actual remaining limitations. | **IN PROGRESS / OPEN.** Search migration and old SwiftUI article-row cleanup are complete, and diagnostic cleanup has progressed. Final cleanup and device/runtime acceptance remain blocked on settling U3 performance architecture and completing U4. |

The selected architecture already includes U2-U4; no new architecture approval
is required simply because UIKit replaces the old implementation. However, this
does **not** pre-approve every current internal implementation detail. While U3
remains open, measured performance evidence may justify fundamental changes
inside the Timeline renderer, layout, cell, image-presentation, preparation, or
scheduling boundaries without reopening frozen product semantics or unrelated
Core/macOS architecture. If the user requests one package, implement that package
and its validation without silently expanding to unrelated phases. Temporary
work-in-progress on a branch is not a supported production fallback. Do not mark
the amendment complete until U3 performance/correctness, U4 worker semantics, and
U5 cleanup/device acceptance are all complete.

### U2 baseline and subsequent evolution

U2 established the owned UIKit Timeline baseline: native cell reuse, image
consumers/prefetching, ordinary article interactions, stable IDs, and the
structural-versus-status update boundary. The initial container was a
`UICollectionView`; subsequent performance work migrated the productive
Timeline to `UITableView` while preserving those product and update semantics.
Since that baseline, U3 added the
productive UIKit Scrollover geometry path and substantial deterministic
layout/performance work. The legacy `IOSScrolloverGeometryController` is only a
historical/regression-test reference and does not drive the production
table view.

Do not interpret the current productive U3 implementation as frozen. The purpose
of the remaining U3 work is to make the selected UIKit Timeline robust on real
hardware, and evidence from that work may still require structural changes to
cells, layout, image presentation, preparation, or scheduling.

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
| Core events, counts, haptics and Undo updates while scrolling. | Ignored events are filtered before main-thread dispatch; no structural article reload from ordinary feedback. Successful explicit Mark as Read uses one system success feedback. Scrollover emits that feedback once only after the motion is idle and the successful persistence group has settled; never once per crossed article. Read-on-open is silent. Successful Star and Unstar state changes use the same success feedback in both the main Timeline and Search. Saving to a configured third-party service uses success feedback only when Miniflux reports `.saved`; no-integration and failure results are silent. Successful Undo uses a distinct lighter selection feedback. |
| Native swipes/full swipe, menus, refresh, routing, scope-capsule navigation chrome, iPad split view, Dynamic Type, VoiceOver, Reduce Motion and localization. | Existing product behavior remains usable and correct across compact/visual layouts. |
| Article accessory/info geometry. | Unread is always outermost, followed by Star, Comments, then Audio with optional duration. Visual portrait has one production path: a 100% content-width 16:9 image followed by metadata, title, publication row, and preview. Every productive layout uses metadata → title → publication row → preview. The publication row uses either the localized absolute date/time or the snapshot-frozen localized relative age selected in Articles settings; relative mode shows `clock.arrow.circlepath`. Optional Miniflux reading time follows the publication value inline in the same row, separated by a centered dot and rendered as `doc.text` + duration; it must not increase row height. The temporary reduced-width image/info-rail A/B path and its diagnostics switch are removed after the iOS 27 real-device test showed smooth full-width scrolling. Audio stays unrendered until supplied by a batched Timeline projection. |

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

## 8. Agreed U3/U4 stabilization and architecture-freeze plan

This section records the owner-approved direction after the September 2026
performance investigation. It is the default completion sequence unless new,
reproducible device evidence demonstrates a different architectural problem.
Do not restart broad renderer experiments merely because older diagnostic plans
contain alternatives that were already tried.

### 8.1 Current productive baseline

Keep the current owned `UITableView` Timeline, native UIKit cells, deterministic
layout preparation, and the normal 100%-content-width Visual portrait image.
The iPhone 15 comparison showed that the same full-width presentation that
remained visibly rough on iOS 26 is substantially smoother after updating the
same device to iOS 27. This does not prove a specific iOS 26 framework defect,
but after the completed SwiftUI/UIKit, collection/table, image-size, raster,
prefetch, scheduling, and layout experiments it is sufficient evidence not to
compromise the product UI or reopen the Timeline container by default.

Visual compact remains a normal product presentation mode, not a performance
workaround that must replace the standard full-width Visual mode.

### 8.2 U4 complete — session mutation worker

The U4 implementation contract is now represented in code and tests. The
existing queue remains owned by the `NewsreaderStore` Core/account session and
still uses 64-ID bounded FIFO batches with pending/in-flight deduplication and
one logical Scrollover writer chain per session.

A small accepted batch now receives one session-owned bounded drain deadline of
500 ms. Reaching 64 IDs, entering idle, or a lifecycle flush still requests an
immediate drain through the same serialized worker. The deadline is cancelled
when a drain starts or the session is invalidated; it never creates a parallel
writer.

Each drain captures the read-mutation writer for the current session. Production
writers capture the current `Flux` instance and continue to execute synchronous
Core/UniFFI work through `AppleCoreExecution`. A Core/account replacement drops
queued work, cancels its deadline, and invalidates completion ownership. An
already-running old writer may finish against only the Core it captured; its
completion cannot clear, publish into, or continue work for the new session.

Newer explicit Read/Unread intent removes conflicting queued/deferred automatic
presentation and Undo state, marks a conflicting in-flight automatic intent as
superseded, and waits for that older Core write before issuing the explicit write.
Automatic completion/failure effects for superseded IDs are ignored. Explicit
read-mutation tokens also keep those IDs ineligible for new automatic acceptance
until the explicit operation finishes. Undo uses the same captured writer path.

Writer failure restores only still-owned automatic presentation, clears the
running state, and continues any remaining FIFO queue; a later batch can run
normally. Presentation-only resets keep valid persistence work for the same
session.

Regression tests now use an injectable, controllably blocked read writer around
the productive drain operation rather than only array-pop helpers. They cover
the bounded deadline, 64-ID limit/FIFO continuation, trigger coalescing,
presentation reset, explicit Read/Unread precedence, blocked successors,
old-session completion, failure recovery, lifecycle flush, and real-writer Undo.

Canonical local validation passed on 2026-09-21. `./apple/ios/Build/test.sh`
executed 343 tests with 0 failures, `./apple/ios/Build/build-app.sh` succeeded,
and `git diff --check HEAD^ HEAD` was clean. U4 is therefore complete. U3
remains open regardless.

### 8.3 Close U3 with targeted observation, not another speculative rewrite

After U4, perform a short U3 closure pass on representative hardware.

Treat synchronous deterministic-layout fallback counters as performance
canaries. During ordinary steady-state scrolling, prepared row heights and
prepared layout metrics should make synchronous Core Text fallback effectively
zero. Rotation, Dynamic Type, or a new geometry generation may legitimately
exercise exceptional preparation paths; recurring fallback during normal
scrolling requires investigation before U3 closes.

Do not replace the current constraint-based cell with manual frame layout merely
to eliminate theoretical duplication. `IOSUIKitArticleLayoutEngine` remains the
authoritative geometry calculation and the cell consumes its prepared metrics.
Keep the UIKit-cell-versus-engine oracle tests as a hard regression boundary.
After U4, reduce remaining duplicate cell-side calculations incrementally where
that can be done without changing rendering behavior.

### 8.4 Retire the legacy image renderer after one final bounded comparison

The production image path is the renderer-driven `imageViewScaled` path:
display-sized ImageIO downsampling, bounded memory/HTTP caching, in-flight
deduplication, visible-over-prefetch priority, cancellation, then ordinary
`UIImageView` / Core Animation aspect-fill presentation.

Before removing the legacy exact-slot `displayReady` renderer, perform one final
bounded comparison on the iPhone 15 where practical:

- iOS 26 with `imageViewScaled`;
- iOS 26 with `displayReady`;
- iOS 27 with `imageViewScaled` — **observed on iPhone 15: smooth through roughly 200 articles**;
- iOS 27 with `displayReady` — **observed on the same device: no visible scrolling advantage over `imageViewScaled`**.

The iOS 27 half of this comparison is therefore complete and currently favors
retaining only `imageViewScaled`. The remaining iOS 26 comparison is a bounded
confirmation only, not a reason to reopen the renderer investigation.

This is a confirmation step, not a new open-ended investigation. If the legacy
renderer shows no clear product-relevant advantage, remove it, its diagnostic
switch/state, its renderer-specific cache-key dimensions, backdrop/P3/exact-slot
CGContext preparation, and the misleading `ArticleImageRequest` legacy default.
Do not keep shipping code as an archive; Git history is sufficient if future OS
evidence ever justifies revisiting the experiment.

The long-term preferred direction is to keep app-owned work focused on
target-size decoding, prioritization, caching, deduplication, and cancellation
while allowing UIKit/Core Animation to own ordinary final image presentation so
future Apple rendering improvements can benefit Flux without a custom raster
pipeline.

### 8.5 Status-bar edge protection during U3 closure

The Timeline deliberately keeps the native scroll edge effect disabled on iOS 26
because device testing showed the progressive blur resampling the full list width
during scrolling. iOS 27 is now tested separately: the custom status-bar scrim is
hidden there and `UITableView.topEdgeEffect` uses Apple's native `.soft` style,
with the bottom effect still disabled. This experiment must be judged on the same
real-device scrolling baseline; if it reintroduces visible frame instability, revert
to the static scrim rather than accepting a readability fix that harms Timeline
performance.

### 8.6 Accept and document the iOS 26 limitation if the closure check confirms it

Flux continues to support iOS 17+, so iOS 26 remains a supported OS. However, the
full-width-image scroll-quality difference observed on iPhone 15 has already
survived extensive app-side investigation and improved materially on the same
hardware under iOS 27.

If the bounded U3 closure comparison reveals no actionable app-side regression,
record the remaining iOS 26 behavior as a known OS/rendering-sensitive
limitation. Do not restore the temporary 80%-image/info-rail design, reduce image
width, or reopen the renderer/container solely to hide that iOS 26 perceptual
difference. New work requires new reproducible evidence that identifies an
actionable app-side cause.

### 8.7 Cleanup after U3/U4, then freeze the Timeline architecture

After U3 and U4 are complete, perform a behavior-preserving cleanup rather than
another performance redesign:

- split the large Timeline source into focused controller, cell, Scrollover,
  presentation-bridge, and performance-metrics files;
- migrate any still-useful regression coverage from the historical
  `IOSScrolloverGeometryController` to the productive
  `IOSUIKitScrolloverGeometryTracker`, then remove or test-isolate the historical
  controller;
- reduce redundant geometry helpers so prepared
  `IOSUIKitArticleLayoutMetrics` is consumed directly wherever practical;
- remove obsolete image diagnostics/legacy renderer code after the comparison
  above;
- keep the existing engine-versus-cell geometry oracle, bounded-cache tests,
  snapshot/status separation tests, and device acceptance checks.

Once the U4 worker contract, U3 closure checks, and this cleanup are complete,
the current Timeline container/rendering architecture should be treated as
frozen. Later feature work should extend the accepted product semantics without
reopening `UITableView`, full-width Visual portrait images, or the fundamental
image/layout pipeline unless new device evidence demonstrates a concrete
regression that cannot be addressed inside those boundaries.

## 9. Apple references

- [Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/): stable identities, cell lifecycle, preparation, prefetch, image handling and targeted updates.
- [Lists in UICollectionView](https://developer.apple.com/videos/play/wwdc2020/10026/): list configurations, native cell content and system swipe integration.
- [Use SwiftUI with UIKit](https://developer.apple.com/videos/play/wwdc2022/10072/): hosting and self-sizing background; useful context for the deliberate native-cell decision, not an instruction to host Timeline cells.
