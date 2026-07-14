#!/usr/bin/env bash
# ============================================================================
# prepare-install.sh — namuVIRT 설치 전 사전준비 (kvm.master 에서 실행).
#
# 이 스크립트는 install-namuvirt.sh 를 돌리기 전에 필요한 것들을 준비한다:
#   1) config.yaml 대화형 생성 (master IP/NIC/GW 는 자동탐지, 관리 VM IP 등은 직접 입력)
#   2) SSH 키 생성(ssh/id_ed25519) + 모든 KVM Host 에 공개키 배포 + 접속/ sudo 확인
#   3) images/ · ssh/ · logs/ 디렉터리 및 golden image/SystemVM template 배치 점검
#
# 전제(이 스크립트가 하지 않는 것):
#   - 각 KVM Host 에 ssh_user 계정 + 비밀번호 없는 sudo 는 미리 준비되어 있어야 한다.
#     (키 배포는 그 계정의 비밀번호로 1회 로그인해 이뤄진다.)
#
# 사용법:
#   ./prepare-install.sh                 # 전체 대화형
#   ./prepare-install.sh --config-only   # config.yaml 만 생성
#   ./prepare-install.sh --ssh-only      # SSH 키 생성/배포만
#   ./prepare-install.sh --check-only    # 디렉터리/이미지 점검만
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"

CONFIG_FILE="$SCRIPT_DIR/config.yaml"
SSH_DIR="$SCRIPT_DIR/ssh"
IMAGES_DIR="$SCRIPT_DIR/images"
LOGS_DIR="$SCRIPT_DIR/logs"
KEY_FILE="$SSH_DIR/id_ed25519"

# 컨테이너 내부 mount 경로 (config.yaml 에 기록되는 값)
C_KEY="/mnt/namuvirt/ssh/id_ed25519"
C_IMG_DIR="/mnt/namuvirt/images"

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
say()  { echo "${c_cyn}▶${c_rst} $*"; }
ok()   { echo "  ${c_grn}OK${c_rst}   $*"; }
warn() { echo "  ${c_yel}WARN${c_rst} $*"; }
die()  { echo "${c_red}ERROR${c_rst} $*" >&2; exit 1; }

# prompt "질문" "기본값"  → stdout 으로 입력값(또는 기본값) 반환
prompt() {
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "  $q [$def]: " ans </dev/tty || true
    echo "${ans:-$def}"
  else
    read -r -p "  $q: " ans </dev/tty || true
    echo "$ans"
  fi
}

