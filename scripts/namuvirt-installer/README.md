# namuVIRT 설치 하네스 (installer-harness)

`install-namuvirt.sh` 하나로 namuVIRT(CloudStack 기반)를 설치하는 **Docker container 기반** 설치 하네스.
설치 로직은 컨테이너 이미지 안의 Ansible playbook 이 수행하고, 고객사는 호스트에 Python/Ansible/패키지를 직접 설치하지 않는다.

> 📖 상세 문서
> - **[BUILD-GUIDE.md](BUILD-GUIDE.md)** — 릴리스 번들 제작(패키지 다운로드 → 빌드 → export), 제작자용
> - **[INSTALL-GUIDE.md](INSTALL-GUIDE.md)** — 고객사 설치(반입 → prepare → install), 지원 OS·사양·옵션 상세
>
> 이 README 는 요약이며, 옵션·사양·사전준비 상세는 위 두 가이드를 참조한다.

## 1. 두 가지 사용 흐름

### (A) 개발/릴리즈 (이미지 빌드 → 폐쇄망 반입 bundle 생성)

```bash
# 1) 이미지 3종 빌드 (온라인 개발 환경). 실제 패키지는 --packages-src 로 스테이징.
./build-images.sh --version 1.0.0 --packages-src /path/to/namuVIRT-packages

# 2) 고객사 반입용 bundle 생성 (image tar + SHA256SUMS)
./export-images.sh --version 1.0.0 --output release/namuvirt-installer-1.0.0
```

산출물 `release/namuvirt-installer-1.0.0/` 을 USB 등으로 폐쇄망에 반입한다(협의: USB 반입).

### (B) 고객사 설치 (kvm.master 에서 실행)

```bash
cd namuvirt-installer-1.0.0
sha256sum -c SHA256SUMS          # 무결성 검증
vi config.yaml                   # config.sample.yaml 복사 후 환경값만 수정
# 외부 mount 배치: ssh/id_ed25519, images/<cloud image>, images/<systemvm template>
./install-namuvirt.sh --load-images   # image-tar/*.tar 적재
./install-namuvirt.sh --preflight     # 설치 전 검증 (mutation 없음)
./install-namuvirt.sh install         # 전체 설치
```

## 2. 명령

```bash
./install-namuvirt.sh --help
./install-namuvirt.sh --load-images        # image-tar/*.tar → docker load
./install-namuvirt.sh --preflight          # 로컬 + 원격 검증만
./install-namuvirt.sh install              # KVM Hosts → Management 전체 설치
./install-namuvirt.sh --tags kvm_hosts     # 단계별: KVM Host 만
./install-namuvirt.sh --tags management    # 단계별: Management 만
./install-namuvirt.sh --tags monitoring    # 단계별: 모니터링 만
./install-namuvirt.sh collect-logs         # logs/ 를 tar.gz 로 수집
```

## 3. config.yaml

`config.sample.yaml` 을 복사해 환경값만 수정한다. 핵심 규칙:

- `kvm.os` 로 Cluster 전체 OS 를 지정한다 (`rocky` 또는 `ubuntu`). **혼합 Cluster 미지원.**
- `kvm.master` 는 관리 VM 을 올릴 물리 KVM Host 이며 **관리 대상에 자동 포함**된다.
- `kvm.master` 를 `kvm.hosts` 에 **중복 기재하지 않는다** (preflight 에서 거부).
- `packages_dir` 는 적지 않는다 (패키지는 이미지 내장).

지원 KVM Host OS: **Rocky 8**, **Ubuntu 24.04**. 관리 VM 은 항상 **Rocky 8**.

## 4. 외부 mount (고객사 준비 파일)

```
namuvirt-installer/
  install-namuvirt.sh
  config.yaml
  images/
    Rocky-8-GenericCloud-Base.latest.x86_64.qcow2
    systemvmtemplate-4.22.0-x86_64-kvm.qcow2.bz2
  ssh/
    id_ed25519          (perm 600 권장)
    id_ed25519.pub
  logs/
  image-tar/
    namuvirt-management-setup_<ver>.tar
    namuvirt-host-setup-rocky_<ver>.tar
    namuvirt-host-setup-ubuntu_<ver>.tar
```

컨테이너 mount 지점: `/mnt/namuvirt/{config.yaml,ssh,images,logs}`.
이미지에는 SSH key / config.yaml / cloud image / template 를 **넣지 않는다.**

## 5. preflight 검증 항목

**로컬(호스트):** Docker Engine 실행 · Compose plugin · 이미지 존재 · config.yaml · kvm.os · SSH key 존재/권한 · cloud image/template 존재 · logs 쓰기.
**원격(컨테이너 내 Ansible):** SSH 접속 · sudo NOPASSWD · OS(Rocky 8 / Ubuntu 24.04) · 동일 OS Cluster · `/dev/kvm` · NIC/gateway · 기존 libvirt domain 경고.

preflight 실패 시 설치를 시작하지 않고 실패 Host/항목을 로그와 콘솔에 출력한다.

