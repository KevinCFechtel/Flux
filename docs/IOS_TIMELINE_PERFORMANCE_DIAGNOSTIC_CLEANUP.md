# iOS Timeline Performance Diagnostics — Experiment Record and Cleanup Contract

Status: **temporary diagnostic inventory / cleanup required before merge or release**

Branch during investigation: `perf/ios-frame-headroom`

This document records the temporary diagnostics used while investigating intermittent scrolling unevenness in the native iOS UIKit article timeline. It exists so that experimental behavior cannot accidentally become shipping architecture.

The experiment history is useful evidence and should remain documented. The diagnostic code paths themselves are not automatically production features. Before this work is merged or released, every diagnostic listed below must be audited and either removed or explicitly promoted to a documented production mechanism.

## Measurement caveat

An early screen-recording analysis treated pixel-identical repeated ReplayKit frames as dropped display frames. The original Flux recording produced a value around 5.6%, but an Apple Calendar control produced roughly 13% with the same method. Therefore the repeated-frame percentage and the earlier `<1%` target are **not valid application-performance KPIs** and must not be used as release gates.

Physical-device subjective comparison and Instruments traces were subsequently used only as diagnostic evidence. Simulator Time Profiler data is useful for locating CPU work, but it is not proof of physical-device frame pacing.

## Baseline hardening that is not diagnostic by itself

The investigation also produced changes intended as genuine hardening rather than temporary A/B switches. These must be reviewed normally, not blindly reverted with the diagnostics. Relevant work included whole-module optimization for archives, BGRA raster preparation, bounded image/cache work, Scrollover copy-on-write reduction, removal of unused hot-path inputs, a larger article-image cache, and related regression tests.

In particular, do **not** interpret this cleanup contract as an instruction to revert every commit made during the performance investigation.

## Temporary experiments

### 1. Standard geometry with article images disabled

Commit: `14747e850e3c4be3387a8c75161804e03c0b2b99` — `Add standard-layout no-image performance diagnostic`

Purpose: keep Standard row/layout/image-slot geometry while suppressing article-image request/cache/prefetch/decode/presentation work.

Physical-device result: Standard became approximately as smooth as Compact.

Conclusion: article-image work is strongly implicated; general Standard geometry became a weaker primary hypothesis.

Cleanup requirement: the source-level no-image performance switch and its diagnostic-only branches/tests must not ship unless deliberately retained as an internal diagnostic facility.

### 2. Deferred article-image presentation while scrolling

Commit: `2dba8d243f81ebabb9ad850dfaade95f6fd17fe0` — `Defer article image presentation while scrolling`

Purpose: defer asynchronous image completions during dragging/deceleration and flush visible images when scrolling became idle. Cache-hit presentation remained immediate in this first version.

Physical-device result: scrolling improved, but placeholders remained visible too long and the behavior was not acceptable product UX.

Cleanup requirement: remove diagnostic scroll-state presentation deferral unless a later production design explicitly reintroduces it with its own contract.

### 3. A′ — suppress all new article-image assignments while scrolling

Commit: `3bc70a9097e047910bfcabb11346c36722191f65` — `Suppress article image assignment while scrolling`

Purpose: close the cache-hit hole from the previous experiment. While scrolling, suppress both cache-hit and asynchronous new raster assignments; retain recycled image content diagnostically and correct cells when idle.

Physical-device result: clearly smoother, with only occasional very small residual unevenness.

Interpretation: new real-image presentation during scrolling is a major contributor. This was deliberately ugly diagnostic behavior, not an acceptable product implementation.

Cleanup requirement: remove stale/wrong-image retention, scroll-state assignment suppression, idle correction logic, and diagnostic tests unless a later production mechanism explicitly supersedes them.

### 4. Diagnostic C — shared opaque article raster

Commit: `0226d54720d5b0bdfe38233883e3a1883a656c7b` — `Use shared opaque article raster for diagnosis`

Purpose: restore normal assignment timing while replacing all real article images with the same shared full-size opaque neutral raster. Standard geometry and image-layer assignment remained present; real article-image network/decode/cache/prefetch work was bypassed.

Physical-device result: nearly smooth, comparable to the best diagnostic variants, with at most very rare inconspicuous unevenness.

Interpretation: `UIImageView.image = ...` by itself was not sufficient to reproduce the issue. Distinct real image content/surfaces remained implicated.

Cleanup requirement: remove the shared-raster switch, synthetic raster cache/generator, pipeline bypass, and diagnostic-specific tests.

### 5. Real decoded raster without exact-slot prerasterization

Commit: `2c3ecd8a606dec07730c3bcb4d0627b4f308bcd5` — `Use decoded article raster for diagnosis`

Diagnostic switch used during this experiment:

