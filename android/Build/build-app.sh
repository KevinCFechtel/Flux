#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GRADLEW="${ANDROID_DIR}/gradlew"
VARIANT="${1:-developmentDebug}"

case "${VARIANT}" in
  developmentDebug) TASK="assembleDevelopmentDebug" ;;
  productionRelease) TASK="assembleProductionRelease" ;;
  --help|-h)
    echo "Usage: build-app.sh [developmentDebug|productionRelease]"
    exit 0
    ;;
  *)
    echo "Unsupported build variant: ${VARIANT}" >&2
    echo "Use developmentDebug or productionRelease." >&2
    exit 2
    ;;
esac

[[ -x "${GRADLEW}" ]] || {
  echo "Gradle Wrapper is missing or not executable: ${GRADLEW}" >&2
  exit 1
}

exec "${GRADLEW}" "${TASK}"
