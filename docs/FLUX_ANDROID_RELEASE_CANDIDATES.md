# Flux: Unified release process (Android, iOS, macOS)

The manual `.github/workflows/release.yml` runs in **Flux**, prior to the FluxNews repository cutover. It accepts the exact `scope` (android, ios, macos, all), `version_name`, immutable full `source_sha` on main, and `mode` (validate or release). Selected version names must match the respective committed `Build/versions/<platform>.properties`; existing date-based versionCodes remain unchanged.

- validate: run the Rust workspace regression gate once, iOS/macOS tests for selected platforms, and for Android the existing F-Droid recipe/scanner/unsigned source-build gate.
- release: the same selected gates; Android additionally runs two independent same-SHA F-Droid builds, compares their exact APK bytes, signs the unsigned APK with the developer key and checks package/version/fingerprint; only then publish to GitHub Releases in **Flux**.
- Tags: android/vX.Y.Z, ios/vX.Y.Z, macos/vX.Y.Z independently. Scope all requires identical version and SHA for all platforms and creates all three tags plus vX.Y.Z, **one** combined GitHub Release.
- Android release assets are signed APK and checksum. iOS/macOS Releases contain test status and notes, not an unverified IPA/PKG. App Store exports and uploads remain manual.
- No F-Droid GitLab submission or Play publication. Cutover to FluxNews remains separate and requires explicit authorization.

## Signing secrets

The `release-testing` GitHub Environment should be restricted to main and require manual deployment approval. In Flux, the following **existing FluxNews names are currently configured as Repository Secrets** and are consumed only by the signer job, which is bound to `release-testing`. This is acceptable for the pre-cutover test; long term, move them to Environment Secrets for tighter exposure:

- `KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_PASSWORD`
- `KEY_ALIAS`

The signing job explicitly checks the existing developer certificate SHA-256 `fee5401bc9d59cf5a8a461ba9698c482e87ed8ffb9258786a3d01d0356ea2ebb`. **Do not use a Play upload key if it has a different fingerprint.** Secret configuration and trust are controlled in GitHub settings, not by this PR.

The full release mode requires a successful exact same-SHA reproducibility comparison; it can fail if native source builds are not byte-identical. That is a blocker to that release mode, not permission to bypass the comparison. A normal CI/validation run uses no signing secrets. No release or tag is created from a push or PR.

## Safety and preflight

- Choose a full immutable SHA on `main`. Old tags are never moved. Each failed build requires a new fixed SHA and new mandatory checks.
- Only the publishing job gets `contents: write`, and only the signer gets the four environment secrets.
- Partial promotion is fail-closed. If tag creation has begun and a later GitHub operation fails, the workflow reports the tags it can observe and requires manual recovery. A rerun is rejected by preflight while any immutable target tag exists; never reuse, move, delete, or overwrite tags automatically.
- FD-01 user-installed CA is owner-accepted residual risk. This release process does not reopen that device test.

## Automated workflow contract

`Release script contracts` validates the release-related workflow YAML with pinned `actionlint` v1.7.12 and runs `Build/test-release-workflow-contract.py`. These checks are intentionally build-free: they cover the four scopes, selective gates, one Rust gate, Android F-Droid reproducibility/signing dependencies, tag sets, restricted write permissions, signing secret names, and partial-promotion fail-closed behavior without starting Android, F-Droid, or Apple builds.
