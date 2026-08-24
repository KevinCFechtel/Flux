#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
generated="$root/macos/FluxBar/Generated"
workspace="$root/core/Cargo.toml"
library="$root/core/target/release/libflux_uniffi.dylib"
mkdir -p "$generated"

if [[ "${FLUX_UNIFFI_PREPARED:-0}" != "1" ]]; then
  cargo build --manifest-path "$workspace" --package flux-uniffi --release
  (
    cd "$root/core"
    cargo run --manifest-path "$workspace" --package flux-uniffi --bin uniffi-bindgen -- generate "$library" --library --crate flux_uniffi --language swift --out-dir "$generated"
  )
fi

for required in "$library" "$generated/flux_uniffi.swift" "$generated/flux_uniffiFFI.h" "$generated/flux_uniffiFFI.modulemap"; do
  [[ -f "$required" ]] || { print -u2 "Missing UniFFI build output: $required"; exit 1; }
done

# Swift discovers Clang modules through the conventional module.modulemap name.
cp "$generated/flux_uniffiFFI.modulemap" "$generated/module.modulemap"

if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
  mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
  cp "$library" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libflux_uniffi.dylib"
  install_name_tool -id "@rpath/libflux_uniffi.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libflux_uniffi.dylib"
fi
