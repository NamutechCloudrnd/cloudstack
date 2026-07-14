#!/usr/bin/env bash
# ============================================================================
# build-images.sh — 설치 컨테이너 이미지 3종 빌드 (개발/릴리즈 환경, 온라인).
#
#   ./build-images.sh --version 1.0.0 [--revision <git-sha>] [--packages-src <dir>]
#                     [--prune-cache | --no-prune] [--platform linux/amd64]
#
#   --prune-cache : 빌드 전 빌드캐시(docker builder prune) 정리 후 진행
#   --no-prune    : 정리 없이 그대로 진행
#   (둘 다 없으면 사용량을 보여주고 지울지 물어본다 — 비대화형이면 유지하고 진행)
#
# 수행:
#   1) 패키지 소스 디렉터리 검증 (없으면 경고)
#   2) (선택) --packages-src 로 지정한 디렉터리에서 packages/ 로 스테이징
#   3) Dockerfile 3종 빌드 (OCI label 주입)
#   4) 이미지 smoke test (ansible syntax-check)
#   5) (manifest/checksum/image-ids 는 export-images.sh 가 고객 번들 안에 생성한다)
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

VERSION="dev"
REVISION="$(git -C "$HARNESS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
PACKAGES_SRC=""
# 타깃 KVM 호스트는 항상 x86_64 이므로 설치 컨테이너도 linux/amd64 로 빌드한다.
# (Apple Silicon 등 arm 개발 머신에서 빌드하면 buildx+qemu 로 amd64 크로스 빌드가 필요하다.)
PLATFORM="linux/amd64"
PRUNE_MODE="ask"                 # ask | yes | no — 빌드 전 빌드캐시 정리 여부

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      VERSION="$2"; shift 2 ;;
    --revision)     REVISION="$2"; shift 2 ;;
    --packages-src) PACKAGES_SRC="$2"; shift 2 ;;
    --platform)     PLATFORM="$2"; shift 2 ;;
    --prune-cache)  PRUNE_MODE="yes"; shift ;;
    --no-prune)     PRUNE_MODE="no";  shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[build] $*"; }
ok()   { echo "[build]   OK $*"; }
warn() { echo "[build]   WARN $*"; }

# ── 시작/종료 시간·소요 시간 ────────────────────────────────────────────────
# EXIT trap 으로 성공/실패 어느 경로로 끝나도 종료 시각과 소요 시간을 출력한다.
_START_EPOCH="$(date +%s)"
log "시작: $(date '+%Y-%m-%d %H:%M:%S')"
_on_exit() {
  local rc=$? end el
  end="$(date +%s)"; el=$((end - _START_EPOCH))
  printf '[build] 종료: %s  소요: %02d:%02d:%02d  (exit=%d)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" $((el/3600)) $(((el%3600)/60)) $((el%60)) "$rc"
}
trap _on_exit EXIT

command -v docker >/dev/null 2>&1 || die "docker 가 필요하다."

# ── 빌드 전 Docker 디스크 점검 + 캐시 정리 선택 ──────────────────────────────
# macOS Docker 는 고정 크기 VM 디스크를 쓰므로 빌드캐시가 쌓이면 빌드 중 apt 가
# "no space" 로 실패할 수 있다. 빌드 전에 사용량을 보여주고 정리 여부를 정한다.
#   --prune-cache : 무조건 정리   --no-prune : 정리 안 함   (기본: 대화형 질문)
precheck_cache() {
  log "Docker 디스크 사용량:"
  docker system df 2>/dev/null | sed 's/^/    /' || true
  case "$PRUNE_MODE" in
    yes)
      log "빌드 캐시 정리 (docker builder prune -f)"
      docker builder prune -f >/dev/null 2>&1 && ok "빌드 캐시 정리 완료" || warn "빌드 캐시 정리 실패(무시)"
      ;;
    no)
      log "캐시 정리 없이 진행 (--no-prune)"
      ;;
    ask)
      if [[ -t 0 ]]; then
        local ans=""
        read -r -p "[build]   빌드 캐시를 지우고 진행할까요? [y/N]: " ans </dev/tty || true
        if [[ "$ans" =~ ^[Yy] ]]; then
          docker builder prune -f >/dev/null 2>&1 && ok "빌드 캐시 정리 완료" || warn "빌드 캐시 정리 실패(무시)"
        else
          log "캐시 유지하고 진행"
        fi
      else
        warn "비대화형 실행 — 캐시 유지하고 진행 (정리하려면 --prune-cache)"
      fi
      ;;
  esac
}
precheck_cache

