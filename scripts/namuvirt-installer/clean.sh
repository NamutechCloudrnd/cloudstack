#!/usr/bin/env bash
# ============================================================================
# clean.sh — installer-harness 빌드 산출물 정리 (레이어/소스별 선택 가능).
#
# installer-harness 는 사실상 빌드 워크스페이스라 각 단계 산출물이 쌓인다. 아래 "레이어"를
# 개별 지정하거나 조합해서 지운다. 아무 레이어도 지정하지 않으면 기본 세트(namuvirt 제외 전부).
#
#   레이어(소스)              지우는 대상
#   --host-packages          packages/os-packages 의 KVM Host 그룹 (mgmt 제외)   ← download-host-packages.sh
#   --mgmt-packages          packages/os-packages/rocky/mgmt                     ← download-management-packages.sh
#   --docker-packages        packages/docker                                     ← download-docker-packages.sh
#   --staged                 packages/{monitoring,exporters,vmware-conversion}   ← build-images.sh --packages-src 스테이징
#   --images                 docker 이미지 namuvirt-*-setup                       ← build-images.sh
#   --release                release/                                            ← export-images.sh
#   --namuvirt               packages/namuvirt (제품 rpm/deb, 수동 배치물)
#
# ★ os-images/ (골든/템플릿 qcow2·ova, 수 GB)는 어떤 옵션으로도 삭제하지 않는다.
#
# 사용법:
#   ./clean.sh                        # 기본: namuvirt·os-images 만 빼고 전부
#   ./clean.sh --release              # export-images 결과만
#   ./clean.sh --images               # build-images 결과(도커 이미지)만
#   ./clean.sh --host-packages        # KVM Host 패키지만
#   ./clean.sh --mgmt-packages --docker-packages   # 조합
#   ./clean.sh --all                  # 위 전부 + namuvirt (os-images 만 보존)
#   ./clean.sh --release --dry-run    # 표시만
#   ./clean.sh -y                     # 확인 없이
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

log() { echo "[clean] $*"; }
sz()  { [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"; }
kb2h() { awk -v k="$1" 'BEGIN{ if(k>=1048576) printf "%.1fG",k/1048576; else if(k>=1024) printf "%.0fM",k/1024; else printf "%dK",k }'; }
duk()  { [[ -d "$1" ]] && du -sk "$1" 2>/dev/null | cut -f1 || echo 0; }
# host-packages = os-packages/rocky(mgmt 제외) + os-packages/ubuntu
sz_host() { kb2h $(( $(duk packages/os-packages/rocky) - $(duk packages/os-packages/rocky/mgmt) + $(duk packages/os-packages/ubuntu) )); }

# 레이어 선택 플래그 (bash 3.2 호환 위해 연관배열 대신 개별 변수)
do_release=0; do_images=0; do_host=0; do_mgmt=0; do_docker=0; do_staged=0; do_namuvirt=0
DRY=0; YES=0; ANY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-packages)   do_host=1;   ANY=1; shift ;;
    --mgmt-packages)   do_mgmt=1;   ANY=1; shift ;;
    --docker-packages) do_docker=1; ANY=1; shift ;;
    --staged)          do_staged=1; ANY=1; shift ;;
    --images)          do_images=1; ANY=1; shift ;;
    --release)         do_release=1; ANY=1; shift ;;
    --namuvirt)        do_namuvirt=1; ANY=1; shift ;;
    --all)             do_host=1; do_mgmt=1; do_docker=1; do_staged=1; do_images=1; do_release=1; do_namuvirt=1; ANY=1; shift ;;
    # 하위호환 별칭
    --release-only)    do_release=1; ANY=1; shift ;;
    --images-only)     do_images=1;  ANY=1; shift ;;
    --packages-only)   do_host=1; do_mgmt=1; do_docker=1; do_staged=1; ANY=1; shift ;;
    --dry-run)         DRY=1; shift ;;
    -y|--yes)          YES=1; shift ;;
    -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

# 레이어 미지정 시 기본 세트(namuvirt 제외 전부)
if [[ "$ANY" -eq 0 ]]; then do_host=1; do_mgmt=1; do_docker=1; do_staged=1; do_images=1; do_release=1; fi

IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^namuvirt-.*-setup' || true)"

