#!/usr/bin/env bash
# ============================================================================
# dedupe-versions.sh — os-packages 에서 같은 패키지의 "구버전" rpm/deb 를 제거한다.
#
# 여러 소스(sample --packages-src, download-host-packages.sh 등)를 섞으면 동일 패키지가
# el8 / el8_10.x 처럼 서로 다른 버전으로 중복 적재될 수 있다. tar-once flatten 은 파일명
# 기준 dedup 이라 버전이 다르면 둘 다 남고, 설치 시 dnf 가
#   "cannot install both X-v1 and X-v2 ... conflicting requests"
# 로 실패한다. 이 스크립트는 패키지별 "최신 버전 1개"만 남기고 구버전을 삭제한다.
#
#   ./scripts/dedupe-versions.sh              # rocky + ubuntu
#   ./scripts/dedupe-versions.sh --os rocky   # 하나만
#
# rocky: rocky:8.10 컨테이너의 repomanage(dnf-utils) 로 판정.
# ubuntu: ubuntu:24.04 컨테이너의 dpkg --compare-versions 로 판정.
# mgmt/(관리 VM offline repo, repodata 포함)는 손대지 않는다.
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
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 필요"; exit 1; }
ROCKY_IMAGE="${ROCKY_IMAGE:-rockylinux/rockylinux:8.10}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
log() { echo "[dedupe-ver] $*"; }

dedupe_rocky() {
  local dir="packages/os-packages/rocky"
  [[ -d "$dir" ]] || { log "없음: $dir"; return 0; }
  local before after
  before="$(find "$dir" -name '*.rpm' | wc -l | tr -d ' ')"
  log "Rocky 버전 중복 제거 (repomanage, mgmt 제외) — 대상 $before rpm"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$dir:/pkgs" "$ROCKY_IMAGE" bash -c '
    set -e
    dnf install -y --quiet dnf-utils >/dev/null 2>&1 || true
    # mgmt/(관리 VM 전용 offline repo)는 자기 closure/repodata 를 온전히 보유해야 하므로
    # dedupe 대상에서 "완전히" 제외한다 — 키퍼 판정 입력에서도 빼야 한다.
    #   (과거엔 repomanage /pkgs 전체를 넣고 출력만 grep -v /mgmt/ 로 걸렀는데, 그러면
    #    mgmt 사본이 최신 키퍼로 뽑힐 때 group 쪽 사본이 "old" 로 찍혀 삭제되는 버그가 있었다.)
    # group 디렉터리들만 repomanage 에 넘긴다(그룹 간 버전 중복만 정리).
    dirs=(); for d in /pkgs/*/; do [ "$(basename "$d")" = mgmt ] && continue; dirs+=("$d"); done
    [ ${#dirs[@]} -eq 0 ] && exit 0
    repomanage --old --keep 1 "${dirs[@]}" 2>/dev/null | while read -r f; do
      [ -n "$f" ] && rm -f "$f" && echo "  removed $(basename "$f")"
    done
  '
  after="$(find "$dir" -name '*.rpm' | wc -l | tr -d ' ')"
  log "Rocky 완료: $before → $after rpm (제거 $((before-after))개)"
}

dedupe_ubuntu() {
  local dir="packages/os-packages/ubuntu"
  [[ -d "$dir" ]] || { log "없음: $dir"; return 0; }
  local before after
  before="$(find "$dir" -name '*.deb' | wc -l | tr -d ' ')"
  log "Ubuntu 버전 중복 제거 (dpkg --compare-versions) — 대상 $before deb"
  docker run --rm --platform linux/amd64 -v "$HARNESS_ROOT/$dir:/pkgs" "$UBUNTU_IMAGE" bash -c '
    set -e
    declare -A best
    while IFS= read -r f; do
      case "$f" in */mgmt/*) continue ;; esac
      pkg="$(dpkg-deb -f "$f" Package 2>/dev/null)"; ver="$(dpkg-deb -f "$f" Version 2>/dev/null)"
      [ -z "$pkg" ] && continue
      if [ -z "${best[$pkg]:-}" ]; then
        best[$pkg]="$ver|$f"
      else
        bver="${best[$pkg]%%|*}"; bfile="${best[$pkg]#*|}"
        if dpkg --compare-versions "$ver" gt "$bver"; then
          rm -f "$bfile"; echo "  removed $(basename "$bfile")"; best[$pkg]="$ver|$f"
        else
          rm -f "$f"; echo "  removed $(basename "$f")"
        fi
      fi
    done < <(find /pkgs -name "*.deb" | sort)
  '
  after="$(find "$dir" -name '*.deb' | wc -l | tr -d ' ')"
  log "Ubuntu 완료: $before → $after deb (제거 $((before-after))개)"
}

[[ "$OS_SEL" == "all" || "$OS_SEL" == "rocky"  ]] && dedupe_rocky
[[ "$OS_SEL" == "all" || "$OS_SEL" == "ubuntu" ]] && dedupe_ubuntu
log "완료. (이후 build-images.sh 로 재빌드하면 단일 버전만 내장됨)"
