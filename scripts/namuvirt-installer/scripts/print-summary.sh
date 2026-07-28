#!/usr/bin/env bash
# print-summary.sh — 설치 결과 요약 출력 + logs/summary-<ts>.txt 기록 (호스트 측 실행).
#
# 사용법:
#   print-summary.sh --status <success|failed> --log-dir <dir> --config <config.yaml> \
#                    [--summary-file <path>] [--install-log <path>]
#
# 요약 항목: 성공/실패, 관리 VM IP, Management UI / Grafana / Prometheus URL,
#            관리 대상 KVM Host 목록(kvm.master 포함), 로그 파일 경로.
set -Eeuo pipefail

STATUS="unknown"
LOG_DIR="./logs"
CONFIG_FILE="./config.yaml"
SUMMARY_FILE=""
INSTALL_LOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)       STATUS="$2"; shift 2 ;;
    --log-dir)      LOG_DIR="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --install-log)  INSTALL_LOG="$2"; shift 2 ;;
    *) echo "print-summary: 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$SUMMARY_FILE" ]] && SUMMARY_FILE="$LOG_DIR/summary-$(date +%Y%m%d-%H%M%S).txt"

# config 에서 값 추출 (python3+yaml 우선, 없으면 grep 폴백)
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  eval "$(python3 - "$CONFIG_FILE" <<'PY'
import sys, yaml, shlex
cfg = yaml.safe_load(open(sys.argv[1])) or {}
kvm = cfg.get("kvm") or {}
mgmt = cfg.get("management") or {}
master = kvm.get("master")
master_ip = master.get("ip") if isinstance(master, dict) else master
hosts = []
for h in (kvm.get("hosts") or []):
    hosts.append(h.get("ip") if isinstance(h, dict) else h)
print(f"VM_IP={shlex.quote(str(mgmt.get('vm_ip','')))}")
print(f"CLUSTER_OS={shlex.quote(str(kvm.get('os','')))}")
print(f"MASTER_IP={shlex.quote(str(master_ip or ''))}")
print(f"HOST_IPS={shlex.quote(' '.join(str(x) for x in hosts if x))}")
PY
)"
else
  VM_IP="$(awk '/^[[:space:]]+vm_ip:/{sub(/^[^:]*:[[:space:]]*/,"");gsub(/[[:space:]]/,"");print;exit}' "$CONFIG_FILE")"
  CLUSTER_OS="$(bash "$(dirname "$0")/detect-host-os.sh" "$CONFIG_FILE" 2>/dev/null || echo "")"
  MASTER_IP=""; HOST_IPS=""
fi

UI_URL="http://${VM_IP}:8080/client"
GRAFANA_URL="http://${VM_IP}:3000"
PROM_URL="http://${VM_IP}:9091"

# 관리 대상 Host 목록 (master 를 항상 맨 앞에)
managed_hosts="${MASTER_IP:+$MASTER_IP (master)}"
for ip in $HOST_IPS; do managed_hosts+=$'\n'"    - $ip"; done

{
  echo "============================================================"
  echo " namuVIRT 설치 요약"
  echo "============================================================"
  echo " 결과            : $STATUS"
  echo " Cluster OS      : ${CLUSTER_OS:-?}"
  echo " 관리 VM IP      : ${VM_IP:-?}"
  echo " Management UI   : $UI_URL"
  echo " Grafana         : $GRAFANA_URL"
  echo " Prometheus      : $PROM_URL"
  echo " 관리 대상 KVM Host:"
  echo "    - ${MASTER_IP:-?} (master)"
  for ip in $HOST_IPS; do echo "    - $ip"; done
  echo " 로그 디렉터리   : $LOG_DIR"
  [[ -n "$INSTALL_LOG" ]] && echo " 설치 로그       : $INSTALL_LOG"
  if [[ "$STATUS" != "success" && -n "$INSTALL_LOG" && -f "$INSTALL_LOG" ]]; then
    echo " 실패 task 요약  :"
    grep -E 'fatal:|failed=|FAILED' "$INSTALL_LOG" 2>/dev/null | tail -20 | sed 's/^/    /' || true
  fi
  echo "============================================================"
} | tee "$SUMMARY_FILE"

echo "요약 저장: $SUMMARY_FILE" >&2
