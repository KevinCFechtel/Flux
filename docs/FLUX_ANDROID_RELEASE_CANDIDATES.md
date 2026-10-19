# Flux Android release candidate

The Android release workflow is deliberately implemented in Flux before any FluxNews cutover. No F-Droid/GitLab, Play or FluxNews publication occurs.

## Manually start

Actions > Flux Android release candidate > Run workflow.

Specify a full 40-character commit SHA that is reachable from main and contains the intended version fields in Build/versions/android.properties.

- Mode validate: one existing F-Droid source build with lint, blocking scanner, package/version/three-ABI checks; never loads signing secrets.
- Mode prerelease: two independent source builds from the identical SHA; strict byte-for-byte APK comparison; only then developer-sign APK and create an immutable GitHub prerelease in Flux with tag android/vX.Y.Z. Existing tags cannot be overwritten.
- Version name and version code are taken from committed Build/versions/android.properties, retaining the date-based code convention such as 2026101901.

## Configure before signing

Create GitHub Actions environment release-testing in the Flux repository, require manual approval and restrict it to a trusted main branch. Repository environment protection must be configured manually.

Provide these environment secrets (never commit the keystore):

- FDROID_DEVELOPER_KEYSTORE_BASE64: base64 of the original Flutter/F-Droid developer signing keystore, one line.
- FDROID_DEVELOPER_STORE_PASSWORD
- FDROID_DEVELOPER_KEY_PASSWORD
- FDROID_DEVELOPER_KEY_ALIAS

The signing job verifies the previously published developer signer SHA-256 fingerprint fee5401bc9d59cf5a8a461ba9698c482e87ed8ffb9258786a3d01d0356ea2ebb and fails for any mismatch. A Google Play upload key is not automatically the same signer. No secrets are passed to source-build jobs.

When moving to FluxNews, recreate the environment in FluxNews, transfer the secrets securely and retire the temporary Flux signing access.

## Explicit limitations

- Flux GitHub prereleases are permitted, but official F-Droid submission and Play publication are not implemented in this workflow.
- Identical unsigned source APKs validate same-SHA build reproducibility; they are not automatically proof that independently built APK bytes can be combined with a developer signature under F-Droid's reproducible-build verification.
- Android updates still require compatible signer fingerprints, the same package ID, and increasing version codes.
- FD-01 user-installed CA remains an owner-accepted risk rather than a proven device test.
- No release tags are created from pushes or PRs. Sign/promotion requires a separate manually dispatched prerelease mode. Only Android/F-Droid work is performed for that mode.
