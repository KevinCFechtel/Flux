# iOS D9 — Flutter Replacement Completion / Legacy-Parity Closure

> **Status: PLANNED — FINAL NATIVE REPLACEMENT COMPLETION GATE**
>
> Decision date: 26 September 2026.
>
> `docs/PHASE_D_NATIVE_IOS_IPADOS.md` remains the authoritative Phase-D
> roadmap. This document records the final product decisions from the
> repository-first FluxNews-to-native gap audit. D9 is not a general Flutter
> parity project: only the explicitly retained capabilities below are required.
> Items explicitly retired or replaced here must not later be reintroduced as
> accidental "parity gaps" without a new product decision.

## 1. Purpose

D1-D7 establish the native architecture and system integrations. D8 is not
required for the replacement release. D9 closes the remaining user-visible and
upgrade/release gaps required to replace the production Flutter iOS/iPadOS app
with the native client.

D9 must preserve the frozen Rust/Core ownership, UIKit Timeline architecture,
D5 background/notification ownership, D6 media runtime, and D7 system-media /
CarPlay ownership. Additive settings or WidgetKit configuration must reuse those
boundaries rather than create parallel state owners.

## 2. D9 release-critical replacement gates

### D9-A — Production Flutter-to-native migration

Complete the production-identity migration coordinator over the already-defined
copy/import-only migration contract.

Required retained state remains limited to semantically compatible,
non-reconstructable state such as account association/credentials, custom HTTP
headers, compatible Core/native settings, compatible feed preferences, media
policies, playback progress, and valid downloaded-media association.

The migration remains idempotent, restart-safe, and non-destructive to legacy
storage. Existing valid native/Core state wins.

### D9-B — Config Backup and Restore on iOS/iPadOS

Expose the existing Flux Config Backup contract through native iOS Settings:

- password-encrypted export;
- native file/share presentation;
- import/restore with validation and explicit failure presentation;
- safe account/Core replacement and widget/cache invalidation according to the
  existing architecture contract.

This is configuration backup, not article/media backup.

### D9-C — Configurable Bottom Action Bar

Restore the useful iOS toolbar configurability from FluxNews using semantic
native actions rather than persisted SwiftUI control identities.

Sync remains a stable direct action. The supported configurable action pool is
the native semantic set already owned by the app, including Search,
All/Unread/filtering, sort/filter access, Mark as Read, Mark as Read and Next,
Listening List, Settings, and More/overflow as appropriate.

Configuration must preserve an always-available overflow route and must continue
to obey the existing adaptive placement rules for iPhone portrait, compact
landscape, regular split presentation, and system vertical-toolbar environments.

### D9-D — Localization parity required for replacement

The native iOS/iPadOS app must restore the production FluxNews language set:

- English;
- German;
- Spanish;
- Galician;
- Dutch;
- Tamil;
- Turkish.

Localization remains native and Weblate-managed. This does not require carrying
forward obsolete Flutter-only strings or settings.

## 3. D9 Settings completion

### D9-E — Downloaded Data

Add a normal Settings destination for downloaded media storage.

Required information/actions:

- downloaded audio item/file count;
- total local downloaded-media storage size;
- destructive **Delete All Downloads** action with confirmation;
- refresh after transfer/deletion changes.

This is a storage-management surface over the existing D6/Core download model.
It must not create a second downloads library or duplicate Listening List state.

### D9-F — Miniflux account information and transport warning

Account/Settings must additionally expose:

- the detected Miniflux server version when available;
- a visible warning when the configured Miniflux server uses unencrypted
  `http://` rather than HTTPS.

HTTP remains supported where the existing account validation permits it; the
warning informs the user rather than changing transport ownership.

### D9-G — Open Source and About

Settings must provide normal user-facing access to:

- the Flux project/source repository;
- app version/build information;
- About/legal information appropriate for the shipped native app;
- Miniflux/project attribution where retained by the product.

Developer Diagnostics is not a substitute for this normal user-facing
information.

## 4. D9 Widget configuration extension

The existing D5 WidgetKit architecture remains authoritative: the extension is
credential-free, Core-free, database-free, and network-free and reads only a
versioned App Group snapshot plus bounded icon files.

D9 adds per-widget configuration for:

- **Read filter:** Unread / All;
- **Sort order:** Newest First / Oldest First.

The configured read filter applies inside the selected widget scope. For
Bookmarks, **All** means all starred articles represented by the retained widget
projection and **Unread** means unread starred articles.

The widget snapshot remains bounded. If `WidgetSnapshotV1` cannot correctly
represent both read filters and both sort directions for the supported widget
capacities, D9 must introduce a versioned backward-safe snapshot extension
rather than letting the WidgetKit extension query Core, SQLite, Miniflux, or
credentials directly.

There is intentionally **no widget-specific Open in Miniflux preference**.
Article taps already enter the main app's normal article-open path, which applies
the article/feed routing policy including the existing per-feed **Open in
Miniflux** setting. D9 must preserve that single routing authority.

## 5. Explicitly retired/replaced FluxNews behaviors

The following audited FluxNews behaviors are deliberately **not** D9 work.

### Feed-icon cache clear

No user-facing "Delete Feed Icons Only" control is required. Feed icons remain
regenerable cache and use the native/Core cache lifecycle.

### OLED / True Black

There is no Flux-specific OLED/True-Black toggle. Native iOS/iPadOS should use
system semantic colors, materials, and platform Dark Mode so OLED-capable
devices receive the best native dark appearance available without a separate
Flux setting.

This is an explicit product decision and replaces the legacy
`useBlackMode` preference.

### Legacy headline-placement toggle

The old `showHeadlineOnTop` option is not carried forward. The native article
views and frozen UIKit Timeline own the canonical content ordering/layout.

### Legacy paragraph and attachment-image preferences

The legacy per-feed `preferParagraph` and `preferAttachmentImage` settings
are not carried forward. Current Core/native article processing and image
selection remain authoritative.

### Image-cache duration

There is no user-configurable image-cache age. Native iOS manages the article
image path with bounded decoded-image caching, normal HTTP caching, memory
pressure/eviction, and implementation-owned cache policy. Cache tuning is a
native performance concern, not a product setting.

## 6. D9 acceptance contract

D9 is complete only when:

1. the production-identity Flutter-to-native migration path is validated on a
   physical device without destructive legacy conversion;
2. config backup/export and restore/import complete a tested native round trip;
3. Bottom Action Bar semantic configuration persists and remains correct across
   the existing adaptive iPhone/iPad layouts;
4. EN/DE/ES/GL/NL/TA/TR native localization coverage is present for the
   production UI;
5. Settings exposes downloaded-data count/size and Delete All Downloads;
6. widget instances can independently select Unread/All and
   Newest First/Oldest First while the extension remains Core/DB/network-free;
7. widget article taps continue to use the normal app/per-feed open policy with
   no widget-specific Miniflux destination setting;
8. Settings exposes Miniflux version, insecure-HTTP warning, Open Source, and
   About/version/legal information;
9. no retired legacy toggle listed in this document is reintroduced;
10. the canonical Rust, native iOS and affected shared-Apple/macOS regression
    gates remain green.

After D9 acceptance, no known release-blocking Flutter replacement gap remains
unless a new concrete product or production-upgrade defect is discovered.