# IPv4 형식 대략 검증 (0~255 옥텟 4개)
_is_ipv4() {
  local ip="$1" n
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; local -a o=($ip)
  for n in "${o[@]}"; do (( 10#$n <= 255 )) || return 1; done
  return 0
}

# 필수 IP 입력: 자동탐지값(있으면)을 기본값으로 제시하되, 빈 값/형식오류면 다시 묻는다.
# ※ 하드코딩 fallback 을 두지 않는다 — 탐지 실패 시 테스트 IP 를 제안하지 않고 반드시 입력받는다.
prompt_ip_required() {
  local q="$1" def="${2:-}" ans
  while :; do
    ans="$(prompt "$q" "$def")"
    if [[ -z "$ans" ]]; then
      echo "  ${c_yel}필수 입력입니다 (자동탐지 실패). IPv4 주소를 입력하세요.${c_rst}" >&2
    elif ! _is_ipv4 "$ans"; then
      echo "  ${c_yel}IPv4 형식이 아닙니다: $ans${c_rst}" >&2
    else
      echo "$ans"; return 0
    fi
  done
}

# 호스트 자동탐지 (이 스크립트는 kvm.master 에서 실행된다고 가정)
# 주의: KVM 설치 후엔 default route 가 브리지(cloudbr0)를 타므로, NIC 자동탐지가
# 브리지를 잡으면 그 브리지의 물리 slave 를 NIC 로 반환한다(브리지 자기참조 버그 방지).
detect_nic() {
  local dev
  dev="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  if [[ -n "$dev" && -d "/sys/class/net/$dev/bridge" ]]; then
    local slave; slave="$(ls "/sys/class/net/$dev/brif" 2>/dev/null | head -1)"
    [[ -n "$slave" ]] && dev="$slave"
  fi
  echo "$dev"
}
detect_gateway() { ip route show default 2>/dev/null | awk '/default/{print $3; exit}'; }
# src IP 는 NIC 과 무관하게 기본 라우트의 source 주소로 구한다 (브리지에 IP 가 있어도 정확).
detect_ip()      { ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# ── 1) config.yaml 대화형 생성 ───────────────────────────────────────────────
gen_config() {
  say "1) config.yaml 대화형 생성"
  if [[ -f "$CONFIG_FILE" ]]; then
    local bak="$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_FILE" "$bak"
    warn "기존 config.yaml 을 백업했다: $(basename "$bak")"
  fi

  local d_nic d_gw d_ip
  d_nic="$(detect_nic || true)"; d_gw="$(detect_gateway || true)"; d_ip="$(detect_ip || true)"

  echo "  (Enter 를 누르면 [기본값] 사용)"
  local ssh_user cluster_os m_ip m_nic m_gw vm_ip vm_name extra_raw
  local st_primary st_secondary nfs_host bridge prefix dns cloudimg systemvm

  ssh_user="$(prompt 'ssh_user (모든 KVM Host 공통 sudo 계정)' 'namuvirt')"
  cluster_os="$(prompt 'kvm.os (rocky 또는 ubuntu, Cluster 전체 동일)' 'rocky')"
  case "$cluster_os" in rocky|ubuntu) ;; *) die "kvm.os 는 rocky 또는 ubuntu 여야 한다: $cluster_os";; esac

  echo "  -- kvm.master (관리 VM 을 올릴 물리 호스트, 이 서버) --"
  m_ip="$(prompt_ip_required 'master IP' "${d_ip}")"
  m_nic="$(prompt 'master NIC' "${d_nic:-eno1}")"
  m_gw="$(prompt 'master gateway' "${d_gw:-${m_ip%.*}.1}")"

  echo "  -- 관리 VM --"
  vm_ip="$(prompt_ip_required '관리 VM IP' '')"
  vm_name="$(prompt '관리 VM 이름' 'namuVIRT-management')"
  # 관리 VM MAC 고정 (라이센스 바인딩 등에 유리). 기본값은 vm_ip 마지막 3옥텟에서 유도 → 예측 가능/고정.
  local _def_mac vm_mac
  _def_mac="$(printf '52:54:00:%02x:%02x:%02x' $(echo "$vm_ip" | awk -F. '{print $2, $3, $4}') 2>/dev/null || echo '')"
  vm_mac="$(prompt '관리 VM MAC 고정 (비우면 자동)' "$_def_mac")"

  echo "  -- 추가 KVM Host (master 제외, 쉼표로 여러 개; 없으면 Enter) --"
  extra_raw="$(prompt '추가 host IP 목록 (예: 192.168.0.11,192.168.0.12)' '')"

  echo "  -- 스토리지 / 네트워크 (보통 기본값) --"
  st_primary="$(prompt 'primary storage 경로' '/export/primary')"
  st_secondary="$(prompt 'secondary storage 경로' '/export/secondary')"
  echo "  (secondary NFS: IP 입력 시 관리 VM 이 그 호스트의 secondary export 를 NFS 마운트.)"
  echo "  (               비우면 관리 VM 로컬 디렉터리 사용 — NFS 마운트 안 함.)"
  nfs_host="$(prompt 'secondary NFS 서버 IP (없으면 Enter=로컬)' '')"
  bridge="$(prompt 'bridge 이름' 'cloudbr0')"
  prefix="$(prompt '네트워크 prefix' '24')"
  dns="$(prompt 'DNS (쉼표 구분)' '8.8.8.8,1.1.1.1')"

  echo "  -- 외부 mount 이미지 파일명 (images/ 에 둘 파일) --"
  cloudimg="$(prompt 'Rocky cloud image 파일명' 'NAMU-Rocky-8-10.qcow2')"
  systemvm="$(prompt 'SystemVM template 파일명' 'SystemVM-Template-KVM.qcow2')"

  # dns 리스트, 추가 host 블록 구성
  local dns_yaml host_yaml
  dns_yaml="[$(echo "$dns" | sed 's/[[:space:]]//g')]"
  if [[ -n "$extra_raw" ]]; then
    host_yaml=""
    IFS=',' read -r -a _hosts <<< "$extra_raw"
    for h in "${_hosts[@]}"; do
      h="$(echo "$h" | tr -d '[:space:]')"; [[ -z "$h" ]] && continue
      host_yaml+="    - ip: $h"$'\n'
    done
  else
    host_yaml="  hosts: []"$'\n'
  fi

  {
    echo "# namuVIRT config.yaml — prepare-install.sh 생성 ($(date +%F' '%T))"
    echo "ssh_user: $ssh_user"
    echo "ssh_private_key_path: $C_KEY"
    echo ""
    echo "kvm:"
    echo "  os: $cluster_os"
    echo "  master:"
    echo "    ip: $m_ip"
    echo "    nic: $m_nic"
    echo "    gateway: $m_gw"
    if [[ -n "$extra_raw" ]]; then
      echo "  hosts:"
      printf '%s' "$host_yaml"
    else
      printf '%s' "$host_yaml"
    fi
    echo ""
    echo "management:"
    echo "  vm_ip: $vm_ip"
    echo "  vm_name: $vm_name"
    echo "  vm_mac: \"$vm_mac\""
    echo "  vm_vcpus: 8"
    echo "  vm_ram_mb: 16384"
    echo "  vm_disk_gb: 200"
    echo "  rocky_cloudimg: $C_IMG_DIR/$cloudimg"
    echo "  systemvm_template: $C_IMG_DIR/$systemvm"
    # secondary NFS 서버 IP 를 입력했을 때만 기록한다. 미기재 시 관리 VM 은 로컬 디렉터리 사용.
    if [[ -n "$nfs_host" ]]; then
      echo "  nfs_export_host_ip: $nfs_host"
    fi
    echo ""
    echo "network:"
    echo "  bridge: $bridge"
    echo "  prefix: $prefix"
    echo "  dns: $dns_yaml"
    echo ""
    echo "storage:"
    echo "  primary: $st_primary"
    echo "  secondary: $st_secondary"
  } > "$CONFIG_FILE"

  ok "config.yaml 생성: $CONFIG_FILE"
  echo "────────────────────────────────────────"
  cat "$CONFIG_FILE"
  echo "────────────────────────────────────────"
}

# config.yaml 에서 값 읽기 — 순수 awk (폐쇄망 KVM 호스트엔 python3/pyyaml 이 없을 수 있다).
# 이 스크립트가 생성하는 고정 포맷을 전제로, dotted key 의 마지막 세그먼트(leaf)를
# 들여쓰기 무시하고 첫 매칭 라인에서 값을 뽑는다. (leaf 키는 우리 포맷에서 유일하다:
# ssh_user / rocky_cloudimg / systemvm_template)
cfg_get() {
  local key="$1" leaf="${1##*.}"
  awk -v k="$leaf" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")   # "key:" 접두 제거
      sub(/[[:space:]]*$/, "")                      # 끝 공백 제거
      gsub(/^["'\'']|["'\'']$/, "")                 # 양끝 따옴표 제거
      print; exit
    }' "$CONFIG_FILE" 2>/dev/null
}

