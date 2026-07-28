#!/usr/bin/env bash
# ============================================================================
# install-docker.sh — kvm.master 에 Docker Engine + Compose plugin 설치 (부트스트랩).
#
# install-namuvirt.sh 는 Docker 가 이미 있다고 가정한다. 고객 환경에 Docker 가 없으면
# 이 스크립트로 먼저 설치한다. root 또는 sudo 로 실행한다.
#
#   sudo ./install-docker.sh                 # 자동: 번들 docker-packages/ 있으면 오프라인, 없으면 온라인
#   sudo ./install-docker.sh --offline       # 오프라인 (번들 docker-packages/<os>/ 사용)
#   sudo ./install-docker.sh --offline <dir>  # 오프라인 (dir 의 rpm/deb 직접 설치)
#   sudo ./install-docker.sh --online        # 강제 온라인 (docker-ce repo)
#
# 폐쇄망(인터넷 없음)에서는 오프라인 모드를 쓴다. 릴리스 번들에 docker-packages/rocky|ubuntu 가
# 포함돼 있으면 인자 없이 실행해도 자동으로 오프라인 설치된다.
# (번들 패키지는 빌드 머신에서 scripts/download-docker-packages.sh 로 미리 받는다.)
#
# 지원 OS: Rocky 8 (dnf), Ubuntu 24.04 (apt).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

MODE="auto"          # auto | offline | online
OFFLINE_DIR=""
DOCKER_USER=""       # docker 그룹에 추가할 계정 (미지정 시 sudo 실행 계정=$SUDO_USER)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)
      MODE="offline"
      # 다음 인자가 플래그가 아니면 디렉터리로 취급(선택적)
      if [[ $# -ge 2 && "${2:0:1}" != "-" ]]; then OFFLINE_DIR="$2"; shift 2; else shift; fi ;;
    --online) MODE="online"; shift ;;
    --user)   DOCKER_USER="${2:?--user 뒤에 계정명 필요}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[docker] $*"; }
[[ "$(id -u)" -eq 0 ]] || die "root 또는 sudo 로 실행할 것."

. /etc/os-release || die "/etc/os-release 를 읽을 수 없다."

# ID → 번들 하위 디렉터리 이름(rocky|ubuntu) 매핑
case "$ID" in
  rocky|rhel|centos|almalinux) OS_DIR="rocky" ;;
  ubuntu|debian)               OS_DIR="ubuntu" ;;
  *) OS_DIR="" ;;
esac
BUNDLE_DIR="$SCRIPT_DIR/docker-packages/$OS_DIR"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "Docker 이미 설치·실행 중: $(docker --version)"
  docker compose version >/dev/null 2>&1 && { log "Compose plugin 존재 — 설치 불필요."; exit 0; }
fi

# ── 모드 자동 결정 (auto): 번들 패키지가 있으면 오프라인 ─────────────────────
if [[ "$MODE" == "auto" ]]; then
  if [[ -n "$OS_DIR" && -n "$(ls "$BUNDLE_DIR"/*.rpm "$BUNDLE_DIR"/*.deb 2>/dev/null)" ]]; then
    MODE="offline"; log "번들 패키지 감지 → 오프라인 설치 ($BUNDLE_DIR)"
  else
    MODE="online"; log "번들 패키지 없음 → 온라인 설치 (docker-ce repo)"
  fi
fi

# ── 온라인 설치 ──────────────────────────────────────────────────────────────
install_rocky_online() {
  log "docker-ce repo 추가 + 설치 (Rocky/dnf)"
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
install_ubuntu_online() {
  log "docker repo 추가 + 설치 (Ubuntu/apt)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# ── 오프라인 설치 (폐쇄망) ───────────────────────────────────────────────────
install_offline() {
  # 디렉터리 미지정 시 번들 경로 사용
  [[ -n "$OFFLINE_DIR" ]] || OFFLINE_DIR="$BUNDLE_DIR"
  [[ -d "$OFFLINE_DIR" ]] || die "오프라인 패키지 디렉터리가 없다: $OFFLINE_DIR
  (빌드 머신에서 scripts/download-docker-packages.sh 로 받아 번들에 포함하거나, --offline <dir> 로 지정)"
  case "$OS_DIR" in
    rocky)
      local n; n="$(ls "$OFFLINE_DIR"/*.rpm 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$n" -gt 0 ]] || die "rpm 파일이 없다: $OFFLINE_DIR/*.rpm"
      log "오프라인 설치 (dnf, $OFFLINE_DIR, ${n}개 rpm) — 온라인 repo 미사용"
      # 온라인 repo 를 끄고, 제공된 rpm 만으로 의존성 해소(closure 완비 전제).
      dnf -y install --disablerepo='*' "$OFFLINE_DIR"/*.rpm ;;
    ubuntu)
      local n; n="$(ls "$OFFLINE_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$n" -gt 0 ]] || die "deb 파일이 없다: $OFFLINE_DIR/*.deb"
      log "오프라인 설치 (apt local deb, $OFFLINE_DIR, ${n}개 deb) — 온라인 repo 미사용"
      export DEBIAN_FRONTEND=noninteractive
      # 로컬 deb 들 사이에서만 의존성 해소(네트워크 접근 없음). 실패 시 dpkg 2-pass 로 폴백.
      apt-get install -y --no-download "$OFFLINE_DIR"/*.deb \
        || { dpkg -i "$OFFLINE_DIR"/*.deb; dpkg -i "$OFFLINE_DIR"/*.deb; } ;;
    *) die "지원하지 않는 OS: $ID" ;;
  esac
}

case "$MODE" in
  offline) install_offline ;;
  online)
    case "$OS_DIR" in
      rocky)  install_rocky_online ;;
      ubuntu) install_ubuntu_online ;;
      *) die "지원하지 않는 OS: $ID (offline 모드로 rpm/deb 직접 설치 가능)" ;;
    esac ;;
esac

log "docker 서비스 활성화"
systemctl enable --now docker

log "검증"
docker --version
docker compose version
docker info >/dev/null 2>&1 && log "Docker Engine 실행 확인 OK" || die "docker info 실패"

# ── 비-root 계정을 docker 그룹에 추가 ────────────────────────────────────────
# install-namuvirt.sh 는 sudo 없이 docker 를 직접 호출한다. 설치 실행 계정(namuvirt 등)이
# docker 그룹에 없으면 'permission denied' 로 못 돈다. 그래서 여기서 자동 추가한다.
#   대상 계정: --user 로 지정, 없으면 sudo 실행 계정($SUDO_USER).
TARGET_USER="${DOCKER_USER:-${SUDO_USER:-}}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  if id "$TARGET_USER" >/dev/null 2>&1; then
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      log "$TARGET_USER 는 이미 docker 그룹 멤버."
    else
      usermod -aG docker "$TARGET_USER"
      log "$TARGET_USER 를 docker 그룹에 추가했다."
      log "!! 지금 세션에는 반영 안 됨 — 로그아웃/로그인 하거나 'newgrp docker' 후에"
      log "!! install-namuvirt.sh 를 실행할 것 (또는 sudo 로 실행)."
    fi
  else
    log "WARN: 계정이 없다: $TARGET_USER — 'usermod -aG docker <user>' 로 수동 추가할 것."
  fi
else
  log "docker 그룹에 추가할 비-root 계정을 특정 못함 (root 로 직접 실행?)."
  log "  설치 실행 계정이 있으면: sudo ./install-docker.sh --user <계정> 또는"
  log "  usermod -aG docker <계정> 후 로그인 재시도."
fi
log "완료."
