# Unified Release and Distribution

> **Status: PLANNED FOLLOW-UP / REPLACEMENT IMPLEMENTATION ALREADY COMPLETE**
>
> This document defines the next repository-level release/distribution work after
> the completed native macOS, iOS/iPadOS and Android replacement. It does not
> reopen product implementation, migration acceptance, or frozen architecture.
> The goal is to make release preparation predictable and consistent across all
> native apps while preserving each store's real distribution model.

## 1. Goals

Create one coherent release-scripting model across Android, iOS and macOS.

The release layer should:

- expose consistent version/build-number inputs;
- separate local build/test concerns from signed distribution preparation;
- validate package/bundle identifiers, versions, embedded extensions and signing;
- put final artifacts in predictable `dist/` locations;
- fail early on missing signing configuration or identity mismatches;
- be callable locally and from GitHub Actions without duplicating release logic;
- keep secrets, keystores, provisioning material and App Store credentials out of Git;
- allow CI to build release artifacts when useful, without making CI artifact
  publication the primary Apple distribution mechanism.

Platform-specific store requirements remain explicit. "Unified" means a common
interface and ownership model, not one generic script that hides important
differences between Gradle, Xcode, Play, F-Droid and App Store Connect.

## 2. Target command model

Prefer a small repository-level release entry point, for example:

```text
Build/release.sh android play <versionCode> <versionName>
Build/release.sh android fdroid <versionCode> <versionName>
Build/release.sh ios appstore <buildNumber> <versionName>
Build/release.sh macos appstore <buildNumber> <versionName>
```

The exact file name may change during implementation, but the public contract
should remain narrow and consistent:

- platform;
- distribution target;
- build/version;
- optional output directory;
- no implicit publication unless the command explicitly says `publish`.

The top-level script should delegate to platform-owned scripts rather than
embedding Gradle/Xcode behavior itself.

A preferred shape is:

```text
Build/
  release.sh

android/Build/
  build-app.sh
  prepare-play-release.sh
  prepare-fdroid-release.sh
  publish-fdroid.sh

apple/ios/Build/
  build-app.sh
  archive.sh
  export-appstore.sh

apple/macos/Build/
  build-app.sh
  archive.sh
  export-appstore.sh
```

Names are illustrative; implementation should reuse and rename current scripts
only where that genuinely improves consistency.

## 3. Common release contract

All production release paths should accept explicit versions.

### Android

- `versionCode`: positive integer accepted by Android/Play/F-Droid.
- `versionName`: user-visible release version.

### Apple

- `CFBundleVersion`: explicit monotonically increasing build number.
- `CFBundleShortVersionString`: user-visible release version.
- Host app and embedded extensions must use matching versions.

Release scripts must never silently invent a production version when invoked for
store distribution.

All final scripts should print a concise release summary containing:

- platform/distribution target;
- application/bundle ID;
- version;
- build/version code;
- artifact path;
- signing identity/certificate fingerprint where safe and useful;
- whether publication occurred.

## 4. Android — Google Play

The current Android build already has a canonical production bundle path through
`android/Build/build-app.sh productionBundle <versionCode> <versionName>`.

Keep that path as the implementation basis, but normalize it behind the shared
release interface.

The Play preparation step must:

- produce the signed production AAB;
- retain application ID `de.circle_dev.flux_news`;
- require explicit versionCode/versionName;
- validate the configured Play upload signing identity;
- verify the resulting bundle/package metadata;
- write the final AAB to a stable `dist/` location;
- never commit signing properties or keystores.

Uploading to Play Console may remain manual initially. If a future publish action
is added, it must be a distinct explicit operation and must not make a normal
release build publish automatically.

## 5. Android — F-Droid

A native F-Droid path is still required.

**Prerequisite:** Complete the reproducible source-build and scanner feasibility gate B2 in [POST_REPLACEMENT_FOLLOWUP_PLAN.md](POST_REPLACEMENT_FOLLOWUP_PLAN.md) before implementing the publication workflow. Pinned Cargo-derived AARs and JNA require provenance/build checks; scanner failure has not yet been established.

The repository must gain both:

1. canonical local F-Droid release preparation; and
2. a GitHub Action that builds and publishes/submits the native F-Droid release
   using the same underlying scripts.

The new F-Droid path must replace the old Flutter-repository distribution
ownership only after the native path is validated.

Requirements:

