#!/usr/bin/env bash
# ============================================================================
# verify-install.sh — namuVIRT 설치 후 검증 (kvm.master 에서 실행).
#
# config.yaml 을 읽어 모든 KVM Host(master 포함)와 관리 VM 에 SSH 로 접속해
# 서비스·포트·엔드포인트를 점검하고 PASS/FAIL 요약을 출력한다.
#
# 사용법:
#   ./verify-install.sh              # 전체 검증
#   ./verify-install.sh --hosts      # KVM Host 만
#   ./verify-install.sh --mgmt       # 관리 VM 만
#
# 종료코드: 0 = 모든 필수 항목 PASS, 1 = 필수 항목 FAIL 있음
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"
CONFIG_FILE="${NAMUVIRT_CONFIG:-$SCRIPT_DIR/config.yaml}"
SSH_DIR="$SCRIPT_DIR/ssh"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
die()  { echo "${c_red}ERROR${c_rst} $*" >&2; exit 1; }
sec()  { echo; echo "${c_cyn}== $* ==${c_rst}"; }
PASS=0; FAILN=0; WARNN=0
pass() { echo "  ${c_grn}PASS${c_rst} $*"; PASS=$((PASS+1)); }
failc(){ echo "  ${c_red}FAIL${c_rst} $*"; FAILN=$((FAILN+1)); }
warnc(){ echo "  ${c_yel}WARN${c_rst} $*"; WARNN=$((WARNN+1)); }

[[ -f "$CONFIG_FILE" ]] || die "config.yaml 이 없다: $CONFIG_FILE"

# ── config 파싱 (host python3+yaml → 없으면 설치 이미지의 python) ────────────
installer_image() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E 'namuvirt-(management-setup|host-setup-rocky|host-setup-ubuntu):' | head -1
}
CFG_PY='import sys,yaml,shlex
c=yaml.safe_load(open(sys.argv[1])) or {}
kvm=c.get("kvm") or {}; m=c.get("management") or {}; n=c.get("network") or {}; s=c.get("storage") or {}
mm=kvm.get("master"); mip=mm.get("ip") if isinstance(mm,dict) else mm
hosts=[(h.get("ip") if isinstance(h,dict) else h) for h in (kvm.get("hosts") or [])]
print("SSH_USER="+shlex.quote(str(c.get("ssh_user","namuvirt"))))
print("SSH_KEY_C="+shlex.quote(str(c.get("ssh_private_key_path","/mnt/namuvirt/ssh/id_ed25519"))))
print("MASTER_IP="+shlex.quote(str(mip or "")))
print("HOST_IPS="+shlex.quote(" ".join(str(x) for x in hosts if x)))
print("VM_IP="+shlex.quote(str(m.get("vm_ip",""))))
print("BRIDGE="+shlex.quote(str(n.get("bridge","cloudbr0"))))
print("PRIMARY="+shlex.quote(str(s.get("primary","/export/primary"))))
print("SECONDARY="+shlex.quote(str(s.get("secondary","/export/secondary"))))'

parse_config() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c "$CFG_PY" "$CONFIG_FILE"
  else
    local img; img="$(installer_image)"
    [[ -n "$img" ]] || die "host 에 python3(yaml) 이 없고 설치 이미지도 없어 config 파싱 불가."
    docker run --rm -v "$CONFIG_FILE:/c.yaml:ro" "$img" python3 -c "$CFG_PY" /c.yaml
  fi
}
eval "$(parse_config)"
SSH_KEY="${SSH_KEY_C/#\/mnt\/namuvirt\/ssh/$SSH_DIR}"
[[ -f "$SSH_KEY" ]] || die "SSH private key 가 없다: $SSH_KEY"
[[ -n "$MASTER_IP" ]] || die "config 에서 kvm.master.ip 를 읽지 못했다."
[[ -n "$VM_IP" ]] || die "config 에서 management.vm_ip 를 읽지 못했다."

# ── 원격/로컬 점검 헬퍼 ──────────────────────────────────────────────────────
rexec() { local h="$1"; shift; ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o ConnectTimeout=8 "${SSH_USER}@${h}" "$@" 2>/dev/null; }
# 원격 포트 listen (curl 없이 /dev/tcp 로 확인)
rport() { rexec "$1" "timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$2' >/dev/null 2>&1"; }
# 로컬(master)에서 대상 TCP 접속
lport() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
svc()   { rexec "$1" "systemctl is-active --quiet $2"; }

