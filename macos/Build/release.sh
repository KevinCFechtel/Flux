#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
APP_DIR="${REPOSITORY_DIR}/dist/FluxNews.app"
RELEASE_DIR="${REPOSITORY_DIR}/dist/release"
INFO_PLIST="${REPOSITORY_DIR}/macos/FluxNews/Info.plist"
APP_ENTITLEMENTS="${REPOSITORY_DIR}/macos/FluxNews/FluxNews.entitlements"
WIDGET_ENTITLEMENTS="${REPOSITORY_DIR}/macos/FluxNewsWidgets/FluxNewsWidgets.entitlements"
RELEASE_ENV_FILE="${FLUX_RELEASE_ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ -f "${RELEASE_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${RELEASE_ENV_FILE}"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGNING_TIMESTAMP_URL="${SIGNING_TIMESTAMP_URL:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
RELEASE_ARCH="$(uname -m)"
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"

[[ -n "${SIGNING_IDENTITY}" ]] || { echo "SIGNING_IDENTITY is required." >&2; exit 1; }
[[ -n "${NOTARY_PROFILE}" ]] || { echo "NOTARY_PROFILE is required." >&2; exit 1; }
[[ "${RELEASE_VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || { echo "Invalid release version: ${RELEASE_VERSION}" >&2; exit 1; }

for command_name in cargo codesign ditto security spctl xcrun; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

security find-identity -v -p codesigning | grep -F -- "${SIGNING_IDENTITY}" >/dev/null || {
  echo "SIGNING_IDENTITY is not an available code-signing identity." >&2
  exit 1
}

SUBMISSION_ARCHIVE="${RELEASE_DIR}/FluxNews-${RELEASE_VERSION}-macos-${RELEASE_ARCH}-notarization.zip"
FINAL_ARCHIVE="${RELEASE_DIR}/FluxNews-${RELEASE_VERSION}-macos-${RELEASE_ARCH}.zip"
CHECK_DIR="$(mktemp -d /tmp/flux-release-check.XXXXXX)"
trap 'rm -rf -- "${CHECK_DIR}"' EXIT

echo "1/8 Building the Release app with the Rust/UniFFI core"
CONFIGURATION=Release "${SCRIPT_DIR}/build-app.sh"

timestamp_args=(--timestamp)
if [[ -z "${SIGNING_TIMESTAMP_URL}" ]]; then
  timestamp_ipv4="$({
      dscacheutil -q host -a name timestamp.apple.com || true
    } | awk '/ip_address:/ && $2 ~ /^[0-9.]+$/ {print $2; exit}')"

    if [[ -z "${timestamp_ipv4}" ]]; then
      echo "Keine IPv4-Adresse für timestamp.apple.com gefunden." >&2
      echo "Alternativ SIGNING_TIMESTAMP_URL explizit setzen." >&2
      exit 1
    fi

    SIGNING_TIMESTAMP_URL="http://${timestamp_ipv4}/ts01"
  timestamp_args=("--timestamp=${SIGNING_TIMESTAMP_URL}")
fi

echo "2/8 Signing nested code with Developer ID and hardened runtime"
UNIFFI_LIBRARY="${APP_DIR}/Contents/Frameworks/libflux_uniffi.dylib"
WIDGET_EXTENSION="${APP_DIR}/Contents/PlugIns/FluxNewsWidgets.appex"
[[ -f "${UNIFFI_LIBRARY}" ]] || { echo "Embedded UniFFI library is missing: ${UNIFFI_LIBRARY}" >&2; exit 1; }
[[ -d "${WIDGET_EXTENSION}" ]] || { echo "Embedded widget extension is missing: ${WIDGET_EXTENSION}" >&2; exit 1; }
codesign --force --options runtime "${timestamp_args[@]}" --sign "${SIGNING_IDENTITY}" --entitlements "${WIDGET_ENTITLEMENTS}" "${WIDGET_EXTENSION}"
codesign --force --options runtime "${timestamp_args[@]}" --sign "${SIGNING_IDENTITY}" "${UNIFFI_LIBRARY}"
codesign --force --options runtime "${timestamp_args[@]}" --sign "${SIGNING_IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" "${APP_DIR}"

verify_release_component() {
  local component="$1"
  codesign --verify --strict --verbose=4 "${component}"
  local details
  details="$(codesign -dvvv "${component}" 2>&1)"
  grep -F -- "Authority=${SIGNING_IDENTITY}" <<<"${details}" >/dev/null || { echo "Unexpected signing authority: ${component}" >&2; exit 1; }
  grep -F -- "flags=0x10000(runtime)" <<<"${details}" >/dev/null || { echo "Hardened Runtime missing: ${component}" >&2; exit 1; }
  grep -F -- "Timestamp=" <<<"${details}" >/dev/null || { echo "Secure timestamp missing: ${component}" >&2; exit 1; }
}

verify_release_component "${WIDGET_EXTENSION}"
verify_release_component "${UNIFFI_LIBRARY}"
verify_release_component "${APP_DIR}"
codesign --verify --deep --strict --verbose=4 "${APP_DIR}"

mkdir -p "${RELEASE_DIR}"
echo "3/8 Creating the notarization archive"
rm -f -- "${SUBMISSION_ARCHIVE}"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "${APP_DIR}" "${SUBMISSION_ARCHIVE}"

echo "4/8 Submitting to Apple and waiting for notarization"
set +e
NOTARY_RESULT="$(xcrun notarytool submit "${SUBMISSION_ARCHIVE}" --keychain-profile "${NOTARY_PROFILE}" --wait --timeout "${NOTARY_TIMEOUT}" --output-format json)"
NOTARY_EXIT=$?
set -e
printf '%s\n' "${NOTARY_RESULT}"
NOTARY_ID="$(plutil -extract id raw - <<<"${NOTARY_RESULT}" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw - <<<"${NOTARY_RESULT}" 2>/dev/null || true)"
if [[ ${NOTARY_EXIT} -ne 0 || "${NOTARY_STATUS}" != "Accepted" ]]; then
  if [[ -n "${NOTARY_ID}" ]]; then xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}"; fi
  echo "Notarization was not accepted; skipping stapling." >&2
  exit 1
fi

echo "5/8 Stapling and validating the notarization ticket"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"

echo "6/8 Verifying the signed app with Gatekeeper"
codesign --verify --deep --strict --verbose=4 "${APP_DIR}"
spctl --assess --type execute --verbose=4 "${APP_DIR}"

echo "7/8 Creating the final release ZIP"
rm -f -- "${FINAL_ARCHIVE}"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "${APP_DIR}" "${FINAL_ARCHIVE}"

echo "8/8 Extracting and validating the final artifact"
ditto -x -k "${FINAL_ARCHIVE}" "${CHECK_DIR}"
xcrun stapler validate "${CHECK_DIR}/FluxNews.app"
codesign --verify --deep --strict --verbose=4 "${CHECK_DIR}/FluxNews.app"
spctl --assess --type execute --verbose=4 "${CHECK_DIR}/FluxNews.app"

echo "Release artifact: ${FINAL_ARCHIVE}"
