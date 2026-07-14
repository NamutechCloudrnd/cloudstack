#!/usr/bin/env bash
# Rocky RPM / Ubuntu deb 빌드 공통 헬퍼.
# 경로: REPO_ROOT=레포 루트, BUILD_DIR=build/, NON_OSS_DIR=vendor/cloudstack-nonoss

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${NAMUVIRT_BUILD_DIR:-$(cd "${LIB_DIR}/.." && pwd)}"
REPO_ROOT="${NAMUVIRT_REPO_ROOT:-$(cd "${BUILD_DIR}/.." && pwd)}"
REPO_DIR="${REPO_DIR:-${REPO_ROOT}}"
NON_OSS_DIR="${NON_OSS_DIR:-${NONOSS_DEPS_DIR:-${REPO_ROOT}/vendor/cloudstack-nonoss}}"
LOG_DIR="${BUILD_DIR}/logs"

RUNTIME_PKGS=(cloudstack-common cloudstack-management cloudstack-agent cloudstack-ui cloudstack-usage)

# 로그 한 줄 출력.
log() { printf '[%s] %s\n' "${NAMUVIRT_SCRIPT_TAG:-build}" "$*"; }
# 경고 로그 (stderr).
warn() { printf '[%s] WARN: %s\n' "${NAMUVIRT_SCRIPT_TAG:-build}" "$*" >&2; }
# 에러 메시지 후 종료.
die() { printf '[%s] ERROR: %s\n' "${NAMUVIRT_SCRIPT_TAG:-build}" "$*" >&2; exit 1; }

# 명령을 '+ cmd' 형태로 출력; DRY_RUN=1 이면 실행 생략.
run() {
  printf '+'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0
  "$@"
}

# root 권한 확인 (DRY_RUN 이면 생략).
require_root() {
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0
  [ "$(id -u)" -eq 0 ] || die "run as root"
}

# deps-*.sh 를 root 또는 sudo 로 실행.
run_build_deps_installer() {
  local script="$1"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    bash "${script}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -E bash "${script}"
  else
    die "missing build tools — run: sudo bash ${script}"
  fi
}

# 빌드 deps 스크립트가 있으면 --check-only, 없으면 설치 (SKIP_ENSURE_BUILD_DEPS·DRY_RUN 존중).
ensure_build_deps_script() {
  local deps_script="$1"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log "ensure build dependencies (dry-run: skip)"
    return 0
  fi
  if [ "${SKIP_ENSURE_BUILD_DEPS:-0}" -eq 1 ]; then
    log "SKIP_ENSURE_BUILD_DEPS=1 — skip auto-install"
    return 0
  fi
  if ! bash "${deps_script}" --check-only 2>/dev/null; then
    log "missing build tools — running ${deps_script}"
    run_build_deps_installer "${deps_script}"
  else
    log "build dependencies OK"
  fi
}

# 산출물 디렉터리를 비운 뒤 재생성 (이전 빌드 잔여물 제거).
prepare_fresh_output_dir() {
  local dir="$1"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log "prepare fresh output: ${dir}/"
    return 0
  fi
  rm -rf "${dir}"
  mkdir -p "${dir}"
}

# /usr/lib/jvm 에서 Java 17 JDK(javac 포함) 홈 경로 탐색.
resolve_java17_jdk_home() {
  local candidate home real_java
  for candidate in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-17-openjdk-*; do
    if [ -d "${candidate}" ] && [ -x "${candidate}/bin/java" ] && [ -x "${candidate}/bin/javac" ]; then
      printf '%s' "$(readlink -f "${candidate}")"
      return 0
    fi
  done
  if [ -x /etc/alternatives/java ]; then
    real_java="$(readlink -f /etc/alternatives/java)"
    candidate="$(dirname "$(dirname "${real_java}")")"
    if [ -x "${candidate}/bin/java" ] && [ -x "${candidate}/bin/javac" ]; then
      java -version 2>&1 | grep -qE 'version "17\.|openjdk version "17\.' || return 1
      printf '%s' "${candidate}"
      return 0
    fi
  fi
  return 1
}

