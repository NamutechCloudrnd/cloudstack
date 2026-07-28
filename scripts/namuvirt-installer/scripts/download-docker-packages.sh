#!/usr/bin/env bash
# ============================================================================
# download-docker-packages.sh — 폐쇄망 kvm.master 부트스트랩용 Docker 패키지 다운로드.
#
# install-docker.sh 는 폐쇄망에서 외부 docker repo 를 못 쓴다. 그래서 Docker Engine +
# Compose plugin 의 "의존성 전체(closure)"를 인터넷 되는 빌드 머신에서 미리 받아
#   packages/docker/rocky/   (*.rpm + repodata)
#   packages/docker/ubuntu/  (*.deb)
# 에 넣는다. export-images.sh 가 이걸 릴리스 번들의 docker-packages/<os>/ 로 담고,
# 고객은  sudo ./install-docker.sh --offline  만 실행하면 된다.
#
#   ./scripts/download-docker-packages.sh            # rocky + ubuntu 둘 다
#   ./scripts/download-docker-packages.sh --os rocky # 하나만
#
# Rocky 는 rockylinux:8.10, Ubuntu 는 ubuntu:24.04 컨테이너로 받는다(둘 다 linux/amd64).
# 대상 OS 와 동일한 베이스에서 받으므로 "설치되어 있지 않은 델타"가 곧 필요한 closure 다.
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

OS_SEL="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_SEL="${2:?}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
case "$OS_SEL" in all|rocky|ubuntu) ;; *) echo "ERROR: --os 는 all|rocky|ubuntu" >&2; exit 2 ;; esac

ROCKY_IMAGE="${ROCKY_IMAGE:-rockylinux/rockylinux:8.10}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
# 고객이 받는 docker-ce 세트 (install-docker.sh 와 동일하게 유지)
DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 필요 (빌드 머신)"; exit 1; }
log() { echo "[docker-dl] $*"; }

# ── Rocky: rpm closure + repodata ────────────────────────────────────────────
download_rocky() {
  local out="packages/docker/rocky"
  mkdir -p "$out"
  log "Rocky rpm 다운로드 → $out ($ROCKY_IMAGE)"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" "$ROCKY_IMAGE" bash -c '
    set -e
    dnf -y install dnf-plugins-core createrepo_c >/dev/null 2>&1
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1
    # docker-ce repo GPG 키를 미리 import 한다. (미리 안 하면 다운로드가 트랜잭션 중 키
    #  import 로 빠지면서 --downloaddir 대신 캐시에 남아 /out 이 비게 된다.)
    rpm --import https://download.docker.com/linux/centos/gpg
    # 이전 install 로 캐시에 남은 rpm 을 비워, 이후 sweep 이 docker 델타만 담게 한다.
    dnf clean packages >/dev/null 2>&1 || true
    echo "== docker-ce 의존성 closure 다운로드 (설치는 안 함) =="
    dnf install -y --downloadonly --downloaddir=/out --setopt=install_weak_deps=False \
      '"$DOCKER_PKGS"'
    # --downloaddir 이 놓친 것까지 캐시에서 확실히 회수(ubuntu 와 동일한 명시적 방식).
    find /var/cache/dnf -name "*.rpm" -exec cp -n {} /out/ \; 2>/dev/null || true
    # docker-ce 가 요구하지만 rocky minimal(@core)에 없을 수 있고, 빌더 컨테이너엔 미리 깔려
    # 델타에서 누락되는 base 도구를 강제 확보한다(dnf download 는 설치돼 있어도 rpm 을 받음).
    #   실제 현장: minimal KVM 호스트에 tar 가 없어 "nothing provides tar" 로 오프라인 설치 실패.
    dnf download --destdir=/out tar >/dev/null 2>&1 || echo "WARN: tar 다운로드 실패"
    echo "== repodata 생성 (createrepo_c) =="
    createrepo_c /out >/dev/null 2>&1 || echo "WARN: createrepo_c 실패 — repodata 없이 진행"
    chmod -R a+rX /out
    echo "== rocky rpm: $(ls /out/*.rpm 2>/dev/null | wc -l) 개 =="
  '
  log "Rocky 완료: $(ls "$out"/*.rpm 2>/dev/null | wc -l) 개 rpm"
}

# ── Ubuntu: deb closure ──────────────────────────────────────────────────────
# ubuntu:24.04 컨테이너에 docker repo 를 붙이고 --download-only 로 받는다.
# 컨테이너/대상 모두 24.04 이므로 "컨테이너에 없는 델타" = 대상에 필요한 closure.
download_ubuntu() {
  local out="packages/docker/ubuntu"
  mkdir -p "$out"
  log "Ubuntu deb 다운로드 → $out ($UBUNTU_IMAGE)"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" "$UBUNTU_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update >/dev/null
    echo "== docker-ce 의존성 delta 다운로드 (--download-only) =="
    apt-get install -y --no-install-recommends --download-only '"$DOCKER_PKGS"'
    cp -v /var/cache/apt/archives/*.deb /out/ 2>/dev/null || true
    chmod -R a+rX /out
    echo "== ubuntu deb: $(ls /out/*.deb 2>/dev/null | wc -l) 개 =="
  '
  log "Ubuntu 완료: $(ls "$out"/*.deb 2>/dev/null | wc -l) 개 deb"
}

[[ "$OS_SEL" == "all" || "$OS_SEL" == "rocky"  ]] && download_rocky
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && download_ubuntu
log "완료. export-images.sh 가 packages/docker/<os>/ 를 릴리스 docker-packages/<os>/ 로 번들한다."
