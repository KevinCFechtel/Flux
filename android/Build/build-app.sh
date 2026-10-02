#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GRADLEW="${ANDROID_DIR}/gradlew"
VARIANT="${1:-developmentDebug}"
VERSION_CODE="${2:-}"

case "${VARIANT}" in
  developmentDebug)
    TASK="assembleDevelopmentDebug"
    EXTRA_ARGS=()
    ;;
  developmentRelease)
    TASK="assembleDevelopmentRelease"
    EXTRA_ARGS=()
    ;;
  developmentBundle)
    SIGNING_PROPERTIES="${ANDROID_DIR}/developmentBundle-signing.properties"
    [[ -f "${SIGNING_PROPERTIES}" ]] || {
      echo "Missing Google Play upload-signing properties: ${SIGNING_PROPERTIES}" >&2
      exit 1
    }
    [[ "${VERSION_CODE}" =~ ^[1-9][0-9]*$ ]] || {
      echo "Usage: build-app.sh developmentBundle <positive-version-code>" >&2
      exit 2
    }
    TASK="bundleDevelopmentRelease"
    EXTRA_ARGS=("-PfluxDevelopmentPlayVersionCode=${VERSION_CODE}")
    ;;
  productionRelease)
    TASK="assembleProductionRelease"
    EXTRA_ARGS=()
    ;;
  --help|-h)
    echo "Usage: build-app.sh [developmentDebug|developmentRelease|developmentBundle <versionCode>|productionRelease]"
    exit 0
    ;;
  *)
    echo "Unsupported build variant: ${VARIANT}" >&2
    echo "Use developmentDebug, developmentRelease, developmentBundle <versionCode>, or productionRelease." >&2
    exit 2
    ;;
esac

[[ -x "${GRADLEW}" ]] || {
  echo "Gradle Wrapper is missing or not executable: ${GRADLEW}" >&2
  exit 1
}

exec "${GRADLEW}" --project-dir "${ANDROID_DIR}" "${TASK}" "${EXTRA_ARGS[@]}"