`IOSUIKitTimelineArticleImageDecodedRasterPerformanceDiagnostic.useDecodedRasterWithoutExactSlotRenderingForPerformanceDiagnosis`

Purpose: restore real requests/cache/loading/prefetch/immediate assignment while changing the native pipeline from:

`Data -> ImageIO thumbnail -> renderDisplayReady exact-slot BGRA raster -> cache -> UIImageView`

to:

`Data -> ImageIO thumbnail -> cache -> UIImageView.scaleAspectFill`

Native-resolution intent remained approximately 3x. Representative iPhone 15 Standard geometry used a `1083x609` exact slot in the old path and an ImageIO maximum around `1088` pixels in the diagnostic path. Runtime corner clipping was temporarily reintroduced because corners were no longer baked into the exact-slot raster.

Physical-device result: **not meaningfully better** than the normal real-image path and subjectively more uneven than Diagnostic C.

Conclusion: the second exact-slot `renderDisplayReady` rasterization was downgraded as the primary explanation. The experiment does not justify replacing the production raster architecture by itself.

Cleanup requirement: remove the decoded-raster representation switch, diagnostic cache-identity mode, runtime-corner diagnostic branch, and diagnostic-only tests unless later work explicitly adopts this architecture for independent reasons.

### 6. 2x exact-slot raster-size diagnostic

A later diagnostic was planned to restore the normal exact-slot pipeline and change only effective article-image raster scale from physical-display scale (typically 3x on iPhone 15) to exactly 2x. Representative dimensions were intended to change from about `1083x609` (~2.52 MiB BGRA) to `722x406` (~1.12 MiB BGRA), while preserving logical slot geometry, real images, normal assignment, cache, prefetch, crop, and baked corners.

Purpose: isolate whether scrolling unevenness scales materially with the pixel/byte volume of distinct image rasters.

**Current repository state and the physical-device outcome of this experiment must be verified from commits/documentation after the investigation continued elsewhere. Do not infer its result from this document.**

Cleanup requirement: any `IOSUIKitTimelineArticleImageRasterScalePerformanceDiagnostic`, `useTwoXArticleImageRasterForPerformanceDiagnosis`, forced 2x scale, or equivalent experiment must be removed unless the final production architecture explicitly adopts a non-native raster scale.

## Evidence that should remain after cleanup

The following conclusions are historical diagnostic evidence, not guaranteed explanations of the final root cause:

- Compact was subjectively very smooth on the physical iPhone 15.
- Standard geometry with article images disabled was approximately Compact-smooth.
- Warm-cache Standard still showed unevenness, weakening network/decode as a sufficient explanation.
- Suppressing new real-image assignments while scrolling improved behavior substantially.
- Normal assignment of one shared opaque raster was nearly smooth.
- Removing exact-slot prerasterization while retaining real approximately-3x images did not materially improve scrolling.
- No experiment above proves a specific Core Animation, Render Server, IOSurface, texture-upload, memory-bandwidth, or GPU mechanism.
- U3.7.5/manual cell layout was not justified by these experiments and remained deferred during this investigation.

## Mandatory pre-merge cleanup audit

Before merging the performance branch or declaring the timeline implementation production-ready, search the iOS source and tests for at least the following terms and for semantically equivalent code introduced later:

- `PerformanceDiagnostic`
- `PerformanceDiagnosis`
- `Diagnosis`
- `useDecodedRasterWithoutExactSlotRenderingForPerformanceDiagnosis`
- `useTwoXArticleImageRasterForPerformanceDiagnosis`
- no-image article-image suppression
- scroll-state image-presentation deferral
- cache-hit/async assignment suppression
- stale image retention during reuse
- shared/synthetic opaque article raster generation
- forced diagnostic raster scale
- diagnostic-only cache representation keys

For each match classify it as one of:

1. **Remove** — temporary experiment only.
2. **Promote** — intentionally becomes production behavior; remove diagnostic naming and document/test the production contract.
3. **Retain as tooling** — only if there is a deliberate long-term diagnostics strategy and the code cannot affect normal Release behavior.

The final cleanup must also remove or rewrite tests whose only purpose is to lock temporary diagnostic behavior. Tests for production invariants discovered during the experiments should be preserved.

## Final-state verification checklist

After cleanup:

- no temporary experiment is enabled by a source-level `true` constant;
- normal Release/TestFlight behavior cannot select a diagnostic branch accidentally;
- article-image request, cache, prefetch, presentation, reuse, and raster-scale behavior match the final documented production design;
- Compact behavior remains intentional;
- Phase-D documentation describes the final architecture separately from this historical experiment record;
- repository-standard Core/iOS tests, app build, archive, and `git diff --check` pass.

This file should remain as the historical experiment/cleanup record even after diagnostic code is removed, updated with the final cleanup commit and final production decision.