- preserve the existing F-Droid application/package identity;
- keep F-Droid signing independent from Google Play signing;
- support the architectures accepted for the native release;
- be reproducible and compatible with F-Droid's build constraints;
- avoid hidden network/bootstrap steps that make source builds non-reproducible;
- prepare/update the F-Droid metadata from the native `Flux` repository;
- validate a signed in-place update over the existing Flutter F-Droid variant;
- retain old Flutter F-Droid metadata/releases until native update compatibility
  is proven;
- make secrets/signing inputs GitHub Actions secrets or local ignored files,
  never repository content.

### F-Droid GitHub Actions

Add a dedicated workflow, for example
`.github/workflows/fdroid.yml`.

It should have two clearly separated responsibilities:

- **build/verify:** reproducible native F-Droid artifact + metadata validation;
- **publish/submit:** explicit release/manual/tag-triggered submission step after
  build/verify succeeds.

Do not make every push to `main` publish an F-Droid release.

Prefer `workflow_dispatch` and/or a deliberate release/tag trigger with
explicit version inputs or validated tag-derived versions.

The Action must call repository scripts. It must not contain a second independent
implementation of signing, versioning or packaging logic in YAML.

## 6. iOS — App Store Connect / Transporter

The primary iOS distribution remains the App Store.

Current building blocks already exist:

- `apple/ios/Build/build-app.sh`;
- `apple/ios/Build/archive.sh`;
- `apple/ios/Build/export-testflight.sh`.

These should be normalized into the common release model.

The final iOS App Store release path should:

- build the production configuration;
- archive the app;
- validate the production bundle identifier;
- validate the Widget extension identifier;
- validate App Group entitlements;
- validate host/extension version equality;
- export an App Store Connect-compatible IPA;
- place it in a predictable `dist/` directory;
- clearly report that the IPA is ready for Transporter/manual App Store Connect
  upload.

Rename `export-testflight.sh` to a more accurate App Store-oriented name if the
implementation confirms that it is a general `app-store-connect` export rather
than TestFlight-specific behavior. Preserve compatibility temporarily if other
automation already calls the old name.

### iOS CI artifact builds

GitHub Actions may optionally create unsigned or appropriately signed release
artifacts for verification/download when credentials are available.

That is supplementary. The primary production-distribution workflow should
remain:

```text
local/canonical release script
→ signed Xcode archive
→ validated App Store Connect IPA
→ Transporter/App Store Connect
→ TestFlight/App Store release
```

CI should never require storing broad Apple developer credentials merely to
replace a reliable Transporter-based release process.

## 7. macOS — App Store Connect / Transporter

