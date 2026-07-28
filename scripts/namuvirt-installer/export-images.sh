#!/usr/bin/env bash
# ============================================================================
# export-images.sh — 폐쇄망 반입용 고객사 릴리즈 bundle 생성.
#
#   ./export-images.sh --version 1.0.0 --output release/namuvirt-installer-1.0.0
#   ./export-images.sh --version 1.0.0 --os rocky   # Rocky 전용 번들 (host-ubuntu 제외)
#
#   --os all|rocky|ubuntu  번들에 포함할 host 이미지 (기본 all). management 는 항상 포함.
#   --with-os-image        os-images(골든/템플릿 qcow2·ova)를 번들에 포함 (기본은 제외).
#
# ※ os-images(수 GB)는 기본적으로 번들에 넣지 않는다. 매 릴리스 tar 마다 중복되어 용량이
#   과도해지므로 이미지 파일은 별도로 관리·배포한다. images/ 는 빈 디렉터리로 두고, 고객이
#   해당 위치에 이미지를 배치한다. (한 번에 같이 담으려면 --with-os-image)
#
# 수행:
#   1) 이미지 3종을 tar 로 export (docker save)
#   2) 고객사 실행에 필요한 최소 파일 구성 (install-namuvirt.sh, config.sample.yaml,
#      INSTALL-GUIDE.md, scripts/, 빈 images/ ssh/ logs/)
#   3) docker-packages 번들
#   4) manifest.yaml / image-ids.txt / SHA256SUMS 생성
# ============================================================================
set -Eeuo pipefail

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$HARNESS_ROOT"

VERSION="dev"
OUTPUT=""

# 기본: os-images 는 번들에 포함하지 않는다(용량 절감, 이미지는 별도 관리). --with-os-image 로 포함.
INCLUDE_OS_IMAGE="false"
OS_IMAGES_SRC=""                 # 기본: <하네스루트>/os-images

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --os)      OS_FILTER="$2"; shift 2 ;;
    --os-images-src) OS_IMAGES_SRC="$2"; shift 2 ;;
    --with-os-image) INCLUDE_OS_IMAGE="true"; shift ;;
    --no-os-image)   INCLUDE_OS_IMAGE="false"; shift ;;   # 하위호환(기본과 동일)
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
OS_IMAGES_SRC="${OS_IMAGES_SRC:-$HARNESS_ROOT/os-images}"

[[ -n "$OUTPUT" ]] || OUTPUT="release/namuvirt-installer-${VERSION}"
OS_FILTER="${OS_FILTER:-all}"   # all | rocky | ubuntu — 번들에 포함할 host 이미지 선택
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[export] $*"; }
warn() { echo "[export]   WARN $*" >&2; }

# ── 시작/종료 시간·소요 시간 ────────────────────────────────────────────────
_START_EPOCH="$(date +%s)"
log "시작: $(date '+%Y-%m-%d %H:%M:%S')"
_on_exit() {
  local rc=$? end el
  end="$(date +%s)"; el=$((end - _START_EPOCH))
  printf '[export] 종료: %s  소요: %02d:%02d:%02d  (exit=%d)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" $((el/3600)) $(((el%3600)/60)) $((el%60)) "$rc"
}
trap _on_exit EXIT

command -v docker >/dev/null 2>&1 || die "docker 가 필요하다."
case "$OS_FILTER" in all|rocky|ubuntu) ;; *) die "--os 는 all|rocky|ubuntu (입력: $OS_FILTER)";; esac

IMG_MGMT="namuvirt-management-setup:${VERSION}"
IMG_ROCKY="namuvirt-host-setup-rocky:${VERSION}"
IMG_UBUNTU="namuvirt-host-setup-ubuntu:${VERSION}"

