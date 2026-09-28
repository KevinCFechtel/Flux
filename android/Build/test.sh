#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GRADLEW="${ANDROID_DIR}/gradlew"

[[ -x "${GRADLEW}" ]] || {
  echo "Gradle Wrapper is missing or not executable: ${GRADLEW}" >&2
  exit 1
}

exec "${GRADLEW}" testDevelopmentDebugUnitTest lintDevelopmentDebug assembleDevelopmentDebug
