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

# ── Ubuntu: cloudstack-agent/common 의존성 전체 closure ───────────────────────
# Ubuntu 는 agent 를 `dpkg -i` 로 설치하는데 dpkg 는 의존성을 못 끌어온다. 그래서 cloudstack-agent/
# common 의 Depends 전부(vlan/ipset/ethtool/rng-tools/ufw/cpu-checker/sysstat/uuid-runtime/python3-pip/
# libvirt-daemon-driver-storage-rbd + qemu/libvirt/openjdk 트리 + 버전 고정 lib libacl1 등)를
# 미리 번들에 넣어야 한다.
#
# ★ 왜 `apt-get install --download-only` 로는 부족한가:
#   그 방식은 "빌드 컨테이너에 이미 (최신으로) 깔린" 패키지는 안 받는다. 그런데 실제 폐쇄망 타깃은
#   그 lib 이 구버전이거나 없을 수 있다(예: libacl1 2.3.2-1build1 → acl 이 요구하는 1.1 이 번들에 없어
#   configure 가 통째로 막힘). 그래서 "설치 상태와 무관하게 무조건 받는" `apt-get download` 로,
#   Depends 의 재귀 closure 전체를 candidate 버전으로 받아 버전 고정 lib 까지 확보한다.
#   (qemu/libvirt/openjdk 등 다른 그룹과 겹치는 건 마지막 dedupe-versions 가 정리한다.)
download_ubuntu_cloudstack() {
  local out="packages/os-packages/ubuntu/cloudstack"
  local csdeb="packages/namuvirt/ubuntu"
  if ! ls "$csdeb"/cloudstack-agent_*.deb "$csdeb"/cloudstack-common_*.deb >/dev/null 2>&1; then
    log "SKIP: $csdeb 에 cloudstack-agent/common deb 없음 — cloudstack 의존성 그룹 생략(제품 deb 배치 후 재실행)"
    return 0
  fi
  mkdir -p "$out"
  log "Ubuntu cloudstack-agent/common 의존성 전체 closure 다운로드 → $out ($UBUNTU_IMAGE)"
  docker run --rm --platform linux/amd64 \
    -v "$HARNESS_ROOT/$out:/out" -v "$HARNESS_ROOT/$csdeb:/csdeb:ro" "$UBUNTU_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get clean

    # (A) apt 로 로컬 cloudstack deb 의 의존성을 "해석"시켜 받는다.
    #     → 가상패키지(rng-tools→rng-tools5)·대체(python3-distutils-extra)를 apt 가 올바른 실제
    #       패키지로 골라준다. 단, 컨테이너에 이미 최신인 버전 고정 lib 은 안 받는다(그건 (B)가 보완).
    echo "== (A) apt 의존성 해석 다운로드(가상/대체 포함) =="
    apt-get install -y --no-install-recommends --download-only \
      /csdeb/cloudstack-common_*.deb /csdeb/cloudstack-agent_*.deb || true
    for f in /var/cache/apt/archives/*.deb; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in cloudstack-*) continue ;; esac
      cp -n "$f" /out/
    done

    # (B) 재귀 closure 를 candidate 버전으로 무조건 받는다(설치상태 무관 → libacl1 등 버전 고정 lib 확보).
    # 1) 로컬 cloudstack deb 의 Depends 에서 패키지명 seed 추출.
    #    쉼표/대체(|)로 분리(대체는 양쪽 다 후보로), 버전제약(...)·arch(:any)·공백 제거.
    raw="$(for d in /csdeb/cloudstack-common_*.deb /csdeb/cloudstack-agent_*.deb; do
             dpkg-deb -f "$d" Depends 2>/dev/null
           done | tr ",|" "\n\n" | sed -E "s/\(.*\)//; s/:[a-z0-9]+//g; s/[[:space:]]//g" | grep -v "^$" | sort -u)"
    # 2) repo 에 실제 존재하는 seed 만(없는 대체 python3-distutils 등 제외).
    seeds=""; for p in $raw; do apt-cache show "$p" >/dev/null 2>&1 && seeds="$seeds $p"; done
    [ -n "$seeds" ] || { echo "ERROR: cloudstack Depends seed 를 하나도 못 구함"; exit 1; }
    # 3) seed 들의 재귀 의존 closure 전체 패키지명(가상패키지<...>·들여쓰기 라인 제외).
    echo "== seed $(echo $seeds | wc -w)개 → 재귀 의존 closure 계산 중... =="
    all="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
             --no-breaks --no-replaces --no-enhances $seeds 2>/dev/null \
           | grep "^[a-zA-Z0-9]" | sort -u)"
    # 실제 다운로드 가능한 것만(가상/Provides-only 제외) — apt-cache show 는 로컬이라 빠르다.
    valid=""; for p in $all; do apt-cache show "$p" >/dev/null 2>&1 && valid="$valid $p"; done
    echo "== closure $(echo $valid | wc -w)개 패키지 배치 다운로드 시작 =="
    # 4) candidate 버전으로 배치 다운로드(설치상태 무관 → 버전 고정 lib 확보). 한 번에 받아 빠르다.
    cd /out
    if ! apt-get download $valid; then
      echo "== 배치 실패 — 개별 재시도(느림) =="
      for p in $valid; do apt-get download "$p" 2>/dev/null || echo "  skip $p"; done
    fi
    chmod -R a+rX /out
    echo "== cloudstack closure 완료: $(ls /out/*.deb 2>/dev/null | wc -l) 개 deb =="
  '
  log "Ubuntu cloudstack closure 완료: $(find "$out" -name '*.deb' 2>/dev/null | wc -l | tr -d ' ') 개 deb"
}

[[ "$OS_SEL" == "all" || "$OS_SEL" == "rocky"  ]] && download_rocky
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && download_ubuntu
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && download_ubuntu_cloudstack

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
