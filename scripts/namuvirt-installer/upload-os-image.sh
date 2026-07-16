#!/usr/bin/env bash
# ============================================================================
# upload-os-image.sh — OS 골든 이미지 / SystemVM 템플릿 업로드 (설치와 무관한 별도 운영 도구).
#
# 설치(install-namuvirt.sh) 와 분리되어 있으며, 관리 VM(config.yaml 의 management.vm_ip)에
# SSH 로 접속해 관리 VM 에 설치된 `cmk`(CloudMonkey) 로 템플릿을 등록한다.
#
# 사용법:
#   # 대화형 메뉴 (인자 없이 실행) — check/list/register/register-systemvm 선택,
#   #   register 선택 시 images/ 목록·ostype·zone·hypervisor·format 을 순서대로 골라 등록
#   ./upload-os-image.sh                 # (= ./upload-os-image.sh menu)
#
#   # 게스트 OS 골든 이미지 등록 (외부 URL)
#   ./upload-os-image.sh register \
#       --name "Rocky8-golden" --url "http://10.10.10.3/images/rocky8.qcow2" \
#       --ostype 245 --zone 1 [--displaytext "Rocky 8 golden"] \
#       [--format QCOW2] [--hypervisor KVM] [-- <cmk 추가 key=value ...>]
#
#   # 로컬 파일 등록 (--file: 임시 HTTP 서버 자동 기동 → 등록 → isready 대기 → 종료)
#   ./upload-os-image.sh register \
#       --file images/NAMU-Rocky-8-10.qcow2 \
#       --name "Rocky8-golden" --ostype 245 --zone 1 \
#       [--serve-ip 10.10.14.193] [--serve-port 8000] [--wait-timeout 1800]
#
#   # SystemVM 템플릿 등록 (SSVM 경유 — SSVM 이 이미 떠 있을 때, 업데이트용)
#   ./upload-os-image.sh register-systemvm \
#       --name "systemvm-4.22" --url "http://10.10.10.3/images/systemvm.qcow2.bz2" \
#       --zone 1 [--format QCOW2] [--hypervisor KVM]
#
#   # ★ SystemVM 템플릿 시드 (폐쇄망 부트스트랩 — SSVM 없이 직접, cloud-install-sys-tmplt)
#   #   최초 설치 시엔 SSVM 이 없어 register-systemvm 으로는 못 넣는다(순환). 이걸로 시드해야
#   #   CloudStack 이 SSVM 을 부팅할 수 있다. zone/secondary storage 준비 후 SSVM 부팅 전에 실행.
#   ./upload-os-image.sh seed-systemvm \
#       [--file images/SystemVM-Template-KVM.qcow2] [--secondary /export/secondary] \
#       [--hypervisor kvm] [--serve-ip <master>] [--serve-port 8000]
#
#   # 관리 VM 의 cmk 설정/연결 확인
#   ./upload-os-image.sh check
#
#   # 등록된 템플릿 목록
#   ./upload-os-image.sh list
#
# 전제: 관리 VM 에 cmk 가 설치·설정(cmk set url/username/apikey, cmk sync)되어 있어야 한다.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"

CONFIG_FILE="${NAMUVIRT_CONFIG:-$SCRIPT_DIR/config.yaml}"
SSH_DIR="$SCRIPT_DIR/ssh"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
c_bold=$'\033[1m'; c_cyan=$'\033[36m'; c_dim=$'\033[2m'
die()  { echo "${c_red}✘ ERROR${c_rst} $*" >&2; exit 1; }
ok()   { echo "  ${c_grn}✔${c_rst} $*"; }
warn() { echo "  ${c_yel}▲ WARN${c_rst} $*"; }
log()  { echo "  ${c_dim}[$(date +%H:%M:%S)]${c_rst} $*"; }

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

# ── 디자인/출력 헬퍼 ─────────────────────────────────────────────────────────
_HR="────────────────────────────────────────────────────────"

