# namuvirt-host-setup-ubuntu — Ubuntu 24.04 KVM Host 설치 컨테이너 (Ansible controller).
#
# 빌드 컨텍스트는 하네스 루트(installer-harness/)이다.
#   docker build -f docker/host-ubuntu/Dockerfile -t namuvirt-host-setup-ubuntu:<ver> .
#
# 컨테이너는 대상 KVM Host 에 SSH 로 접속해 KVM/libvirt/agent/exporter 를 구성한다.
# 실제 deb 는 대상 호스트로 전송되어 dpkg 로 설치되므로, 컨테이너는 controller 역할만 한다.
FROM python:3.12-slim

ARG VERSION=dev
ARG CREATED=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.title="namuvirt-host-setup-ubuntu" \
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

COPY ansible/ /opt/namuvirt-installer/ansible/
COPY scripts/ /opt/namuvirt-installer/scripts/

# Ubuntu 24.04 Host 에 필요한 패키지만 내장 (offline)
COPY packages/os-packages/ubuntu/   /opt/namuvirt-installer/packages/os-packages/ubuntu/
COPY packages/namuvirt/ubuntu/      /opt/namuvirt-installer/packages/namuvirt/ubuntu/
COPY packages/exporters/            /opt/namuvirt-installer/packages/exporters/
COPY packages/vmware-conversion/    /opt/namuvirt-installer/packages/vmware-conversion/

RUN chmod +x /opt/namuvirt-installer/scripts/*.sh \
 && mkdir -p /opt/namuvirt-installer/work /opt/namuvirt-installer/logs

CMD ["/opt/namuvirt-installer/scripts/run-ansible.sh", "--help"]