**Implementation/acceptance distinction (16 October 2026):** PR #38
implemented host Sandbox entitlements and sandbox-local media storage, and
PR #53 added signed-development-build verification and safe local installation.
C3.1–C3.7 are now implemented and merged; C3.8 and the **separate B1 signed
fresh-container runtime acceptance are still open**. [Apple CI #167](https://github.com/KevinCFechtel/Flux/actions/runs/38934397341)
passed on the combined `main`, but does not close B1. Finish
[MACOS_SANDBOX_ACCEPTANCE.md](MACOS_SANDBOX_ACCEPTANCE.md) **before implementing**
the Mac App Store archive/export deliverable. That later Store export is part
of R, not part of the B1 runtime sign-off.

The primary macOS distribution should likewise be the Mac App Store.

**Mac release prerequisite and approved decision:** The macOS app has **never been released**. Its host App Sandbox entitlement has been implemented but signed-app acceptance is still outstanding. The existing Developer ID/notarization path is not a Mac App Store export. Validate host Sandbox, outbound network access, actual file-dialog capabilities and App Group provisioning **before** Mac App Store archive/export scripting. The developer explicitly accepts losing all existing unsandboxed local development data on their machine. Initialize a fresh sandbox storage/credential environment: **no database/download/Keychain migration, `container-migration.plist`, legacy-location fallback or compatibility layer is required**. See B1 in [POST_REPLACEMENT_FOLLOWUP_PLAN.md](POST_REPLACEMENT_FOLLOWUP_PLAN.md).

The existing `apple/macos/Build/build-app.sh` is currently a build/validation
script, not a complete App Store distribution path.

Add macOS equivalents to the iOS archive/export flow.

The final macOS App Store path should:

- use the production Xcode configuration;
- build/archive the host app and Widget extension;
- validate the already-implemented Sandbox, outbound network/user-selected-file permissions and host/widget App Group provisioning **in the final Mac App Store-signed artifact**;
- use the correct Mac App Store distribution signing/provisioning;
- apply explicit app/extension build and marketing versions;
- validate bundle identifiers and embedded extension metadata;
- export an App Store Connect-compatible artifact accepted by Transporter;
- place the final artifact in a predictable `dist/` directory;
- perform no upload unless explicitly requested.

The desired primary flow is:

```text
local/canonical release script
→ signed macOS archive
→ validated App Store Connect export
→ Transporter/App Store Connect
→ Mac App Store
```

As on iOS, GitHub Actions may optionally build release artifacts, but the App
Store remains the primary distribution channel.

## 8. Apple script convergence

iOS and macOS should share conventions even when their Xcode export mechanics
differ.

Align at least:

- positional/flag version inputs;
- `--help` output;
- output directory conventions;
- archive naming;
- release summaries;
- validation style;
- fail-fast handling;
- no-publish-by-default behavior.

Prefer shared shell helpers only for genuinely identical logic such as version
validation or common output formatting. Do not create a large cross-platform
shell abstraction that obscures Xcode target-specific signing or entitlement
requirements.

## 9. GitHub Actions strategy

Keep CI and distribution separate.

Existing canonical Android/Apple regression workflows remain the merge gate.

Add release-oriented workflows only where they provide value:

- Android F-Droid build/publish: required;
- Android Play release artifact: optional;
- iOS App Store artifact: optional;
- macOS App Store artifact: optional.

Release workflows should generally be manual or release/tag-driven and should:

- call the same canonical scripts used locally;
- surface artifacts for inspection when appropriate;
- use environment/secret protection for signing credentials;
- never publish from arbitrary pull requests;
- never silently derive a production signing identity from development config.

## 10. Implementation order

Implement in this order:

1. **Define common version/CLI conventions.**
   Document exact argument names and artifact paths before changing platform
   scripts.

2. **Normalize Android Play preparation.**
   Wrap the existing production AAB flow without changing its signing model.

3. **Validate F-Droid build/scanner feasibility, then implement native preparation.**
   Complete B2 in `POST_REPLACEMENT_FOLLOWUP_PLAN.md` first. Port only the still-
   required metadata/signing/reproducibility behavior from the old Flutter repository.

4. **Add Android F-Droid build/publish GitHub Action.**
   Make it call the canonical scripts and validate update compatibility before
   retiring old Flutter distribution automation.

5. **Normalize iOS archive/export.**
   Convert the existing archive + App Store Connect export path to the shared
   release interface and rename TestFlight-specific naming where appropriate.

6. **Enable and validate the macOS sandbox, then add macOS archive/export.**
   Complete B1 in `POST_REPLACEMENT_FOLLOWUP_PLAN.md` first, with fresh developer
   data (no migration), and only then create the missing App Store Connect/
   Transporter path with proper Mac App Store signing and entitlement validation.

7. **Optionally add Apple release-artifact workflows.**
   Only after local scripts are authoritative and stable.

8. **Final release smoke/documentation pass.**
   Verify `--help`, versioning, paths, signing failure modes and produced
   artifacts for all four targets: Play, F-Droid, iOS App Store and macOS App
   Store.

## 11. Definition of done

This release-scripting follow-up is complete when:

- one documented top-level interface can prepare each supported distribution
  target;
- Android Play AAB preparation is deterministic and versioned;
- the F-Droid-style source build and scanner feasibility checks pass before publishing is automated;
- Android has a native F-Droid build/publish workflow in this repository;
- F-Droid update compatibility over the existing Flutter-distributed app is
  validated;
- iOS can produce a validated production App Store Connect IPA for Transporter;
- the previously unreleased macOS app passes a fresh-install sandbox acceptance without migrating local development data;
- macOS can produce a validated Mac App Store Connect artifact for Transporter;
- Apple host apps and extensions are version/signing/entitlement checked;
- optional CI artifact jobs delegate to the same local scripts;
- no production release path publishes implicitly;
- the primary Apple release path remains App Store Connect/Transporter;
- replacement/product implementation remains untouched.

## 12. Non-goals

This follow-up does not:

- change application functionality;
- reopen migration logic;
- change Core/UniFFI architecture;
- replace Play/App Store/F-Droid with GitHub Releases;
- require fully automatic store publication;
- move production secrets into the repository;
- make CI-produced artifacts the authoritative release source when the canonical
  local script produced and validated the final signed store artifact.
