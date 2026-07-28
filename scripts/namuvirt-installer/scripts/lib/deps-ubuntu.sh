#!/usr/bin/env bash
# Ubuntu deb 빌드 호스트 의존성 설치·검사.
# ./build/ubuntu.sh 가 자동 호출하거나, 수동: sudo ./build/lib/deps-ubuntu.sh

set -Eeuo pipefail

export NAMUVIRT_SCRIPT_TAG="${NAMUVIRT_SCRIPT_TAG:-build/deps-ubuntu}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${NAMUVIRT_BUILD_DIR:-$(cd "${LIB_DIR}/.." && pwd)}"
export NAMUVIRT_BUILD_DIR="${BUILD_DIR}"
export NAMUVIRT_REPO_ROOT="${NAMUVIRT_REPO_ROOT:-$(cd "${BUILD_DIR}/.." && pwd)}"

# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"
MAVEN_INSTALL_DIR="${MAVEN_INSTALL_DIR:-/opt/apache-maven-${MAVEN_VERSION}}"
MAVEN_LINK="${MAVEN_LINK:-/opt/maven}"

# --help 출력.
usage() {
  cat <<USAGE
Usage:
  ./build/lib/deps-ubuntu.sh [--check-only] [--dry-run]

Installs Ubuntu build tools for ./build/ubuntu.sh:
  openjdk-17-jdk, maven (apt or ${MAVEN_LINK}), devscripts, nodejs/npm,
  python2/python-setuptools equivs when missing (Noble+)
USAGE
}

# Maven tarball 다운로드 URL.
maven_download_url() {
  printf '%s' "https://dlcdn.apache.org/maven/maven-3/${1}/binaries/apache-maven-${1}-bin.tar.gz"
}

# Maven tarball 다운로드 (dlcdn 실패 시 archive.apache.org).
fetch_maven_archive() {
  local version="$1" dest="$2" primary fallback
  primary="$(maven_download_url "${version}")"
  fallback="https://archive.apache.org/dist/maven/maven-3/${version}/binaries/apache-maven-${version}-bin.tar.gz"
  log "download ${primary}"
  if curl -fsSL -o "${dest}" "${primary}"; then
    return 0
  fi
  warn "primary Maven mirror failed; trying archive.apache.org"
  log "download ${fallback}"
  curl -fsSL -o "${dest}" "${fallback}"
}

# /opt/maven 을 PATH 앞에 추가.
build_deps_path() {
  if [ -x "${MAVEN_LINK}/bin/mvn" ]; then
    export PATH="${MAVEN_LINK}/bin:${PATH}"
  fi
}

# dpkg 로 패키지 설치 여부 확인.
dpkg_installed() {
  dpkg -l "$1" 2>/dev/null | awk '{print $1}' | grep -qx 'ii'
}

# 설치된 패키지 버전이 min 이상인지.
dpkg_version_ge() {
  local pkg="$1" min="$2" ver
  ver="$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true)"
  [ -n "${ver}" ] || return 1
  dpkg --compare-versions "${ver}" ge "${min}"
}

# python (>=2.7) | python2 (>=2.7) Build-Depends 충족 여부.
legacy_python_build_dep_ok() {
  dpkg_version_ge python 2.7 || dpkg_version_ge python2 2.7
}