# 번들에 포함할 이미지 목록 (management 는 항상 포함)
EXPORT_IMAGES=("$IMG_MGMT")
[[ "$OS_FILTER" == "all" || "$OS_FILTER" == "rocky"  ]] && EXPORT_IMAGES+=("$IMG_ROCKY")
[[ "$OS_FILTER" == "all" || "$OS_FILTER" == "ubuntu" ]] && EXPORT_IMAGES+=("$IMG_UBUNTU")

for t in "${EXPORT_IMAGES[@]}"; do
  docker image inspect "$t" >/dev/null 2>&1 || die "이미지가 없다: $t (먼저 ./build-images.sh --version ${VERSION})"
done

log "출력 디렉터리 준비: $OUTPUT (os=$OS_FILTER)"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"/{image-tar,images,ssh,logs,scripts}

# ── 이미지 export ────────────────────────────────────────────────────────────
log "이미지 export (docker save): ${EXPORT_IMAGES[*]}"
for img in "${EXPORT_IMAGES[@]}"; do
  # namuvirt-management-setup:1.0.0 → namuvirt-management-setup_1.0.0.tar
  tar_name="$(echo "$img" | tr ':' '_').tar"
  docker save -o "$OUTPUT/image-tar/${tar_name}" "$img"
done

# ── 실행 파일 구성 ──────────────────────────────────────────────────────────
log "실행 파일 복사"
cp install-namuvirt.sh "$OUTPUT/"
cp prepare-install.sh   "$OUTPUT/"
cp verify-install.sh    "$OUTPUT/"
cp install-docker.sh    "$OUTPUT/"
cp upload-os-image.sh   "$OUTPUT/"
cp config.sample.yaml   "$OUTPUT/"
cp INSTALL-GUIDE.md     "$OUTPUT/" 2>/dev/null || true
cp UPLOAD-OS-IMAGE.md   "$OUTPUT/" 2>/dev/null || true
cp README.md            "$OUTPUT/" 2>/dev/null || echo "namuVIRT installer ${VERSION}" > "$OUTPUT/README.md"
# 호스트 측 헬퍼 스크립트 (install-namuvirt.sh 가 참조)
cp scripts/detect-host-os.sh scripts/collect-logs.sh scripts/print-summary.sh "$OUTPUT/scripts/"
chmod +x "$OUTPUT/install-namuvirt.sh" "$OUTPUT/prepare-install.sh" "$OUTPUT/verify-install.sh" "$OUTPUT/install-docker.sh" "$OUTPUT/upload-os-image.sh" "$OUTPUT/scripts/"*.sh

# ── Docker 부트스트랩 패키지 번들 (폐쇄망용) ────────────────────────────────
# packages/docker/<os>/ 의 rpm/deb 를 릴리스 docker-packages/<os>/ 로 담는다.
# 고객은 폐쇄망에서 sudo ./install-docker.sh --offline (또는 인자 없이) 로 설치.
# OS_FILTER 에 맞는 것만 담는다(all 이면 둘 다).
_docker_bundled=0
for _os in rocky ubuntu; do
  [[ "$OS_FILTER" == "all" || "$OS_FILTER" == "$_os" ]] || continue
  _src="packages/docker/$_os"
  # rpm/deb 개수를 find 로 센다. (ls "$dir"/*.rpm "$dir"/*.deb 는 한쪽 glob 이 매칭 안 되면
  #  exit!=0 → pipefail+set -e 로 스크립트가 죽어 ubuntu 가 통째로 스킵되던 버그를 피한다.)
  _cnt="$(find "$_src" -maxdepth 1 -type f \( -name '*.rpm' -o -name '*.deb' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$_cnt" -gt 0 ]]; then
    mkdir -p "$OUTPUT/docker-packages/$_os"
    cp -r "$_src"/. "$OUTPUT/docker-packages/$_os/"
    log "docker 패키지 번들: $_os (${_cnt}개)"
    _docker_bundled=$((_docker_bundled+1))
  else
    warn "docker 패키지 없음: $_src — 폐쇄망 대상이면 scripts/download-docker-packages.sh --os $_os 먼저 실행"
  fi
