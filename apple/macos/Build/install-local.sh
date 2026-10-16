#!/usr/bin/env bash
# B1: require a signed provisioned macOS Sandbox app.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
SOURCE_APP="${SOURCE_APP:-${REPOSITORY_DIR}/dist/FluxNews.app}"
INSTALLED_APP="/Applications/FluxNews.app"
BUNDLE_IDENTIFIER="dev.kevincfechtel.fluxNews"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || { echo "Signed app missing: $SOURCE_APP" >&2; exit 1; }
"$SCRIPT_DIR/verify-sandbox.sh" "$SOURCE_APP" development
if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
  [[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] || { echo "Refusing unexpected installation path" >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INSTALLED_APP/Contents/Info.plist")" == "$BUNDLE_IDENTIFIER" ]] || { echo "Refusing unrelated app" >&2; exit 1; }
fi
stage="$(mktemp -d /Applications/.FluxNews-stage.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
staged="$stage/FluxNews.app"
ditto "$SOURCE_APP" "$staged"
"$SCRIPT_DIR/verify-sandbox.sh" "$staged" development
osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true
for _ in {1..10}; do pgrep -x FluxNews >/dev/null 2>&1 || break; sleep 1; done
if pgrep -x FluxNews >/dev/null 2>&1; then echo "FluxNews is still running" >&2; exit 1; fi
if [[ -e "$INSTALLED_APP" ]]; then rm -rf -- "$INSTALLED_APP"; fi
mv -- "$staged" "$INSTALLED_APP"
"$SCRIPT_DIR/verify-sandbox.sh" "$INSTALLED_APP" development
open -n "$INSTALLED_APP"
echo "Installed signed sandbox app: $INSTALLED_APP"
echo "Persistent app data and Keychain were not deleted."
