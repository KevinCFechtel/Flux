# iOS Localization Usage Audit

> **Status: SOURCE-USAGE AUDIT IMPLEMENTED / TEST-GATE PENDING / GERMAN COMPLETE / ES-GL-NL-TA-TR REVIEW PENDING**
>
> This audit exists because Xcode String Catalog `extractionState` is not a
> reliable runtime-usage authority for the native iOS app. Productive SwiftUI,
> interpolated and dynamically carried localization keys can be reported as
> `stale`, while some localization-aware call sites can also be absent from the
> catalog entirely.

## Scope

The production usage gate scans localization-aware source in:

- `apple/ios/FluxNews/`
- `apple/ios/FluxNewsWidgets/`
- `apple/shared/FluxApple/`

It covers direct literals used by `String(localized:)`,
`LocalizedStringResource`, SwiftUI text/control initializers, navigation
titles, alerts and progress views. Dynamic/interpolated keys that cannot be
reliably reconstructed by static extraction are listed explicitly in the test
contract and retained as `manual` catalog entries.

`DeveloperDiagnosticsView.swift` is excluded from the production scan because
that surface is reachable only through DEBUG / performance-diagnostics builds.
Its diagnostic labels are intentionally not allowed to determine the production
translation set.

## Findings

The audit found two independent classes of regression introduced by the initial
D9-D cleanup:

1. 151 existing German entries had been removed because their Xcode extraction
   state was `stale`, even though many remained reachable at runtime.
2. 120 currently used iOS/widget/shared strings were absent from the String
   Catalog entirely, especially newer D9 Backup/Restore, Downloaded Data,
   About/Open Source and Support Diagnostics copy.

The audit also found three concrete localization bypasses where ordinary
`String` values were carried into user-facing presentation instead of being
resolved through a localization-aware API:

- the Search / Search Results dynamic navigation title;
- the Account / Set Up FluxNews dynamic navigation title;
- the no-subscription Feed Discovery error.

Those call sites now resolve their product text explicitly through
`String(localized:)`.

## Catalog classification

After the usage pass the iOS catalog contains 457 keys:

- 262 `manual`: source-proven or dynamic runtime keys that must not be removed
  based on Xcode extraction state;
- 169 normally extracted active keys;
- 26 remaining `stale` keys.

The remaining 26 stale keys are not treated as an automatic deletion list.

### DEBUG / legacy-diagnostic only

These are consumed only by the legacy migration/developer diagnostic path and do
not belong to the production UI localization gate:

- API key
- App Group
- Base URL
- Compatible settings
- Custom headers
- Download metadata
- Feed preferences
- Keychain credentials
- Legacy cache
- Legacy database
- Legacy downloads
- Legacy migration feasibility
- Playback progress
- Production identity
- Rust Core
- Sandbox paths
- Smoke test
- Status

### No current productive iOS reference

Repository search found no current production iOS presentation use for:

- Article Action
- Comments available
- Connection Diagnostics
- Continue
- Miniflux server returned an unexpected response.
- No results
- Showing %lld of %lld
- Unexpected

These remain preserved until a deliberate catalog cleanup is performed; they are
not needed to establish production localization coverage.

## Language state after the audit

German is the preservation baseline because it was the mature native iOS
translation before D9-D:

- DE: 456 translated, 0 missing, 0 needs-review.

The usage audit exposed that the previous seven-language completion count was
incorrect: it counted only the reduced catalog after productive keys had been
removed or omitted.

For ES/GL/NL/TA/TR, missing production locale structures are now staged as
`needs_review` instead of being falsely marked translated. They must be
reviewed/translated before D9-D can again be considered localization-complete.

No English fallback marked `needs_review` is evidence of a completed
translation.

## Regression contract

The iOS XCTest gate now:

- derives production localization keys from source rather than trusting
  `extractionState`;
- requires every source-used key to exist in the catalog;
- requires the production locale set to be structurally present;
- requires every production key to have a non-empty translated German value;
- protects interpolated/dynamic runtime keys explicitly;
- keeps placeholder/plural compatibility checks;
- excludes the DEBUG-only Developer Diagnostics surface from production
  localization completeness.

Future catalog cleanup must use repository/source evidence. Xcode
`extractionState == stale` alone is never sufficient evidence that a key is
unused.
