#!/usr/bin/env bash
# Rocky 8 RPM 빌드 엔트리. lib/rocky.sh 로 위임.
set -Eeuo pipefail
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NAMUVIRT_BUILD_DIR="${BUILD_DIR}"
export NAMUVIRT_REPO_ROOT="$(cd "${BUILD_DIR}/.." && pwd)"
export NAMUVIRT_SCRIPT_TAG="build/rocky"
exec bash "${BUILD_DIR}/lib/rocky.sh" "$@"
