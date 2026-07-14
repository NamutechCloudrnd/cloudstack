# namuvirt-management-setup — 관리 VM 생성 + 관리 VM 내부 설치 컨테이너 (Ansible controller).
#
# 빌드 컨텍스트는 하네스 루트(installer-harness/)이다.
#   docker build -f docker/management/Dockerfile -t namuvirt-management-setup:<ver> .
#
# 역할:
#   - kvm.master 에 SSH 로 접속해 Rocky 8 관리 VM 을 virt-install 로 생성
#   - 관리 VM 내부에 namuvirt-management/usage/ui, MariaDB, Prometheus, Grafana 설치
#   - /etc/cloudstack/management/config.json 의 grafanaBaseUrl 설정
# 관리 VM 은 항상 Rocky 8 이므로 Rocky 패키지 + monitoring 패키지를 내장한다.
FROM python:3.12-slim

ARG VERSION=dev
ARG CREATED=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.title="namuvirt-management-setup" \
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

# 관리 VM(Rocky 8) 에 필요한 패키지 내장 (offline)
COPY packages/os-packages/rocky/    /opt/namuvirt-installer/packages/os-packages/rocky/
COPY packages/namuvirt/rocky/       /opt/namuvirt-installer/packages/namuvirt/rocky/
COPY packages/monitoring/           /opt/namuvirt-installer/packages/monitoring/
COPY packages/exporters/            /opt/namuvirt-installer/packages/exporters/

RUN chmod +x /opt/namuvirt-installer/scripts/*.sh \
 && mkdir -p /opt/namuvirt-installer/work /opt/namuvirt-installer/logs

CMD ["/opt/namuvirt-installer/scripts/run-ansible.sh", "--help"]
