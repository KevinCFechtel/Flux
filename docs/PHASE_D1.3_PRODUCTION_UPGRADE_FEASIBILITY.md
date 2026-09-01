# Phase D1.3: Production Upgrade Feasibility

## Verified legacy contract

The historical FluxNews revision `8f8161787d99b6bedb3d17404bb370b53c869aae`
defines the production identity as `dev.kevincfechtel.fluxNews`. Its iOS
entitlements declare `group.dev.kevincfechtel.fluxNews` and
`com.apple.developer.carplay-audio`. The URL scheme is `fluxnews`.

The repository does not contain the Flutter project itself. The historical
source audit therefore proves storage names and code paths, but not the state
of a particular installed user's device.

## Configurations

`FluxNews` remains the normal native development scheme. It uses the existing
`dev.kevincfechtel.fluxNews.nativeDev` Bundle ID, has no production App Group
entitlement, and stores Core data under `FluxNewsNativeDev`.

`FluxNewsUpgradeTest` uses the `Upgrade Test` build configuration. It uses the
existing production Bundle ID and the verified App Group/CarPlay entitlements.
Its Rust Core data is deliberately separate under `FluxNewsNativeUpgradeTest`.
It is not an App Store upload configuration and requires a matching signed
development profile before device installation.

## Read-only probe

`LegacyStateDiscovery` performs no writes. It reads Keychain attributes only,
checks App Group access, checks file existence/counts, and reads file metadata.
It does not open SQLite, modify UserDefaults, read secret values, move/delete
files, or initialize Core from legacy paths.

| Category | Proven source | Probe result |
| --- | --- | --- |
| Account | Flutter secure storage, service `flutter_secure_storage_service`, keys `minifluxURL` and `minifluxAPIKey` | Presence only; values never displayed |
| Custom headers | Secure-storage keys with `customHeadersKey_` / `customHeadersValue_` prefixes | Key count only |
| Compatible settings | Secure-storage keys including `useBlackMode`, sync, truncation, and audio settings | Count of known current-equivalent keys |
| Feed preferences | Secure-storage key `feedSettingsOverrides` | Presence only |
| Playback progress | Secure-storage keys prefixed `audio_progress_` | Count only |
| Download metadata | Secure-storage path/timestamp/title/feed-title prefixes | Count only |
| Download files | Application Support `audio_cache`, files prefixed `audio_` | File count only; no adoption |
| Legacy database | Library `news_database.db` | Existence only; never opened |
| Legacy cache | Library `Caches` | Read-only file presence |

The App Group and Keychain results require the production identity, valid
entitlements, and a physical installation containing legacy state. The
nativeDev build should report them unavailable because it intentionally uses a
different identity.

## Physical upgrade procedure

1. Install or use the current Flutter FluxNews production/TestFlight build on
   a physical iPhone.
2. Configure an account, a current setting, one feed preference, podcast
   playback progress, and a downloaded audio item where practical.
3. Record the expected categories without recording secret values.
4. Install the signed native `FluxNewsUpgradeTest` build over the Flutter app;
   do not delete the Flutter app first.
5. Launch it and verify the diagnostic discovery section reports the expected
   identity, App Group, Keychain presence, settings, progress, downloads, and
   database/cache detection.
6. Verify Core paths use `FluxNewsNativeUpgradeTest`, not `Library/news_database.db`
   or `audio_cache`.
7. Compare the legacy files and database timestamps/content after the run.
   The probe must not have moved, renamed, deleted, or rewritten them.

This procedure has not been executed in the available environment. Simulator
launches prove only the native shell and Core behavior, not production App
Group/Keychain access or an update over Flutter.

## Repeating migration tests later

Application deletion does not reliably remove Keychain items. App Group data
may remain while another group member is installed. Reinstalling Flutter may
also create a new database rather than reproduce the original state. D9/D10
tests should preserve a device backup/fixture, explicitly inspect and reset
Keychain/App Group state, and clear the new `FluxNewsNativeUpgradeTest` Core
directory between repetitions. No migration marker or reset tool exists in
D1.3.
