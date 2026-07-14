#!/usr/bin/env bash
# ============================================================================
# install-namuvirt.sh — namuVIRT 설치 단일 엔트리포인트 (고객사 실행).
#
#   cd namuvirt-installer
#   vi config.yaml
#   ./install-namuvirt.sh --load-images   # 폐쇄망: image-tar/*.tar 적재
#   ./install-namuvirt.sh --preflight
#   ./install-namuvirt.sh install
#
# 설치 로직은 전부 설치 컨테이너 이미지 안의 Ansible playbook 이 수행한다.
# 이 스크립트는 호스트 측에서 로컬 검증 + 컨테이너 오케스트레이션만 담당한다.
# ============================================================================
set -Eeuo pipefail

# ── 경로/버전 ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"

CONFIG_FILE="$SCRIPT_DIR/config.yaml"
SSH_DIR="$SCRIPT_DIR/ssh"
IMAGES_DIR="$SCRIPT_DIR/images"
LOGS_DIR="$SCRIPT_DIR/logs"
IMAGE_TAR_DIR="$SCRIPT_DIR/image-tar"
MANIFEST="$SCRIPT_DIR/manifest.yaml"
IMAGE_IDS="$SCRIPT_DIR/image-ids.txt"   # export 가 기록한 "이미지 docker Id  태그" (해시 비교용)
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS_DIR"
INSTALL_LOG="$LOGS_DIR/install-$TS.log"
PREFLIGHT_LOG="$LOGS_DIR/preflight-$TS.log"

# 버전: env > manifest.yaml > 기본값
VERSION="${NAMUVIRT_VERSION:-}"
if [[ -z "$VERSION" && -f "$MANIFEST" ]]; then
  VERSION="$(awk -F'[:[:space:]]+' '/^version:/{print $2; exit}' "$MANIFEST" 2>/dev/null || true)"
fi
VERSION="${VERSION:-1.0.0}"

IMG_MGMT="namuvirt-management-setup:$VERSION"
IMG_HOST_ROCKY="namuvirt-host-setup-rocky:$VERSION"
IMG_HOST_UBUNTU="namuvirt-host-setup-ubuntu:$VERSION"

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────────
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "  ${c_grn}OK${c_rst}   $*"; }
warn() { echo "  ${c_yel}WARN${c_rst} $*"; }
die()  { echo "${c_red}ERROR${c_rst} $*" >&2; exit 1; }