# RPM 이 rpmbuild --short-circuit 산출물인지 확인 (dnf 설치 불가).
rpm_requires_shortcircuited() {
  local rpm_path="$1"
  rpm -qp --requires "${rpm_path}" 2>/dev/null | grep -q 'rpmlib(ShortCircuited)'
}

# runtime RPM 5종 존재·설치 가능 여부 검증.
validate_cloudstack_rpms() {
  local dir="$1" dry_run="$2"
  shift 2
  local pkg rpm_path

  for pkg in "$@"; do
    if [ "${dry_run}" -eq 1 ]; then
      log "require ${dir}/${pkg}-*.rpm"
      continue
    fi
    rpm_path="$(compgen -G "${dir}/${pkg}-*.rpm" | head -1 || true)"
    [ -n "${rpm_path}" ] || die "missing package: ${pkg}-*.rpm in ${dir}"
    if rpm_requires_shortcircuited "${rpm_path}"; then
      die "uninstallable RPM (rpmlib ShortCircuited): ${rpm_path}
  Rebuild with full rpmbuild only (never rpmbuild --short-circuit):
    ./build/rocky.sh"
    fi
  done
}

# 공통 CLI 플래그 파싱 (--mode, --dry-run, --without-vmware 등). --help 시 return 1.
build_parse_common_args() {
  DRY_RUN=0
  MODE="${BUILD_MODE:-normal}"
  WITH_VMWARE=1
  SKIP_ENSURE_BUILD_DEPS=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --without-vmware) WITH_VMWARE=0; shift ;;
      --no-auto-deps) SKIP_ENSURE_BUILD_DEPS=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) return 1 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  case "${MODE}" in
    normal|dev|clean) ;;
    *) die "invalid mode: ${MODE}" ;;
  esac
}

# BUILD_INFO 메타데이터용 브랜치/커밋 (git 상태로 빌드 차단 안 함).
build_preflight_repo() {
  BRANCH="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "HEAD" ]; then
    BRANCH="$(git -C "${REPO_DIR}" describe --tags --always 2>/dev/null || echo unknown)"
  fi
}

# ~/.m2 에 VMware vim25/pbm JAR 존재 여부.
vmware_maven_jar_exists() {
  local artifact="$1" version="$2"
  [ -s "${HOME}/.m2/repository/com/cloud/com/vmware/${artifact}/${version}/${artifact}-${version}.jar" ]
}

# ~/.m2 에 지정 Maven artifact JAR 존재 여부.
maven_jar_exists() {
  local group_path="$1" artifact="$2" version="$3"
  [ -s "${HOME}/.m2/repository/${group_path}/${artifact}/${version}/${artifact}-${version}.jar" ]
}

# noredist 빌드용 non-OSS JAR — 매 빌드 vendor/install-non-oss.sh 로 ~/.m2 등록.
ensure_vmware_non_oss_deps() {
  [ "${WITH_VMWARE}" -eq 1 ] || return 0
  [ "${DRY_RUN}" -eq 1 ] && return 0

  [ -d "${NON_OSS_DIR}" ] || die "vendor/cloudstack-nonoss not found — JAR 10종이 레포에 있어야 합니다"
  [ -f "${NON_OSS_DIR}/install-non-oss.sh" ] || die "missing ${NON_OSS_DIR}/install-non-oss.sh"
  command -v mvn >/dev/null 2>&1 || die "mvn is required to register non-OSS dependencies"

  (cd "${NON_OSS_DIR}" && sh ./install-non-oss.sh)

  if ! vmware_maven_jar_exists "vmware-vim25" "8.0" || ! vmware_maven_jar_exists "vmware-pbm" "8.0"; then
    die "VMware SDK missing in ~/.m2 after install-non-oss.sh"
  fi
}

