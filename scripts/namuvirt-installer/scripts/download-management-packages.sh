#!/usr/bin/env bash
# ============================================================================
# download-management-packages.sh — 폐쇄망 설치용 RPM 의존성 closure 다운로드.
#
# 관리 VM(Rocky 8)은 폐쇄망이라 dnf 가 온라인 미러를 못 쓴다. 설치에 필요한
# base + cloudstack + grafana 패키지의 "의존성 전체(closure)"를 rocky:8.10 컨테이너에서
# 미리 받아 packages/os-packages/rocky/mgmt/ 에 넣는다. (이미지 빌드 시 관리 이미지에 내장)
#
#   ./scripts/download-management-packages.sh
#
# 이후 base_packages.yml 이 이 그룹을 disablerepo='*' 로 오프라인 설치한다.
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

IMAGE="${ROCKY_IMAGE:-rockylinux/rockylinux:8.10}"
OUT="packages/os-packages/rocky/mgmt"
CSRPM="packages/namuvirt/rocky"          # cloudstack-*.rpm (의존성만 받는다)
GRPM="packages/monitoring/rocky"         # grafana-*.rpm (의존성만 받는다)

# 관리 VM 이 필요로 하는 top-level 패키지 (Java 17, DB, NFS 클라이언트, 유틸)
TOP_PKGS=(
  java-17-openjdk-headless
  mariadb-server mariadb
  nfs-utils
  chrony
  wget tar bzip2 rsync genisoimage
)

mkdir -p "$OUT"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 필요"; exit 1; }
# 입력 rpm 검증 — 없으면 컨테이너 안에서 glob 이 리터럴로 dnf 에 넘어가 "Can not load RPM file"
# → set -e abort → mgmt 가 조용히 빈 채로 생성되던 버그가 있었다. 여기서 먼저 막는다.
[[ -n "$(ls "$CSRPM"/cloudstack-*.rpm 2>/dev/null)" ]] \
  || { echo "ERROR: $CSRPM 에 cloudstack-*.rpm 없음 (제품 rpm 배치 필요)"; exit 1; }
[[ -n "$(ls "$GRPM"/grafana-*.rpm 2>/dev/null)" ]] \
  || { echo "ERROR: $GRPM 에 grafana-*.rpm 없음 — 'scripts/download-monitoring-packages.sh' 먼저 실행하라"; exit 1; }

echo "[download] rocky:8.10 컨테이너로 의존성 closure 다운로드 → $OUT"
echo "[download] top-level: ${TOP_PKGS[*]} + cloudstack/grafana rpm 의존성"

docker run --rm --platform linux/amd64 \
  -v "$HARNESS_ROOT/$OUT:/out" \
  -v "$HARNESS_ROOT/$CSRPM:/csrpm:ro" \
  -v "$HARNESS_ROOT/$GRPM:/grpm:ro" \
  "$IMAGE" bash -c '
    set -e
    echo "== repo/도구 준비 (powertools/crb + epel + createrepo_c) =="
    dnf -y install dnf-plugins-core createrepo_c >/dev/null 2>&1 || true
    dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
      || dnf config-manager --set-enabled crb   >/dev/null 2>&1 || true
    dnf -y install epel-release >/dev/null 2>&1 || true
    # 위 도구 설치로 캐시에 남은 rpm 을 비운다(closure /out 에 섞이지 않도록).
    dnf clean packages >/dev/null 2>&1 || true
    echo "== 의존성 closure 다운로드 (설치는 안 함) =="
    # grafana 는 버전이 여러 개 남아 있으면 glob 이 전부 넘어가 "cannot install both" 로
    # 실패한다. ansible(monitoring.yml)과 동일하게 최신 버전 하나만 고른다(sort -V | tail -1).
    GRPM_NEWEST="$(ls /grpm/grafana-*.rpm 2>/dev/null | sort -V | tail -1)"
    [ -n "$GRPM_NEWEST" ] || { echo "ERROR: /grpm 에 grafana rpm 이 없다"; exit 1; }
    echo "== grafana rpm 선택: $(basename "$GRPM_NEWEST") =="
    # 로컬 cloudstack/grafana rpm + top-level 패키지의 전체 트랜잭션을 받는다.
    # (로컬 rpm 자체는 안 받고 그 의존성만 받음 → 로컬 rpm 은 packages/ 에 이미 있음)
    dnf install -y --downloadonly --downloaddir=/out --setopt=install_weak_deps=False \
      /csrpm/cloudstack-common-*.rpm /csrpm/cloudstack-management-*.rpm \
      /csrpm/cloudstack-usage-*.rpm /csrpm/cloudstack-ui-*.rpm \
      "$GRPM_NEWEST" \
      '"${TOP_PKGS[*]}"'
    # rocky:8.10 dnf 는 --downloaddir 을 무시하고 rpm 을 /var/cache/dnf 에 두는 경우가 있다.
    # /out 이 비어 있으면 캐시에서 직접 수확한다(closure 유실 방지).
    if [ "$(ls /out/*.rpm 2>/dev/null | wc -l)" -eq 0 ]; then
      echo "== --downloaddir 미반영 → dnf 캐시에서 rpm 수확 =="
      find /var/cache/dnf -name "*.rpm" -exec cp -n {} /out/ \;
    fi
    echo "== repodata 생성 (createrepo_c) — 로컬 offline repo 로 쓰기 위함 =="
    rm -rf /out/repodata
    createrepo_c /out >/dev/null 2>&1 || echo "WARN: createrepo_c 실패 — repodata 없이 진행됨"
    chmod -R a+rX /out
    echo "== 다운로드 완료: $(ls /out/*.rpm 2>/dev/null | wc -l) 개 rpm + repodata =="
  '

echo "[download] 완료. $OUT 파일 수: $(ls "$OUT"/*.rpm 2>/dev/null | wc -l)"
echo "[download] 다음: base_packages.yml 이 mgmt 그룹을 disablerepo='*' 로 오프라인 설치."