## 6. 실행 아키텍처 (핵심 설계)

- **모든 대상(master 포함)에 SSH 접속**한다. 컨테이너는 throwaway 이므로 local 접속을 쓰지 않는다.
  `kvm.master` 도 자기 IP 로 SSH 하여 물리 호스트를 구성하고, 관리 VM 은 master 에서 `virt-install` 로 생성된다.
- **이미지 선택**: `install-namuvirt.sh` 가 `kvm.os` 를 읽어 `namuvirt-host-setup-rocky|ubuntu` 를 고른다.
  Management 는 항상 `namuvirt-management-setup`.
- **설치 순서**: preflight → `--tags kvm_hosts`(host 이미지) → `--tags management`(management 이미지) → 요약.
- **협의 반영**:
  - 기존 KVM 이 있으면 qemu-kvm/libvirt 설치는 skip 하고 관리 바이너리만 설치.
  - 기존 VM 이 있으면 삭제하지 않고 "namuVIRT UI 에서 import" 안내를 남김.
  - VMware 변환 도구 포함(옵션 `kvm_enable_vmware_conversion`).
  - CloudStack Zone/Pod/Cluster/Host/Storage 등록은 UI 별도 운영 절차.

## 7. 로그와 요약

```
logs/
  install-YYYYMMDD-HHMMSS.log
  preflight-YYYYMMDD-HHMMSS.log
  ansible-<tag>-YYYYMMDD-HHMMSS.log
  summary-YYYYMMDD-HHMMSS.txt
```

요약에는 성공/실패, 관리 VM IP, Management UI(:8080/client)/Grafana(:3000)/Prometheus(:9091) URL,
관리 대상 KVM Host 목록(`kvm.master` 포함), 실패 task 요약, 로그 경로가 포함된다.

## 7.5 OS 이미지 / SystemVM 템플릿 업로드 (설치와 분리된 별도 도구)

골든 이미지·SystemVM 템플릿 업로드는 **설치와 무관한 독립 스크립트** `upload-os-image.sh` 로 수행한다.
이 스크립트는 `config.yaml` 의 `management.vm_ip` 로 SSH 접속해 관리 VM 의 `cmk`(CloudMonkey)로 등록한다.
(그래서 install 흐름에는 systemvm/golden 업로드가 포함되지 않는다.)

```bash
# cmk 연결 확인 (관리 VM 에 cmk 설치·설정 전제: cmk set url/username/apikey; cmk sync)
./upload-os-image.sh check

# 게스트 OS 골든 이미지 등록
./upload-os-image.sh register \
    --name "Rocky8-golden" --url "http://10.10.10.3/images/rocky8.qcow2" \
    --ostype 245 --zone 1 [--format QCOW2] [--hypervisor KVM] [--displaytext "..."]

# SystemVM 템플릿 등록
./upload-os-image.sh register-systemvm \
    --name "systemvm-4.22" --url "http://10.10.10.3/images/systemvm.qcow2.bz2" --zone 1

# 등록 상태 확인 (isready)
./upload-os-image.sh list
```

환경별 추가 파라미터는 `--` 뒤에 `key=value` 로 pass-through 한다 (예: `-- account=admin projectid=...`).

## 8. 설치 후 운영 (협의: 운영 도구 제공)

Management VM:
```bash
systemctl {start|stop|restart|status} cloudstack-management cloudstack-usage
journalctl -u cloudstack-management -f
```
KVM Host: `namuvirt-agent` / `libvirtd` / exporter 3종(node:9100, process:9256, libvirt:9177) 상태 확인.

## 9. 재설치 / 롤백 / 리셋 (협의: 절차 제공 필요)

파괴적 reset/wipe 는 기본 명령에 포함하지 않는다(안전). 재설치 절차:
1. `./install-namuvirt.sh --tags <단계>` 로 실패 단계만 재실행.
2. 관리 VM 재생성이 필요하면 master 에서 `virsh destroy/undefine <vm_name>` 후 `--tags management`.
3. 전체 리셋 전용 스크립트는 명시 요청 시 별도 제공(현재 미포함).

## 10. 개발자용 로컬 검증

```bash
make lint      # 모든 bash 스크립트 bash -n
make syntax    # ansible-playbook --syntax-check (로컬 ansible 필요)
```

## 11. 디렉터리 구조

```
installer-harness/
  install-namuvirt.sh       고객 엔트리포인트 (호스트 측)
  build-images.sh            이미지 빌드
  export-images.sh           릴리즈 bundle 생성
  Makefile                   build/export/syntax/lint/clean
  config.sample.yaml         config 계약 샘플
  docker/{management,host-rocky,host-ubuntu}/Dockerfile
  ansible/                   site.yml, preflight.yml, ansible.cfg, roles/
  packages/                  이미지 내장 패키지 (packages/README.md 참고)
  scripts/                   validate-config/validate-mounts/detect-host-os/
                             run-ansible/collect-logs/print-summary
  release/                   manifest.yaml, checksums/
```