# java/javac 17 설치·PATH 확인; 필요 시 JAVA_HOME 자동 설정.
verify_java17_jdk() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "verify Java 17 JDK: java/javac version 17"
    return 0
  fi
  if ! java -version 2>&1 | grep -qE 'version "17\.|openjdk version "17\.' \
    || ! command -v javac >/dev/null 2>&1; then
    if candidate="$(resolve_java17_jdk_home)"; then
      export JAVA_HOME="${candidate}"
      export PATH="${JAVA_HOME}/bin:${PATH}"
      log "JAVA_HOME=${JAVA_HOME}"
    fi
  fi
  command -v java >/dev/null 2>&1 || die "java not found — run ./build/rocky.sh or ./build/ubuntu.sh without --no-auto-deps (sudo may be required)"
  command -v javac >/dev/null 2>&1 || die "javac not found — install Java 17 JDK (Rocky: deps-rocky.sh, Ubuntu: deps-ubuntu.sh)"
  java -version 2>&1 | grep -qE 'version "17\.|openjdk version "17\.' || die "Java 17 is required"
  javac -version 2>&1 | grep -qE 'javac 17\.' || die "javac 17 is required"
}

# cloudstack-management RPM/deb 안에 VMware 모듈·JAR 포함 여부 검증.
verify_vmware_artifacts_in_archive() {
  local archive="$1" format="$2"
  [ "${WITH_VMWARE}" -eq 1 ] || return 0
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "verify VMware artifacts inside cloudstack-management ${format}"
    return 0
  fi

  command -v jar >/dev/null 2>&1 || die "jar command not found; Java JDK is required"
  local verify_dir cloudstack_jar contents

  verify_dir="$(mktemp -d)"
  case "${format}" in
    rpm)
      (cd "${verify_dir}" && rpm2cpio "${archive}" | cpio -idm --quiet)
      cloudstack_jar="$(find "${verify_dir}" -path '*/usr/share/cloudstack-management/lib/cloudstack-*.jar' | sort | tail -1 || true)"
      ;;
    deb)
      dpkg-deb -x "${archive}" "${verify_dir}"
      cloudstack_jar="$(find "${verify_dir}/usr/share/cloudstack-management/lib" -maxdepth 1 -type f -name 'cloudstack-*.jar' | sort | tail -1 || true)"
      ;;
    *) die "unsupported package format: ${format}" ;;
  esac

  [ -n "${cloudstack_jar}" ] || die "cloudstack management jar not found in ${archive}"
  contents="$(jar tf "${cloudstack_jar}" | grep -iE 'META-INF/cloudstack/vmware|com/vmware/vim25|com/vmware/pbm' || true)"
  [ -n "${contents}" ] || die "VMware support was not found inside ${archive}"

  for req in \
    "META-INF/cloudstack/vmware-compute/module.properties" \
    "META-INF/cloudstack/vmware-storage/module.properties" \
    "META-INF/cloudstack/vmware-network/module.properties" \
    "META-INF/cloudstack/vmware-discoverer/module.properties" \
    "com/vmware/vim25/" \
    "com/vmware/pbm/"; do
    grep -qi "${req}" <<<"${contents}" || die "missing VMware artifact: ${req}"
  done
  printf '%s\n' "${contents}" > "${OUT_DIR}/cloudstack-management-vmware-jars.txt"
  rm -rf "${verify_dir}"
}

# SHA256SUMS·BUILD_INFO.txt 작성 (산출물 디렉터리 OUT_DIR).
write_build_metadata() {
  local format="$1" ext="$2"
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "write ${OUT_DIR}/SHA256SUMS"
    log "write ${OUT_DIR}/BUILD_INFO.txt"
    return 0
  fi
  (
    cd "${OUT_DIR}"
    sha256sum ./*."${ext}" > SHA256SUMS
  )
  {
    printf 'build_id=%s\n' "${BUILD_ID}"
    printf 'branch=%s\n' "${BRANCH}"
    printf 'commit=%s\n' "$(git -C "${REPO_DIR}" rev-parse HEAD)"
    printf 'describe=%s\n' "$(git -C "${REPO_DIR}" describe --tags --always --dirty 2>/dev/null || true)"
    printf 'mode=%s\n' "${MODE}"
    printf 'with_vmware=%s\n' "${WITH_VMWARE}"
    printf 'package_format=%s\n' "${format}"
    printf 'repo_dir=%s\n' "${REPO_DIR}"
    printf 'built_at=%s\n' "$(date -Is)"
  } > "${OUT_DIR}/BUILD_INFO.txt"
}
