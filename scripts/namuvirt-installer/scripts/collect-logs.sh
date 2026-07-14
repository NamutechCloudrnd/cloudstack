#!/usr/bin/env bash
# collect-logs.sh — 설치 로그를 하나의 tar.gz 로 묶는다 (호스트 측 실행).
#
# 지원 엔지니어에게 전달할 로그 번들을 만든다:
#   logs/*.log, logs/*.txt → logs/namuvirt-logs-<timestamp>.tar.gz
set -Eeuo pipefail

LOG_DIR="${1:-./logs}"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "ERROR: logs 디렉터리가 없다: $LOG_DIR" >&2
  exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"
bundle="$LOG_DIR/namuvirt-logs-$ts.tar.gz"

# 번들 자기 자신은 제외하고 로그/요약만 수집
shopt -s nullglob
files=("$LOG_DIR"/*.log "$LOG_DIR"/*.txt)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "수집할 로그가 없다: $LOG_DIR/*.log|*.txt" >&2
  exit 0
fi

tar -czf "$bundle" -C "$LOG_DIR" $(printf '%s\n' "${files[@]}" | xargs -n1 basename)
echo "로그 번들 생성: $bundle"
echo "포함 파일 ${#files[@]}개:"
printf '  %s\n' "${files[@]##*/}"
