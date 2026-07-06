#!/usr/bin/env bash
# Rocky 8 EL8 RPM 빌드 본체. 엔트리: ./build/rocky.sh
# packaging/package.sh 호출 → build/packages/rpm/latest/ 수집.

set -Eeuo pipefail

: "${NAMUVIRT_SCRIPT_TAG:?NAMUVIRT_SCRIPT_TAG required}"
: "${NAMUVIRT_BUILD_DIR:?NAMUVIRT_BUILD_DIR required}"
: "${NAMUVIRT_REPO_ROOT:?NAMUVIRT_REPO_ROOT required}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

RPM_DIST="${RPM_DIST:-el8}"
UI_NODE_HEAP_MB="${NODE_MAX_OLD_SPACE_SIZE:-16384}"
UI_NODE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
OUT_DIR="${BUILD_DIR}/packages/rpm/latest"
PACKAGE_PACK="oss"

# --help 출력.
usage() {
  cat <<'USAGE'
Usage:
  ./build/rocky.sh [--mode normal|dev|clean] [--without-vmware] [--no-auto-deps] [--dry-run]

Builds the current namuVIRT tree as EL8 RPMs via packaging/package.sh.
Output: build/packages/rpm/latest/

Never runs git checkout, git reset, or git clean.
Every run: install missing host deps → full package build → fresh output under build/packages/.
Missing Java 17 / rpmbuild / Maven on Rocky 8: auto-install via build/lib/deps-rocky.sh
  (disable with --no-auto-deps or SKIP_ENSURE_BUILD_DEPS=1; sudo may be used).

Environment:
  NON_OSS_DIR              default: vendor/cloudstack-nonoss
  RPM_DIST                 default: el8
  NODE_MAX_OLD_SPACE_SIZE  UI npm heap MiB (default: 16384)
USAGE
}

# rpmbuild/npm 이 IDE Node·오염된 NODE_OPTIONS 를 쓰지 않게 PATH 정리.
sanitize_ui_build_env() {
  unset NODE_OPTIONS npm_config_node_options
  local base_path="${UI_NODE_PATH}:/usr/local/bin"
  if [ -x /opt/maven/bin/mvn ]; then
    export PATH="/opt/maven/bin:${base_path}"
  else
    export PATH="${base_path}"
  fi
}

# Rocky 빌드 도구 누락 시 deps-rocky.sh 자동 호출.
ensure_build_dependencies() {
  ensure_build_deps_script "${LIB_DIR}/deps-rocky.sh"
}

# rpmbuild·mvn·/usr/bin/node 등 RPM 빌드 필수 도구 확인.
verify_rpm_build_tools() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "verify rpm-build tools: rpmbuild mvn>=3.6.3 /usr/bin/node npm jq"
    return 0
  fi
  sanitize_ui_build_env
  command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild not found — run as root without --no-auto-deps"
  command -v rpm2cpio >/dev/null 2>&1 || die "rpm2cpio not found"
  command -v mvn >/dev/null 2>&1 || die "mvn not found"
  local mvn_ver min_ok
  mvn_ver="$(mvn -version 2>/dev/null | awk '/Apache Maven/{print $3; exit}')"
  [ -n "${mvn_ver}" ] || die "unable to parse mvn version"
  min_ok="$(printf '%s\n' '3.6.3' "${mvn_ver}" | sort -V | head -1)"
  [ "${min_ok}" = "3.6.3" ] || die "Maven ${mvn_ver} is too old; need >= 3.6.3"
  [ -x /usr/bin/node ] || die "/usr/bin/node not found"
  [ -x /usr/bin/npm ] || die "/usr/bin/npm not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v make >/dev/null 2>&1 || die "make not found"
  command -v g++ >/dev/null 2>&1 || die "g++ not found"
  log "ui build node: /usr/bin/node $(/usr/bin/node -v 2>/dev/null || echo unknown)"
}

# noredist/oss·빌드 모드에 따른 package.sh --pack 값 결정.
configure_build_options() {
  sanitize_ui_build_env
  if [ "${WITH_VMWARE}" -eq 1 ]; then
    PACKAGE_PACK="noredist"
  else
    PACKAGE_PACK="oss"
  fi
  case "${MODE}" in
    normal|dev) log "build mode ${MODE}: mvn -DskipTests; UI npm heap=${UI_NODE_HEAP_MB}MiB" ;;
    clean) log "build mode clean: full mvn clean package via rpmbuild" ;;
  esac
  log "package_pack=${PACKAGE_PACK}"
}

# cloud.spec %build 에 넣을 UI npm 한 줄 생성 (heap·PATH 고정).
cloud_spec_ui_npm_cmd() {
  printf '%s' "cd ui && unset NODE_OPTIONS npm_config_node_options && PATH=${UI_NODE_PATH}:\$PATH npm install && PATH=${UI_NODE_PATH}:\$PATH NODE_OPTIONS=--max-old-space-size=${UI_NODE_HEAP_MB} npm run build && cd .."
}

CLOUD_SPEC=""
CLOUD_SPEC_BAK=""