# ── KVM Host 검증 ────────────────────────────────────────────────────────────
verify_hosts() {
  local all="$MASTER_IP $HOST_IPS"
  for h in $all; do
    local tag="[$h$( [[ "$h" == "$MASTER_IP" ]] && echo ' (master)')]"
    sec "KVM Host 검증 $tag"
    if ! rexec "$h" 'true'; then failc "$h: SSH 접속 실패 — 이후 점검 생략"; continue; fi
    pass "$h: SSH 접속"
    rexec "$h" 'test -e /dev/kvm' && pass "$h: /dev/kvm 존재" || failc "$h: /dev/kvm 없음"
    svc "$h" libvirtd && pass "$h: libvirtd active" || failc "$h: libvirtd 비정상"
    # nfs-server (Rocky) 또는 nfs-kernel-server (Ubuntu)
    if svc "$h" nfs-server || svc "$h" nfs-kernel-server; then pass "$h: nfs server active"; else failc "$h: nfs server 비정상"; fi
    svc "$h" chronyd && pass "$h: chronyd active" || warnc "$h: chronyd 비정상"
    # 브리지에 host IP
    rexec "$h" "ip -br addr show $BRIDGE 2>/dev/null | grep -q $h" \
      && pass "$h: bridge($BRIDGE) 에 IP 바인딩" || failc "$h: bridge($BRIDGE) IP 없음"
    # cloudstack-agent (기존 KVM skip 시 없을 수 있어 WARN)
    if svc "$h" cloudstack-agent; then pass "$h: cloudstack-agent active"; else warnc "$h: cloudstack-agent 비활성(기존 KVM skip 이면 정상일 수 있음)"; fi
    # 8250 은 "관리서버(.194)"가 여는 agent 포트다. KVM 호스트는 8250 을 열지 않고,
    # cloudstack-agent 가 관리서버 8250 으로 나가는 연결만 한다(netstat 상 host→VM:8250).
    # 따라서 호스트에서는 관리서버 8250 에 "도달 가능한지"를 본다(agent 연결 전제조건).
    rexec "$h" "timeout 3 bash -c 'exec 3<>/dev/tcp/$VM_IP/8250' >/dev/null 2>&1" \
      && pass "$h: 관리서버 agent포트($VM_IP:8250) 도달" \
      || warnc "$h: 관리서버 agent포트($VM_IP:8250) 미도달"
    # exporter 3종 (비필수 → WARN)
    rport "$h" 9100 && pass "$h: node-exporter(9100)" || warnc "$h: node-exporter(9100) 미응답"
    rport "$h" 9256 && pass "$h: process-exporter(9256)" || warnc "$h: process-exporter(9256) 미응답"
    rport "$h" 9177 && pass "$h: libvirt-exporter(9177)" || warnc "$h: libvirt-exporter(9177) 미응답"
  done
}

# ── 관리 VM 검증 ─────────────────────────────────────────────────────────────
verify_mgmt() {
  sec "관리 VM 검증 [$VM_IP]"
  if ! rexec "$VM_IP" 'true'; then failc "$VM_IP: SSH 접속 실패 — 관리 VM 점검 생략"; return; fi
  pass "$VM_IP: SSH 접속"
  svc "$VM_IP" mariadb && pass "$VM_IP: mariadb active" || failc "$VM_IP: mariadb 비정상"
  svc "$VM_IP" cloudstack-management && pass "$VM_IP: cloudstack-management active" || failc "$VM_IP: cloudstack-management 비정상"
  svc "$VM_IP" cloudstack-usage && pass "$VM_IP: cloudstack-usage active" || failc "$VM_IP: cloudstack-usage 비정상"
  rport "$VM_IP" 8080 && pass "$VM_IP: Management UI(8080) listen" || failc "$VM_IP: Management UI(8080) 미응답"
  # 8250 = agent 접속 포트(관리서버가 LISTEN). KVM 호스트가 아니라 여기서 열려야 정상.
  rport "$VM_IP" 8250 && pass "$VM_IP: agent 포트 8250 listen" || warnc "$VM_IP: agent 포트 8250 미응답"
  rport "$VM_IP" 9091 && pass "$VM_IP: Prometheus(9091) listen" || warnc "$VM_IP: Prometheus(9091) 미응답"
  rport "$VM_IP" 3000 && pass "$VM_IP: Grafana(3000) listen" || warnc "$VM_IP: Grafana(3000) 미응답"
  # config.json grafana 반영 (best-effort)
  if rexec "$VM_IP" "grep -qi 'grafana' /etc/cloudstack/management/config.json 2>/dev/null"; then
    pass "$VM_IP: config.json grafanaBase 반영"
  else
    warnc "$VM_IP: config.json grafanaBase 미확인"
  fi
  # 관리 VM 에는 KVM 흔적이 없어야 정상
  rexec "$VM_IP" 'test -e /dev/kvm' && warnc "$VM_IP: /dev/kvm 존재(관리 전용 VM 엔 없어야 정상)" || pass "$VM_IP: KVM 흔적 없음"

  sec "master → 관리 VM 엔드포인트 접속 (외부 도달성)"
  lport "$VM_IP" 8080 && pass "Management UI  http://$VM_IP:8080/client" || failc "Management UI  http://$VM_IP:8080 미접속"
  lport "$VM_IP" 3000 && pass "Grafana        http://$VM_IP:3000"        || warnc "Grafana        http://$VM_IP:3000 미접속"
  lport "$VM_IP" 9091 && pass "Prometheus     http://$VM_IP:9091"        || warnc "Prometheus     http://$VM_IP:9091 미접속"
}

# ── 요약 ─────────────────────────────────────────────────────────────────────
summary() {
  sec "검증 요약"
  echo "  관리 대상 KVM Host: $MASTER_IP (master) $HOST_IPS"
  echo "  관리 VM           : $VM_IP"
  echo "  PASS=$PASS  WARN=$WARNN  FAIL=$FAILN"
  if [[ $FAILN -eq 0 ]]; then
    echo "  ${c_grn}==> 설치 검증 성공 (필수 항목 모두 PASS)${c_rst}"
    [[ $WARNN -gt 0 ]] && echo "  ${c_yel}    WARN 항목은 exporter/모니터링 등 비필수 — 필요 시 개별 확인${c_rst}"
  else
    echo "  ${c_red}==> 검증 실패: FAIL $FAILN 건 — 위 FAIL 항목 조치 필요${c_rst}"
  fi
}

MODE="${1:-all}"
case "$MODE" in
  --hosts) verify_hosts ;;
  --mgmt)  verify_mgmt ;;
  all|"")  verify_hosts; verify_mgmt ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "알 수 없는 옵션: $MODE (--hosts|--mgmt)" ;;
esac
summary
[[ $FAILN -eq 0 ]]