# ── 패키지 스테이징 ─────────────────────────────────────────────────────────
# 소스별 담당:
#   os-packages       ← download-host-packages.sh / download-management-packages.sh (여기서 스테이징하지 않음!)
#   docker            ← download-docker-packages.sh
#   monitoring/exporters/vmware-conversion ← 소스 디렉터리(sample)에서 스테이징
#   namuvirt          ← packages/namuvirt/ 에 직접 배치(하네스)
# ★ os-packages 를 sample 에서 다시 스테이징하면 download-host-packages 로 받은 깨끗한
#   버전 위에 sample 의 구버전이 섞여 "cannot install both" 가 난다. 그래서 스테이징 대상에서 뺀다.
#   --packages-src 미지정 시 기본 소스(개발 머신의 sample packages)를 사용한다.
DEFAULT_PACKAGES_SRC="/Users/geontae/workspaces/sample/namuVIRT-work/ansible/packages"
[[ -z "$PACKAGES_SRC" && -d "$DEFAULT_PACKAGES_SRC" ]] && PACKAGES_SRC="$DEFAULT_PACKAGES_SRC"

if [[ -n "$PACKAGES_SRC" ]]; then
  [[ -d "$PACKAGES_SRC" ]] || die "패키지 소스 디렉터리가 없다: $PACKAGES_SRC"
  log "패키지 스테이징: $PACKAGES_SRC → packages/ (os-packages·namuvirt 제외)"
  # os-packages 는 download-host-packages.sh 담당이라 스테이징하지 않는다. namuvirt 도 제외(직접 배치).
  for sub in monitoring exporters vmware-conversion; do
    [[ -d "$PACKAGES_SRC/$sub" ]] || continue
    mkdir -p "packages/$sub"
    cp -R "$PACKAGES_SRC/$sub/." "packages/$sub/"
    log "  staged: $sub"
  done
  # ※ 이름 중복 제거(dedupe-os-packages.sh → _base 공용 풀)는 더 이상 하지 않는다.
  #   각 그룹이 자기 closure 를 그대로 보유한다(java/utils 등이 비지 않음).
  # ※ 버전 중복 제거(dedupe-versions.sh)도 컨테이너를 띄워 느리므로 빌드에서 하지 않는다.
  #   패키지 준비 단계(download-*.sh)에서 처리하고, 빌드는 아래 "패키지 소스 검증"에서
  #   버전 중복이 남아있으면 빠르게 감지만 한다.
  :
else
  log "패키지 소스 미지정 — packages/ 에 이미 배치된 파일만 사용한다."
fi

# ── 버전 중복 감지 (컨테이너 없이 파일명만으로 빠르게) ───────────────────────
# 같은 패키지의 서로 다른 버전이 남아 있으면 설치 시 dnf/dpkg 가 "cannot install both" 로
# 실패한다. 여기서 감지되면 빌드를 멈추고 dedupe-versions.sh 를 안내한다.
#   판정: 파일명 중복(동일 파일)을 sort -u 로 접은 뒤, 패키지명이 같은데 파일이 2개 이상 → 버전 중복.
# $1=디렉터리 $2=확장자(rpm|deb). 파일명을 NAME.ARCH 로 정규화해, 같은 NAME.ARCH 가 서로
# 다른 버전 파일로 2개 이상이면 "버전 중복"으로 본다. (arch 를 포함해야 multilib(x86_64/i686)
# 오탐을 피한다. mgmt/ 는 관리 VM 별개 경로라 제외.)
detect_version_dupes() {
  local osdir="$1" ext="$2" dupes
  [[ -d "$osdir" ]] || return 0
  dupes="$(find "$osdir" -path '*/mgmt/*' -prune -o -name "*.$ext" -print 2>/dev/null \
    | sed 's#.*/##' | grep -v '^$' | sort -u \
    | awk -v ext="$ext" '{
        f=$0; arch=f; name=f
        sub("\\." ext "$","",arch)                          # 확장자 제거
        if (ext=="rpm") { sub(/.*\./,"",arch); sub(/-[0-9].*/,"",name) }  # rpm: name-ver-rel.ARCH
        else            { sub(/.*_/,"",arch); sub(/_.*/,"",name) }        # deb: name_ver_ARCH
        print name"."arch
      }' | sort | uniq -d)"
  if [[ -n "$dupes" ]]; then
    warn "os-packages($osdir)에 같은 패키지의 여러 버전이 있다 (NAME.ARCH):"
    echo "$dupes" | sed 's/^/      /' >&2
    die "버전 중복 → './scripts/dedupe-versions.sh' 로 정리 후 다시 빌드하라 (설치 시 'cannot install both' 방지)."
  fi
}
detect_version_dupes packages/os-packages/rocky  rpm
detect_version_dupes packages/os-packages/ubuntu deb

