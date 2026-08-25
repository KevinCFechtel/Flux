# Flux

Flux is a native-client RSS reader for [Miniflux](https://miniflux.app/) built around one shared Rust core. FluxNews is the current macOS client.

## Requirements

- macOS 15 or later
- Rust
- Xcode Command Line Tools
- An accessible Miniflux instance with an API key

## Development

The Rust workspace is contained in `core/`. Run its checks from the repository root:

```bash
cargo fmt --manifest-path core/Cargo.toml --all --check
cargo test --manifest-path core/Cargo.toml --workspace
cargo build --manifest-path core/Cargo.toml --workspace
```

Generate the Swift bindings and release dylib required by Xcode:

```bash
zsh macos/Build/build-uniffi.sh
```

Build the macOS app for normal development. The resulting ad-hoc-signed app is at `dist/FluxNews.app`:

```bash
bash macos/Build/build-app.sh
```

## Diagnostics

FluxNews forwards structured Rust Core diagnostics to macOS Unified Logging. Stream all application activity with:

```bash
log stream --style compact --predicate 'process == "FluxNews"'
```

Limit output to Core diagnostics with:

```bash
log stream --style compact --predicate 'process == "FluxNews" AND subsystem == "dev.kevincfechtel.fluxNews"'
```

Use the same production configuration without signing or notarization to prepare a release build:

```bash
CONFIGURATION=Release bash macos/Build/build-app.sh
```

## Create a Release

A release uses a Developer ID signing identity and a `notarytool` Keychain profile. Keep those local or supply them through the environment:

```bash
xcrun notarytool store-credentials FluxNews-notary
cp macos/Build/.env.example macos/Build/.env
bash macos/Build/release.sh
```

`macos/Build/.env` is ignored by Git. `release.sh` builds the Rust/UniFFI-backed app, signs it with hardened runtime, notarizes and staples it, then creates and validates `dist/release/FluxNews-<version>-macos-<architecture>.zip`.

Changes should be covered by appropriate tests. Pull requests should focus on a clearly described problem or feature.

## License

FluxNews is released under the [BSD 3-Clause License](LICENSE).