done
[[ $_docker_bundled -eq 0 ]] && warn "docker-packages 번들 없음 — install-docker.sh 는 온라인 설치만 가능"

# ── 관리 VM 골든 OS 이미지 번들 (os-images/bundle.list → images/) ────────────
# os-images/ 에는 게스트 테스트 이미지 등이 섞여 있을 수 있으므로, glob 이 아니라
# bundle.list 화이트리스트에 나열된 파일만 번들 images/ 로 복사한다.
BUNDLE_LIST="$OS_IMAGES_SRC/bundle.list"
if [[ "$INCLUDE_OS_IMAGE" != "true" ]]; then
  log "os-images 번들 생략(기본) — 이미지는 별도 관리. 포함하려면 --with-os-image. images/ 는 빈 채로 둔다."
elif [[ -f "$BUNDLE_LIST" ]]; then
  log "OS 이미지 번들 (bundle.list → images/)"
  _bundled=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"   # 주석/양끝 공백 제거
    [[ -z "$line" ]] && continue
    src="$OS_IMAGES_SRC/$line"
    if [[ -f "$src" ]]; then
      cp "$src" "$OUTPUT/images/"
      log "  bundled: $line ($(du -h "$src" | cut -f1))"
      _bundled=$((_bundled+1))
    else
      warn "bundle.list 항목이 없다: $line ($src)"
    fi
  done < "$BUNDLE_LIST"
  [[ $_bundled -eq 0 ]] && warn "번들된 OS 이미지가 없다 — bundle.list 확인"
else
  warn "os-images/bundle.list 이 없다 — 번들할 OS 이미지가 지정되지 않았다 (images/ 비움). os-images/README.md 참고"
fi

# 빈 mount 디렉터리 placeholder (내용이 없을 때만 .gitkeep)
for d in images ssh logs; do
  if [[ -z "$(ls -A "$OUTPUT/$d" 2>/dev/null)" ]]; then
    cat > "$OUTPUT/$d/.gitkeep" <<EOF
# 이 디렉터리에 외부 mount 파일을 배치한다 ($d/).
EOF
  fi
done

# ── manifest + image-ids (모두 고객 번들 안 — 서버가 여기서 검증한다) ─────────
log "manifest.yaml / image-ids.txt 생성"
REVISION="$(git -C "$HARNESS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
tar_sha() { sha256sum "$1" | awk '{print $1}'; }
{
  echo "version: ${VERSION}"
  echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "revision: ${REVISION}"
  echo "image_tars:"
  for f in "$OUTPUT"/image-tar/*.tar; do
    echo "  - name: $(basename "$f")"
    echo "    sha256: $(tar_sha "$f")"
  done
} > "$OUTPUT/manifest.yaml"

# 이미지 docker Id (반입 후 docker load 결과를 대조하는 용도)
: > "$OUTPUT/image-ids.txt"
for img in "${EXPORT_IMAGES[@]}"; do
  id="$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || echo unknown)"
  echo "${id}  ${img}" >> "$OUTPUT/image-ids.txt"
done

# ── SHA256SUMS ───────────────────────────────────────────────────────────────
log "SHA256SUMS 생성"
( cd "$OUTPUT"
  # bundle 내 배포 대상 파일 전체 (SHA256SUMS 자기 자신 제외)
  find image-tar images docker-packages install-namuvirt.sh prepare-install.sh verify-install.sh install-docker.sh upload-os-image.sh \
       config.sample.yaml INSTALL-GUIDE.md UPLOAD-OS-IMAGE.md README.md manifest.yaml image-ids.txt scripts \
    -type f 2>/dev/null | sort | xargs sha256sum > SHA256SUMS
)

log "완료: $OUTPUT"
log "고객사 반입 후: cd $(basename "$OUTPUT") && sha256sum -c SHA256SUMS && ./install-namuvirt.sh --load-images"
