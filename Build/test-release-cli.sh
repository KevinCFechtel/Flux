#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="$ROOT/Build/release.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
check_failure() {
  local expected="$1"; shift
  if "$@" >"$tmp/out" 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
  grep -F -- "$expected" "$tmp/out" >/dev/null || {
    cat "$tmp/out" >&2
    echo "Missing expected diagnostic: $expected" >&2
    exit 1
  }
}
bash -n "$RELEASE"
bash "$RELEASE" --help >"$tmp/help"
grep -F -- '--debug' "$tmp/help" >/dev/null
check_failure "Unknown platform" bash "$RELEASE" nonsense
check_failure "Version code and name must be provided together" bash "$RELEASE" android --version-code 12
check_failure "Version code must be a positive integer" bash "$RELEASE" android --version-code nope --version-name 3.0.0
check_failure "Invalid version name" bash "$RELEASE" android --version-code 12 --version-name invalid
check_failure "Play bundle requires explicit version" bash "$RELEASE" android --target play
check_failure "App Store export requires explicit version" bash "$RELEASE" ios --target appstore
check_failure "--debug cannot be combined" bash "$RELEASE" android --target play --debug
check_failure "macOS build does not yet accept version overrides" bash "$RELEASE" macos --version-code 12 --version-name 3.0.0
check_failure "Unsupported target" bash "$RELEASE" macos --target appstore
echo "Release CLI argument contract: PASS"
