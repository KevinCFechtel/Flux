#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE="${REPOSITORY_DIR}/core/Cargo.toml"
CRATE="flux-uniffi"
PACKAGE_DIR="${SCRIPT_DIR}/Products/FluxUniFFI"
XCFRAMEWORK="${PACKAGE_DIR}/FluxUniFFI.xcframework"
SOURCES_DIR="${PACKAGE_DIR}/Sources"

for command_name in cargo lipo install_name_tool rustup xcodebuild; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

targets=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
)

for target in "${targets[@]}"; do
  rustup target list --installed | grep -qx "${target}" || {
    echo "Required Rust target is not installed: ${target}" >&2
    echo "Install it with: rustup target add ${target}" >&2
    exit 1
  }
done

for target in "${targets[@]}"; do
  cargo build --manifest-path "${WORKSPACE}" --package "${CRATE}" --release --target "${target}"
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/flux-uniffi-apple.XXXXXX")"
trap 'rm -rf -- "${work_dir}"' EXIT

macos_library="${work_dir}/macos/libflux_uniffi.dylib"
ios_library="${work_dir}/ios/libflux_uniffi.dylib"
ios_simulator_library="${work_dir}/ios-simulator/libflux_uniffi.dylib"
headers_dir="${work_dir}/Headers"

mkdir -p \
  "$(dirname -- "${macos_library}")" \
  "$(dirname -- "${ios_library}")" \
  "$(dirname -- "${ios_simulator_library}")" \
  "${headers_dir}" \
  "${SOURCES_DIR}"

(
  cd "${REPOSITORY_DIR}/core"
  cargo run --manifest-path "${WORKSPACE}" --package "${CRATE}" --bin uniffi-bindgen -- \
    generate "${REPOSITORY_DIR}/core/target/aarch64-apple-darwin/release/libflux_uniffi.dylib" \
    --library --crate flux_uniffi --language swift --out-dir "${headers_dir}"
)

lipo -create \
  "${REPOSITORY_DIR}/core/target/aarch64-apple-darwin/release/libflux_uniffi.dylib" \
  "${REPOSITORY_DIR}/core/target/x86_64-apple-darwin/release/libflux_uniffi.dylib" \
  -output "${macos_library}"
cp "${REPOSITORY_DIR}/core/target/aarch64-apple-ios/release/libflux_uniffi.dylib" "${ios_library}"
cp "${REPOSITORY_DIR}/core/target/aarch64-apple-ios-sim/release/libflux_uniffi.dylib" "${ios_simulator_library}"

for library in "${macos_library}" "${ios_library}" "${ios_simulator_library}"; do
  [[ -f "${library}" ]] || { echo "Missing UniFFI library: ${library}" >&2; exit 1; }
  install_name_tool -id "@rpath/libflux_uniffi.dylib" "${library}"
done

cp "${headers_dir}/flux_uniffi.swift" "${SOURCES_DIR}/flux_uniffi.swift"
rm "${headers_dir}/flux_uniffi.swift"
cp "${headers_dir}/flux_uniffiFFI.modulemap" "${headers_dir}/module.modulemap"

rm -rf -- "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -library "${macos_library}" -headers "${headers_dir}" \
  -library "${ios_library}" -headers "${headers_dir}" \
  -library "${ios_simulator_library}" -headers "${headers_dir}" \
  -output "${XCFRAMEWORK}"

for required in \
  "${SOURCES_DIR}/flux_uniffi.swift" \
  "${XCFRAMEWORK}/Info.plist"; do
  [[ -f "${required}" ]] || { echo "Missing packaged UniFFI artifact: ${required}" >&2; exit 1; }
done

echo "FluxUniFFI package: ${PACKAGE_DIR}"
