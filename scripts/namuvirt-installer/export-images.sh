#!/usr/bin/env bash
# ============================================================================
# export-images.sh — 폐쇄망 반입용 고객사 릴리즈 bundle 생성.
#
#   ./export-images.sh --version 1.0.0 --output release/namuvirt-installer-1.0.0
#   ./export-images.sh --version 1.0.0 --os rocky   # Rocky 전용 번들 (host-ubuntu 제외)
#
#   --os all|rocky|ubuntu  번들에 포함할 host 이미지 (기본 all). management 는 항상 포함.
#   --with-os-image        os-images(골든/템플릿 qcow2·ova)를 번들에 포함 (기본은 제외).
#   --skip-package-check   제품 패키지 정합성 검증 생략 (권장하지 않음).
#
# ※ os-images(수 GB)는 기본적으로 번들에 넣지 않는다. 매 릴리스 tar 마다 중복되어 용량이
#   과도해지므로 이미지 파일은 별도로 관리·배포한다. images/ 는 빈 디렉터리로 두고, 고객이
#   해당 위치에 이미지를 배치한다. (한 번에 같이 담으려면 --with-os-image)
#
# 수행:
#   0) 제품 패키지(cloudstack-*) 정합성 검증 — 낡은 패키지 반출 차단
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
CHECK_PACKAGES="true"            # 제품 패키지 정합성 검증

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --os)      OS_FILTER="$2"; shift 2 ;;
    --os-images-src) OS_IMAGES_SRC="$2"; shift 2 ;;
    --with-os-image) INCLUDE_OS_IMAGE="true"; shift ;;
    --no-os-image)   INCLUDE_OS_IMAGE="false"; shift ;;   # 하위호환(기본과 동일)
    --skip-package-check) CHECK_PACKAGES="false"; shift ;;
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

# ── 제품 패키지(cloudstack-*) 정합성 검증 ────────────────────────────────────
# BUILD-GUIDE §2.1 대로 cloudstack-*.rpm/deb 는 build/rocky.sh·build/ubuntu.sh 산출물을
# packages/namuvirt/<os>/ 에 "수동 배치"한다. 이 연결이 사람 손에만 의존해서, 교체를 잊으면
# 낡은 제품 패키지가 그대로 다시 포장된다. 실제로 4.22.0.1 이 uefi.properties 없이 반출되어
# UEFI 게스트 이관이 전면 실패한 사례가 있다. 커밋·버전·필수파일 3가지를 대조해 이를 막는다.
#
# 검사 대상:
#   rocky  — 항상. 관리 VM 은 OS 무관하게 항상 Rocky 8 이라 management/ui 가 여기서 나온다.
#   ubuntu — --os all|ubuntu 일 때만. Ubuntu KVM 호스트용 agent.
REPO_ROOT="$(git -C "$HARNESS_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$(cd "$HARNESS_ROOT/../.." && pwd -P)"

# pom.xml 의 제품 버전(4.x.y.z). 파일 첫 <version> 은 maven-parent 라 4.* 패턴으로 고른다.
# -SNAPSHOT 은 package.sh 가 타임스탬프로 치환하므로 비교에서 뗀다.
pom_base_version() {
  [[ -f "$REPO_ROOT/pom.xml" ]] || return 0
  sed -n 's|.*<version>\(4\.[0-9][^<]*\)</version>.*|\1|p' "$REPO_ROOT/pom.xml" \
    | head -1 | sed 's/-SNAPSHOT$//'
}

# 패키지 내부 파일 목록. 빌드 머신 OS 에 따라 rpm/dpkg 도구가 없을 수 있어 순차 폴백한다.
# (Rocky 에서 deb 를, Ubuntu 에서 rpm 을 열어야 하는 경우가 있다.)
#   반환 3 = 열 도구가 없음(검사 생략), 0 = 목록 출력
pkg_list_files() {
  local f="$1"
  case "$f" in
    *.rpm)
      if command -v rpm    >/dev/null 2>&1; then rpm -qlp "$f" 2>/dev/null; return 0; fi
      if command -v bsdtar >/dev/null 2>&1; then bsdtar -tf "$f" 2>/dev/null; return 0; fi
      ;;
    *.deb)
      if command -v dpkg-deb >/dev/null 2>&1; then dpkg-deb -c "$f" 2>/dev/null | awk '{print $NF}'; return 0; fi
      if command -v bsdtar   >/dev/null 2>&1; then bsdtar -tf "$f" 2>/dev/null; return 0; fi
      ;;
  esac
  return 3
}

