# AGENTS.md

## Goal

Build Flux toward one shared Rust core consumed by native macOS, iOS, and Android clients.
Prioritize durable product value. Avoid temporary architectures, compatibility layers, PoCs, migrations, or refactors that are expected to be replaced shortly afterward.

The human developer owns product and architecture decisions. Do not silently introduce or reopen major design choices.

## Architecture Authority

For non-trivial work, use this order of authority:

1. `docs/ARCHITECTURE_DECISIONS.md` — authoritative target architecture and explicitly agreed product/core boundaries.
2. Current Rust implementation and tests — evidence of what is implemented today, not permission to override the target architecture.
3. `docs/reference/` — historical product and feature evidence used to avoid losing valuable behavior.

If reference material conflicts with `ARCHITECTURE_DECISIONS.md`, the architecture decisions win.

The former Go core is retired and out of scope. Do not preserve Go compatibility, Go ABI behavior, Go database interoperability, or Go migration phases unless a task explicitly asks for historical analysis.

## Binding Decision

UniFFI is the selected binding technology for the shared Rust core.
Do not reopen the binding choice or introduce a temporary C/JSON/JNI/Swift bridge as an intermediate architecture unless explicitly requested.

Design the public Rust boundary to be UniFFI-friendly: coarse-grained domain operations, owned DTOs/records/enums, explicit errors, batch operations where appropriate, and no UI-specific concepts.

## Core / Native Boundary

The Rust core owns background/domain responsibilities such as persistence, Miniflux communication, sync/reconciliation, durable mutations, article/feed/category data, content processing, cache/media metadata, core settings, queries, and structured core events.

Native clients own presentation and OS integration: navigation, visible list snapshots, scroll position, gestures, dialogs, theme/layout, browser/share surfaces, secure credential storage, native background scheduling/transfer facilities, playback engines, widgets, and OS notifications.

A UI interaction may call a core domain operation, but the core API must not be named or shaped around a swipe, button, context menu, pull-to-refresh, or other UI mechanism.

## Implementation Rules

- Prefer the smallest durable implementation that advances the target architecture.
- Do not create parallel implementations when an existing target abstraction can be extended cleanly.
- Do not perform broad compatibility audits or exploratory PoCs unless a concrete unresolved blocker requires them.
- Reuse old documentation only as evidence of required behavior or feature coverage.
- Keep visible UI snapshots independent from background core state changes as defined in the architecture decisions.
- Keep secrets out of core persistence and logs.
- Keep changes focused; report unrelated issues instead of fixing them automatically.
- New dependencies require a concrete justification.

If a requested change requires a product/architecture decision not already covered by `ARCHITECTURE_DECISIONS.md`, stop and surface that decision instead of guessing.

## Validation

Run validation appropriate to the changed Rust/native target. Never claim a build, test, migration, or command succeeded unless it was actually executed successfully.

Give extra scrutiny to persistence/schema changes, Miniflux sync/reconciliation, concurrency/background execution, credentials/security/privacy, automatic read-state mutation, notifications, media/download state, UniFFI boundaries, and destructive reset/cleanup behavior.

## Human Review Summary

After non-trivial implementation, report briefly:

- **What** changed.
- **Why** it was needed.
- **Code** files/symbols worth reviewing.
- **Risk** only where meaningful.
- **Validation** actually executed.
- **Open decision** only if human input is genuinely required before proceeding.

Do not generate a new roadmap unless explicitly asked.
