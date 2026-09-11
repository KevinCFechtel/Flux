# UIKit Timeline Performance Plan — U3.6.5 through U3.7

> **Status: ACCEPTED / IMPLEMENTATION STARTED**
>
> Baseline: `main` after U3.6.1–U3.6.4, currently including the merged UIKit renderer, targeted presentation bridge, resolved Scrollover geometry, and bounded image scheduler.
>
> This plan follows the physical-device reviews after U3.6. It keeps the owned `UICollectionView` architecture and deliberately postpones U4 mutation-worker work until the rendering path has been repaired and optimized further.

## 1. Objective

The goal is no longer merely to remove individually proven regressions. The production Timeline should be optimized so that scrolling through previously unseen articles does not depend on expensive full-cell measurement or unnecessary asynchronous presentation work.

The target end state is:

- no image pixel or icon arrival can alter cell geometry;
- no status-only update performs structural list work;
- article image work remains bounded and consumer-safe;
- Timeline sizing no longer depends on `systemLayoutSizeFitting` in the production scroll path;
- article geometry is derived deterministically from presentation metrics plus bounded text measurement;
- sizing and rendering consume the same layout metrics;
- layout metrics can be prepared ahead of scrolling;
- physical-device acceptance covers both cold and warm scrolling, not only repeated/cache-warm passes.

U4 remains separate and must not be folded into these packages.

## 2. Package order

| Package | Purpose | Main gate |
|---|---|---|
| **U3.6.5 — Cell Geometry Acceptance Repair** | Remove image intrinsic-size pressure from card geometry and add productive-cell geometry tests. | Placeholder, square/tall/wide decoded images, and cached image arrival all preserve the same row and image-slot geometry; no Auto Layout conflict is introduced. |
| **U3.6.6 — Presentation Delivery Repair** | Repair feed-icon/status delivery ownership and prepared-cell reconciliation. | Timeline and Search can both receive the correct icon/status stream; a prepared cell entering display resolves current icon state without structural work; transient icon failures remain retryable. |
| **U3.6.7 — Image Scheduler Race Repair** | Close cancellation-generation and admission/promotion races in `ArticleImagePipeline`. | A new consumer cannot attach to a cancelling generation; old completion cannot fail the successor; queue/concurrency bounds remain true under promotion and cancellation. |
| **U3.7.1 — Timeline Performance Instrumentation** | Add low-overhead counters/signposts around the real production hot paths. | Device runs can report measurement count/time, cache hits/misses, cell configuration, layout invalidation, image completion, and structural snapshot activity without changing product behavior. |
| **U3.7.2 — Deterministic Article Layout Engine** | Replace full-cell sizing with deterministic geometry plus bounded text measurement. | The engine returns the same geometry as the production cell across variants, widths, Dynamic Type, locale/direction, preview-line choices, and image/no-image states. |
| **U3.7.3 — Prepared Layout Metrics** | Prepare metrics before cells need them, prioritizing visible/nearby articles and optionally the remaining current selection. | New cells normally receive ready metrics; preparation remains bounded/prioritized and does not block list adoption or scrolling. |
| **U3.7.4 — Remove Production Self-Sizing** | Stop using `preferredLayoutAttributesFitting` / `systemLayoutSizeFitting` for normal Timeline item heights. | Collection layout receives explicit deterministic heights; cold scrolling does not trigger full-cell solver measurement. |
| **U3.7.5 — Optional Manual Cell Layout** | Remove Auto Layout/StackView work from the Timeline cell only if instrumentation still shows meaningful layout cost. | Cell subview frames consume the same layout metrics directly; no product/layout regression; this step is optional and evidence-gated. |
| **U3.7.6 — Physical Device Acceptance** | Validate Release scrolling on the reference iPhone under cold and warm conditions. | Previously unseen articles scroll fluidly with Scrollover enabled; warm scrolling is not materially different because of avoidable first-display work; counters show no unexpected solver/snapshot/layout bursts. |