# ── 패키지 소스 검증 ────────────────────────────────────────────────────────
log "패키지 소스 검증"
warn_missing() { echo "  WARN: $1 에 파일이 없다 (빌드는 계속, 설치 시 skip/경고)"; }
count_files() { find "$1" -type f ! -name '.gitkeep' ! -name 'README*' 2>/dev/null | wc -l | tr -d ' '; }
for d in \
  packages/namuvirt/rocky packages/namuvirt/ubuntu \
  packages/os-packages/rocky packages/os-packages/ubuntu \
  packages/monitoring/common packages/exporters ; do
  n="$(count_files "$d")"
  if [[ "$n" -gt 0 ]]; then echo "  OK  $d ($n 파일)"; else warn_missing "$d"; fi
done

# ── 이미지 빌드 ──────────────────────────────────────────────────────────────
build_one() {
  local name="$1" dockerfile="$2"
  local tag="${name}:${VERSION}"
  log "빌드: $tag (platform=$PLATFORM)"
  docker build \
    --platform "$PLATFORM" \
    --build-arg "VERSION=${VERSION}" \
    --build-arg "CREATED=${CREATED}" \
    --build-arg "REVISION=${REVISION}" \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.created=${CREATED}" \
    --label "org.opencontainers.image.revision=${REVISION}" \
    -f "$dockerfile" -t "$tag" "$HARNESS_ROOT"
}

# 관리 이미지는 mgmt 오프라인 closure(java-17/mariadb + repodata)를 반드시 내장해야 한다.
# mgmt/ 는 build 산출물이 아니라 download-management-packages.sh 로 미리 채워야 하는 "입력"이며,
# 과거 bind-mount 등으로 비워진 채 빌드되어 빈 이미지가 출하된 사례가 있어 여기서 강제 검증한다.
# 비어 있으면(=repodata 없거나 rpm 부족) 빌드를 막아, 설치 단계의 조기-실패로 넘어가지 않게 한다.
_mgmt_dir="packages/os-packages/rocky/mgmt"
_mgmt_rpms="$(find "$_mgmt_dir" -name '*.rpm' 2>/dev/null | wc -l | tr -d ' ')"
if [[ ! -f "$_mgmt_dir/repodata/repomd.xml" || "$_mgmt_rpms" -lt 50 ]]; then
  die "관리 이미지 mgmt closure 가 비어있음/부족 ($_mgmt_dir: rpm=${_mgmt_rpms}, repodata=$([[ -f "$_mgmt_dir/repodata/repomd.xml" ]] && echo 있음 || echo 없음)).
  → './scripts/download-management-packages.sh' 로 mgmt closure(+repodata)를 먼저 생성한 뒤 다시 빌드하라.
    (빈 mgmt 로 관리 이미지를 만들면 설치 시 java-17/mariadb 오프라인 설치가 불가하다.)"
fi

build_one namuvirt-management-setup   docker/management/Dockerfile
build_one namuvirt-host-setup-rocky   docker/host-rocky/Dockerfile
build_one namuvirt-host-setup-ubuntu  docker/host-ubuntu/Dockerfile

# ── smoke test (ansible syntax-check) ───────────────────────────────────────
log "smoke test: ansible syntax-check"
smoke() {
  local tag="$1"
  docker run --rm --platform "$PLATFORM" "$tag" /opt/namuvirt-installer/scripts/run-ansible.sh --syntax-check \
    >/dev/null 2>&1 && echo "  OK  $tag syntax-check" \
    || die "$tag syntax-check 실패"
}
smoke "namuvirt-management-setup:${VERSION}"
smoke "namuvirt-host-setup-rocky:${VERSION}"
smoke "namuvirt-host-setup-ubuntu:${VERSION}"

# manifest / checksum / image-ids 는 export-images.sh 가 고객 번들
# (release/namuvirt-installer-<version>/) 안에 생성한다 — 서버가 그 안에서 검증하기 때문.
# build 단계에서는 별도 manifest 를 만들지 않는다(중복/혼란 방지).

log "완료. 이미지 3종 빌드/검증 성공 (version ${VERSION})."
log "다음 단계: ./export-images.sh --version ${VERSION} --output release/namuvirt-installer-${VERSION}"