# 누락된 빌드 도구를 stdout 에 한 줄씩 출력. 모두 있으면 exit 0.
build_deps_missing() {
  build_deps_path
  local ok_java=1 ok_tools=1

  if java -version 2>&1 | grep -qE 'version "17\.|openjdk version "17\.' \
    && command -v javac >/dev/null 2>&1 \
    && javac -version 2>&1 | grep -qE 'javac 17\.'; then
    :
  elif resolve_java17_jdk_home >/dev/null 2>&1; then
    :
  else
    ok_java=0
    printf '%s\n' 'openjdk-17-jdk (java/javac 17)'
  fi

  for tool in mvn dch dpkg-buildpackage node npm python3 genisoimage jar; do
    command -v "${tool}" >/dev/null 2>&1 || {
      ok_tools=0
      printf '%s\n' "${tool}"
    }
  done

  if command -v mvn >/dev/null 2>&1; then
    local mvn_ver min_ok
    mvn_ver="$(mvn -version 2>/dev/null | awk '/Apache Maven/{print $3; exit}')"
    if [ -z "${mvn_ver}" ]; then
      ok_tools=0
      printf '%s\n' 'mvn (version parse failed)'
    else
      min_ok="$(printf '%s\n' '3.6.3' "${mvn_ver}" | sort -V | head -1)"
      if [ "${min_ok}" != "3.6.3" ]; then
        ok_tools=0
        printf '%s\n' "maven>=3.6.3 (found ${mvn_ver})"
      fi
    fi
  fi

  if ! legacy_python_build_dep_ok; then
    ok_tools=0
    printf '%s\n' 'python|python2 (>= 2.7, equivs)'
  fi

  if ! dpkg_installed python-setuptools; then
    ok_tools=0
    printf '%s\n' 'python-setuptools (equivs)'
  fi

  if ! dpkg_installed python3-setuptools; then
    ok_tools=0
    printf '%s\n' 'python3-setuptools'
  fi

  for pkg in devscripts debhelper build-essential lsb-release; do
    dpkg_installed "${pkg}" || {
      ok_tools=0
      printf '%s\n' "${pkg}"
    }
  done

  [ "${ok_java}" -eq 1 ] && [ "${ok_tools}" -eq 1 ]
}

# apt 로 deb 빌드 필수 패키지 설치.
install_apt_packages() {
  local pkgs=(
    openjdk-17-jdk maven devscripts debhelper build-essential genisoimage
    nodejs npm python3 python3-mysql.connector python3-setuptools
    lsb-release equivs curl ca-certificates
  )
  # dh-systemd: Ubuntu 22.04 이하 전용. Noble(24.04)+ 는 debhelper(>=13)에 포함.
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "apt-get install -y ${pkgs[*]}"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq
  run apt-get install -y "${pkgs[@]}"
}

# Noble 등 python2/python 없는 배포판용 equivs 더미 패키지.
# debian/control: python (>= 2.7) | python2 (>= 2.7) — Version 필드 필요.
install_equivs_package() {
  local name="$1" depends="$2" provides="$3" version="$4" description="$5"
  if dpkg_installed "${name}"; then
    if [ -z "${version}" ] || dpkg_version_ge "${name}" "${version}"; then
      log "${name} already installed"
      return 0
    fi
    warn "replacing ${name} (Build-Depends need >= ${version})"
    if [ "${DRY_RUN}" -eq 0 ]; then
      dpkg -r --force-depends "${name}" 2>/dev/null || true
    fi
  fi
  local tmpdir equivs_file deb_path version_line
  tmpdir="$(mktemp -d)"
  equivs_file="${tmpdir}/${name}.equivs"
  version_line=""
  [ -n "${version}" ] && version_line="Version: ${version}"
  cat > "${equivs_file}" <<EOF
Section: misc
Priority: optional
Standards-Version: 3.9.2

Package: ${name}
${version_line}
Depends: ${depends}
Provides: ${provides}
Description: ${description}
 Transitional package for CloudStack debian/control Build-Depends on Ubuntu.
EOF
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "equivs-build ${name} ${version:+(>= ${version})}"
    rm -rf "${tmpdir}"
    return 0
  fi
  (cd "${tmpdir}" && equivs-build "${equivs_file}")
  deb_path="$(find "${tmpdir}" -maxdepth 1 -type f -name "${name}_*.deb" | head -1)"
  [ -n "${deb_path}" ] || die "equivs-build failed for ${name}"
  run dpkg -i "${deb_path}" || run apt-get install -f -y
  rm -rf "${tmpdir}"
  log "installed equivs package: ${name}${version:+ ${version}}"
}