# cloud.spec 에 -DskipTests·UI npm heap 임시 패치 (빌드 후 restore).
patch_cloud_spec_for_build() {
  [ "${DRY_RUN}" -eq 1 ] && return 0
  CLOUD_SPEC="${REPO_DIR}/packaging/${RPM_DIST}/cloud.spec"
  [ -f "${CLOUD_SPEC}" ] || die "cloud.spec not found: ${CLOUD_SPEC}"
  CLOUD_SPEC_BAK="$(mktemp)"
  cp -a "${CLOUD_SPEC}" "${CLOUD_SPEC_BAK}"
  local ui_cmd ui_safe
  ui_cmd="$(cloud_spec_ui_npm_cmd)"
  ui_safe="${ui_cmd//\\/\\\\}"
  ui_safe="${ui_safe//&/\\&}"
  ui_safe="${ui_safe//|/\\|}"
  ui_safe="${ui_safe//\$/\\$}"
  if [ "${MODE}" != "clean" ] && [ "${SKIP_TESTS:-1}" != "0" ]; then
    sed -i 's/mvn -Psystemvm,developer $FLAGS clean package/mvn -Psystemvm,developer $FLAGS -DskipTests clean package/' "${CLOUD_SPEC}"
    sed -i 's/mvn -Psystemvm,developer $FLAGS -DskipTests -DskipTests clean package/mvn -Psystemvm,developer $FLAGS -DskipTests clean package/' "${CLOUD_SPEC}"
    log "patched ${CLOUD_SPEC} for mvn -DskipTests"
  fi
  sed -i "s|cd ui && npm install && npm run build && cd ..|${ui_safe}|" "${CLOUD_SPEC}"
  sed -i "s|cd ui && unset NODE_OPTIONS.*npm run build && cd ..|${ui_safe}|" "${CLOUD_SPEC}"
  log "patched ${CLOUD_SPEC} for UI npm (heap=${UI_NODE_HEAP_MB}MiB)"
}

# patch_cloud_spec_for_build 로 백업해 둔 cloud.spec 원복.
restore_cloud_spec() {
  [ -n "${CLOUD_SPEC_BAK}" ] && [ -f "${CLOUD_SPEC_BAK}" ] && [ -n "${CLOUD_SPEC}" ] || return 0
  mv -f "${CLOUD_SPEC_BAK}" "${CLOUD_SPEC}"
  log "restored ${CLOUD_SPEC}"
}

# dist/rpmbuild/RPMS 에서 패키지명으로 RPM 경로 탐색.
find_built_rpm() {
  find "${REPO_DIR}/dist/rpmbuild/RPMS" -maxdepth 2 -type f -name "$1-*.rpm" 2>/dev/null | sort | tail -1
}

# 빌드된 RPM을 build/packages/rpm/latest/ 로 복사.
collect_runtime_packages() {
  local pkg rpm
  for pkg in "${RUNTIME_PKGS[@]}"; do
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "collect dist/rpmbuild/RPMS/*/${pkg}-*.rpm -> ${OUT_DIR}/"
      continue
    fi
    rpm="$(find_built_rpm "${pkg}")"
    [ -n "${rpm}" ] || die "missing built package: ${pkg}-*.rpm under ${REPO_DIR}/dist/rpmbuild/RPMS"
    log "collect ${rpm}"
    cp -a "${rpm}" "${OUT_DIR}/"
  done
}

# ── Main ──────────────────────────────────────────────────────────

build_parse_common_args "$@" || { usage; exit 0; }
sanitize_ui_build_env

[ -x "${REPO_DIR}/packaging/package.sh" ] || die "packaging/package.sh not found in ${REPO_DIR}"

build_preflight_repo

BUILD_ID="$(date +%Y%m%d_%H%M%S)"

log "repo=${REPO_DIR}"
log "rpm_dist=${RPM_DIST}"
log "branch=${BRANCH}"
log "build-mode=${MODE}"
log "with-vmware=${WITH_VMWARE}"
log "ui-node-heap-mb=${UI_NODE_HEAP_MB}"
log "output=${OUT_DIR}"
log "execution=$([ "${DRY_RUN}" -eq 1 ] && echo dry-run || echo apply)"

ensure_build_dependencies
verify_java17_jdk
verify_rpm_build_tools
ensure_vmware_non_oss_deps
run mkdir -p "${LOG_DIR}"
prepare_fresh_output_dir "${OUT_DIR}"
configure_build_options

log "build command: packaging/package.sh --distribution ${RPM_DIST} --pack ${PACKAGE_PACK}"
if [ "${DRY_RUN}" -eq 0 ]; then
  patch_cloud_spec_for_build
  trap restore_cloud_spec EXIT
  (
    sanitize_ui_build_env
    cd "${REPO_DIR}/packaging" && ./package.sh --distribution "${RPM_DIST}" --pack "${PACKAGE_PACK}"
  )
  trap - EXIT
  restore_cloud_spec
fi

collect_runtime_packages
if [ "${DRY_RUN}" -eq 0 ]; then
  validate_cloudstack_rpms "${OUT_DIR}" 0 "${RUNTIME_PKGS[@]}"
  log "RPM installability OK (no rpmlib ShortCircuited)"
  mgmt_rpm="$(find "${OUT_DIR}" -maxdepth 1 -type f -name 'cloudstack-management-*.rpm' | sort | tail -1 || true)"
  [ -n "${mgmt_rpm}" ] && verify_vmware_artifacts_in_archive "${mgmt_rpm}" rpm
fi
write_build_metadata rpm rpm

log "done"
