#!/usr/bin/env bash
# validate-config.sh — config.yaml 스키마/규칙 검증 (컨테이너 내부에서 실행).
#
# 검증 항목:
#   - YAML 문법
#   - 필수 key: ssh_user, kvm.os, kvm.master(.ip), management.vm_ip
#   - kvm.os 값이 rocky/ubuntu 인지
#   - kvm.master 가 kvm.hosts 에 중복 기재되지 않았는지
#   - kvm.hosts 항목의 os 표기가 kvm.os 와 다르지 않은지 (혼합 Cluster 거부)
#
# stdout 마지막 줄에 `cluster_os=<rocky|ubuntu>` 를 출력한다 (호출자가 파싱).
set -Eeuo pipefail

CONFIG_FILE="${1:-/mnt/namuvirt/config.yaml}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.yaml 을 찾을 수 없다: $CONFIG_FILE" >&2
  exit 1
fi

python3 - "$CONFIG_FILE" <<'PY'
import sys, yaml

path = sys.argv[1]
errors = []

try:
    with open(path) as f:
        cfg = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"ERROR: YAML 문법 오류: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(cfg, dict):
    print("ERROR: config.yaml 최상위가 매핑(mapping)이 아니다.", file=sys.stderr)
    sys.exit(1)

def req(cond, msg):
    if not cond:
        errors.append(msg)

req(cfg.get("ssh_user"), "필수 key 누락: ssh_user")

kvm = cfg.get("kvm") or {}
req("os" in kvm, "필수 key 누락: kvm.os")
req(kvm.get("master"), "필수 key 누락: kvm.master")

cluster_os = str(kvm.get("os", "")).lower()
req(cluster_os in ("rocky", "ubuntu"),
    f"kvm.os 값이 잘못되었다: '{kvm.get('os')}'. rocky 또는 ubuntu 만 허용한다.")

master = kvm.get("master")
if isinstance(master, dict):
    master_ip = master.get("ip")
else:
    master_ip = master
req(master_ip, "필수 key 누락: kvm.master.ip")

hosts = kvm.get("hosts") or []
host_ips = []
for h in hosts:
    if isinstance(h, dict):
        host_ips.append(h.get("ip"))
        h_os = h.get("os")
        if h_os is not None and str(h_os).lower() != cluster_os:
            errors.append(
                f"혼합 Cluster 거부: kvm.os={cluster_os} 인데 host {h.get('ip')} 의 os={h_os}")
    else:
        host_ips.append(h)

if master_ip and master_ip in host_ips:
    errors.append(
        f"kvm.master({master_ip}) 가 kvm.hosts 에 중복 기재되었다. master 는 자동 포함되므로 제거할 것.")

mgmt = cfg.get("management") or {}
req(mgmt.get("vm_ip"), "필수 key 누락: management.vm_ip")

if errors:
    print("config.yaml 검증 실패:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print("config.yaml 검증 통과")
print(f"cluster_os={cluster_os}")
PY
