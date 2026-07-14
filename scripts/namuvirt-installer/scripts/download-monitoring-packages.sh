#!/usr/bin/env bash
# ============================================================================
# download-monitoring-packages.sh — 모니터링 스택(Grafana/Prometheus/Exporter) 다운로드.
#
# 폐쇄망에서 레포 없이 설치할 모니터링 산출물을 인터넷 되는 빌드 머신에서 미리 받아 채운다
# (수동 배치를 자동화 — gremlin 등으로 지워져도 이 스크립트 한 번으로 복구):
#   packages/monitoring/common/  prometheus-<ver>.linux-amd64.tar.gz  (관리 VM, OS 무관)
#   packages/monitoring/rocky/   grafana-<ver>-1.x86_64.rpm           (Rocky 관리 VM)
#   packages/monitoring/ubuntu/  grafana_<ver>_amd64.deb              (Ubuntu 관리 VM)
#   packages/exporters/          node/process/libvirt exporter tar.gz (KVM Host, OS 무관)
#
# build-images.sh 가 이걸 관리 이미지에 내장(COPY packages/monitoring/)하고,
# 설치 시 ansible(management/configure/monitoring.yml)이 직접 설치한다.
# ※ Grafana 의 "의존성"은 download-management-packages.sh 가 mgmt offline repo 로 받는다.
#   이 스크립트는 Grafana/Prometheus "본체"를 받는다(그게 download-management 의 입력이기도 함).
#
#   ./scripts/download-monitoring-packages.sh                 # rocky + ubuntu + prometheus
#   ./scripts/download-monitoring-packages.sh --os rocky      # grafana rpm + prometheus 만
#   GRAFANA_VER=11.6.1 PROM_VER=2.55.1 ./scripts/download-monitoring-packages.sh
#
# Grafana OSS: rpm.grafana.com / apt.grafana.com,  Prometheus: github releases.
# 버전 미지정(빈 값)이면 저장소의 최신을 받는다. 재현성 위해 배포 시엔 고정 권장.
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

OS_SEL="all"
GRAFANA_VER="${GRAFANA_VER:-11.6.1}"      # 빈 값이면 최신. 예: 11.6.1
PROM_VER="${PROM_VER:-2.55.1}"            # prometheus github 릴리스 태그(v 제외). 빈 값이면 최신 조회.
# KVM Host 용 exporter 3종 (github releases tar.gz → packages/exporters/, OS 무관)
NODE_EXPORTER_VER="${NODE_EXPORTER_VER:-1.8.2}"
PROCESS_EXPORTER_VER="${PROCESS_EXPORTER_VER:-0.8.3}"
LIBVIRT_EXPORTER_VER="${LIBVIRT_EXPORTER_VER:-2.3.1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)                 OS_SEL="${2:?}"; shift 2 ;;
    --grafana-version)    GRAFANA_VER="${2:-}"; shift 2 ;;
    --prometheus-version) PROM_VER="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
case "$OS_SEL" in all|rocky|ubuntu) ;; *) echo "ERROR: --os 는 all|rocky|ubuntu" >&2; exit 2 ;; esac

