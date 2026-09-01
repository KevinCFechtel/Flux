# Flux Documentation

This directory is intentionally small.

## Authoritative target architecture

- `ARCHITECTURE_DECISIONS.md` — explicitly agreed target architecture for the shared Rust core and native macOS/iOS/Android clients. This is the primary architecture authority.
- `PHASE_D_NATIVE_IOS_IPADOS.md` — authoritative Phase-D contract and roadmap for the native iOS/iPadOS replacement, including Apple sharing boundaries, development/production identities, migration safety, mobile UX, system integrations, and D1–D10 sequencing.
- `PHASE_D_D1_STATUS.md` — implementation status for the completed/frozen D1 foundation and current D2 progress.

## Phase status

- **Phase A — Newsreader Completion:** complete and architecture-frozen.
- **Phase B — Shared Podcast / Media Core:** complete and architecture-frozen.
- **Phase C — Native macOS Audio Experience:** complete and architecture-frozen. `PHASE_C_NATIVE_MACOS_AUDIO.md` remains the implemented Phase-C contract even if historical wording inside that document still describes it as planned.
- **Phase D — Native iOS/iPadOS:** in progress. D1 is complete/frozen for continued development, D2.1 is complete, and D2.2 is the next implementation step. `PHASE_D_NATIVE_IOS_IPADOS.md` remains authoritative for the Phase-D architecture and roadmap; `PHASE_D_D1_STATUS.md` records implementation status.

A physical-device production-upgrade smoke confirmation remains required before final Flutter-to-native replacement/release, but it is not a blocker for D2 development.

## Reference evidence

`reference/` contains historical FluxBar and FluxNews material that can help preserve useful product behavior and identify feature gaps. These documents are **not** implementation roadmaps and are **not** authoritative when they conflict with the architecture decisions or the active Phase-D contract.

For Phase D, the current native macOS implementation is the primary native reference. Flutter FluxNews is consulted only for mobile-specific capability and legacy-migration evidence; it is not a parity checklist and intentionally removed behavior must not be reintroduced without a product decision.

Old Go-core compatibility contracts, Go-to-Rust migration plans, temporary mobile runtime-proof plans/status files, differential-testing plans, and superseded shared-core roadmaps have deliberately been removed from the active documentation set. The Go core is retired; new work targets the Rust architecture directly.

## Working rule

Use documentation to answer a concrete implementation question or preserve an existing feature. Do not start broad compatibility or possibility-analysis work unless an unresolved decision blocks durable implementation.

For Phase D specifically, inspect the current Rust Core and native macOS implementation before treating a Flutter behavior as a missing requirement. Extract Apple-shared Swift code only on first real reuse rather than through a speculative up-front refactor.