# debian/control Build-Depends: python (>=2.7) | python2 (>=2.7), python-setuptools
install_legacy_python_equivs() {
  install_equivs_package "python" "python3-minimal" "python" "2.7.18" \
    "python 2.7 transitional package for CloudStack deb build"
  install_equivs_package "python2" "python3-minimal" "python2" "2.7.18" \
    "python2 transitional package for CloudStack deb build"
  install_equivs_package "python-setuptools" "python3-setuptools" "python-setuptools" "" \
    "python-setuptools transitional package for CloudStack deb build"
  if [ "${DRY_RUN}" -eq 0 ]; then
    log "Noble+: /usr/bin/python·python2 는 없음 — equivs dpkg 패키지로 Build-Depends 만 충족 (빌드는 python3 사용)"
  fi
}

# apt Maven 이 너무 낮으면 /opt/maven 에 Apache Maven 설치.
install_maven_if_needed() {
  build_deps_path
  if command -v mvn >/dev/null 2>&1; then
    local mvn_ver min_ok
    mvn_ver="$(mvn -version 2>/dev/null | awk '/Apache Maven/{print $3; exit}')"
    if [ -n "${mvn_ver}" ]; then
      min_ok="$(printf '%s\n' '3.6.3' "${mvn_ver}" | sort -V | head -1)"
      if [ "${min_ok}" = "3.6.3" ]; then
        log "Maven ${mvn_ver} OK"
        return 0
      fi
    fi
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "install Apache Maven ${MAVEN_VERSION} -> ${MAVEN_LINK}"
    return 0
  fi
  if [ -x "${MAVEN_LINK}/bin/mvn" ]; then
    local mvn_ver min_ok
    mvn_ver="$("${MAVEN_LINK}/bin/mvn" -version 2>/dev/null | awk '/Apache Maven/{print $3; exit}')"
    if [ -n "${mvn_ver}" ]; then
      min_ok="$(printf '%s\n' '3.6.3' "${mvn_ver}" | sort -V | head -1)"
      if [ "${min_ok}" = "3.6.3" ]; then
        log "Maven ${mvn_ver} already at ${MAVEN_LINK}"
        return 0
      fi
    fi
  fi
  local archive tmpdir
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  fetch_maven_archive "${MAVEN_VERSION}" "${archive}"
  run tar -xzf "${archive}" -C /opt
  [ -d "${MAVEN_INSTALL_DIR}" ] || die "Maven extract dir missing: ${MAVEN_INSTALL_DIR}"
  ln -sfn "${MAVEN_INSTALL_DIR}" "${MAVEN_LINK}"
  rm -rf "${tmpdir}"
  cat > /etc/profile.d/namuvirt-maven.sh <<EOF
# namuVIRT Ubuntu build host — Apache Maven
export PATH=${MAVEN_LINK}/bin:\${PATH}
EOF
  chmod 644 /etc/profile.d/namuvirt-maven.sh
  log "Maven ${MAVEN_VERSION} -> ${MAVEN_LINK}"
}

# ── CLI ───────────────────────────────────────────────────────────

CHECK_ONLY=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root

if [ "${DRY_RUN}" -eq 1 ]; then
  log "check build dependencies (dry-run)"
  if build_deps_missing >/tmp/namuvirt-build-deps-missing.$$ 2>/dev/null; then
    log "all build dependencies present"
  else
    log "would install missing:"
    sed 's/^/  - /' /tmp/namuvirt-build-deps-missing.$$
    log "would run full deps-ubuntu install"
  fi
  rm -f /tmp/namuvirt-build-deps-missing.$$
  exit 0
fi

if build_deps_missing >/tmp/namuvirt-build-deps-missing.$$ 2>/dev/null; then
  rm -f /tmp/namuvirt-build-deps-missing.$$
  log "build dependencies OK"
  exit 0
fi

log "missing build dependencies:"
sed 's/^/  - /' /tmp/namuvirt-build-deps-missing.$$
rm -f /tmp/namuvirt-build-deps-missing.$$

if [ "${CHECK_ONLY}" -eq 1 ]; then
  exit 1
fi

install_apt_packages
install_legacy_python_equivs
install_maven_if_needed
build_deps_path
build_deps_missing >/dev/null 2>&1 || die "build dependencies still missing after install"

log "done — build dependencies ready"
