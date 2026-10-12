# macOS App Sandbox — B1 implementation and acceptance

The macOS app has **not been released**. The developer has explicitly accepted losing existing local macOS development data when the app switches to sandboxed storage. There is **no migration or compatibility path**.

## Implemented in this branch

- Host entitlements: `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-write`, and the existing `group.dev.kevincfechtel.fluxNews` App Group.
- Widget entitlements remain separate and keep their existing sandbox and App Group.
- Internal podcast downloads are now under sandbox-local `Application Support/FluxNews/Media` instead of `~/Movies/FluxNews`. The existing `BrowserStore` persistent/core cache locations resolve under the app container when sandboxed.
- `apple/macos/Build/build-app.sh` now verifies that the signed host has the new entitlements rather than asserting that the host is unsandboxed.
- XCTest checks verify source entitlements and that the derived media path uses Application Support.

## Not implemented

No old data, Keychain, download or account migration. The existing Developer ID/notarization script remains separate from the future Mac App Store export script. No claim of successful App Store provisioning or review is made.

## Required device and signed-app acceptance (still open)

1. Sign the app with an actual development/distribution profile supporting its host+widget App Group. Inspect **signed** entitlements, not only XML sources.
2. Start with a fresh sandbox container and fresh account credentials. Confirm that Core database and caches persist across relaunch.
3. Verify sync, image/media networking, remote podcast playback, downloaded podcast playback, and the Listening List with local file access.
4. Verify Settings backup import/export via `NSOpenPanel` and `NSSavePanel`, including read/write permissions and actual encrypted backup round-trip.
5. Verify WidgetKit snapshots and the App Group across app/widget process boundaries.
6. Verify Keychain save/load after relaunch, periodic sync, menu bar controls, login-item registration and media remote controls.
7. Test existing Developer ID packaging separately if it is retained; implement and validate the Mac App Store archive/Transporter path only after acceptance.
8. Keep a record of sandbox-denial logs and resolve actual missing capabilities without granting broad filesystem access.

CI compilation and source-plist tests alone **do not prove** end-to-end sandbox behavior.
