# namuvirt-host-setup-rocky — Rocky 8 KVM Host 설치 컨테이너 (Ansible controller).
#
# 빌드 컨텍스트는 하네스 루트(installer-harness/)이다.
#   docker build -f docker/host-rocky/Dockerfile -t namuvirt-host-setup-rocky:<ver> .
#
# 컨테이너는 대상 KVM Host 에 SSH 로 접속해 KVM/libvirt/agent/exporter 를 구성한다.
# 실제 rpm 은 대상 호스트로 전송되어 dnf 로 설치되므로, 컨테이너는 controller 역할만 한다.
FROM python:3.12-slim

ARG VERSION=dev
ARG CREATED=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.title="namuvirt-host-setup-rocky" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

ENV DEBIAN_FRONTEND=noninteractive \
    ANSIBLE_CONFIG=/opt/namuvirt-installer/ansible/ansible.cfg

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client ca-certificates bzip2 tar \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "ansible-core>=2.16,<2.17" pyyaml

WORKDIR /opt/namuvirt-installer

# Ansible playbook/roles + 검증/실행 스크립트
COPY ansible/ /opt/namuvirt-installer/ansible/
COPY scripts/ /opt/namuvirt-installer/scripts/

# Rocky Host 에 필요한 패키지만 내장 (offline)
COPY packages/os-packages/rocky/    /opt/namuvirt-installer/packages/os-packages/rocky/
COPY packages/namuvirt/rocky/       /opt/namuvirt-installer/packages/namuvirt/rocky/
COPY packages/exporters/            /opt/namuvirt-installer/packages/exporters/
COPY packages/vmware-conversion/    /opt/namuvirt-installer/packages/vmware-conversion/

RUN chmod +x /opt/namuvirt-installer/scripts/*.sh \
 && mkdir -p /opt/namuvirt-installer/work /opt/namuvirt-installer/logs

CMD ["/opt/namuvirt-installer/scripts/run-ansible.sh", "--help"]