# 로그인 배너풍 헤더 (관리 VM IP 표시)
banner() {
  local ip="${VM_IP:-$(config_get management.vm_ip 2>/dev/null || true)}"; ip="${ip:-(미확인)}"
  printf '\n%s' "$c_cyan"
  cat <<'ART'
                               _    __________  ______
   ____  ____ _____ ___  __  _| |  / /  _/ __ \/_  __/
  / __ \/ __ `/ __ `__ \/ / / / | / // // /_/ / / /
 / / / / /_/ / / / / / / /_/ /| |/ // // _, _/ / /
/_/ /_/\__,_/_/ /_/ /_/\__,_/ |___/___/_/ |_| /_/
ART
  printf '%s' "$c_rst"
  printf '  %sOS 이미지 / SystemVM 템플릿 등록 콘솔%s   %s관리 VM: %s%s\n' "$c_dim" "$c_rst" "$c_dim" "$ip" "$c_rst"
  printf '  %s%s%s\n' "$c_cyan" "$_HR" "$c_rst"
}

# 섹션 헤더 (통일된 형식)
section() { printf '\n  %s%s▸ %s%s\n' "$c_bold" "$c_cyan" "$1" "$c_rst"; }

# cmk 조회 결과 출력: 결과가 비면 "(조회된 결과가 없습니다)" 로 통일 표시
show_result() {   # $1 = vm_exec 로 실행할 cmk 명령
  local out; out="$(vm_exec "$1" 2>/dev/null || true)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    printf '    %s(조회된 결과가 없습니다)%s\n' "$c_dim" "$c_rst"
  else
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# ── 로컬 파일 임시 HTTP 노출 (--file 용) ─────────────────────────────────────
# master 에 python3 가 없을 수 있으므로, 이미 로드된 설치 이미지의 python 으로 서버를 띄운다.
SERVE_CONTAINER=""
cleanup_serve() { [[ -n "$SERVE_CONTAINER" ]] && docker rm -f "$SERVE_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup_serve EXIT

serve_image() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E 'namuvirt-(management-setup|host-setup-rocky|host-setup-ubuntu):' | head -1
}

# SSVM 이 도달 가능한 master IP (기본: config kvm.master.ip → 문자열 master → 기본 라우트 src)
detect_serve_ip() {
  local ip
  ip="$(config_get kvm.master.ip)"
  [[ -z "$ip" ]] && ip="$(config_get kvm.master)"
  [[ -z "$ip" ]] && ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  echo "$ip"
}

# ── config.yaml 조회 (python3+yaml 우선) ────────────────────────────────────
config_get() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$key" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
cur = cfg
for part in sys.argv[2].split('.'):
    cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None: break
print(cur if cur is not None else "")
PY
  else
    # python3 미설치(폐쇄망 KVM 호스트) 폴백: dotted key 의 leaf 를 awk 로 추출.
    local leaf="${key##*.}"
    awk -v k="$leaf" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, ""); sub(/[[:space:]]*$/, "");
        gsub(/^["'\'']|["'\'']$/, ""); print; exit
      }' "$CONFIG_FILE" 2>/dev/null
  fi
}

load_target() {
  [[ -f "$CONFIG_FILE" ]] || die "config.yaml 이 없다: $CONFIG_FILE"
  VM_IP="$(config_get management.vm_ip)"
  [[ -n "$VM_IP" ]] || die "config.yaml 에서 management.vm_ip 를 읽지 못했다."
  SSH_USER="$(config_get ssh_user)"; SSH_USER="${SSH_USER:-namuvirt}"
  local key; key="$(config_get ssh_private_key_path)"; key="${key:-/mnt/namuvirt/ssh/id_ed25519}"
  # 컨테이너 경로(/mnt/namuvirt/ssh) → 호스트 경로(./ssh) 매핑
  SSH_KEY="${key/#\/mnt\/namuvirt\/ssh/$SSH_DIR}"
  [[ -f "$SSH_KEY" ]] || die "SSH private key 가 없다: $SSH_KEY"
}

# 관리 VM 에서 명령 실행
vm_exec() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${SSH_USER}@${VM_IP}" "$@"
}

ensure_cmk() {
  vm_exec "command -v cmk >/dev/null 2>&1" \
    || die "관리 VM($VM_IP) 에 cmk 가 없다. cmk 설치 후 'cmk set url ...; cmk set username/apikey ...; cmk sync' 로 설정할 것."
}

# cmk 인자 escape (key="value")
cmk_kv() { printf '%s="%s"' "$1" "$2"; }