ROCKY_IMAGE="${ROCKY_IMAGE:-rockylinux/rockylinux:8.10}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 필요 (빌드 머신)"; exit 1; }
log() { echo "[mon-dl] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Grafana RPM (Rocky) ──────────────────────────────────────────────────────
download_grafana_rocky() {
  local out="packages/monitoring/rocky"
  mkdir -p "$out"
  log "Grafana rpm 다운로드 → $out (ver=${GRAFANA_VER:-latest})"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" \
    -e GVER="$GRAFANA_VER" "$ROCKY_IMAGE" bash -c '
      set -e
      dnf -y install dnf-plugins-core >/dev/null 2>&1
      cat >/etc/yum.repos.d/grafana.repo <<EOF
[grafana]
name=grafana-oss
baseurl=https://rpm.grafana.com
repo_gpgcheck=0
gpgcheck=0
enabled=1
EOF
      # grafana(OSS) 본체만, x86_64 만 받는다(레포엔 aarch64 도 있어 --arch 로 제한).
      # 의존성은 mgmt closure(download-management) 담당. 버전 지정 있으면 고정.
      if [ -n "$GVER" ]; then
        dnf download --arch x86_64 --destdir=/out "grafana-${GVER}" \
          || dnf download --arch x86_64 --destdir=/out grafana
      else
        dnf download --arch x86_64 --destdir=/out grafana
      fi
      chmod -R a+rX /out
      echo "== grafana rpm: $(ls /out/grafana-*.rpm 2>/dev/null | wc -l) 개 =="
      for f in /out/grafana-*.rpm; do [ -e "$f" ] && basename "$f"; done
    '
  [[ -n "$(ls "$out"/grafana-*.rpm 2>/dev/null)" ]] || die "Grafana rpm 다운로드 실패 ($out 비어있음)"
  log "Rocky 완료: $(ls "$out"/grafana-*.rpm 2>/dev/null | wc -l) 개 grafana rpm"
}

# ── Grafana DEB (Ubuntu) ─────────────────────────────────────────────────────
download_grafana_ubuntu() {
  local out="packages/monitoring/ubuntu"
  mkdir -p "$out"
  log "Grafana deb 다운로드 → $out (ver=${GRAFANA_VER:-latest})"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$out:/out" \
    -e GVER="$GRAFANA_VER" "$UBUNTU_IMAGE" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
      echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
      apt-get update >/dev/null
      cd /out
      if [ -n "$GVER" ]; then
        apt-get download "grafana=${GVER}" || apt-get download grafana
      else
        apt-get download grafana
      fi
      chmod -R a+rX /out
      echo "== grafana deb: $(ls /out/grafana*.deb 2>/dev/null | wc -l) 개 =="
      for f in /out/grafana*.deb; do [ -e "$f" ] && basename "$f"; done
    '
  [[ -n "$(ls "$out"/grafana*.deb 2>/dev/null)" ]] || die "Grafana deb 다운로드 실패 ($out 비어있음)"
  log "Ubuntu 완료: $(ls "$out"/grafana*.deb 2>/dev/null | wc -l) 개 grafana deb"
}

# ── Prometheus tar.gz (OS 무관, common) ──────────────────────────────────────
download_prometheus() {
  local out="packages/monitoring/common"
  mkdir -p "$out"
  local ver="$PROM_VER"
  if [[ -z "$ver" ]]; then
    log "Prometheus 최신 버전 조회 (github API)"
    ver="$(curl -fsSL https://api.github.com/repos/prometheus/prometheus/releases/latest \
            | sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p' | head -1)"
    [[ -n "$ver" ]] || die "Prometheus 최신 버전 조회 실패 — --prometheus-version 로 지정하라"
  fi
  local tarball="prometheus-${ver}.linux-amd64.tar.gz"
  local url="https://github.com/prometheus/prometheus/releases/download/v${ver}/${tarball}"
  log "Prometheus 다운로드 → $out/$tarball"
  # 기존 다른 버전 tar 는 제거(설치 시 최신 1개만 잡히도록)
  find "$out" -maxdepth 1 -name 'prometheus-*linux-amd64.tar.gz' ! -name "$tarball" -delete 2>/dev/null || true
  curl -fSL "$url" -o "$out/$tarball" || die "Prometheus 다운로드 실패: $url"
  [[ -s "$out/$tarball" ]] || die "Prometheus tar.gz 가 비어있음: $out/$tarball"
  log "완료: $out/$tarball ($(du -h "$out/$tarball" | cut -f1))"
}

# ── KVM Host exporter 3종 (github releases → packages/exporters/) ────────────
# node/process/libvirt exporter tar.gz. host 이미지에 내장되어 KVM Host 에 설치된다.
download_exporters() {
  local out="packages/exporters"
  mkdir -p "$out"
  log "Exporter tar.gz 다운로드 → $out"
  # name|repo|version
  local specs=(
    "node_exporter|prometheus/node_exporter|${NODE_EXPORTER_VER}"
    "process-exporter|ncabatoff/process-exporter|${PROCESS_EXPORTER_VER}"
    "prometheus-libvirt-exporter|inovex/prometheus-libvirt-exporter|${LIBVIRT_EXPORTER_VER}"
  )
  local spec name repo ver dest url aurl
  for spec in "${specs[@]}"; do
    IFS='|' read -r name repo ver <<<"$spec"
    dest="$out/${name}-${ver}.linux-amd64.tar.gz"
    if [[ -s "$dest" ]]; then log "  skip(있음): $(basename "$dest")"; continue; fi
    # 다른 버전 tar 는 제거(설치 시 최신 1개만 잡히도록)
    find "$out" -maxdepth 1 -name "${name}-*.linux-amd64.tar.gz" ! -name "$(basename "$dest")" -delete 2>/dev/null || true
    url="https://github.com/${repo}/releases/download/v${ver}/${name}-${ver}.linux-amd64.tar.gz"
    log "  ${name} ${ver} ← ${repo}"
    if ! curl -fSL "$url" -o "$dest" 2>/dev/null; then
      # 직접 URL 실패(자산 naming 다름) → github API 로 linux-amd64 자산 조회
      log "    직접 URL 실패 → github API 자산 탐색"
      aurl="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/v${ver}" \
              | sed -n 's/.*"browser_download_url": *"\([^"]*linux[-_]amd64\.tar\.gz\)".*/\1/p' | head -1)"
      [[ -n "$aurl" ]] || die "${name} ${ver} linux-amd64 자산을 못 찾음 (repo=${repo}) — 버전/repo 확인"
      curl -fSL "$aurl" -o "$dest" || die "${name} 다운로드 실패: $aurl"
    fi
    [[ -s "$dest" ]] || die "${name} tar.gz 가 비어있음"
    log "    완료: $(basename "$dest") ($(du -h "$dest" | cut -f1))"
  done
}

# ── 실행 ─────────────────────────────────────────────────────────────────────
download_prometheus
download_exporters
[[ "$OS_SEL" == "all" || "$OS_SEL" == "rocky"  ]] && download_grafana_rocky
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && download_grafana_ubuntu
log "완료. build-images.sh 가 packages/monitoring/(관리) 와 packages/exporters/(host) 를 이미지에 내장한다."
log "다음: download-management-packages.sh (grafana 의존성 → mgmt closure) → build-images.sh"
