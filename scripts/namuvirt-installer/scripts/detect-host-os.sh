#!/usr/bin/env bash
# detect-host-os.sh — config.yaml 의 kvm.os 를 읽어 rocky/ubuntu 를 stdout 으로 출력한다.
#
# install-namuvirt.sh 가 어느 host-setup 이미지를 실행할지 고르는 데 사용한다 (호스트 측 실행).
# python3+PyYAML 이 있으면 그것을 쓰고, 없으면 간단한 grep 파서로 폴백한다.
set -Eeuo pipefail

CONFIG_FILE="${1:-./config.yaml}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.yaml 을 찾을 수 없다: $CONFIG_FILE" >&2
  exit 1
fi

os=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  os="$(python3 - "$CONFIG_FILE" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
print(str(((cfg.get("kvm") or {}).get("os") or "")).lower())
PY
)"
else
  # 폴백: 'kvm:' 블록 안의 'os:' 첫 줄을 읽는다.
  os="$(awk '
    /^[[:space:]]*kvm:[[:space:]]*$/ {inkvm=1; next}
    inkvm && /^[^[:space:]]/ {inkvm=0}
    inkvm && /^[[:space:]]+os:[[:space:]]*/ {
      sub(/^[[:space:]]+os:[[:space:]]*/, ""); gsub(/[",[:space:]]/, "");
      print tolower($0); exit
    }
  ' "$CONFIG_FILE")"
fi

case "$os" in
  rocky|ubuntu) echo "$os" ;;
  *)
    echo "ERROR: kvm.os 값이 rocky/ubuntu 가 아니다: '${os:-<빈값>}'" >&2
    exit 1
    ;;
esac
