# Flux Documentation

This directory is intentionally small.

## Authoritative target architecture

- `ARCHITECTURE_DECISIONS.md` — explicitly agreed target architecture for the shared Rust core and native macOS/iOS/Android clients. This is the primary architecture authority.
- `MOBILE_PRODUCT_SEMANTICS.md` — shared native-mobile behavior contract for iOS/iPadOS and Android. It captures product semantics that must not be rediscovered per platform while deliberately leaving SwiftUI/UIKit/Compose and OS-integration mechanics platform-specific.
- `PHASE_D_NATIVE_IOS_IPADOS.md` — authoritative Phase-D contract and roadmap for the native iOS/iPadOS replacement, including Apple sharing boundaries, development/production identities, migration safety, mobile UX, system integrations, and the active D1–D9 sequencing.
- `IOS_D9_FLUTTER_REPLACEMENT_COMPLETION.md` — final native replacement-completion contract: retained Flutter migration/parity release gates, Settings/widget completion work, and explicit retired/replaced legacy behaviors.
- `PHASE_E_NATIVE_ANDROID.md` — authoritative Phase-E contract for the native Android replacement, including Kotlin/Compose/UniFFI foundation, production migration, adaptive UI, background work, widgets, media, Android Auto, testing, and E1–E9 sequencing.
- `PHASE_D_D1_STATUS.md` — historical snapshot of the completed/frozen D1 foundation and early D2.1 progress; it is not a current status authority.

## Phase status

- **Phase A — Newsreader Completion:** complete and architecture-frozen.
- **Phase B — Shared Podcast / Media Core:** complete and architecture-frozen.
- **Phase C — Native macOS Audio Experience:** complete and architecture-frozen. The native macOS client implements the Phase-C Listening List, playback, transfer, settings and system-media contract; `PHASE_C_NATIVE_MACOS_AUDIO.md` is the completed contract.
- **Phase D — Native iOS/iPadOS:** implementation complete. D7 is architecture-frozen; D8 is deferred and not required for replacement; D9 production Flutter-to-native migration is real-device accepted as of 10 October 2026, including recovered legacy downloads and terminal handling of stale playback positions with no local download and confirmed 404/410. The current PR regression gate remains the only mechanical acceptance check for later shared changes. `PHASE_D_NATIVE_IOS_IPADOS.md` remains authoritative.
- **Phase E — Native Android:** E1 through E7 are complete and real-device accepted for their defined scopes. E9 implementation, the signed production Flutter-to-native upgrade path, and Playback Verification v2 are all real-device accepted as of 10 October 2026. The v2 pass correctly re-opened only the previously manually skipped playback stage and completed green while identifying stale historical positions with no local download and confirmed 404/410. `PHASE_E_NATIVE_ANDROID.md` is the Phase-E implementation/sequencing authority.

There is no remaining known replacement-blocking implementation or migration-acceptance gap across macOS, iOS/iPadOS, or Android. Release-distribution work such as final Play/F-Droid packaging remains separate from replacement implementation acceptance.

## Reference evidence

`reference/` contains historical FluxBar and FluxNews material that can help preserve useful product behavior and identify feature gaps. These documents are **not** implementation roadmaps and are **not** authoritative when they conflict with the architecture decisions or the active Phase-D contract.

For Phase D, the current native macOS implementation is the primary native reference. Flutter FluxNews is consulted only for mobile-specific capability and legacy-migration evidence; it is not a parity checklist and intentionally removed behavior must not be reintroduced without a product decision.

Shared native-mobile behavior that should survive across iOS/iPadOS and Android belongs in `MOBILE_PRODUCT_SEMANTICS.md`. Platform-specific fixes and framework workarounds remain in their platform implementation and must not be promoted into shared requirements unless they reveal a genuine shared product/Core semantic.

Old Go-core compatibility contracts, Go-to-Rust migration plans, temporary mobile runtime-proof plans/status files, differential-testing plans, and superseded shared-core roadmaps have deliberately been removed from the active documentation set. The Go core is retired; new work targets the Rust architecture directly.

## Working rule

Use documentation to answer a concrete implementation question or preserve an existing feature. Do not start broad compatibility or possibility-analysis work unless an unresolved decision blocks durable implementation.

For Phase D specifically, inspect the current Rust Core and native macOS implementation before treating a Flutter behavior as a missing requirement. Extract Apple-shared Swift code only on first real reuse rather than through a speculative up-front refactor.

For Phase E, use `PHASE_E_NATIVE_ANDROID.md` together with `ARCHITECTURE_DECISIONS.md` and `MOBILE_PRODUCT_SEMANTICS.md`. Preserve shared Core/product behavior, but derive navigation, lifecycle, gestures, background work, credentials, browser, notifications, widgets, media, and automotive integration from native Android capabilities rather than copying the Apple implementation. Flutter FluxNews remains behavioral/migration evidence only.
