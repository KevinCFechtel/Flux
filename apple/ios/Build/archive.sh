#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
PROJECT="${REPOSITORY_DIR}/apple/ios/FluxNews.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${REPOSITORY_DIR}/.build/Archives/FluxNews-nativeDev.xcarchive}"
EXPECTED_BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews.nativeDev"
BUILD_NUMBER=""

usage() {
  cat <<'EOF'
Usage: archive.sh [--build-number BUILD_NUMBER]

Examples:
  archive.sh
  archive.sh --build-number 3

The archive always uses the nativeDev Release configuration.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      [[ $# -ge 2 ]] || { echo "Missing value for --build-number." >&2; exit 2; }
      BUILD_NUMBER="$2"
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

if [[ -n "${BUILD_NUMBER}" && ! "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: ${BUILD_NUMBER}" >&2
  exit 1
fi

for command_name in awk plutil xcodebuild; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

"${REPOSITORY_DIR}/apple/Build/build-uniffi.sh"

build_settings="$(xcodebuild \
  -project "${PROJECT}" \
  -scheme FluxNews \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "${DERIVED_DATA}" \
  -showBuildSettings -quiet)"
configured_bundle_identifier="$(awk -F ' = ' '$1 ~ /^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER$/ { print $2; exit }' <<<"${build_settings}")"
[[ "${configured_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing to archive unexpected Bundle ID: ${configured_bundle_identifier:-<missing>}" >&2
  echo "Expected: ${EXPECTED_BUNDLE_IDENTIFIER}" >&2
  exit 1
}
configured_team="$(awk -F ' = ' '$1 ~ /^[[:space:]]*DEVELOPMENT_TEAM$/ { print $2; exit }' <<<"${build_settings}")"
if [[ -z "${configured_team}" && -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Automatic signing requires an Apple Developer Team ID." >&2
  echo "Set DEVELOPMENT_TEAM locally or configure the project in Xcode; no team is stored by this script." >&2
  exit 1
fi

configured_build_number="$(awk -F ' = ' '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION$/ { print $2; exit }' <<<"${build_settings}")"
[[ -n "${BUILD_NUMBER}" ]] || BUILD_NUMBER="${configured_build_number}"
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Configured build number is not a positive integer: ${BUILD_NUMBER:-<missing>}" >&2
  exit 1
}

rm -rf -- "${ARCHIVE_PATH}"
mkdir -p "$(dirname -- "${ARCHIVE_PATH}")"

xcodebuild_args=(
  -project "${PROJECT}"
  -scheme FluxNews
  -configuration Release
  -destination "generic/platform=iOS"
  -derivedDataPath "${DERIVED_DATA}"
  -archivePath "${ARCHIVE_PATH}"
  -allowProvisioningUpdates
  CODE_SIGN_STYLE=Automatic
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  xcodebuild_args+=(DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}")
fi

FLUX_UNIFFI_PREPARED=1 xcodebuild "${xcodebuild_args[@]}" archive

archived_app="${ARCHIVE_PATH}/Products/Applications/FluxNews.app"
archived_info_plist="${archived_app}/Info.plist"
[[ -d "${archived_app}" ]] || { echo "Archived app is missing: ${archived_app}" >&2; exit 1; }
[[ -x "${archived_app}/FluxNews" ]] || { echo "Archived executable is missing: ${archived_app}/FluxNews" >&2; exit 1; }
archived_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${archived_info_plist}")"
[[ "${archived_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing archive with unexpected Bundle ID: ${archived_bundle_identifier}" >&2
  echo "Expected: ${EXPECTED_BUNDLE_IDENTIFIER}" >&2
  exit 1
}
archived_build_number="$(plutil -extract CFBundleVersion raw "${archived_info_plist}")"
[[ "${archived_build_number}" == "${BUILD_NUMBER}" ]] || {
  echo "Archived build number mismatch: ${archived_build_number} (expected ${BUILD_NUMBER})." >&2
  exit 1
}

echo "NativeDev archive: ${ARCHIVE_PATH}"
echo "Bundle ID: ${archived_bundle_identifier}"
echo "Build number: ${archived_build_number}"