# 템플릿이 isready=true 될 때까지 폴링 (--file 시 서버를 켜둔 채 대기)
wait_template_ready() {
  local name="$1" timeout="${2:-1800}" interval=15 waited=0
  log "템플릿 다운로드/변환 대기: '$name' (isready, 최대 ${timeout}s)"
  while (( waited < timeout )); do
    if vm_exec "cmk -o json list templates templatefilter=all keyword='$name' 2>/dev/null" \
         | grep -qiE '"isready"[[:space:]]*:[[:space:]]*true'; then
      echo; ok "템플릿 준비 완료(isready=true): $name"; return 0
    fi
    sleep "$interval"; waited=$((waited+interval)); printf '.'
  done
  echo; warn "타임아웃(${timeout}s) — '$name' 아직 isready 아님. 'list' 로 계속 확인할 것 (서버는 곧 종료됨)."
  return 1
}

# ── 커맨드 ───────────────────────────────────────────────────────────────────
cmd_check() {
  load_target; ensure_cmk
  section "cmk 연결 확인"
  log "관리 VM($VM_IP) 에서 cmk sync ..."
  vm_exec "cmk sync >/dev/null 2>&1 && cmk list zones filter=id,name" \
    || die "cmk sync/list 실패 — cmk url/자격증명 설정을 확인할 것."
  ok "cmk 연결 정상"
}

cmd_list() {
  load_target; ensure_cmk
  section "등록된 템플릿 (templates)"
  show_result "cmk list templates templatefilter=all filter=id,name,ostypename,ispublic,isready"
}

# 인프라 확인 — zone / secondary storage / host / systemvm 현황을 한 화면에, 통일된 형식으로.
cmd_infra() {
  load_target; ensure_cmk
  section "Zones"
  show_result "cmk list zones filter=id,name,allocationstate,networktype"
  section "Secondary storage (imagestores)"
  show_result "cmk list imagestores filter=id,name,url"
  section "Hosts (KVM / Routing)"
  show_result "cmk list hosts type=Routing filter=name,state,resourcestate"
  section "SystemVMs"
  show_result "cmk list systemvms filter=name,state"
}

# 로컬 파일을 임시 HTTP 서버(설치 이미지 python)로 노출. 성공 시 전역 SERVE_CONTAINER + SERVE_URL 세팅.
# --network host 로 띄운다(-p 대신): KVM 호스트의 firewalld/iptables 로 docker NAT 체인이 깨져도 회피.
start_temp_serve() {  # $1=localfile  $2=serve_ip(빈값=자동)  $3=serve_port
  local localfile="$1" serve_ip="$2" serve_port="$3"
  [[ -f "$localfile" ]] || die "파일이 없다: $localfile"
  command -v docker >/dev/null 2>&1 || die "임시 서버는 docker 가 필요하다."
  [[ -z "$serve_ip" ]] && serve_ip="$(detect_serve_ip)"
  [[ -n "$serve_ip" ]] || die "serve IP 를 정할 수 없다 — --serve-ip 로 지정할 것."
  local img fdir fbase
  img="$(serve_image)"; [[ -n "$img" ]] || die "임시 서버로 쓸 namuvirt 설치 이미지가 없다 (docker images 확인)."
  fdir="$(cd "$(dirname "$localfile")" && pwd)"; fbase="$(basename "$localfile")"
  SERVE_CONTAINER="namuvirt-imgserve-$$"
  log "로컬 파일 임시 HTTP 노출: $fdir/$fbase → http://$serve_ip:$serve_port/$fbase (image=$img)"
  docker run --rm -d --name "$SERVE_CONTAINER" --network host \
    -v "$fdir:/srv:ro" "$img" \
    python3 -m http.server "$serve_port" --bind 0.0.0.0 --directory /srv >/dev/null \
    || die "임시 HTTP 서버 컨테이너 기동 실패 (포트 $serve_port 사용중? 'ss -ltnp | grep $serve_port' 확인)."
  sleep 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$SERVE_CONTAINER" 2>/dev/null)" == "true" ]] \
    || die "임시 HTTP 서버가 뜨지 않았다 — 'docker logs $SERVE_CONTAINER' 확인."
  SERVE_URL="http://$serve_ip:$serve_port/$fbase"
  ok "임시 서버 기동: $SERVE_URL"
}

