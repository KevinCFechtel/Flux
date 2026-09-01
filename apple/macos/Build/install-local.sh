#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
SOURCE_APP="${REPOSITORY_DIR}/dist/FluxNews.app"
INSTALLED_APP="/Applications/FluxNews.app"
WIDGET_EXTENSION="${SOURCE_APP}/Contents/PlugIns/FluxNewsWidgets.appex"
BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews"

for command_name in codesign ditto open osascript pgrep /usr/libexec/PlistBuddy; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "Required command missing: ${command_name}" >&2; exit 1; }
done

[[ -d "${SOURCE_APP}" ]] || { echo "Build the app first: ${SOURCE_APP}" >&2; exit 1; }
[[ -d "${WIDGET_EXTENSION}" ]] || { echo "Embedded widget extension is missing: ${WIDGET_EXTENSION}" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${SOURCE_APP}/Contents/Info.plist")" == "${BUNDLE_IDENTIFIER}" ]] || {
  echo "Refusing to install an unexpected app bundle: ${SOURCE_APP}" >&2
  exit 1
}

# Quit by bundle ID before replacing the fixed installation target.
osascript -e "tell application id \"${BUNDLE_IDENTIFIER}\" to quit" >/dev/null 2>&1 || true
for _ in {1..10}; do
  pgrep -x "FluxNews" >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -x "FluxNews" >/dev/null 2>&1; then
  echo "FluxNews is still running; quit it before installing." >&2
  exit 1
fi

if [[ -e "${INSTALLED_APP}" ]]; then
  [[ -d "${INSTALLED_APP}" ]] || { echo "Refusing to replace non-directory path: ${INSTALLED_APP}" >&2; exit 1; }
  rm -rf -- "${INSTALLED_APP}"
fi
ditto "${SOURCE_APP}" "${INSTALLED_APP}"
[[ -d "${INSTALLED_APP}/Contents/PlugIns/FluxNewsWidgets.appex" ]] || {
  echo "Installed app is missing the widget extension." >&2
  exit 1
}
codesign --verify --deep --strict --verbose=4 "${INSTALLED_APP}"

open -n "${INSTALLED_APP}"
echo "Installed and started: ${INSTALLED_APP}"