# ── 대상 요약 ────────────────────────────────────────────────────────────────
echo "── 삭제 대상 ───────────────────────────────────────────────"
[[ "$do_release" -eq 1 ]] && echo "  [release]         release/                         ($(sz release))"
if [[ "$do_images" -eq 1 ]]; then
  if [[ -n "$IMAGES" ]]; then echo "  [images]          docker 이미지:"; echo "$IMAGES" | sed 's/^/                        /'; else echo "  [images]          docker 이미지: (없음)"; fi
fi
[[ "$do_host" -eq 1 ]]     && echo "  [host-packages]   os-packages 그룹(mgmt 제외)       ($(sz_host))"
[[ "$do_mgmt" -eq 1 ]]     && echo "  [mgmt-packages]   os-packages/rocky/mgmt           ($(sz packages/os-packages/rocky/mgmt))"
[[ "$do_docker" -eq 1 ]]   && echo "  [docker-packages] packages/docker                  ($(sz packages/docker))"
[[ "$do_staged" -eq 1 ]]   && echo "  [staged]          packages/{monitoring,exporters,vmware-conversion}"
[[ "$do_namuvirt" -eq 1 ]] && echo "  [namuvirt]        packages/namuvirt                ($(sz packages/namuvirt))"
echo "── 보존 ────────────────────────────────────────────────────"
echo "  os-images/  ($(sz os-images))   ← 절대 삭제 안 함"
[[ "$do_namuvirt" -eq 0 ]] && echo "  packages/namuvirt/  ($(sz packages/namuvirt))   ← --namuvirt/--all 로만 삭제"
echo "────────────────────────────────────────────────────────────"

if [[ "$DRY" -eq 1 ]]; then log "--dry-run: 실제로 삭제하지 않았다."; exit 0; fi
if [[ "$YES" -ne 1 ]]; then
  read -r -p "위 대상을 삭제한다. 진행하려면 'yes' 입력: " ans
  [[ "$ans" == "yes" ]] || { log "취소됨."; exit 0; }
fi

# 이미지 COPY 대상 — 패키지 삭제 후 빈 디렉터리로 재생성해야 다음 build 의 COPY 가 안 깨진다.
ensure_copy_dirs() {
  local d
  for d in packages/os-packages/rocky packages/os-packages/ubuntu \
           packages/namuvirt/rocky packages/namuvirt/ubuntu \
           packages/monitoring packages/exporters packages/vmware-conversion; do
    mkdir -p "$d"
    [[ -z "$(ls -A "$d" 2>/dev/null)" ]] && printf '# clean.sh 가 비운 디렉터리. download-*.sh 또는 build-images.sh --packages-src 로 다시 채운다.\n' > "$d/.gitkeep"
  done
}

# ── 삭제 실행 ────────────────────────────────────────────────────────────────
[[ "$do_release" -eq 1 ]] && { rm -rf release; log "release/ 제거"; }
if [[ "$do_images" -eq 1 && -n "$IMAGES" ]]; then
  echo "$IMAGES" | xargs -r docker rmi -f >/dev/null 2>&1 || true; log "docker 이미지 제거"
fi
if [[ "$do_host" -eq 1 ]]; then
  [[ -d packages/os-packages/rocky ]] && find packages/os-packages/rocky -mindepth 1 -maxdepth 1 -not -name mgmt -exec rm -rf {} +
  rm -rf packages/os-packages/ubuntu
  log "host-packages(os-packages 그룹, mgmt 제외) 제거"
fi
[[ "$do_mgmt" -eq 1 ]]   && { rm -rf packages/os-packages/rocky/mgmt; log "mgmt-packages(os-packages/rocky/mgmt) 제거"; }
[[ "$do_docker" -eq 1 ]] && { rm -rf packages/docker; log "docker-packages 제거"; }
[[ "$do_staged" -eq 1 ]] && { rm -rf packages/monitoring packages/exporters packages/vmware-conversion; log "staged(monitoring/exporters/vmware) 제거"; }
[[ "$do_namuvirt" -eq 1 ]] && { rm -rf packages/namuvirt; log "namuvirt 제거"; }

# 패키지 레이어를 하나라도 건드렸으면 COPY 대상 빈 디렉터리 보장
if [[ $((do_host + do_mgmt + do_docker + do_staged + do_namuvirt)) -gt 0 ]]; then
  ensure_copy_dirs; log "이미지 COPY 대상 빈 디렉터리 보장(.gitkeep)"
fi

log "완료. os-images/ 는 보존됨."