## 3. U3.6.5 — Cell Geometry Acceptance Repair

### Problem

`IOSUIKitArticleCell` assigns required vertical hugging and compression resistance to `articleImageView` while the layout also gives the image view an explicit 16:9 slot. A decoded `UIImage` contributes an intrinsic content size. Required intrinsic-size pressure can therefore compete with the explicit image-slot constraints and cause additional layout work or unsatisfiable constraints.

The image pixels are presentation only. The slot geometry is already determined by `ArticlePresentationLayout` and the cell variant.

### Required implementation

- make the explicit image slot the sole geometry authority;
- remove or lower intrinsic-size CHCR priorities that can compete with the fixed slot;
- do not add image pixel dimensions to the sizing key;
- preserve `scaleAspectFill`, clipping and the existing 16:9 slot rules;
- placeholder -> decoded image, cache hit, and image replacement must be pixel-only updates;
- keep the permanent hierarchy introduced by U3.6.1.

### Required productive-cell tests

1. Configure and measure a visual portrait cell with placeholder/no decoded pixels.
2. Apply a square image, tall image and wide image to the same slot; row height and slot frame remain unchanged.
3. Image available before first measurement vs image arriving after first measurement yields identical geometry.
4. Visual landscape obeys the same invariant.
5. Read/Starred/feed-icon changes still do not change geometry.
6. No test should satisfy the gate only through a recreated pure helper; exercise the real cell/layout path where practical.

During device validation, use an `UIViewAlertForUnsatisfiableConstraints` symbolic breakpoint or equivalent diagnostic to verify image arrival does not create constraint conflicts.

## 4. U3.6.6 — Presentation Delivery Repair

### Problems

The current presentation bridge owns one weak controller receiver. Timeline and Search can both use the shared feed-icon bridge, so a later attachment can replace the earlier receiver. In addition, icon deltas are currently applied to visible cells; a prepared-but-not-yet-visible cell can miss an icon completion and later display a fallback even though the icon is already retained.

Feed icon loading also conflates successful "no icon" with transient failure, which can make a temporary failure permanent for the store lifetime.

### Required implementation

- replace single-receiver ownership with explicit subscriptions or separated article-status and feed-icon channels;
- Timeline receives its article-status and icon streams;
- Search keeps its own article-status stream while subscribing to the shared icon stream;
- unsubscribe/cleanup must be lifecycle-safe and must not retain controllers indefinitely;
- `willDisplay` (or equivalent binding point) reconciles the latest retained icon state by stable feed ID + variant without structural snapshot, full-list remap, or height measurement;
- icon state distinguishes at least idle/loading/available/successful-unavailable/retryable-failure;
- transient failures retry lazily after a cooldown or later demand; successful "no icon" must not enter a retry loop;
- concurrent requests for the same feed/variant remain deduplicated.

### Tests

- Timeline + Search attached simultaneously both receive current icon presentation.
- Search attachment cannot steal Timeline updates.
- Icon completes after cell preparation but before display -> correct icon appears on display.
- Cached icon before configure -> immediate correct presentation.
- Stale completion after reuse/variant change cannot paint the wrong icon.
- Multiple visible rows for one feed update correctly.
- Transient failure followed by later success is retryable.
- Successful no-icon result is retained without repeated requests.

## 5. U3.6.7 — Image Scheduler Race Repair

### Problems

A job with its last consumer cancelled can remain in the job table until the underlying loader actually finishes. A new consumer for the same request can attach to that cancelling job and then receive its cancellation/failure. Queue promotion/admission also needs stronger invariant coverage when visible and prefetch limits interact.

### Required implementation

- give each underlying request job an explicit generation/state;
- a cancelling job cannot accept new consumers;
- a new consumer for the same request either starts/queues a successor generation or waits for the old generation to retire and then joins a successor;
- completion closes only the generation that produced it;
- a cancelled active operation continues to occupy the active-concurrency budget until it actually finishes;
- preserve maximum active operation count;
- simplify/clarify pending admission so visible demand can evict queued speculative work without violating visible/total bounds;
- promotion from prefetch to visible must preserve all queue bounds;
- visible priority must remain stronger than speculative prefetch without spawning unbounded work.

