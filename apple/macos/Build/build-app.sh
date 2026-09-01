#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-${REPOSITORY_DIR}/.build/DerivedData}"
APP_DIR="${APP_DIR:-${REPOSITORY_DIR}/dist/FluxNews.app}"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/FluxNews.app"
APP_ENTITLEMENTS="${REPOSITORY_DIR}/apple/macos/FluxNews/FluxNews.entitlements"
WIDGET_ENTITLEMENTS="${REPOSITORY_DIR}/apple/macos/FluxNewsWidgets/FluxNewsWidgets.entitlements"
HOST_BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews"
WIDGET_BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews.FluxNewsWidgets"
APP_GROUP_IDENTIFIER="group.dev.kevincfechtel.fluxNews"
DEVELOPMENT_SIGNING="${DEVELOPMENT_SIGNING:-1}"

for command_name in codesign ditto plutil /usr/libexec/PlistBuddy xcodebuild; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

case "${CONFIGURATION}" in
  Debug|Release) ;;
  *)
    echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2
    exit 1
    ;;
esac

case "${DEVELOPMENT_SIGNING}" in
  0|1) ;;
  *)
    echo "DEVELOPMENT_SIGNING must be 0 or 1." >&2
    exit 1
    ;;
esac

"${SCRIPT_DIR}/build-uniffi.sh"

xcodebuild_args=(
  -project "${REPOSITORY_DIR}/apple/macos/FluxNews.xcodeproj"
  -scheme FluxNews
  -configuration "${CONFIGURATION}"
  -destination "platform=macOS"
  -derivedDataPath "${DERIVED_DATA}"
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)

if [[ "${DEVELOPMENT_SIGNING}" == "1" ]]; then
  xcodebuild_args+=(
    -allowProvisioningUpdates
  )
else
  xcodebuild_args+=(
    CODE_SIGNING_ALLOWED=NO
  )
fi

FLUX_UNIFFI_PREPARED=1 xcodebuild "${xcodebuild_args[@]}" build

rm -rf -- "${APP_DIR}"
mkdir -p "$(dirname -- "${APP_DIR}")"
ditto "${BUILT_APP}" "${APP_DIR}"

# Ad-hoc builds are unsigned until this point so they do not require an Apple
# identity. Development builds retain Xcode's provisioning and target-specific
# signatures; re-signing here would discard their provisioning authorization.
WIDGET_EXTENSION="${APP_DIR}/Contents/PlugIns/FluxNewsWidgets.appex"
UNIFFI_LIBRARY="${APP_DIR}/Contents/Frameworks/libflux_uniffi.dylib"
[[ -d "${WIDGET_EXTENSION}" ]] || { echo "Embedded widget extension is missing: ${WIDGET_EXTENSION}" >&2; exit 1; }
[[ -f "${UNIFFI_LIBRARY}" ]] || { echo "Embedded UniFFI library is missing: ${UNIFFI_LIBRARY}" >&2; exit 1; }
if [[ "${DEVELOPMENT_SIGNING}" == "1" ]]; then
  echo "Using Xcode-configured Apple Development signing."
else
  # Sign nested code explicitly: --deep would replace the extension signature
  # and discard its distinct App Group entitlement.
  codesign --force --sign "${SIGNING_IDENTITY}" --entitlements "${WIDGET_ENTITLEMENTS}" "${WIDGET_EXTENSION}"
  codesign --force --sign "${SIGNING_IDENTITY}" "${UNIFFI_LIBRARY}"
  codesign --force --sign "${SIGNING_IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" "${APP_DIR}"
fi

HOST_INFO_PLIST="${APP_DIR}/Contents/Info.plist"
WIDGET_INFO_PLIST="${WIDGET_EXTENSION}/Contents/Info.plist"
plutil -lint "${HOST_INFO_PLIST}" >/dev/null
plutil -lint "${WIDGET_INFO_PLIST}" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${HOST_INFO_PLIST}")" == "${HOST_BUNDLE_IDENTIFIER}" ]] || {
  echo "Unexpected host bundle identifier." >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${WIDGET_INFO_PLIST}")" == "${WIDGET_BUNDLE_IDENTIFIER}" ]] || {
  echo "Unexpected widget bundle identifier." >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "${WIDGET_INFO_PLIST}")" == "com.apple.widgetkit-extension" ]] || {
  echo "WidgetKit extension point is missing." >&2
  exit 1
}

ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/flux-entitlements.XXXXXX")"
trap 'rm -f -- "${ENTITLEMENTS_FILE}"' EXIT

verify_app_group_entitlement() {
  local component="$1"

  codesign -d --entitlements :- "${component}" > "${ENTITLEMENTS_FILE}"

  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "${ENTITLEMENTS_FILE}")" == "${APP_GROUP_IDENTIFIER}" ]] || {
    echo "Expected App Group entitlement is missing: ${component}" >&2
    exit 1
  }
}

verify_app_group_entitlement "${APP_DIR}"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${ENTITLEMENTS_FILE}" >/dev/null 2>&1; then
  echo "Host App Sandbox entitlement changed unexpectedly." >&2
  exit 1
fi
verify_app_group_entitlement "${WIDGET_EXTENSION}"

codesign -d --entitlements :- "${WIDGET_EXTENSION}" > "${ENTITLEMENTS_FILE}"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${ENTITLEMENTS_FILE}")" == "true" ]] || {
  echo "Widget App Sandbox entitlement is missing." >&2
  exit 1
}

codesign --verify --strict --verbose=4 "${WIDGET_EXTENSION}"
codesign --verify --strict --verbose=4 "${APP_DIR}"
codesign --verify --deep --strict --verbose=4 "${APP_DIR}"

if [[ "${DEVELOPMENT_SIGNING}" == "1" ]]; then
  verify_development_component() {
    local component="$1"
    local details
    details="$(codesign -dvvv "${component}" 2>&1)"
    grep -F -- "Authority=Apple Development" <<<"${details}" >/dev/null || { echo "Apple Development authority missing: ${component}" >&2; exit 1; }
    host_details="$(codesign -dvvv "${APP_DIR}" 2>&1)"
    widget_details="$(codesign -dvvv "${WIDGET_EXTENSION}" 2>&1)"

    grep -F -- "Authority=Apple Development" <<<"${host_details}" >/dev/null
    grep -F -- "Authority=Apple Development" <<<"${widget_details}" >/dev/null

    host_team="$(
      sed -n 's/^TeamIdentifier=//p' <<<"${host_details}"
    )"

    widget_team="$(
      sed -n 's/^TeamIdentifier=//p' <<<"${widget_details}"
    )"

    [[ -n "${host_team}" ]]
    [[ "${host_team}" == "${widget_team}" ]]
  }

  verify_development_component "${WIDGET_EXTENSION}"
  verify_development_component "${APP_DIR}"
fi

echo "FluxNews ${CONFIGURATION} app: ${APP_DIR}"