# config 에서 전체 호스트 IP 목록(master + hosts) — 순수 awk.
# 우리 포맷에서 master 는 "    ip:" (dash 없음), hosts 항목은 "    - ip:" (dash) 로만 나타난다.
all_host_ips() {
  # master ip (dash 없는 bare ip:) — 첫 매칭 하나
  awk '/^[[:space:]]+ip:[[:space:]]/ {
         sub(/^[[:space:]]*ip:[[:space:]]*/,""); gsub(/["'\'']/,""); sub(/[[:space:]]*$/,"");
         if ($0!="") { print; exit }
       }' "$CONFIG_FILE" 2>/dev/null
  # hosts ip (- ip:)
  awk '/^[[:space:]]*-[[:space:]]*ip:[[:space:]]/ {
         sub(/^.*ip:[[:space:]]*/,""); gsub(/["'\'']/,""); sub(/[[:space:]]*$/,"");
         if ($0!="") print
       }' "$CONFIG_FILE" 2>/dev/null
}

# ── 2) SSH 키 생성 + 배포 ────────────────────────────────────────────────────
ssh_setup() {
  say "2) SSH 키 생성 + 배포"
  [[ -f "$CONFIG_FILE" ]] || die "config.yaml 이 없다. 먼저 config 를 생성할 것."
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"

  local ssh_user; ssh_user="$(cfg_get ssh_user)"; ssh_user="${ssh_user:-namuvirt}"

  if [[ -f "$KEY_FILE" ]]; then
    ok "SSH 키 이미 존재: $KEY_FILE"
  else
    say "SSH 키 생성 (ed25519, passphrase 없음)"
    ssh-keygen -t ed25519 -N '' -C "namuvirt-installer" -f "$KEY_FILE" >/dev/null
    ok "생성: $KEY_FILE (+ .pub)"
  fi
  chmod 600 "$KEY_FILE"; chmod 644 "$KEY_FILE.pub"

  local ips; ips="$(all_host_ips)"
  [[ -n "$ips" ]] || die "config.yaml 에서 KVM Host IP 를 읽지 못했다."

  echo "  대상 호스트: $(echo "$ips" | tr '\n' ' ')"
  echo "  각 호스트의 ${ssh_user} 계정 비밀번호를 물어볼 수 있다 (키가 이미 있으면 건너뜀)."
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    say "→ $ssh_user@$ip 공개키 배포"
    if ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
         "$ssh_user@$ip" 'true' 2>/dev/null; then
      ok "$ip: 키 접속 이미 가능"
    else
      if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -i "$KEY_FILE.pub" -o StrictHostKeyChecking=no "$ssh_user@$ip" \
          && ok "$ip: 공개키 배포 완료" || warn "$ip: 공개키 배포 실패 (계정/비밀번호 확인)"
      else
        warn "ssh-copy-id 없음 — 수동 배포 필요: ssh-copy-id -i $KEY_FILE.pub $ssh_user@$ip"
      fi
    fi
  done <<< "$ips"

  say "접속 + NOPASSWD sudo 확인"
  local fail=0
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
         "$ssh_user@$ip" 'sudo -n true' 2>/dev/null; then
      ok "$ip: SSH 키 + NOPASSWD sudo 정상"
    else
      warn "$ip: SSH 키 접속 또는 NOPASSWD sudo 실패 — ${ssh_user} 계정/sudoers 확인"
      fail=1
    fi
  done <<< "$ips"
  [[ $fail -eq 0 ]] && ok "모든 호스트 접속/ sudo 정상" || warn "일부 호스트 미완료 — preflight 전에 조치할 것"
}

# ── 3) 디렉터리 / 이미지 점검 ────────────────────────────────────────────────
check_layout() {
  say "3) 디렉터리 / 이미지 점검"
  mkdir -p "$IMAGES_DIR" "$SSH_DIR" "$LOGS_DIR"
  chmod 700 "$SSH_DIR"
  ok "디렉터리 준비: images/ ssh/ logs/"

  if [[ -f "$CONFIG_FILE" ]]; then
    local cimg simg h_c h_s
    cimg="$(cfg_get management.rocky_cloudimg)"; simg="$(cfg_get management.systemvm_template)"
    h_c="${cimg/#$C_IMG_DIR/$IMAGES_DIR}"; h_s="${simg/#$C_IMG_DIR/$IMAGES_DIR}"
    [[ -f "$h_c" ]] && ok "cloud image 존재: $(basename "$h_c")" \
                    || warn "cloud image 없음 → 여기에 배치: $h_c"
    [[ -f "$h_s" ]] && ok "SystemVM template 존재: $(basename "$h_s")" \
                    || warn "SystemVM template 없음 → 여기에 배치: $h_s"
  else
    warn "config.yaml 이 없어 이미지 파일명 확인 생략"
  fi

  # 설치 컨테이너 이미지 로드 여부(참고)
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker image inspect namuvirt-host-setup-rocky:1.0.0 >/dev/null 2>&1 \
       || docker image inspect namuvirt-host-setup-ubuntu:1.0.0 >/dev/null 2>&1; then
      ok "설치 컨테이너 이미지 로드됨"
    else
      warn "설치 이미지 미로드 → ./install-namuvirt.sh --load-images"
    fi
  fi
}

summary() {
  echo ""
  say "사전준비 완료 — 다음 단계"
  echo "  1) images/ 에 cloud image + SystemVM template 배치 (위 WARN 참고)"
  echo "  2) ./install-namuvirt.sh --load-images -K   # 폐쇄망 이미지 적재(필요 시)"
  echo "  3) ./install-namuvirt.sh --preflight -K"
  echo "  4) ./install-namuvirt.sh install -K"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    --config-only) gen_config ;;
    --ssh-only)    ssh_setup ;;
    --check-only)  check_layout ;;
    all|"")        gen_config; echo; ssh_setup; echo; check_layout; summary ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "알 수 없는 옵션: $mode (--config-only|--ssh-only|--check-only)" ;;
  esac
}
main "$@"
