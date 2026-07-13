#!/usr/bin/env bash
# Ubuntu deb 빌드 본체. 엔트리: ./build/ubuntu.sh
# packaging/build-deb.sh -o 로 build/packages/deb/latest/ 에 직접 출력.

set -Eeuo pipefail

: "${NAMUVIRT_SCRIPT_TAG:?NAMUVIRT_SCRIPT_TAG required}"
: "${NAMUVIRT_BUILD_DIR:?NAMUVIRT_BUILD_DIR required}"
: "${NAMUVIRT_REPO_ROOT:?NAMUVIRT_REPO_ROOT required}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

OUT_DIR="${BUILD_DIR}/packages/deb/latest"

# --help 출력.
usage() {
  cat <<'USAGE'
Usage:
  ./build/ubuntu.sh [--mode normal|dev|clean] [--without-vmware] [--no-auto-deps] [--dry-run]

Builds the current namuVIRT tree as Debian packages via packaging/build-deb.sh.
Output: build/packages/deb/latest/

Never runs git checkout, git reset, or git clean.
Every run: install missing host deps → full deb build → fresh output under build/packages/.
Missing build tools on Ubuntu: auto-install via build/lib/deps-ubuntu.sh
  (disable with --no-auto-deps or SKIP_ENSURE_BUILD_DEPS=1; sudo may be used).

Environment:
  NON_OSS_DIR   default: vendor/cloudstack-nonoss
USAGE
}

# ACS_BUILD_OPTS 에 Maven 옵션 중복 없이 추가.
append_acs_build_opt() {
  local opt="$1"
  case " ${ACS_BUILD_OPTS:-} " in
    *" ${opt} "*) ;;
    *) export ACS_BUILD_OPTS="${ACS_BUILD_OPTS:+${ACS_BUILD_OPTS} }${opt}" ;;
  esac
}

# DEB_BUILD_OPTIONS·ACS_BUILD_OPTS·NODE_OPTIONS 설정 (noredist/skipTests).
configure_build_options() {
  case "${MODE}" in
    clean) export DEB_BUILD_OPTIONS="" ;;
    normal|dev)
      export DEB_BUILD_OPTIONS="nocheck"
      append_acs_build_opt "-DskipTests"
      ;;
  esac
  if [ "${WITH_VMWARE}" -eq 1 ]; then
    append_acs_build_opt "-Dnoredist"
  fi
  export NODE_OPTIONS="${NODE_OPTIONS:+${NODE_OPTIONS} }--openssl-legacy-provider"
  log "DEB_BUILD_OPTIONS=${DEB_BUILD_OPTIONS:-}"
  log "ACS_BUILD_OPTS=${ACS_BUILD_OPTS:-}"
}

# Ubuntu 빌드 도구 누락 시 deps-ubuntu.sh 자동 호출.
ensure_build_dependencies() {
  ensure_build_deps_script "${LIB_DIR}/deps-ubuntu.sh"
}

# dch·dpkg-buildpackage·mvn 등 Ubuntu deb 빌드 필수 도구 확인.
verify_ubuntu_build_tools() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "verify ubuntu build tools: dch mvn>=3.6.3 node npm jar"
    return 0
  fi
  if [ -x /opt/maven/bin/mvn ]; then
    export PATH="/opt/maven/bin:${PATH}"
  fi
  command -v dch >/dev/null 2>&1 || die "dch not found — run without --no-auto-deps or: sudo ./build/lib/deps-ubuntu.sh"
  command -v dpkg-buildpackage >/dev/null 2>&1 || die "dpkg-buildpackage not found — sudo ./build/lib/deps-ubuntu.sh"
  command -v mvn >/dev/null 2>&1 || die "mvn not found — sudo ./build/lib/deps-ubuntu.sh"
  local mvn_ver min_ok
  mvn_ver="$(mvn -version 2>/dev/null | awk '/Apache Maven/{print $3; exit}')"
  [ -n "${mvn_ver}" ] || die "unable to parse mvn version"
  min_ok="$(printf '%s\n' '3.6.3' "${mvn_ver}" | sort -V | head -1)"
  [ "${min_ok}" = "3.6.3" ] || die "Maven ${mvn_ver} is too old; need >= 3.6.3"
  command -v node >/dev/null 2>&1 || die "node not found"
  command -v npm >/dev/null 2>&1 || die "npm not found"
  command -v jar >/dev/null 2>&1 || die "jar not found — openjdk-17-jdk required"
}

# build-deb.sh 가 OUT_DIR 에 떨군 runtime deb 5종 존재 확인.
collect_runtime_packages() {
  local pkg deb
  for pkg in "${RUNTIME_PKGS[@]}"; do
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "require ${OUT_DIR}/${pkg}_*.deb"
      continue
    fi
    deb="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "${pkg}_*.deb" | sort | tail -1 || true)"
    [ -n "${deb}" ] || die "missing built package: ${pkg}_*.deb in ${OUT_DIR}"
    log "found ${deb}"
  done
}

# ── Main ──────────────────────────────────────────────────────────

build_parse_common_args "$@" || { usage; exit 0; }

[ -f "${REPO_DIR}/packaging/build-deb.sh" ] || die "packaging/build-deb.sh not found in ${REPO_DIR}"

build_preflight_repo
BUILD_ID="$(date +%Y%m%d_%H%M%S)"

log "repo=${REPO_DIR}"
log "branch=${BRANCH}"
log "build-mode=${MODE}"
log "with-vmware=${WITH_VMWARE}"
log "output=${OUT_DIR}"
log "execution=$([ "${DRY_RUN}" -eq 1 ] && echo dry-run || echo apply)"

ensure_build_dependencies
verify_java17_jdk
ensure_vmware_non_oss_deps
verify_ubuntu_build_tools
run mkdir -p "${LOG_DIR}"
prepare_fresh_output_dir "${OUT_DIR}"
configure_build_options

log "build command: packaging/build-deb.sh -o ${OUT_DIR}"
if [ "${DRY_RUN}" -eq 0 ]; then
  (cd "${REPO_DIR}" && bash packaging/build-deb.sh -o "${OUT_DIR}")
fi

collect_runtime_packages
if [ "${DRY_RUN}" -eq 0 ]; then
  mgmt_deb="$(find "${OUT_DIR}" -maxdepth 1 -type f -name 'cloudstack-management_*.deb' | sort | tail -1 || true)"
  [ -n "${mgmt_deb}" ] && verify_vmware_artifacts_in_archive "${mgmt_deb}" deb
fi
write_build_metadata deb deb

log "done"
