#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
PROJECT="${REPOSITORY_DIR}/apple/ios/FluxNews.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 11 Pro Max}"

"${REPOSITORY_DIR}/apple/Build/build-uniffi.sh"

xcodebuild \
  -project "${PROJECT}" \
  -scheme FluxNews \
  -configuration Debug \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  test
