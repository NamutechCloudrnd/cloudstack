#!/usr/bin/env bash
# ============================================================================
# download-host-packages.sh — 폐쇄망 KVM Host 용 OS 패키지(그룹별) 의존성 다운로드.
#
# KVM Host(Rocky 8 / Ubuntu 24.04) 구성에 필요한 패키지를 "그룹별"로, 의존성 전체(closure)와
# 함께 인터넷 되는 빌드 머신에서 미리 받아 아래에 채운다:
#   packages/os-packages/rocky/<그룹>/*.rpm
#   packages/os-packages/ubuntu/<그룹>/*.deb
# 이 디렉터리들은 build-images.sh 가 host 이미지에 내장하고, 설치 시 ansible(packages_rocky/ubuntu.yml)이
# 레포 없이 직접 설치한다. (그룹: qemu-kvm libvirt network nfs iscsi vm-tools java chrony utils)
#
#   ./scripts/download-host-packages.sh              # rocky + ubuntu 둘 다
#   ./scripts/download-host-packages.sh --os rocky   # 하나만
#
# 대상 OS 와 동일 베이스(rockylinux:8.10 / ubuntu:24.04) 컨테이너로 받으므로 "설치되어 있지 않은
# 델타"가 곧 필요한 closure 다. 각 그룹은 자기 closure 를 그대로 보유한다(그룹 간 공유 rpm 을
# _base 로 모으는 이름-중복 제거는 하지 않는다). 버전 중복 제거만 마지막에 수행한다.
#
# ※ 아래 그룹별 패키지 목록은 CloudStack KVM Host 표준 요구를 기준으로 한 편집 가능한 기본값이다.
#   환경(추가 스토리지/네트워크 드라이버 등)에 따라 목록을 조정할 수 있다.
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

OS_SEL="all"
RUN_DEDUPE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)        OS_SEL="${2:?}"; shift 2 ;;
    --no-dedupe) RUN_DEDUPE=0; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
case "$OS_SEL" in all|rocky|ubuntu) ;; *) echo "ERROR: --os 는 all|rocky|ubuntu" >&2; exit 2 ;; esac

ROCKY_IMAGE="${ROCKY_IMAGE:-rockylinux/rockylinux:8.10}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 필요 (빌드 머신)"; exit 1; }
log() { echo "[host-dl] $*"; }

# ── Rocky: 그룹별 rpm closure ────────────────────────────────────────────────
download_rocky() {
  local out="packages/os-packages/rocky"
  mkdir -p "$out"
  log "Rocky rpm 다운로드 → $out ($ROCKY_IMAGE)"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" "$ROCKY_IMAGE" bash -c '
    set -e
    dnf -y install dnf-plugins-core >/dev/null 2>&1
    dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
      || dnf config-manager --set-enabled crb   >/dev/null 2>&1 || true
    dnf -y install epel-release >/dev/null 2>&1 || true
    declare -A G=(
      [qemu-kvm]="qemu-kvm qemu-img qemu-kvm-core"
      [libvirt]="libvirt libvirt-client libvirt-daemon-kvm virt-install"
      [network]="bridge-utils iptables-ebtables iptables"
      [nfs]="nfs-utils rpcbind"
      [iscsi]="iscsi-initiator-utils"
      [vm-tools]="virt-what genisoimage cloud-utils-growpart"
      [java]="java-17-openjdk-headless"
      [chrony]="chrony"
      [utils]="wget tar bzip2 rsync lsof"
    )
    for g in "${!G[@]}"; do
      mkdir -p "/out/$g"
      dnf clean packages >/dev/null 2>&1 || true
      echo "== [rocky:$g] ${G[$g]} =="
      dnf install -y --downloadonly --downloaddir="/out/$g" --setopt=install_weak_deps=False ${G[$g]} \
        || echo "WARN: [rocky:$g] 일부 패키지 확인 필요"
      # --downloaddir 이 놓친 것 캐시에서 회수
      find /var/cache/dnf -name "*.rpm" -exec cp -n {} "/out/$g/" \; 2>/dev/null || true
      # 명시 패키지(tar 등)가 빌더에 미리 깔려 델타에서 누락되는 것을 방지: 강제로 rpm 확보.
      # (dnf download 는 설치돼 있어도 rpm 을 받는다. tar 는 minimal 타깃에 없고 unarchive 에 필요.)
      dnf download --destdir="/out/$g" ${G[$g]} >/dev/null 2>&1 || true
    done
    chmod -R a+rX /out
    echo "== rocky 그룹별 rpm 수 =="
    for g in "${!G[@]}"; do echo "  $g: $(ls /out/$g/*.rpm 2>/dev/null | wc -l)"; done
  '
  log "Rocky 완료: $(find "$out" -name '*.rpm' 2>/dev/null | wc -l | tr -d ' ') 개 rpm(그룹 합계)"
}

# ── Ubuntu: 그룹별 deb closure ───────────────────────────────────────────────
download_ubuntu() {
  local out="packages/os-packages/ubuntu"
  mkdir -p "$out"
  log "Ubuntu deb 다운로드 → $out ($UBUNTU_IMAGE)"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" "$UBUNTU_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    declare -A G=(
      [qemu-kvm]="qemu-system-x86 qemu-utils"
      [libvirt]="libvirt-daemon-system libvirt-clients virtinst"
      [network]="bridge-utils ebtables iptables"
      [nfs]="nfs-common nfs-kernel-server rpcbind"
      [iscsi]="open-iscsi"
      [vm-tools]="cloud-image-utils genisoimage"
      [java]="openjdk-17-jre-headless"
      [chrony]="chrony"
      [utils]="wget tar bzip2 rsync lsof"
    )
    for g in "${!G[@]}"; do
      mkdir -p "/out/$g"
      apt-get clean
      echo "== [ubuntu:$g] ${G[$g]} =="
      apt-get install -y --no-install-recommends --download-only ${G[$g]} \
        || echo "WARN: [ubuntu:$g] 일부 패키지 확인 필요"
      cp -n /var/cache/apt/archives/*.deb "/out/$g/" 2>/dev/null || true
    done
    chmod -R a+rX /out
    echo "== ubuntu 그룹별 deb 수 =="
    for g in "${!G[@]}"; do echo "  $g: $(ls /out/$g/*.deb 2>/dev/null | wc -l)"; done
  '
  log "Ubuntu 완료: $(find "$out" -name '*.deb' 2>/dev/null | wc -l | tr -d ' ') 개 deb(그룹 합계)"
}

[[ "$OS_SEL" == "all" || "$OS_SEL" == "rocky"  ]] && download_rocky
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && download_ubuntu

# 다운로드 직후 정리. --no-dedupe 로 생략 가능.
# 버전 중복 제거만 수행한다: 같은 패키지의 구버전 삭제(최신만) → 설치 시 "cannot install both" 방지.
# ※ 그룹 간 공유 rpm 을 _base 로 모으는 이름-중복 제거(dedupe-os-packages.sh)는 하지 않는다.
#   각 그룹이 자기 closure 를 그대로 보유한다(java/utils 등이 비지 않음).
if [[ "$RUN_DEDUPE" -eq 1 ]]; then
  if [[ -x scripts/dedupe-versions.sh ]]; then
    log "os-packages 버전 중복 제거(dedupe-versions.sh --os $OS_SEL)"
    scripts/dedupe-versions.sh --os "$OS_SEL" || log "WARN: 버전 중복 제거 실패 — 수동 확인"
  fi
fi
log "완료. build-images.sh 가 packages/os-packages/<os>/<그룹>/ 을 host 이미지에 내장한다."