### Tests

- force cancellation-aware loader behavior: cancel final consumer, attach a new consumer before old operation completes, then verify successor succeeds and old cancellation cannot fail it;
- promotion at full queue respects all bounds;
- visible admission at full speculative capacity succeeds by evicting speculative work where policy permits;
- active count never exceeds configured concurrency under cancel/promote/successor races;
- shared consumer cancellation remains correct.

## 6. U3.7.1 — Timeline Performance Instrumentation

Before replacing sizing, add instrumentation around the real production path so the architectural change can be verified rather than judged only from video.

Track at minimum:

- `preferredLayoutAttributesFitting` calls;
- `systemLayoutSizeFitting` solve count;
- solve duration total, p50/p95/max or equivalent sampled statistics;
- height/metrics cache hits and misses;
- cell configure/rebind counts;
- layout variant switches;
- structural snapshot applications;
- layout invalidations;
- article-image cache hit/miss/completion counts;
- feed-icon presentation completions;
- optional signposts around cold cell preparation and collection-view update blocks.

Instrumentation must be low-overhead and removable/disableable for normal builds. Do not add per-frame logging to stdout.

## 7. U3.7.2 — Deterministic Article Layout Engine

### Principle

The production row height is deterministically derivable. The layout should no longer ask a fully configured cell to discover its own height.

The engine computes geometry from:

- container width and outer insets;
- presentation mode/variant;
- fixed stack/inter-column spacings;
- fixed 16:9 image slot when present;
- Dynamic Type font metrics;
- exact bounded text measurement for title and preview;
- deterministic metadata-row geometry;
- locale/writing direction and any other layout-relevant typography input.

Do **not** approximate line count from character count. Use Apple's text layout/bounding APIs with the same fonts, width, paragraph/line-break behavior, and maximum line count as the renderer.

### Current deterministic geometry

The existing production cell already defines:

- compact iPhone horizontal inset: 10 pt;
- visual iPhone horizontal inset: 16 pt;
- >700 pt container horizontal inset: 28 pt;
- compact outer vertical padding: 11 pt;
- visual portrait outer vertical padding: 15 pt;
- visual landscape outer vertical padding: 13 pt;
- text stack spacing: 7 pt;
- portrait image-to-text spacing: 12 pt;
- landscape image-to-text spacing: 14 pt;
- portrait/landscape image aspect ratio: 16:9;
- landscape image allocation: 48% of article content width;
- unread dot: 6x6 pt;
- feed-icon slot: 22x22 pt;
- metadata column fallback below 370 pt available width;
- preview line choices: 2, 3 or 5.

### Proposed API

A dedicated `ArticleLayoutInput` / `ArticleLayoutKey` should contain only geometry-relevant inputs. `isRead`, `isStarred`, decoded article pixels, decoded feed-icon pixels and transient loading state must not participate.

The output should be an `ArticleLayoutMetrics` value containing at least:

- layout variant;
- exact cell height;
- title height;
- metadata height;
- preview height;
- image frame when present;
- text/title/metadata/preview frames or enough deterministic metrics to derive them without another independent geometry implementation.

Sizing and eventual manual rendering must consume this same output so there is one geometry authority.

### Geometry formulas

Text-only/compact conceptual height:

`top padding + title height + text-stack spacing + metadata height + optional (text-stack spacing + preview height) + bottom padding`

Visual portrait conceptual height:

`top padding + 16:9 image height + 12 + text block height + bottom padding`

Visual landscape conceptual height:

`top padding + max(image height, text block height) + bottom padding`

The exact implementation must account for the production title-row star reservation and current metadata layout rules.

### Tests

Compare deterministic metrics against the real UIKit cell over a matrix of:

