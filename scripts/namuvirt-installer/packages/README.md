# packages/ — 설치 컨테이너 이미지에 내장되는 패키지

이 디렉터리의 파일은 `build-images.sh` 가 각 Dockerfile 로 이미지에 `COPY` 한다.
고객사는 이 디렉터리를 준비하지 않는다 (패키지는 이미지에 내장되어 반입됨).

빌드 시 패키지 배치 규칙:

- **namuVIRT(CloudStack) RPM** 은 `packages/namuvirt/rocky/` 에 직접 배치한다 (하네스 관리).
  현재 배치됨: `cloudstack-{common,agent,management,usage,ui}-4.22.0.1-1.noarch.rpm`.
- **그 외**(os-packages / monitoring / exporters / vmware-conversion) 는 `build-images.sh` 가
  소스 디렉터리에서 자동 스테이징한다. `--packages-src` 미지정 시 기본값
  `/Users/geontae/workspaces/sample/namuVIRT-work/ansible/packages` 를 사용한다.

```bash
# 기본 소스에서 스테이징
./build-images.sh --version 1.0.0
# 다른 소스에서 스테이징
./build-images.sh --version 1.0.0 --packages-src /path/to/namuVIRT-packages
```

> Ubuntu 호스트용 `packages/namuvirt/ubuntu/*.deb` 는 아직 없다. Ubuntu Cluster 를 설치하면
> `namuvirt-agent` 는 WARN-skip 된다 (deb 산출물 확보 후 배치하면 자동 설치됨).

## 구조

```
packages/
  namuvirt/
    rocky/       cloudstack-{common,agent,management,usage,ui}-*.rpm
    ubuntu/      cloudstack-{common,agent}-*.deb
  os-packages/
    rocky/       그룹별 rpm 디렉터리 (아래 그룹 참고)
    ubuntu/      그룹별 deb 디렉터리
  monitoring/
    common/      prometheus-*.linux-amd64.tar.gz   (OS 무관)
    rocky/       grafana-*-1.x86_64.rpm
    ubuntu/      grafana_*_amd64.deb
  exporters/     node_exporter-*, process-exporter-*, prometheus-libvirt-exporter-*  (.tar.gz)
  vmware-conversion/   (선택) virt-v2v / nbdkit / VDDK 등
```

## os-packages 그룹 (레포 없이 직접 설치하므로 의존성까지 포함)

각 OS 아래에 그룹 디렉터리를 만들고 해당 그룹 + 의존 패키지를 모두 넣는다.

| 그룹 | 용도 | 대상 |
|------|------|------|
| `qemu-kvm` | qemu-kvm/core | KVM Host (기존 KVM 있으면 skip) |
| `libvirt` | libvirt daemon/client | KVM Host (기존 KVM 있으면 skip) |
| `network` | iproute/iptables/ebtables/arptables | KVM Host |
| `nfs` | nfs-utils / nfs-kernel-server, rpcbind | Host / 관리 VM |
| `iscsi` | iscsi-initiator-utils / open-iscsi | KVM Host |
| `vm-tools` | virt-install/genisoimage | KVM Host |
| `java` | java-17-openjdk-headless | Host + 관리 VM |
| `mariadb` | mariadb-server | 관리 VM |
| `chrony` | chrony | KVM Host |
| `utils` | curl/wget/tar/bzip2 | Host + 관리 VM |

- Rocky Host 는 `os-packages/rocky/<그룹>/*.rpm` 을 dnf 로 설치한다.
- Ubuntu 24.04 Host 는 `os-packages/ubuntu/<그룹>/*.deb` 을 dpkg 로 설치한다.
- 관리 VM(항상 Rocky 8)은 `nfs/java/mariadb/utils` 그룹만 사용한다.

> 협의: 컨테이너 이미지 포함 패키지에 대한 SHA256 검증은 수행하지 않는다.
> 릴리즈 bundle 자체는 `SHA256SUMS` 로 무결성 검증한다.
