#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-${REPOSITORY_DIR}/.build/Archives/FluxNews-nativeDev.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${REPOSITORY_DIR}/.build/Exports/FluxNews-nativeDev}"
EXPECTED_BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews.nativeDev"

usage() {
  cat <<'EOF'
Usage: upload-testflight.sh [--archive ARCHIVE_PATH] [--export-path EXPORT_PATH]

The archive must be produced by archive.sh. Upload authentication is provided by
the local Xcode/App Store Connect environment; no credentials are read from the
repository.
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

for command_name in awk plutil unzip xcodebuild; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

archived_app="${ARCHIVE_PATH}/Products/Applications/FluxNews.app"
archived_info_plist="${archived_app}/Info.plist"
[[ -d "${archived_app}" ]] || { echo "Archive not found: ${ARCHIVE_PATH}" >&2; echo "Run archive.sh first." >&2; exit 1; }
[[ -x "${archived_app}/FluxNews" ]] || { echo "Archived executable is missing: ${archived_app}/FluxNews" >&2; exit 1; }
archived_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${archived_info_plist}")"
[[ "${archived_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing upload of unexpected Bundle ID: ${archived_bundle_identifier}" >&2
  echo "Expected: ${EXPECTED_BUNDLE_IDENTIFIER}" >&2
  exit 1
}

export_options_plist="$(mktemp "${TMPDIR:-/tmp}/flux-nativeDev-export.XXXXXX.plist")"
trap 'rm -f -- "${export_options_plist}"' EXIT
plutil -create xml1 "${export_options_plist}"
plutil -insert method -string app-store "${export_options_plist}"
plutil -insert destination -string upload "${export_options_plist}"
plutil -insert signingStyle -string automatic "${export_options_plist}"
plutil -insert manageAppVersionAndBuildNumber -bool false "${export_options_plist}"
plutil -insert uploadSymbols -bool true "${export_options_plist}"

rm -rf -- "${EXPORT_PATH}"
mkdir -p "${EXPORT_PATH}"

echo "Uploading nativeDev archive to TestFlight."
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${export_options_plist}" \
  -exportPath "${EXPORT_PATH}" \
  -allowProvisioningUpdates

exported_ipa=""
while IFS= read -r candidate; do
  exported_ipa="${candidate}"
  break
done < <(printf '%s\n' "${EXPORT_PATH}"/*.ipa 2>/dev/null)
if [[ -n "${exported_ipa}" && -f "${exported_ipa}" ]]; then
  ipa_info_entry="$(unzip -l "${exported_ipa}" | awk '$4 ~ /^Payload\/[^/]+\.app\/Info.plist$/ { print $4; exit }')"
  [[ -n "${ipa_info_entry}" ]] || { echo "Exported IPA has no application Info.plist: ${exported_ipa}" >&2; exit 1; }
  ipa_info_plist="$(mktemp "${TMPDIR:-/tmp}/flux-nativeDev-ipa-info.XXXXXX.plist")"
  trap 'rm -f -- "${export_options_plist}" "${ipa_info_plist}"' EXIT
  unzip -p "${exported_ipa}" "${ipa_info_entry}" > "${ipa_info_plist}"
  exported_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${ipa_info_plist}")"
  [[ "${exported_bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] || {
    echo "Refusing exported IPA with unexpected Bundle ID: ${exported_bundle_identifier}" >&2
    exit 1
  }
  echo "Exported package: ${exported_ipa}"
else
  echo "Upload completed without an IPA in ${EXPORT_PATH}."
fi
echo "Uploaded Bundle ID: ${archived_bundle_identifier}"