# register / register-systemvm 공통
do_register() {
  local systemvm="$1"; shift
  local name="" url="" fmt="QCOW2" hyp="KVM" ostype="" zone="" displaytext=""
  local localfile="" serve_ip="" serve_port="8000" wait_timeout="1800"
  local -a passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)        name="$2"; shift 2 ;;
      --url)         url="$2"; shift 2 ;;
      --file)        localfile="$2"; shift 2 ;;
      --serve-ip)    serve_ip="$2"; shift 2 ;;
      --serve-port)  serve_port="$2"; shift 2 ;;
      --wait-timeout) wait_timeout="$2"; shift 2 ;;
      --format)      fmt="$2"; shift 2 ;;
      --hypervisor)  hyp="$2"; shift 2 ;;
      --ostype)      ostype="$2"; shift 2 ;;
      --zone)        zone="$2"; shift 2 ;;
      --displaytext) displaytext="$2"; shift 2 ;;
      --)            shift; passthrough=("$@"); break ;;
      *) die "알 수 없는 인자: $1 (--help 참고)" ;;
    esac
  done

  [[ -n "$name" ]] || die "--name 이 필요하다."
  [[ -n "$url" || -n "$localfile" ]] || die "--url 또는 --file 이 필요하다."
  [[ -n "$url" && -n "$localfile" ]] && die "--url 과 --file 은 동시에 쓸 수 없다."
  [[ -n "$zone" ]] || die "--zone (zoneid) 가 필요하다."
  [[ -n "$displaytext" ]] || displaytext="$name"

  load_target; ensure_cmk

  # --file: 로컬 파일을 임시 HTTP 서버로 노출하고 url 을 만든다(SSVM 이 받아감).
  if [[ -n "$localfile" ]]; then
    start_temp_serve "$localfile" "$serve_ip" "$serve_port"
    url="$SERVE_URL"
  fi

  local -a args=(
    "$(cmk_kv name "$name")"
    "$(cmk_kv displaytext "$displaytext")"
    "$(cmk_kv url "$url")"
    "$(cmk_kv format "$fmt")"
    "$(cmk_kv hypervisor "$hyp")"
    "$(cmk_kv zoneid "$zone")"
  )
  if [[ "$systemvm" == "yes" ]]; then
    # SystemVM 템플릿: 시스템 템플릿 플래그
    args+=( "$(cmk_kv templatetype SYSTEM)" "$(cmk_kv ispublic true)" "$(cmk_kv isfeatured false)" )
    [[ -n "$ostype" ]] && args+=( "$(cmk_kv ostypeid "$ostype")" )
  else
    [[ -n "$ostype" ]] || die "--ostype (ostypeid) 가 필요하다 (게스트 템플릿)."
    args+=( "$(cmk_kv ostypeid "$ostype")" "$(cmk_kv ispublic true)" )
  fi
  # 사용자 추가 key=value pass-through
  [[ ${#passthrough[@]} -gt 0 ]] && args+=( "${passthrough[@]}" )

  log "템플릿 등록 (관리 VM $VM_IP): name=$name url=$url zone=$zone systemvm=$systemvm"
  vm_exec "cmk register template ${args[*]}" \
    || die "cmk register template 실패 — 인자/URL 도달성/ostypeid/zoneid 를 확인할 것."
  ok "등록 요청 완료: $name"

  # --file 이면 SSVM 이 다 받을 때까지 임시 서버를 켜둔 채 대기 후 정리한다.
  if [[ -n "$localfile" ]]; then
    wait_template_ready "$name" "$wait_timeout" || true
    cleanup_serve; SERVE_CONTAINER=""
    ok "임시 서버 종료"
  else
    log "SSVM 다운로드/변환 완료까지 시간이 걸릴 수 있다 → 'list' 로 isready 확인"
  fi
}

# ── SystemVM 템플릿 시드 (폐쇄망 부트스트랩, SSVM 불필요) ─────────────────────
# CloudStack 은 SSVM/CPVM 자체가 SystemVM 템플릿으로 만들어지는 인스턴스라, 최초엔 SSVM 이
# 없어 register-systemvm(SSVM 경유)으로는 넣을 수 없다(순환). cloud-install-sys-tmplt 로
# 로컬 SystemVM 템플릿을 secondary storage 에 "직접" 시드한다(인터넷/SSVM 불필요).
#   ./upload-os-image.sh seed-systemvm [--file images/SystemVM-Template-KVM.qcow2]
#       [--secondary /export/secondary] [--hypervisor kvm] [--serve-ip <master>] [--serve-port 8000]
cmd_seed_systemvm() {
  local localfile="" secondary="" hyp="kvm" serve_ip="" serve_port="8000"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)       localfile="$2"; shift 2 ;;
      --secondary)  secondary="$2"; shift 2 ;;
      --hypervisor) hyp="$2"; shift 2 ;;
      --serve-ip)   serve_ip="$2"; shift 2 ;;
      --serve-port) serve_port="$2"; shift 2 ;;
      *) die "알 수 없는 인자: $1 (--help 참고)" ;;
    esac
  done
  load_target
  # SystemVM 파일 자동 선택 (images/ 의 SystemVM*KVM*.qcow2)
  if [[ -z "$localfile" ]]; then
    localfile="$(ls images/SystemVM-Template-KVM.qcow2 images/SystemVM*KVM*.qcow2* 2>/dev/null | head -1)"
  fi
  [[ -n "$localfile" && -f "$localfile" ]] || die "SystemVM 템플릿 파일이 없다 — --file images/<...>.qcow2 로 지정."
  # secondary storage 경로 (config.yaml storage.secondary → 기본 /export/secondary)
  [[ -z "$secondary" ]] && secondary="$(config_get storage.secondary)"
  [[ -z "$secondary" ]] && secondary="/export/secondary"

  local SYS_TMPLT=/usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt
  vm_exec "test -x $SYS_TMPLT" || die "관리 VM($VM_IP) 에 cloud-install-sys-tmplt 가 없다 (cloudstack-common 확인)."
  vm_exec "test -d '$secondary'" || warn "관리 VM 에 secondary 경로 '$secondary' 가 없다 — NFS 마운트/경로 확인 필요."

  # 임시 HTTP 로 SystemVM 파일 노출 → 관리 VM 의 cloud-install-sys-tmplt 가 http:// 로 받아 secondary 에 시드
  start_temp_serve "$localfile" "$serve_ip" "$serve_port"
  log "SystemVM 시드: cloud-install-sys-tmplt -m $secondary -u $SERVE_URL -h $hyp -F"
  if vm_exec "sudo $SYS_TMPLT -m '$secondary' -u '$SERVE_URL' -h '$hyp' -F"; then
    ok "SystemVM 템플릿 시드 완료 (secondary=$secondary). CloudStack 이 이 템플릿으로 SSVM 을 부팅한다."
  else
    cleanup_serve; SERVE_CONTAINER=""
    die "cloud-install-sys-tmplt 실패 — secondary 마운트/DB/URL 도달성 확인 (SSVM 로그 아님, 관리 VM 로그)."
  fi
  cleanup_serve; SERVE_CONTAINER=""
}

