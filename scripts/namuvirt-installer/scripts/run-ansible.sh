#!/usr/bin/env bash
# run-ansible.sh — 설치 컨테이너 내부 엔트리포인트.
#
# install-namuvirt.sh 가 docker run 으로 이 스크립트를 호출한다.
# 컨테이너 표준 경로:
#   /opt/namuvirt-installer/ansible   (site.yml, preflight.yml, roles)
#   /opt/namuvirt-installer/scripts   (검증 스크립트)
#   /mnt/namuvirt/config.yaml         (mount)
#   /mnt/namuvirt/logs                (mount, 로그 출력)
#
# 사용법:
#   run-ansible.sh --syntax-check
#   run-ansible.sh --preflight
#   run-ansible.sh install
#   run-ansible.sh --tags kvm_hosts|management|monitoring|storage|agent
set -Eeuo pipefail

INSTALLER_ROOT="/opt/namuvirt-installer"
ANSIBLE_DIR="$INSTALLER_ROOT/ansible"
SCRIPTS_DIR="$INSTALLER_ROOT/scripts"
CONFIG_FILE="/mnt/namuvirt/config.yaml"
LOG_DIR="/mnt/namuvirt/logs"

export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
CONFIG_EXTRA=(-e "namuvirt_config_file=$CONFIG_FILE")

# sudo NOPASSWD 가 없는 환경: install-namuvirt.sh -K 로 받은 sudo 비밀번호를
# NAMUVIRT_BECOME_PASS 환경변수로 전달받아, become-password-file 로 ansible 에 넘긴다.
# (argv 에 노출되지 않도록 0600 임시파일 사용. 컨테이너는 --rm 이라 종료 시 파일도 사라짐.)
BECOME_ARGS=()
if [[ -n "${NAMUVIRT_BECOME_PASS:-}" ]]; then
  _bpf="$(mktemp)"; chmod 600 "$_bpf"
  printf '%s' "$NAMUVIRT_BECOME_PASS" > "$_bpf"
  unset NAMUVIRT_BECOME_PASS
  BECOME_ARGS=(--become-password-file "$_bpf")
fi

cd "$ANSIBLE_DIR"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

mode="${1:-}"; shift || true

case "$mode" in
  --syntax-check)
    exec ansible-playbook --syntax-check "${CONFIG_EXTRA[@]}" site.yml
    ;;

  --preflight)
    # 1) config 스키마 + mount 파일 (컨테이너 로컬 검증)
    bash "$SCRIPTS_DIR/validate-config.sh" "$CONFIG_FILE"
    bash "$SCRIPTS_DIR/validate-mounts.sh" "$CONFIG_FILE" "$LOG_DIR"
    # 2) 원격 검증 (SSH/sudo/OS/dev-kvm)
    exec ansible-playbook "${CONFIG_EXTRA[@]}" "${BECOME_ARGS[@]}" preflight.yml "$@"
    ;;

  install)
    # 전체 설치 (site.yml 순서대로)
    exec ansible-playbook "${CONFIG_EXTRA[@]}" "${BECOME_ARGS[@]}" site.yml "$@"
    ;;

  --tags)
    tags="${1:?--tags 뒤에 대상 태그가 필요하다 (kvm_hosts|management|monitoring|storage|agent)}"
    shift || true
    # 각 컨테이너가 자기 대상 호스트만 건드리도록 --limit 을 건다.
    # site.yml 은 관리 VM play 를 포함하는데, --tags 만 걸면 그 play 의 gather_facts 가
    # 아직 생성되지 않은 관리 VM 에 SSH 를 시도해 unreachable 로 전체 실행이 실패한다.
    # localhost(load_config) 는 항상 포함해야 동적 인벤토리가 구성된다.
    case "$tags" in
      kvm_hosts|storage|agent) limit="localhost,kvm_hosts" ;;
      management|monitoring)   limit="localhost,kvm_master,management_vm" ;;
      *)                       limit="all" ;;
    esac
    exec ansible-playbook "${CONFIG_EXTRA[@]}" "${BECOME_ARGS[@]}" site.yml --tags "$tags" --limit "$limit" "$@"
    ;;

  -h|--help|"")
    usage
    ;;

  *)
    echo "ERROR: 알 수 없는 모드: $mode" >&2
    usage >&2
    exit 2
    ;;
esac
