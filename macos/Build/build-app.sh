#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
APP_DIR="${APP_DIR:-${REPOSITORY_DIR}/dist/FluxBar.app}"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/FluxBar.app"

case "${CONFIGURATION}" in
  Debug|Release) ;;
  *)
    echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2
    exit 1
    ;;
esac

"${SCRIPT_DIR}/build-uniffi.sh"

FLUX_UNIFFI_PREPARED=1 xcodebuild \
  -project "${REPOSITORY_DIR}/macos/FluxBar.xcodeproj" \
  -scheme FluxBar \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf -- "${APP_DIR}"
mkdir -p "$(dirname -- "${APP_DIR}")"
ditto "${BUILT_APP}" "${APP_DIR}"
codesign --force --deep --sign - "${APP_DIR}"

echo "FluxBar ${CONFIGURATION} app: ${APP_DIR}"