# ── 대화형(메뉴) 모드 ────────────────────────────────────────────────────────
# 프롬프트/메뉴는 stderr 로 출력(결과값은 전역변수로 넘겨 stdout 오염 방지).
prompt_tty() {
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then read -r -p "  $q [$def]: " ans </dev/tty || true; echo "${ans:-$def}"
  else read -r -p "  $q: " ans </dev/tty || true; echo "$ans"; fi
}

# menu_pick "제목" 라벨...  → 선택 인덱스(0-base)를 전역 PICK 에
menu_pick() {
  local title="$1"; shift
  local -a L=("$@"); local i sel
  { printf '\n  %s%s%s\n' "$c_bold" "$title" "$c_rst"
    for i in "${!L[@]}"; do printf "    %s%2d)%s %s\n" "$c_cyan" $((i+1)) "$c_rst" "${L[$i]}"; done; } >&2
  while :; do
    read -r -p "  ${c_cyan}번호>${c_rst} " sel </dev/tty || true
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#L[@]} )) && { PICK=$((sel-1)); return 0; }
    printf '  %s1~%s 중에서 고르세요.%s\n' "$c_yel" "${#L[@]}" "$c_rst" >&2
  done
}

pick_image() {  # images/ 의 이미지 → IMG_SEL
  local -a files=(); local f
  shopt -s nullglob
  for f in images/*.qcow2 images/*.qcow2.bz2 images/*.ova images/*.img images/*.raw images/*.vhd images/*.vmdk; do files+=("$f"); done
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || die "images/ 에 이미지 파일이 없다 (qcow2/ova 등을 images/ 에 두라)."
  menu_pick "images/ 이미지 선택:" "${files[@]}"
  IMG_SEL="${files[$PICK]}"
}

pick_ostype() {  # cmk ostype 목록 → OSTYPE_ID
  local kw id desc; local -a ids=() labels=()
  kw="$(prompt_tty 'OS 검색어 (rocky/centos/ubuntu 등, 빈값=전체)')"
  while IFS=',' read -r id desc; do
    [[ -z "$id" || "$id" == "id" ]] && continue
    id="${id//\"/}"; desc="${desc//\"/}"
    [[ -n "$kw" ]] && ! grep -qi -- "$kw" <<<"$desc" && continue
    ids+=("$id"); labels+=("$desc  [$id]")
  done < <(vm_exec "cmk -o csv list ostypes filter=id,description" 2>/dev/null)
  [[ ${#ids[@]} -gt 0 ]] || die "ostype 조회 실패 또는 '$kw' 매칭 없음 (cmk 설정 확인)."
  menu_pick "OS Type 선택:" "${labels[@]}"
  OSTYPE_ID="${ids[$PICK]}"
}

pick_zone() {  # cmk zone 목록 → ZONE_ID
  local id name; local -a ids=() labels=()
  while IFS=',' read -r id name; do
    [[ -z "$id" || "$id" == "id" ]] && continue
    id="${id//\"/}"; name="${name//\"/}"
    ids+=("$id"); labels+=("$name  [$id]")
  done < <(vm_exec "cmk -o csv list zones filter=id,name" 2>/dev/null)
  [[ ${#ids[@]} -gt 0 ]] || die "등록된 zone 이 없습니다. admin 콘솔의 'Add Zone' 으로 존을 먼저 구성하세요."
  menu_pick "Zone 선택:" "${labels[@]}"
  ZONE_ID="${ids[$PICK]}"
}

pick_hypervisor() {  # → HYP
  menu_pick "Hypervisor 선택:" "KVM" "VMware" "XenServer" "직접입력"
  case "$PICK" in 0) HYP=KVM;; 1) HYP=VMware;; 2) HYP=XenServer;; 3) HYP="$(prompt_tty 'hypervisor 이름')";; esac
}

pick_format() {  # $1=파일명 → FMT (확장자 기준 기본 안내)
  local def=QCOW2
  case "$1" in *.ova) def=OVA;; *.raw|*.img) def=RAW;; *.vhd) def=VHD;; *.vmdk) def=VMDK;; *) def=QCOW2;; esac
  menu_pick "Format 선택 (파일 기준 추천=$def):" "QCOW2" "OVA" "RAW" "VHD" "VMDK"
  local -a fmts=(QCOW2 OVA RAW VHD VMDK); FMT="${fmts[$PICK]}"
}

interactive_register() {  # $1 = no(게스트) | yes(SystemVM)
  local systemvm="$1"; OSTYPE_ID=""
  load_target; ensure_cmk
  require_zone
  pick_image
  local name; name="$(prompt_tty '템플릿 이름' "$(basename "$IMG_SEL" | sed 's/\.[^.]*$//')")"
  pick_zone
  pick_hypervisor
  pick_format "$IMG_SEL"
  local -a args=(--file "$IMG_SEL" --name "$name" --zone "$ZONE_ID" --hypervisor "$HYP" --format "$FMT")
  if [[ "$systemvm" == "no" ]]; then
    pick_ostype; args+=(--ostype "$OSTYPE_ID")
  else
    [[ "$(prompt_tty 'ostype 도 지정할까? (y/N)')" =~ ^[Yy] ]] && { pick_ostype; args+=(--ostype "$OSTYPE_ID"); }
  fi
  { echo "  ── 등록 요약 ──────────────────────────────"
    echo "    file       : $IMG_SEL"
    echo "    name       : $name"
    echo "    zone       : $ZONE_ID"
    echo "    hypervisor : $HYP"
    echo "    format     : $FMT"
    [[ -n "$OSTYPE_ID" ]] && echo "    ostype     : $OSTYPE_ID"
    echo "    systemvm   : $systemvm"
    echo "  ───────────────────────────────────────────"; } >&2
  [[ "$(prompt_tty '이대로 등록? (Y/n)' 'Y')" =~ ^[Nn] ]] && { echo "  취소됨." >&2; return 0; }
  do_register "$systemvm" "${args[@]}"
}

interactive_seed() {  # SystemVM 부트스트랩 시드 (SSVM 불필요)
  load_target
  pick_image
  local sec_def; sec_def="$(config_get storage.secondary 2>/dev/null)"; [[ -z "$sec_def" ]] && sec_def="/export/secondary"
  local secondary; secondary="$(prompt_tty 'secondary storage 경로' "$sec_def")"
  menu_pick "SystemVM Hypervisor:" "kvm" "vmware" "xenserver"
  local -a hyps=(kvm vmware xenserver); local hyp="${hyps[$PICK]}"
  { echo "  ── SystemVM 시드 요약 (부트스트랩) ─────────"
    echo "    file       : $IMG_SEL"
    echo "    secondary  : $secondary"
    echo "    hypervisor : $hyp"
    echo "  ───────────────────────────────────────────"; } >&2
  [[ "$(prompt_tty '이대로 시드? (Y/n)' 'Y')" =~ ^[Nn] ]] && { echo "  취소됨." >&2; return 0; }
  cmd_seed_systemvm --file "$IMG_SEL" --secondary "$secondary" --hypervisor "$hyp"
}

# ── 대화형 UX 헬퍼 ───────────────────────────────────────────────────────────
cls() { clear 2>/dev/null || printf '\033[2J\033[3J\033[H'; }

# 결과/에러를 보여준 뒤 Enter 로 메뉴 복귀
pause_return() { echo >&2; read -r -p "  ${c_grn}[Enter]${c_rst} 를 눌러 메뉴로 돌아갑니다... " _ </dev/tty || true; }

# 메뉴 액션 실행: subshell 로 격리해 die/오류가 나도 스크립트가 종료되지 않고 메뉴로 복귀한다.
# subshell 은 EXIT trap 을 리셋하므로 임시 HTTP 서버 정리 trap 을 재설정해 컨테이너 누수를 막는다.
run_action() {
  cls; banner
  local rc=0
  ( trap cleanup_serve EXIT; "$@" ) || rc=$?
  (( rc != 0 )) && { echo >&2; warn "작업이 오류로 종료되었습니다 (위 메시지 확인)."; }
  pause_return
}

# 등록된 zone 이 없으면 die (run_action 이 잡아 메뉴로 복귀). register 계열 진입 시 사용.
require_zone() {
  local zcnt
  zcnt="$(vm_exec "cmk -o csv list zones filter=id" 2>/dev/null | grep -vcE '^(id)?$')" || zcnt=0
  [[ "${zcnt:-0}" -gt 0 ]] || die "등록된 zone 이 없습니다. admin 콘솔의 'Add Zone' 으로 존/스토리지/호스트를 먼저 구성한 뒤 다시 시도하세요."
}

cmd_menu() {
  [[ -t 0 ]] || die "대화형 모드는 터미널이 필요하다 (인자를 주고 실행하거나 --help 참고)."
  local -a items=(
    "check   (cmk 연결 확인)"
    "list    (등록 템플릿 목록)"
    "infra   (zone/secondary/host/systemvm 확인)"
    "register (게스트 OS 템플릿 등록)"
    "register-systemvm (SystemVM 등록 — SSVM 경유, 업데이트용)"
    "seed-systemvm (SystemVM 부트스트랩 — SSVM 없이 직접 시드)"
  )
  local sel i
  while :; do
    cls; banner
    { printf '\n  %s작업을 선택하세요:%s\n' "$c_bold" "$c_rst"
      for i in "${!items[@]}"; do printf "    %s%2d)%s %s\n" "$c_cyan" $((i+1)) "$c_rst" "${items[$i]}"; done
      printf "    %s%2d)%s %s종료%s\n" "$c_cyan" 0 "$c_rst" "$c_dim" "$c_rst"; } >&2
    read -r -p "  ${c_cyan}번호>${c_rst} " sel </dev/tty || true
    case "$sel" in
      0) break ;;
      1) run_action cmd_check ;;
      2) run_action cmd_list ;;
      3) run_action cmd_infra ;;
      4) run_action interactive_register no ;;
      5) run_action interactive_register yes ;;
      6) run_action interactive_seed ;;
      *) printf '  %s0~%s 중에서 고르세요.%s\n' "$c_yel" "${#items[@]}" "$c_rst" >&2; sleep 1 ;;
    esac
  done
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    -h|--help)                usage ;;
    ""|menu|-i|--interactive) cmd_menu ;;
    check)              cmd_check ;;
    list)               cmd_list ;;
    infra)              cmd_infra ;;
    register)           do_register no  "$@" ;;
    register-systemvm)  do_register yes "$@" ;;
    seed-systemvm)      cmd_seed_systemvm "$@" ;;
    *) die "알 수 없는 command: $cmd (--help 참고)" ;;
  esac
}

main "$@"