check_product_packages() {
  local os="$1" ext tool_hint dir="packages/namuvirt/$1"
  case "$os" in
    rocky)  ext="rpm"; tool_hint="rpm 또는 bsdtar" ;;
    ubuntu) ext="deb"; tool_hint="dpkg-deb 또는 bsdtar" ;;
    *) die "알 수 없는 OS: $os" ;;
  esac
  log "제품 패키지 검증: $os ($dir)"

  # 1) 제품 패키지 존재
  local n=0
  [[ -d "$dir" ]] && n="$(find "$dir" -maxdepth 1 -type f -name "cloudstack-*.${ext}" | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] || die "$dir 에 cloudstack-*.${ext} 가 없다.
  build/${os}.sh 산출물을 이 디렉터리에 배치하고 build-images.sh 부터 다시 실행하라."
  log "  패키지 ${n}개"

  # 2) 빌드 커밋 == 현재 저장소 HEAD (낡은 패키지 반출 차단 — 이 검증의 핵심)
  local bi="$dir/BUILD_INFO.txt" pkg_commit head_commit describe
  if [[ -f "$bi" ]]; then
    pkg_commit="$(sed -n 's/^commit=//p' "$bi" | head -1)"
    describe="$(sed -n 's/^describe=//p' "$bi" | head -1)"
    head_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$head_commit" ]]; then
      warn "  git 저장소가 아니라 빌드 커밋 대조 생략"
    elif [[ -z "$pkg_commit" ]]; then
      warn "  BUILD_INFO.txt 에 commit 항목이 없어 대조 생략"
    elif [[ "$pkg_commit" != "$head_commit" ]]; then
      die "$os 제품 패키지가 현재 소스와 다른 커밋에서 빌드됐다.
    패키지 빌드 커밋 : $pkg_commit
    현재 저장소 HEAD : $head_commit
  build/${os}.sh 로 다시 빌드해 $dir 에 배치한 뒤 build-images.sh 부터 다시 실행하라.
  (의도한 것이라면 --skip-package-check)"
    else
      log "  빌드 커밋 일치: ${pkg_commit:0:10}"
    fi
    case "$describe" in
      *-dirty) warn "  커밋되지 않은 변경이 있는 트리에서 빌드됨 (describe=$describe)" ;;
    esac
  else
    warn "  $bi 없음 — 빌드 커밋을 대조할 수 없다"
  fi

  # 3) 패키지 버전 == pom.xml 제품 버전 (4.22 트리로 4.23 패키지가 섞이는 사고 차단)
  local pomv f bad=0
  pomv="$(pom_base_version)"
  if [[ -z "$pomv" ]]; then
    warn "  pom.xml 에서 제품 버전을 읽지 못해 버전 대조 생략"
  else
    while IFS= read -r f; do
      case "$(basename "$f")" in
        *"$pomv"*) ;;
        *) warn "  버전 불일치: $(basename "$f")"; bad=$((bad+1)) ;;
      esac
    done < <(find "$dir" -maxdepth 1 -type f -name "cloudstack-*.${ext}" | sort)
    [[ "$bad" -eq 0 ]] || die "$os 제품 패키지 ${bad}개의 버전이 pom.xml($pomv)과 다르다.
  빌드 트리와 배치된 패키지가 어긋났다. (우회: --skip-package-check)"
    log "  버전 일치: $pomv"
  fi

  # 4) cloudstack-agent 에 uefi.properties 포함
  #    없으면 UEFI 게스트가 OVMF loader 없이 Q35+SeaBIOS 로 정의되어 부팅에 실패한다.
  local agent listing rc=0
  agent="$(find "$dir" -maxdepth 1 -type f -name "cloudstack-agent[-_]*.${ext}" | sort | tail -1)"
  if [[ -z "$agent" ]]; then
    warn "  cloudstack-agent 패키지가 없어 uefi.properties 검사 생략"
    return 0
  fi
  listing="$(pkg_list_files "$agent")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    warn "  $tool_hint 이 없어 uefi.properties 검사 생략 ($(basename "$agent"))"
  elif printf '%s\n' "$listing" | grep -q 'etc/cloudstack/agent/uefi\.properties'; then
    log "  uefi.properties 포함 확인"
  else
    die "$(basename "$agent") 에 /etc/cloudstack/agent/uefi.properties 가 없다.
  이 파일이 없으면 UEFI 게스트가 OVMF 없이 정의되어 부팅에 실패한다(4.22.0.1 반출 사고).
  해당 패키징이 포함된 소스로 다시 빌드하라. (우회: --skip-package-check)"
  fi
}

if [[ "$CHECK_PACKAGES" == "true" ]]; then
  check_product_packages rocky      # 관리 VM 은 항상 Rocky 8
  if [[ "$OS_FILTER" == "all" || "$OS_FILTER" == "ubuntu" ]]; then
    check_product_packages ubuntu
  fi
else
  warn "제품 패키지 검증 생략(--skip-package-check) — 낡은 cloudstack 패키지가 번들에 들어갈 수 있다"
fi

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
