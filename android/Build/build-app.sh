#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GRADLEW="${ANDROID_DIR}/gradlew"

usage() {
  cat <<'HELP'
Build FluxNews Android from the repository root or any working directory.

Usage:
  android/Build/build-app.sh [variant] [versionCode versionName]
  android/Build/build-app.sh --help

Variants:
  developmentDebug    Debug APK (default if no variant is supplied).
  developmentRelease  Native development release APK.
  developmentBundle   Signed development release AAB for Play internal testing.
  productionRelease   Production release APK (signing must be configured separately).

Parameters:
  versionCode         Positive Android update number (1..2100000000).
                      Must be greater than the versionCode already installed
                      when performing an in-place Flutter-to-native update.
  versionName         Display version, e.g. 3.0.0. Development flavors append
                      -native-dev automatically.
  Pass both versionCode and versionName together, or omit both.
  Omitting both retains Gradle's non-release fallback (1 / 0.1.0).
  developmentBundle requires a versionCode and
                      android/developmentBundle-signing.properties.
                      For compatibility its old two-argument form still works,
                      using Gradle's default versionName (0.1.0).

Examples:
  ./android/Build/build-app.sh
  ./android/Build/build-app.sh developmentRelease 2026100901 3.0.0
  ./android/Build/build-app.sh developmentBundle 2026100901 3.0.0
  ./android/Build/build-app.sh developmentBundle 2026100901
  ./android/Build/build-app.sh productionRelease 2026100901 3.0.0

Note: A production in-place upgrade additionally requires the same signing
certificate as the installed Flutter app. A different versionName alone does
not make an Android update; Android compares versionCode and signing identity.
HELP
}

fail_usage() {
  echo "Error: $*" >&2
  echo "Run './android/Build/build-app.sh --help' for usage." >&2
  exit 2
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  [[ $# -eq 1 ]] || fail_usage "--help does not accept additional arguments."
  usage
  exit 0
fi

[[ $# -le 3 ]] || fail_usage "Too many arguments."
VARIANT="${1:-developmentDebug}"
VERSION_CODE="${2:-}"
VERSION_NAME="${3:-}"

case "${VARIANT}" in
  developmentDebug) TASK="assembleDevelopmentDebug" ;;
  developmentRelease) TASK="assembleDevelopmentRelease" ;;
  developmentBundle) TASK="bundleDevelopmentRelease" ;;
  productionRelease) TASK="assembleProductionRelease" ;;
  *) fail_usage "Unknown variant: ${VARIANT}" ;;
esac

if [[ "${VARIANT}" == "developmentBundle" && -n "${VERSION_CODE}" && -z "${VERSION_NAME}" ]]; then
  VERSION_NAME="0.1.0"
fi

if [[ -n "${VERSION_CODE}" || -n "${VERSION_NAME}" ]]; then
  [[ -n "${VERSION_CODE}" && -n "${VERSION_NAME}" ]] ||
    fail_usage "versionCode and versionName must be supplied together."
  [[ "${VERSION_CODE}" =~ ^[1-9][0-9]*$ ]] ||
    fail_usage "versionCode must be a positive decimal integer."
  [[ ${#VERSION_CODE} -le 10 ]] ||
    fail_usage "versionCode is outside the allowed Android range."
  (( 10#${VERSION_CODE} <= 2100000000 )) ||
    fail_usage "versionCode must be <= 2100000000."
  [[ "${VERSION_NAME}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
    fail_usage "versionName must look like 3.0.0 or 3.0.0-beta1."
elif [[ "${VARIANT}" == "developmentBundle" ]]; then
  fail_usage "developmentBundle requires at least versionCode."
fi

if [[ "${VARIANT}" == "developmentBundle" ]]; then
  SIGNING_PROPERTIES="${ANDROID_DIR}/developmentBundle-signing.properties"
  [[ -f "${SIGNING_PROPERTIES}" ]] || {
    echo "Missing Google Play upload-signing properties: ${SIGNING_PROPERTIES}" >&2
    exit 1
  }
fi

[[ -x "${GRADLEW}" ]] || {
  echo "Gradle Wrapper is missing or not executable: ${GRADLEW}" >&2
  exit 1
}

EXTRA_ARGS=()
if [[ -n "${VERSION_CODE}" ]]; then
  EXTRA_ARGS+=("-PfluxBuildVersionCode=${VERSION_CODE}" "-PfluxBuildVersionName=${VERSION_NAME}")
fi

exec "${GRADLEW}" --project-dir "${ANDROID_DIR}" "${TASK}" "${EXTRA_ARGS[@]}"
