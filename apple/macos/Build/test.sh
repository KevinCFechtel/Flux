#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
PROJECT="${REPOSITORY_DIR}/apple/macos/FluxNews.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData-macos}"
DESTINATION="${DESTINATION:-platform=macOS}"

"${REPOSITORY_DIR}/apple/Build/build-uniffi.sh"

xcodebuild \
  -project "${PROJECT}" \
  -scheme FluxNews \
  -configuration Debug \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  test
