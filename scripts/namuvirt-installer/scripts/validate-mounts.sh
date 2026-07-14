#!/usr/bin/env bash
# validate-mounts.sh — 외부 mount 파일 존재/권한 검증 (컨테이너 내부에서 실행).
#
# 검증 항목:
#   - /mnt/namuvirt/config.yaml
#   - SSH private key (config.yaml 의 ssh_private_key_path) 존재 + 안전 권한
#   - management.rocky_cloudimg / management.systemvm_template 존재
#   - /mnt/namuvirt/logs 쓰기 가능
set -Eeuo pipefail

CONFIG_FILE="${1:-/mnt/namuvirt/config.yaml}"
LOG_DIR="${2:-/mnt/namuvirt/logs}"
rc=0

fail() { echo "  - $1" >&2; rc=1; }

echo "외부 mount 검증:"

# config.yaml
if [[ -f "$CONFIG_FILE" ]]; then
  echo "  OK  config.yaml: $CONFIG_FILE"
else
  fail "config.yaml 누락: $CONFIG_FILE"
  echo "mount 검증 실패" >&2
  exit 1
fi

# config 에서 경로 추출
read -r SSH_KEY CLOUDIMG SYSVM < <(python3 - "$CONFIG_FILE" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
mgmt = cfg.get("management") or {}
print(
    cfg.get("ssh_private_key_path", "/mnt/namuvirt/ssh/id_ed25519"),
    mgmt.get("rocky_cloudimg", "/mnt/namuvirt/images/NAMU-Rocky-8-10.qcow2"),
    mgmt.get("systemvm_template", "/mnt/namuvirt/images/SystemVM-Template-KVM.qcow2"),
)
PY
)

# SSH private key + 권한
if [[ -f "$SSH_KEY" ]]; then
  perm=$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%Lp' "$SSH_KEY")
  echo "  OK  SSH key: $SSH_KEY (perm $perm)"
  # 0600/0400 이 아니면 경고 (그룹/기타 읽기 권한 존재)
  case "$perm" in
    600|400) ;;
    *) echo "  WARN SSH key 권한이 느슨하다($perm) — 600 권장" >&2 ;;
  esac
else
  fail "SSH private key 누락: $SSH_KEY (ssh/ 디렉터리 mount 확인)"
fi

# cloud image
if [[ -f "$CLOUDIMG" ]]; then
  echo "  OK  Rocky cloud image: $CLOUDIMG"
else
  fail "Rocky cloud image 누락: $CLOUDIMG (images/ mount 확인)"
fi

# SystemVM template
if [[ -f "$SYSVM" ]]; then
  echo "  OK  SystemVM template: $SYSVM"
else
  fail "SystemVM template 누락: $SYSVM (images/ mount 확인)"
fi

# logs 쓰기 가능
if [[ -d "$LOG_DIR" ]] && touch "$LOG_DIR/.writetest.$$" 2>/dev/null; then
  rm -f "$LOG_DIR/.writetest.$$"
  echo "  OK  logs 쓰기 가능: $LOG_DIR"
else
  fail "logs 디렉터리에 쓸 수 없다: $LOG_DIR"
fi

if [[ $rc -ne 0 ]]; then
  echo "mount 검증 실패" >&2
fi
exit $rc
