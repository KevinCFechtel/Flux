# Flux Documentation

This directory is intentionally small.

## Authoritative target architecture

- `ARCHITECTURE_DECISIONS.md` — explicitly agreed target architecture for the shared Rust core and native macOS/iOS/Android clients. This is the primary architecture authority.

## Reference evidence

`reference/` contains historical FluxBar and FluxNews material that can help preserve useful product behavior and identify feature gaps. These documents are **not** implementation roadmaps and are **not** authoritative when they conflict with the architecture decisions.

Old Go-core compatibility contracts, Go-to-Rust migration plans, temporary mobile runtime-proof plans/status files, differential-testing plans, and superseded shared-core roadmaps have deliberately been removed from the active documentation set. The Go core is retired; new work targets the Rust architecture directly.

## Working rule

Use documentation to answer a concrete implementation question or preserve an existing feature. Do not start broad compatibility or possibility-analysis work unless an unresolved decision blocks durable implementation.
