#!/usr/bin/env bash
# Rocky 8 빌드 호스트 의존성 설치·검사.
# ./build/rocky.sh 가 자동 호출하거나, 수동: sudo ./build/lib/deps-rocky.sh

set -Eeuo pipefail

export NAMUVIRT_SCRIPT_TAG="${NAMUVIRT_SCRIPT_TAG:-build/deps-rocky}"
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
  ./build/lib/deps-rocky.sh [--check-only] [--dry-run]

Installs Rocky 8 build tools for ./build/rocky.sh:
  Java 17 JDK, rpm-build, nodejs, Maven ${MAVEN_VERSION} -> ${MAVEN_LINK}
USAGE
}

# Apache Maven tarball 다운로드 URL.
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
    printf '%s\n' 'java-17-openjdk-devel (java/javac 17)'
  fi

  for tool in rpmbuild rpm2cpio mvn node npm python3 make g++ jq; do
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

  [ "${ok_java}" -eq 1 ] && [ "${ok_tools}" -eq 1 ]
}

# dnf 로 java-17-openjdk-devel 설치.
install_java17_devel() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "dnf install -y java-17-openjdk-devel"
    return 0
  fi
  if rpm -q java-17-openjdk-devel >/dev/null 2>&1; then
    log "java-17-openjdk-devel already installed"
    return 0
  fi
  run dnf install -y java-17-openjdk-devel
}

# alternatives 로 시스템 기본 java/javac 을 17로 설정.
configure_java17_alternatives() {
  local java_home
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "alternatives --set java/javac to Java 17"
    return 0
  fi
  java_home="$(resolve_java17_jdk_home)" || die "Java 17 JDK not found under /usr/lib/jvm after install"
  run alternatives --set java_sdk_17_openjdk "${java_home}"
  run alternatives --set java_sdk_17 "${java_home}"
  run alternatives --set java "${java_home}/bin/java"
  run alternatives --set javac "${java_home}/bin/javac"
  log "alternatives: java/javac -> ${java_home}"
}

# /etc/profile.d/namuvirt-java17.sh 에 JAVA_HOME 기록.
write_java_home_profile() {
  local java_home
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "write /etc/profile.d/namuvirt-java17.sh"
    return 0
  fi
  java_home="$(resolve_java17_jdk_home)" || die "Java 17 JDK not found for profile.d"
  cat > /etc/profile.d/namuvirt-java17.sh <<EOF
# namuVIRT Rocky build host — Java 17 JDK
export JAVA_HOME=${java_home}
export PATH=\${JAVA_HOME}/bin:\${PATH}
EOF
  chmod 644 /etc/profile.d/namuvirt-java17.sh
}

# dnf 로 rpmbuild·nodejs·gcc 등 RPM/UI 빌드 패키지 설치.
install_build_packages() {
  local pkgs=(
    rpm-build rpm-sign nodejs npm python3 python3-setuptools
    make gcc gcc-c++ glibc-devel genisoimage jpackage-utils
    wget curl tar patch which jq
  )
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "dnf install -y ${pkgs[*]}"
    return 0
  fi
  run dnf install -y "${pkgs[@]}"
}

# Apache Maven 을 /opt/maven 에 설치 (Rocky appstream 3.5.x 대신).
install_maven() {
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
  log "Maven ${MAVEN_VERSION} -> ${MAVEN_LINK}"
}

# /etc/profile.d/namuvirt-maven.sh 에 Maven PATH 기록.
write_maven_profile() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "write /etc/profile.d/namuvirt-maven.sh"
    return 0
  fi
  cat > /etc/profile.d/namuvirt-maven.sh <<EOF
# namuVIRT Rocky build host — Apache Maven
export PATH=${MAVEN_LINK}/bin:\${PATH}
EOF
  chmod 644 /etc/profile.d/namuvirt-maven.sh
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
    log "would run full deps-rocky install"
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

install_java17_devel
configure_java17_alternatives
write_java_home_profile
install_build_packages
install_maven
write_maven_profile
build_deps_path
build_deps_missing >/dev/null 2>&1 || die "build dependencies still missing after install"

log "done — build dependencies ready"
