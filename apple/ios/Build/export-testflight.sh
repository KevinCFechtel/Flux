#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-${REPOSITORY_DIR}/.build/Archives/FluxNews-nativeDev.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${REPOSITORY_DIR}/dist/TestFlightExport}"
EXPECTED_BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews.nativeDev"
EXPECTED_DISPLAY_NAME="FluxNews Dev"

usage() {
  cat <<'EOF'
Usage: export-testflight.sh [--archive ARCHIVE_PATH] [--export-path EXPORT_PATH]

Exports the nativeDev archive to a local App Store Connect IPA for manual
upload with Apple's Transporter app. This script never uploads the IPA.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || { echo "Missing value for --archive." >&2; exit 2; }
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --export-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --export-path." >&2; exit 2; }
      EXPORT_PATH="$2"
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

for command_name in plutil unzip xcodebuild; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

archived_app="${ARCHIVE_PATH}/Products/Applications/FluxNews.app"
archived_info_plist="${archived_app}/Info.plist"
[[ -d "${archived_app}" ]] || { echo "Archive not found: ${ARCHIVE_PATH}" >&2; echo "Run archive.sh first." >&2; exit 1; }
[[ -f "${archived_info_plist}" ]] || { echo "Archived application Info.plist is missing: ${archived_info_plist}" >&2; exit 1; }
[[ -x "${archived_app}/FluxNews" ]] || { echo "Archived executable is missing: ${archived_app}/FluxNews" >&2; exit 1; }
archived_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${archived_info_plist}")"
[[ "${archived_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing export of unexpected Bundle ID: ${archived_bundle_identifier}" >&2
  echo "Expected: ${EXPECTED_BUNDLE_IDENTIFIER}" >&2
  exit 1
}

export_options_plist="$(mktemp "${TMPDIR:-/tmp}/flux-nativeDev-export.XXXXXX.plist")"
ipa_info_plist=""
trap 'rm -f -- "${export_options_plist}" ${ipa_info_plist:+"${ipa_info_plist}"}' EXIT
plutil -create xml1 "${export_options_plist}"
plutil -insert method -string app-store-connect "${export_options_plist}"
plutil -insert destination -string export "${export_options_plist}"
plutil -insert signingStyle -string automatic "${export_options_plist}"
plutil -insert manageAppVersionAndBuildNumber -bool false "${export_options_plist}"
plutil -insert uploadSymbols -bool true "${export_options_plist}"

rm -rf -- "${EXPORT_PATH}"
mkdir -p "${EXPORT_PATH}"

echo "Exporting nativeDev archive for manual TestFlight upload."
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${export_options_plist}" \
  -exportPath "${EXPORT_PATH}" \
  -allowProvisioningUpdates

ipa_candidates=("${EXPORT_PATH}"/*.ipa)
[[ -f "${ipa_candidates[0]}" ]] || { echo "No IPA was produced in ${EXPORT_PATH}." >&2; exit 1; }
[[ ! -e "${ipa_candidates[1]:-}" ]] || { echo "Multiple IPAs were produced in ${EXPORT_PATH}." >&2; exit 1; }
exported_ipa="${ipa_candidates[0]}"

ipa_info_entry=""
while IFS= read -r candidate; do
  case "${candidate}" in
    Payload/*.app/Info.plist)
      ipa_info_entry="${candidate}"
      break
      ;;
  esac
done < <(unzip -Z1 "${exported_ipa}")
[[ -n "${ipa_info_entry}" ]] || { echo "Exported IPA has no application Info.plist: ${exported_ipa}" >&2; exit 1; }

ipa_info_plist="$(mktemp "${TMPDIR:-/tmp}/flux-nativeDev-ipa-info.XXXXXX.plist")"
unzip -p "${exported_ipa}" "${ipa_info_entry}" > "${ipa_info_plist}"
exported_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${ipa_info_plist}")"
[[ "${exported_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing exported IPA with unexpected Bundle ID: ${exported_bundle_identifier}" >&2
  echo "Expected: ${EXPECTED_BUNDLE_IDENTIFIER}" >&2
  exit 1
}
exported_build_number="$(plutil -extract CFBundleVersion raw "${ipa_info_plist}")"
[[ -n "${exported_build_number}" ]] || { echo "Exported IPA has no build number: ${exported_ipa}" >&2; exit 1; }
exported_display_name="$(plutil -extract CFBundleDisplayName raw "${ipa_info_plist}")"
[[ "${exported_display_name}" == "${EXPECTED_DISPLAY_NAME}" ]] || {
  echo "Exported display name mismatch: ${exported_display_name} (expected ${EXPECTED_DISPLAY_NAME})." >&2
  exit 1
}

echo "IPA: ${exported_ipa}"
echo "Bundle ID: ${exported_bundle_identifier}"
echo "Build number: ${exported_build_number}"
echo "Display name: ${exported_display_name}"
echo "Ready for manual upload with Transporter; nothing was uploaded."
