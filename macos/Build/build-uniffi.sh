#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
generated="$root/macos/FluxNews/Generated"
workspace="$root/core/Cargo.toml"
library="$root/core/target/release/libflux_uniffi.dylib"
arm64_library="$root/core/target/aarch64-apple-darwin/release/libflux_uniffi.dylib"
x86_64_library="$root/core/target/x86_64-apple-darwin/release/libflux_uniffi.dylib"
required_architectures=(arm64 x86_64)
mkdir -p "$generated"

if [[ "${FLUX_UNIFFI_PREPARED:-0}" != "1" ]]; then
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target list --installed | grep -qx "$target" || {
      print -u2 "Required Rust target is not installed: $target"
      print -u2 "Install it with: rustup target add $target"
      exit 1
    }
    cargo build --manifest-path "$workspace" --package flux-uniffi --release --target "$target"
  done
  for artifact in "$arm64_library" "$x86_64_library"; do
    [[ -f "$artifact" ]] || { print -u2 "Missing architecture-specific UniFFI library: $artifact"; exit 1; }
  done
  mkdir -p "${library:h}"
  lipo -create "$arm64_library" "$x86_64_library" -output "$library"
  install_name_tool -id "@rpath/libflux_uniffi.dylib" "$library"
  (
    cd "$root/core"
    cargo run --manifest-path "$workspace" --package flux-uniffi --bin uniffi-bindgen -- generate "$arm64_library" --library --crate flux_uniffi --language swift --out-dir "$generated"
  )
fi

for required in "$library" "$generated/flux_uniffi.swift" "$generated/flux_uniffiFFI.h" "$generated/flux_uniffiFFI.modulemap"; do
  [[ -f "$required" ]] || { print -u2 "Missing UniFFI build output: $required"; exit 1; }
done

architectures="$(lipo -archs "$library")"
for architecture in $required_architectures; do
  [[ " $architectures " == *" $architecture "* ]] || { print -u2 "Universal UniFFI library is missing $architecture: $architectures"; exit 1; }
done

# Swift discovers Clang modules through the conventional module.modulemap name.
cp "$generated/flux_uniffiFFI.modulemap" "$generated/module.modulemap"

if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
  embedded_library="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libflux_uniffi.dylib"

  mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
  cp "$library" "$embedded_library"
  install_name_tool -id "@rpath/libflux_uniffi.dylib" "$embedded_library"

  if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign \
      --force \
      --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      --timestamp=none \
      "$embedded_library"
  fi
fi