usage() {
  cat <<EOF
namuVIRT 설치 하네스 (version $VERSION)

사용법: ./install-namuvirt.sh <command>

Commands:
  --help              이 도움말
  --load-images       image-tar/*.tar 를 docker load (폐쇄망 반입)
  --preflight         설치 전 로컬+원격 검증만 수행 (mutation 없음)
  install             전체 설치 (KVM Hosts → Management)
  --tags <tag>        단계별 실행: kvm_hosts | management | monitoring | storage | agent
  collect-logs        logs/ 를 tar.gz 로 수집

옵션:
  -K, --ask-become-pass   sudo(become) 비밀번호를 입력받아 사용한다.
                          KVM Host 계정에 NOPASSWD sudo 가 없을 때 사용
                          (예: ./install-namuvirt.sh -K install).
                          NOPASSWD 가 설정돼 있으면 불필요.

외부 mount (현재 디렉터리 기준):
  config.yaml, ssh/, images/, logs/
EOF
}

# ── 로컬 런타임 검증 ────────────────────────────────────────────────────────
validate_local_runtime() {
  log "로컬 런타임 검증"
  command -v docker >/dev/null 2>&1 || die "Docker 가 설치되어 있지 않다. (sudo ./install-docker.sh)"
  if ! docker info >/dev/null 2>&1; then
    # 데몬 다운과 권한 부족(docker 그룹 미소속)을 구분해 안내한다.
    if docker info 2>&1 | grep -qiE 'permission denied|dial unix.*connect: permission'; then
      die "현재 계정($(id -un))이 docker 소켓에 접근할 수 없다 (docker 그룹 미소속).
  → sudo usermod -aG docker $(id -un) 후 로그아웃/로그인(또는 'newgrp docker') 하고 재실행.
  (또는 이 스크립트를 sudo 로 실행하거나, sudo ./install-docker.sh --user $(id -un) 로 그룹 추가)"
    else
      die "Docker Engine 이 실행 중이 아니다 (docker info 실패). 'sudo systemctl start docker' 확인."
    fi
  fi
  ok "Docker Engine 실행 중"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin 이 없다 (docker compose version 실패)."
  ok "Docker Compose plugin 존재"
}

# ── 이미지 적재/존재 ────────────────────────────────────────────────────────
load_images() {
  # force="force" 면 이미 있어도 재적재. 그 외에는 이미 로드된 이미지는 skip 한다.
  # (매 실행마다 GB tar 를 재적재하면 느리고, 이미지에 가한 로컬 수정도 덮어써진다.)
  local force="${1:-}"
  log "설치 컨테이너 이미지 적재 (image-tar/)"
  if [[ ! -d "$IMAGE_TAR_DIR" ]]; then
    warn "image-tar/ 디렉터리가 없다 — 이미 로컬에 이미지가 있다고 가정한다."
    return 0
  fi
  shopt -s nullglob
  local tars=("$IMAGE_TAR_DIR"/*.tar)
  shopt -u nullglob
  [[ ${#tars[@]} -eq 0 ]] && { warn "image-tar/ 에 .tar 파일이 없다 — 적재 skip."; return 0; }

  # 재적재 판정은 "tar 파일 내용(sha256)"으로 한다. manifest.yaml 이 export 시 각 tar 의 sha256 을
  # 기록해 두므로 그걸 쓴다. 로드된 도커 이미지의 .Id 는 크로스플랫폼(arm64에서 amd64 빌드)·
  # containerd store 에서 표현이 달라 매번 불일치로 오탐하므로 사용하지 않는다.
  # 마지막으로 적재한 tar 의 sha256 을 .image-state/ 에 기록하고, 번들 manifest 의 sha256 과 비교한다.
  local state_dir="$SCRIPT_DIR/.image-state"
  mkdir -p "$state_dir" 2>/dev/null || true

  for t in "${tars[@]}"; do
    # tar 파일명 → 이미지 태그: namuvirt-management-setup_1.0.0.tar → namuvirt-management-setup:1.0.0
    local base tag tar_name bundle_sha loaded_sha
    base="$(basename "$t" .tar)"
    tag="${base%_*}:${base##*_}"
    tar_name="$(basename "$t")"
    bundle_sha="$(awk -v n="$tar_name" '/name:/ && index($0,n){f=1;next} f && /sha256:/{print $NF; exit}' "$MANIFEST" 2>/dev/null || true)"
    loaded_sha="$(cat "$state_dir/$tar_name.sha" 2>/dev/null || true)"

    if [[ "$force" != "force" ]] && docker image inspect "$tag" >/dev/null 2>&1; then
      if [[ -z "$bundle_sha" ]]; then
        ok "이미 로드됨 — 재적재 skip: $tag (manifest sha 없음)"
        continue
      elif [[ "$bundle_sha" == "$loaded_sha" ]]; then
        ok "이미 로드됨(번들 tar 동일) — 재적재 skip: $tag"
        continue
      else
        log "번들 tar 가 갱신됨(sha 불일치) → 재적재: $tag"
      fi
    fi

    log "docker load < $tar_name"
    if docker load -i "$t" >/dev/null; then
      ok "적재: $tar_name"
      [[ -n "$bundle_sha" ]] && printf '%s' "$bundle_sha" > "$state_dir/$tar_name.sha" 2>/dev/null || true
    fi
  done
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

ensure_host_image() {
  local os="$1" img
  case "$os" in
    rocky)  img="$IMG_HOST_ROCKY" ;;
    ubuntu) img="$IMG_HOST_UBUNTU" ;;
    *) die "지원하지 않는 kvm.os: $os" ;;
  esac
  image_exists "$img" || die "설치 이미지가 없다: $img — './install-namuvirt.sh --load-images' 실행 또는 build 확인."
  echo "$img"
}

ensure_mgmt_image() {
  image_exists "$IMG_MGMT" || die "설치 이미지가 없다: $IMG_MGMT — './install-namuvirt.sh --load-images' 실행 또는 build 확인."
  echo "$IMG_MGMT"
}

# ── 로컬 파일 검증 ──────────────────────────────────────────────────────────
validate_local_files() {
  log "외부 mount 파일 검증 (호스트 측)"
  [[ -f "$CONFIG_FILE" ]] || die "config.yaml 이 없다: $CONFIG_FILE (config.sample.yaml 참고)."
  ok "config.yaml 존재"

  # kvm.os 파싱 (이미지 선택 + 스키마 1차 확인)
  CLUSTER_OS="$(bash "$SCRIPTS_DIR/detect-host-os.sh" "$CONFIG_FILE")" \
    || die "config.yaml 의 kvm.os 를 읽지 못했다 (rocky/ubuntu)."
  ok "kvm.os = $CLUSTER_OS"

  # SSH key
  local ssh_key
  ssh_key="$(config_get ssh_private_key_path)"
  ssh_key="${ssh_key:-/mnt/namuvirt/ssh/id_ed25519}"
  # 컨테이너 내부 경로 → 호스트 경로 매핑 (/mnt/namuvirt/ssh → ./ssh)
  local host_ssh_key="${ssh_key/#\/mnt\/namuvirt\/ssh/$SSH_DIR}"
  if [[ -f "$host_ssh_key" ]]; then
    local perm; perm=$(stat -c '%a' "$host_ssh_key" 2>/dev/null || stat -f '%Lp' "$host_ssh_key")
    ok "SSH private key 존재 ($host_ssh_key, perm $perm)"
    case "$perm" in 600|400) ;; *) warn "SSH key 권한이 느슨하다($perm) — chmod 600 권장" ;; esac
  else
    die "SSH private key 가 없다: $host_ssh_key (ssh/id_ed25519 배치 확인)."
  fi

  # cloud image + systemvm template (컨테이너 경로 → images/ 매핑)
  local cimg simg
  cimg="$(config_get management.rocky_cloudimg)"; cimg="${cimg:-/mnt/namuvirt/images/NAMU-Rocky-8-10.qcow2}"
  simg="$(config_get management.systemvm_template)"; simg="${simg:-/mnt/namuvirt/images/SystemVM-Template-KVM.qcow2}"
  local h_cimg="${cimg/#\/mnt\/namuvirt\/images/$IMAGES_DIR}"
  local h_simg="${simg/#\/mnt\/namuvirt\/images/$IMAGES_DIR}"
  [[ -f "$h_cimg" ]] && ok "Rocky cloud image 존재 ($(basename "$h_cimg"))" || die "Rocky cloud image 가 없다: $h_cimg"
  [[ -f "$h_simg" ]] && ok "SystemVM template 존재 ($(basename "$h_simg"))" || die "SystemVM template 가 없다: $h_simg"

  # logs 쓰기 가능
  ( : > "$LOGS_DIR/.wtest.$$" ) 2>/dev/null && { rm -f "$LOGS_DIR/.wtest.$$"; ok "logs 쓰기 가능"; } \
    || die "logs 디렉터리에 쓸 수 없다: $LOGS_DIR"
}

# config.yaml 에서 점 표기 key 조회 (python3+yaml 우선, 없으면 빈값)
config_get() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$key" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
cur = cfg
for part in sys.argv[2].split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = ""; break
print(cur if cur is not None else "")
PY
  else
    # python3 미설치(폐쇄망 KVM 호스트) 폴백: dotted key 의 leaf 를 awk 로 추출.
    # 우리 config 포맷에서 leaf 키(ssh_private_key_path/rocky_cloudimg/systemvm_template)는 유일.
    local leaf="${key##*.}"
    awk -v k="$leaf" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, ""); sub(/[[:space:]]*$/, "");
        gsub(/^["'\'']|["'\'']$/, ""); print; exit
      }' "$CONFIG_FILE" 2>/dev/null
  fi
}

# ── 컨테이너 실행 ────────────────────────────────────────────────────────────
run_container() {
  # $1=image  나머지=run-ansible.sh 인자
  local image="$1"; shift
  # sudo NOPASSWD 가 없을 때(-K) 받은 비밀번호를 env 로 전달한다.
  # `-e NAME`(값 없이 이름만)은 값을 argv 에 노출하지 않고 현재 환경에서 가져간다.
  local env_args=()
  [[ -n "${NAMUVIRT_BECOME_PASS:-}" ]] && env_args+=(-e NAMUVIRT_BECOME_PASS)
  docker run --rm \
    --name "namuvirt-installer-$TS-$$" \
    --network host \
    "${env_args[@]}" \
    -v "$CONFIG_FILE:/mnt/namuvirt/config.yaml:ro" \
    -v "$SSH_DIR:/mnt/namuvirt/ssh:ro" \
    -v "$IMAGES_DIR:/mnt/namuvirt/images:ro" \
    -v "$LOGS_DIR:/mnt/namuvirt/logs" \
    "$image" \
    /opt/namuvirt-installer/scripts/run-ansible.sh "$@"
}

# ── 커맨드 ───────────────────────────────────────────────────────────────────
cmd_preflight() {
  validate_local_runtime
  validate_local_files
  load_images
  local host_img; host_img="$(ensure_host_image "$CLUSTER_OS")"
  log "원격 preflight 실행 (이미지: $host_img)"
  run_container "$host_img" --preflight 2>&1 | tee "$PREFLIGHT_LOG"
  local rc="${PIPESTATUS[0]}"
  [[ "$rc" -eq 0 ]] || die "preflight 실패 — $PREFLIGHT_LOG 확인. 설치를 진행하지 않는다."
  ok "preflight 통과 — 로그: $PREFLIGHT_LOG"
}

cmd_install() {
  validate_local_runtime
  validate_local_files
  load_images
  local host_img mgmt_img
  host_img="$(ensure_host_image "$CLUSTER_OS")"
  mgmt_img="$(ensure_mgmt_image)"

  local status="failed"
  {
    log "1/4 원격 preflight"
    run_container "$host_img" --preflight

    log "2/4 KVM Host 설치 (kvm.master 포함, 이미지: $host_img)"
    run_container "$host_img" --tags kvm_hosts

    log "3/4 Management 설치 (이미지: $mgmt_img)"
    run_container "$mgmt_img" --tags management

    status="success"
  } 2>&1 | tee "$INSTALL_LOG"
  local rc="${PIPESTATUS[0]}"
  [[ "$rc" -eq 0 ]] || status="failed"

  log "4/4 요약 출력"
  bash "$SCRIPTS_DIR/print-summary.sh" \
    --status "$status" --log-dir "$LOGS_DIR" --config "$CONFIG_FILE" \
    --install-log "$INSTALL_LOG" --summary-file "$LOGS_DIR/summary-$TS.txt"

  [[ "$status" == "success" ]] || die "설치 실패 — $INSTALL_LOG 및 summary-$TS.txt 확인."
}

cmd_tags() {
  local tag="${1:?--tags 뒤에 대상이 필요하다 (kvm_hosts|management|monitoring|storage|agent)}"
  validate_local_runtime
  validate_local_files
  load_images
  local img
  case "$tag" in
    management|monitoring) img="$(ensure_mgmt_image)" ;;
    kvm_hosts|storage|agent) img="$(ensure_host_image "$CLUSTER_OS")" ;;
    *) die "알 수 없는 tag: $tag" ;;
  esac
  log "단계 실행 --tags $tag (이미지: $img)"
  run_container "$img" --tags "$tag" 2>&1 | tee "$LOGS_DIR/ansible-$tag-$TS.log"
}

# ── 시작/종료/소요 시간 ──────────────────────────────────────────────────────
# 실제 작업 command(install/preflight/tags/load-images/collect-logs)에 대해
# 시작 시각을 찍고, EXIT trap 으로 성공/실패 어느 경로든 종료 시각과 소요 시간을 출력한다.
_timing_begin() {
  _START_EPOCH="$(date +%s)"
  log "시작: $(date '+%Y-%m-%d %H:%M:%S')  (command: $1)"
  trap '_timing_end' EXIT
}
_timing_end() {
  local rc=$? end el
  end="$(date +%s)"; el=$((end - _START_EPOCH))
  printf '[%s] 종료: %s  소요: %02d:%02d:%02d  (exit=%d)\n' \
    "$(date +%H:%M:%S)" "$(date '+%Y-%m-%d %H:%M:%S')" \
    $((el/3600)) $(((el%3600)/60)) $((el%60)) "$rc"
}

# sudo 비밀번호 입력 (NOPASSWD 미설정 환경). NAMUVIRT_BECOME_PASS 로 export → 컨테이너 전달.
prompt_become_pass() {
  local p
  read -r -s -p "sudo(become) 비밀번호 — 모든 KVM Host 공통 SSH 계정: " p; echo
  [[ -n "$p" ]] || die "비밀번호가 비어 있다."
  export NAMUVIRT_BECOME_PASS="$p"
  ok "sudo 비밀번호 입력 완료 (become-password-file 로 안전 전달)."
}

# ── 디스패치 ─────────────────────────────────────────────────────────────────
main() {
  # -K / --ask-become-pass 를 위치 무관하게 먼저 뽑아낸다.
  local args=() _ask_become=0 a
  for a in "$@"; do
    case "$a" in
      -K|--ask-become-pass) _ask_become=1 ;;
      *) args+=("$a") ;;
    esac
  done
  if [[ ${#args[@]} -gt 0 ]]; then set -- "${args[@]}"; else set --; fi
  [[ "$_ask_become" -eq 1 ]] && prompt_become_pass

  local cmd="${1:-}"; shift || true
  case "$cmd" in
    -h|--help|"") usage ;;
    --load-images) _timing_begin "$cmd"; validate_local_runtime; load_images force ;;
    --preflight)   _timing_begin "$cmd"; cmd_preflight ;;
    install)       _timing_begin "$cmd"; cmd_install ;;
    --tags)        _timing_begin "$cmd $1"; cmd_tags "$@" ;;
    collect-logs)  _timing_begin "$cmd"; bash "$SCRIPTS_DIR/collect-logs.sh" "$LOGS_DIR" ;;
    *) die "알 수 없는 command: $cmd (--help 참고)" ;;
  esac
}

main "$@"
