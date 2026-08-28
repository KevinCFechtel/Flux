#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
APP_DIR="${APP_DIR:-${REPOSITORY_DIR}/dist/FluxNews.app}"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/FluxNews.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APP_ENTITLEMENTS="${REPOSITORY_DIR}/macos/FluxNews/FluxNews.entitlements"
WIDGET_ENTITLEMENTS="${REPOSITORY_DIR}/macos/FluxNewsWidgets/FluxNewsWidgets.entitlements"

case "${CONFIGURATION}" in
  Debug|Release) ;;
  *)
    echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2
    exit 1
    ;;
esac

"${SCRIPT_DIR}/build-uniffi.sh"

FLUX_UNIFFI_PREPARED=1 xcodebuild \
  -project "${REPOSITORY_DIR}/macos/FluxNews.xcodeproj" \
  -scheme FluxNews \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA}" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf -- "${APP_DIR}"
mkdir -p "$(dirname -- "${APP_DIR}")"
ditto "${BUILT_APP}" "${APP_DIR}"

# Xcode intentionally builds unsigned so this local path does not require a
# Developer ID identity. Sign nested code explicitly: --deep would replace the
# extension signature and discard its distinct App Group entitlement.
WIDGET_EXTENSION="${APP_DIR}/Contents/PlugIns/FluxNewsWidgets.appex"
UNIFFI_LIBRARY="${APP_DIR}/Contents/Frameworks/libflux_uniffi.dylib"
[[ -d "${WIDGET_EXTENSION}" ]] || { echo "Embedded widget extension is missing: ${WIDGET_EXTENSION}" >&2; exit 1; }
[[ -f "${UNIFFI_LIBRARY}" ]] || { echo "Embedded UniFFI library is missing: ${UNIFFI_LIBRARY}" >&2; exit 1; }
codesign --force --sign "${SIGNING_IDENTITY}" --entitlements "${WIDGET_ENTITLEMENTS}" "${WIDGET_EXTENSION}"
codesign --force --sign "${SIGNING_IDENTITY}" "${UNIFFI_LIBRARY}"
codesign --force --sign "${SIGNING_IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" "${APP_DIR}"
codesign --verify --strict --verbose=4 "${WIDGET_EXTENSION}"
codesign --verify --strict --verbose=4 "${APP_DIR}"

echo "FluxNews ${CONFIGURATION} app: ${APP_DIR}"
