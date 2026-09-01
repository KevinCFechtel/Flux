#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
PROJECT="${REPOSITORY_DIR}/apple/ios/FluxNews.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 11 Pro Max}"

usage() {
  cat <<'EOF'
Usage: build-app.sh [--configuration CONFIGURATION] [--destination DESTINATION]

Examples:
  build-app.sh
  build-app.sh --configuration "Upgrade Test"
  build-app.sh --destination 'generic/platform=iOS'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "Missing value for --configuration." >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || { echo "Missing value for --destination." >&2; exit 2; }
      DESTINATION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${CONFIGURATION}" in
  Debug|Release|"Upgrade Test") ;;
  *)
    echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2
    echo 'Use Debug, Release, or "Upgrade Test".' >&2
    exit 1
    ;;
esac

"${REPOSITORY_DIR}/apple/Build/build-uniffi.sh"

FLUX_UNIFFI_PREPARED=1 xcodebuild \
  -project "${PROJECT}" \
  -scheme FluxNews \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

build_settings="$(xcodebuild \
  -project "${PROJECT}" \
  -scheme FluxNews \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -showBuildSettings -quiet)"
target_build_dir="$(awk -F ' = ' '$1 ~ /^[[:space:]]*TARGET_BUILD_DIR$/ { print $2; exit }' <<<"${build_settings}")"
[[ -n "${target_build_dir}" ]] || { echo "Could not determine the Xcode output directory." >&2; exit 1; }
app_path="${target_build_dir}/FluxNews.app"
[[ -d "${app_path}" ]] || { echo "Built app is missing: ${app_path}" >&2; exit 1; }

echo "FluxNews ${CONFIGURATION} app: ${app_path}"
