# iOS D4 follow-up findings

Status: **OPEN / follow-up required before final Phase-D acceptance**

This note records two findings discovered while validating D5. They belong to the existing D4/U4 native iOS mutation and interaction contract; they are not new D5 work and do not reopen the frozen UIKit Timeline architecture.

## 1. Native iOS mutation delivery mode

The Rust Core already supports `DeliveryMode::Live` and `DeliveryMode::Deferred`. Native iOS Read/Unread and Star/Unstar mutations, including Scrollover bulk Read mutations, already use the existing Core mutation/pending-delivery path. The Core default is currently `Deferred`, and native iOS does not currently make an explicit product-level selection of `Live`.

Follow-up decision/implementation:

- Native iOS should use the existing Core `DeliveryMode::Live` for Read/Unread and Star/Unstar mutations.
- Local persistence remains authoritative and immediate; UI/count/widget feedback must not wait for the network.
- `Live` means attempting delivery of the persisted pending mutation to Miniflux immediately. It must not start a full/delta sync merely to deliver the mutation.
- Retryable remote/network failure must leave the mutation durably pending for later retry through the existing Core reconciliation/sync path.
- Scrollover keeps the accepted U4 worker contract: session-owned serialization, deduplication, maximum 64 IDs per Core bulk call, 500 ms bounded drain deadline, ordering/precedence and failure recovery. Enabling live delivery must not introduce one Swift-side network request per crossed article or otherwise redesign Scrollover scheduling.
- Do not change the global Rust Core default solely to achieve the iOS product behavior without separately evaluating other Core clients (including macOS).

This is a D4/U4 contract completion/configuration item, not a new sync architecture.

## 2. UIKit Timeline swipe-action assignment

The existing D4 UIKit Timeline contract currently specifies system-native swipe actions with:

- leading: Read / Unread;
- trailing: Star / Unstar;
- native full-swipe behavior retained.

A follow-up product review is required for the **number and assignment of swipe actions on each side**. Any decision to add, remove, move, or reorder actions should be recorded as an amendment to the D4 UIKit interaction contract and covered by focused regression tests.

This does **not** by itself reopen the frozen Timeline container, layout, image pipeline, Scrollover detector, or mutation-worker architecture. It is an interaction/presentation configuration change unless future requirements provide concrete evidence that a deeper architecture change is necessary.

## Scope guard

These findings must not be folded into D5 Background Sync / Notifications / Widgets. D5 validation can continue independently. A later implementation chat should re-read the authoritative `docs/PHASE_D_NATIVE_IOS_IPADOS.md`, current `main`, and this note before changing either behavior.