- compact / visual text-only / visual portrait / visual landscape;
- short and multiline titles;
- empty/1/2/3/5+/very long preview text;
- image/no image;
- comments/no comments;
- widths around the 370, 600 and 700 pt transitions;
- all supported preview-line choices;
- representative Dynamic Type sizes including accessibility sizes;
- LTR/RTL;
- portrait -> landscape -> portrait.

The goal is equality within a clearly defined pixel/point rounding tolerance, not visual approximation.

## 8. U3.7.3 — Prepared Layout Metrics

Once deterministic metrics exist, move their computation ahead of active scrolling.

Priority model:

1. visible / immediately requested items;
2. near-future items within a bounded look-ahead window;
3. optionally the remainder of the current adopted selection at low priority.

Requirements:

- never synchronously prepare all loaded history on the main thread;
- preparation must be cancellable/revision-aware when width, Dynamic Type, content or selection changes;
- duplicate layout keys coalesce;
- metrics cache is bounded or revision-scoped with an explicit memory policy;
- a list of roughly 1,000 current articles may be fully warmed opportunistically if the measured cost and memory use are acceptable, but visible/nearby work always wins;
- adoption/sync may enqueue preparation but may not turn into a long blocking "recalculate every row" operation.

## 9. U3.7.4 — Remove Production Self-Sizing

After deterministic metrics are validated, the collection layout obtains explicit item heights from `ArticleLayoutMetrics`.

Required end state:

- normal Timeline scrolling does not invoke `systemLayoutSizeFitting` to discover row height;
- `preferredLayoutAttributesFitting` is removed from the normal production sizing path or becomes a non-solving compatibility fallback that is not used in accepted configurations;
- cell rendering receives the same layout metrics used for sizing;
- image/icon/status arrival cannot invalidate item height;
- width/Dynamic-Type/layout-revision changes calculate a new metrics revision and preserve the existing visible-anchor guarantees.

A temporary comparison/debug assertion against Auto Layout may remain in non-production validation code while the deterministic engine is proven.

## 10. U3.7.5 — Optional Manual Cell Layout

Do this only if post-U3.7.4 instrumentation still attributes meaningful main-thread cost to Auto Layout/StackView layout inside already-sized cells.

If needed:

- keep the permanent native subviews;
- use `ArticleLayoutMetrics` in `layoutSubviews()` to assign frames directly;
- remove Timeline-cell StackView/constraint solver dependency where practical;
- keep accessibility, Dynamic Type, RTL and all existing product presentation semantics;
- do not apply this optimization to unrelated screens without separate evidence.

This package is optional because explicit deterministic item heights may already remove the dominant first-display cost.

## 11. U3.7.6 — Device acceptance

Use the same physical iPhone class used in the performance review and a Release configuration.

Required scenarios:

### Cold path

- launch/reload a selection containing previously unvisited articles;
- scroll continuously through rows whose text/image/layout metrics have not already been consumed by a prior pass;
- Scrollover enabled;
- include an image-rich feed/selection.

### Warm path

- immediately repeat the same region without structural changes.

### Control path

- repeat with a mostly text-only selection where possible.

Capture instrumentation for each path. The final decision must distinguish actual first-display work from recording artifacts or unrelated app/system activity.

Acceptance is not "warm scrolling looks fine". The intended product property is that **previously unseen unread articles scroll fluidly**.

## 12. Explicit non-goals until this plan is complete

- U4 mutation worker/session queue redesign;
- Rust/Core API changes for Timeline layout;
- custom scroll physics;
- replacement of `UICollectionView`;
- reintroduction of SwiftUI article cells;
- product changes to Scrollover, Undo, Remove When Read, Search, article card presentation or navigation semantics.

## 13. Immediate next action

Start with **U3.6.5 — Cell Geometry Acceptance Repair** on branch `u3-6-5-timeline-acceptance-repair`.

Do not start deterministic sizing by layering it on top of a cell whose image intrinsic content can still compete with the explicit slot. First make the current renderer geometrically sound and add the real-cell regression tests that will later become the comparison oracle for U3.7.2.
