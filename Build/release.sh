#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'HELP'
Usage: bash Build/release.sh <android|ios|macos> [--debug] [--version-code N] [--version-name V]
       bash Build/release.sh android --target play --version-code N --version-name V
       bash Build/release.sh ios --target appstore --version-code N --version-name V

Defaults to production RELEASE builds (never publishes).
  android: productionRelease APK
  ios:     production identity build (Upgrade Test configuration)
  macos:   Release app
--debug opts into a development/debug build.
--target play creates a signed production AAB; requires signing properties.
--target appstore (iOS) archives and exports a production IPA for manual upload.
--version-code is the Android versionCode or Apple CFBundleVersion.
For macOS, version overrides and App Store archive/export are not yet implemented.
HELP
}

die() { echo "Error: $*" >&2; exit 2; }
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0;; android|ios|macos) platform="$1"; shift;; *) die "Unknown platform: $1";; esac
debug=0; target=build; version_code=; version_name=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) debug=1; shift;;
    --target) [[ $# -ge 2 ]] || die "Missing --target value"; target="$2"; shift 2;;
    --version-code) [[ $# -ge 2 ]] || die "Missing --version-code value"; version_code="$2"; shift 2;;
    --version-name) [[ $# -ge 2 ]] || die "Missing --version-name value"; version_name="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done
[[ -z "$version_code" && -z "$version_name" || -n "$version_code" && -n "$version_name" ]] || die "Version code and name must be provided together"
if [[ -n "$version_code" ]]; then
  [[ "$version_code" =~ ^[1-9][0-9]*$ ]] || die "Version code must be a positive integer"
  [[ "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || die "Invalid version name"
fi
args=()
if [[ -n "$version_code" ]]; then args+=("$version_code" "$version_name"); fi
case "$platform:$target" in
  android:build)
    if ((debug)); then variant=developmentDebug; else variant=productionRelease; fi
    exec bash "$ROOT/android/Build/build-app.sh" "$variant" "${args[@]}"
    ;;
  android:play)
    (( !debug )) || die "--debug cannot be combined with --target play"
    [[ -n "$version_code" ]] || die "Play bundle requires explicit version"
    exec bash "$ROOT/android/Build/build-app.sh" productionBundle "${args[@]}"
    ;;
  ios:build)
    if ((debug)); then variant=developmentDebug; else variant=productionRelease; fi
    exec bash "$ROOT/apple/ios/Build/build-app.sh" "$variant" "${args[@]}"
    ;;
  ios:appstore)
    (( !debug )) || die "--debug cannot be combined with --target appstore"
    [[ -n "$version_code" ]] || die "App Store export requires explicit version"
    bash "$ROOT/apple/ios/Build/archive.sh" productionRelease "${args[@]}"
    exec bash "$ROOT/apple/ios/Build/export-testflight.sh" productionRelease
    ;;
  macos:build)
    [[ -z "$version_code" ]] || die "macOS build does not yet accept version overrides"
    if ((debug)); then export CONFIGURATION=Debug; else export CONFIGURATION=Release; fi
    exec bash "$ROOT/apple/macos/Build/build-app.sh"
    ;;
  *) die "Unsupported target '$target' for $platform (F-Droid and macOS App Store are pending)";;
esac
