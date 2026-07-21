# namuVIRT Install Guide (고객사 설치)

이 문서는 반입한 번들(`namuvirt-installer-<version>/`)로 **kvm.master 서버에서** namuVIRT 를 설치하는 전 과정을 다룬다.
흐름은 **반입/검증 → Docker → 이미지 로드 → prepare → preflight → install → verify** 다.

> 번들 제작(패키지 다운로드/빌드/export)은 [BUILD-GUIDE.md](BUILD-GUIDE.md) 를 참고한다(제작자용).

---

## 0. 전체 흐름 한눈에

```
[kvm.master 서버 — 폐쇄망]
  ① USB 반입 + sha256sum -c SHA256SUMS         # 무결성
  ② sudo ./install-docker.sh                   # Docker(+compose) + docker 그룹
  ③ ./install-namuvirt.sh --load-images       # 설치 이미지 3종 load
  ④ ./prepare-install.sh                        # config.yaml + SSH 키 배포 + 점검
  ⑤ ./install-namuvirt.sh --preflight          # 설치 전 검증(변경 없음)
  ⑥ ./install-namuvirt.sh install              # KVM Hosts → 관리 VM 설치
  ⑦ ./verify-install.sh                         # 설치 후 검증
  ⑧ (설치 후) 템플릿 등록 콘솔  ./upload-os-image.sh   # §12 — infra/seed-systemvm/register
```

> ⑧ 템플릿 등록은 설치와 분리된 운영 작업이다. 번들의 대화형 콘솔 **`./upload-os-image.sh`** 로
> **SystemVM(`6) seed-systemvm`)** 과 **게스트(`4) register`)** 를 등록한다 — 상세는 **§12** 및
> **[UPLOAD-OS-IMAGE.md](UPLOAD-OS-IMAGE.md)**.

---

## 1. 지원 OS 및 시스템 사양

### 1.1 지원 OS

| 대상 | 지원 OS | 비고 |
|------|---------|------|
| **KVM Host** (master + hosts) | **Rocky Linux 8**, **Ubuntu 24.04 LTS** | Cluster 전체가 **동일 OS** 여야 함 (Rocky/Ubuntu 혼합 불가) |
| **관리 VM** | **Rocky Linux 8** (고정) | kvm.master 위에 자동 생성 |

- 아키텍처: **64-bit x86_64** 전용.
- KVM Host 는 CPU 가상화(**Intel VT-x / AMD-V**)를 BIOS 에서 활성화하고 `/dev/kvm` 이 존재해야 한다.

### 1.2 KVM Host (하이퍼바이저) 사양

| 구분 | 최소 | 권장 | 비고 |
|------|------|------|------|
| CPU | 64-bit x86, VT-x/AMD-V, 4 core | 16 core+ | 게스트 vCPU 총합 + 오버커밋 고려 |
| 메모리 | 8 GB | 64 GB+ | 관리 VM(16GB) + 게스트 메모리 합 이상 |
| 로컬 디스크 | 40 GB (OS) | + primary/secondary 스토리지 용량 | `/export/primary`,`/export/secondary` 또는 별도 볼륨 |
| NIC | 1 | 2+ (관리/스토리지 분리) | 관리 대역 + bridge(cloudbr0) |

> master 는 KVM Host 역할 + 관리 VM 호스팅 + 설치 컨테이너 실행을 겸하므로 **가장 여유 있게** 잡는다
> (최소 8 core / 32 GB / 관리 VM 200GB 디스크 + 스토리지).

### 1.3 관리 VM (namuVIRT 관리/DB/모니터링) 사양

관리 VM 사양은 `config.yaml` 의 `management.vm_vcpus / vm_ram_mb / vm_disk_gb` 로 지정한다.

| 구분 | 최소 | 기본(권장) | 대규모 |
|------|------|-----------|--------|
| vCPU | 2 | **8** | 16 |
| 메모리 | 4 GB | **16 GB** | 32 GB |
| 디스크 | 40 GB | **200 GB** | 500 GB+ |

- 최소 사양은 소규모/PoC 기준. 관리 서버는 DB·API·UI·Prometheus·Grafana 를 함께 올리므로 **기본 8vCPU/16GB** 권장.
- 관리 대상 Host/게스트 수가 늘수록 메모리·DB 디스크를 키운다.

### 1.4 확장 규모 (가이드)

- 하나의 Cluster 는 **동일 OS 의 KVM Host N대**로 구성한다(단일 노드 = master 1대도 지원).
- 관리 VM 1대가 다수 Host/게스트를 관리한다. 규모가 커지면 관리 VM 메모리/DB 디스크를 상향한다.
- Host 20대 초과 병렬 설치가 필요하면 설치 병렬도(ansible forks)를 상향한다(제작자 문의).

---

## 2. 설치 전 사람이 준비할 것 (스크립트가 만들지 않음)

`prepare-install.sh` 는 **config.yaml 생성 · SSH 키 배포 · 디렉터리/이미지 점검**만 한다.
아래는 **그 전에** 준비되어 있어야 한다.

| # | 준비 항목 | 대상 | 스크립트가 하나? |
|---|-----------|------|------------------|
| 1 | Docker + Compose plugin | kvm.master | △ (`install-docker.sh` 제공) |
| 2 | 설치 이미지 반입/로드 | kvm.master | △ (`--load-images`) |
| 3 | `ssh_user`(namuvirt) 계정 + 비밀번호 | **모든 KVM Host** | ✗ |
| 4 | 비밀번호 없는 sudo(NOPASSWD) | **모든 KVM Host** | ✗ |
| 5 | SSH password 인증 임시 허용(최초 1회) | **모든 KVM Host** | ✗ |
| 6 | `/dev/kvm`(BIOS VT/AMD-V) | **모든 KVM Host** | ✗ |
| 7 | 동일 OS(Rocky 8 또는 Ubuntu 24.04) | **모든 KVM Host** | ✗ |
| 8 | 관리 네트워크 IP/NIC/Gateway | **모든 KVM Host** | ✗ |
| 9 | 관리 VM IP(미사용 IP) 확보 | 네트워크 | ✗ |
| 10 | 관리 VM 골든 이미지·SystemVM 템플릿 | kvm.master `images/` | ✗(번들에 포함되면 자동 배치) |

### 2.1 ssh_user 계정 + NOPASSWD sudo (모든 KVM Host)

키 배포를 하려면 계정에 **비밀번호**가 있어야 한다(최초 1회 로그인용).

**Rocky 8**
```bash
useradd -m namuvirt
echo 'namuvirt:비밀번호' | chpasswd
echo 'namuvirt ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/namuvirt
chmod 440 /etc/sudoers.d/namuvirt
```
**Ubuntu 24.04**
```bash
adduser --gecos "" namuvirt
echo 'namuvirt ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/namuvirt
chmod 440 /etc/sudoers.d/namuvirt
```
확인: `sudo -l -U namuvirt` → `(ALL) NOPASSWD: ALL`

> **NOPASSWD 를 설정할 수 없는 환경**이면, 설치 시 `-K`(`--ask-become-pass`)로 sudo 비밀번호를 입력받아
> 처리할 수 있다: `./install-namuvirt.sh -K install`. (모든 KVM Host 가 **동일한** sudo 비밀번호를 쓰는 계정이어야 함)
> 다만 자동화/재실행 편의상 **NOPASSWD 를 권장**한다.

### 2.2 SSH password 인증 임시 허용 (최초 키 배포용)
```bash
# /etc/ssh/sshd_config(.d/*.conf)
PasswordAuthentication yes
systemctl restart sshd      # Ubuntu: ssh
```
> 이미 공개키를 각 호스트 `~namuvirt/.ssh/authorized_keys` 에 수동 배포했다면 2.1 비밀번호·2.2 는 불필요
> (prepare-install.sh 가 키 접속을 감지해 배포를 건너뜀).

### 2.3 가상화 / 네트워크 확인 (모든 KVM Host)
```bash
ls -l /dev/kvm                       # 존재해야 함
egrep -c '(vmx|svm)' /proc/cpuinfo   # 1 이상
ip -br addr ; ip route show default  # config 에 넣을 IP/NIC/Gateway
```

---

## 3. Step ① — 반입 + 무결성 검증

```bash
# USB 등으로 반입한 번들 압축 해제 후
cd namuvirt-installer-1.0.0
sha256sum -c SHA256SUMS       # 전 파일 OK 확인
```

---

## 4. Step ② — Docker 설치 (`install-docker.sh`)

`install-namuvirt.sh` 는 docker 를 직접 호출한다. docker 가 없으면 먼저 설치한다.

```bash
sudo ./install-docker.sh          # auto: 번들 docker-packages 있으면 오프라인, 없으면 온라인
```

### 옵션

| 옵션 | 역할 |
|------|------|
| (없음) | **auto** — 번들 `docker-packages/<os>/` 감지 시 오프라인, 없으면 온라인(docker-ce repo) |
| `--offline` | 강제 오프라인(번들 `docker-packages/` 사용, 외부 repo 미접속) |
| `--offline <dir>` | 오프라인 + rpm/deb 디렉터리 직접 지정 |
| `--online` | 강제 온라인(docker-ce repo) |
| `--user <계정>` | docker 그룹에 추가할 계정 지정(미지정 시 `sudo` 실행 계정) |
| `--help` | 도움말 |

- 폐쇄망이면 번들에 `docker-packages/` 가 있으므로 **인자 없이** 실행하면 오프라인 설치된다.
- 설치 끝에 **실행 계정(namuvirt)을 docker 그룹에 자동 추가**한다. 반영하려면:
  ```bash
  newgrp docker        # 현재 셸에 즉시 반영 (또는 로그아웃/재로그인)
  docker info          # sudo 없이 되는지 확인
  ```

---

## 5. Step ③ — 설치 이미지 로드 (`--load-images`)

```bash
./install-namuvirt.sh --load-images
docker images | grep namuvirt      # 3종 확인
```
- `image-tar/*.tar` 를 `docker load` 한다. 이미 로드된 이미지는 건너뛴다(재실행 안전).

---

## 6. Step ④ — 설치 전 준비 (`prepare-install.sh`)

config.yaml 대화형 생성 + SSH 키 생성/배포 + 디렉터리/이미지 점검을 한 번에.

```bash
./prepare-install.sh
```

### 옵션

| 옵션 | 역할 |
|------|------|
| (없음) / `all` | config 생성 → SSH 키 배포 → 점검 → 요약 (전체) |
| `--config-only` | `config.yaml` 만 생성(키 이미 배포된 경우) |
| `--ssh-only` | SSH 키 생성/배포만 |
| `--check-only` | 디렉터리/이미지 점검만 |
| `--help` | 도움말 |

- 대화형 질문(Enter=기본값): ssh_user, kvm.os, master IP/NIC/Gateway, 관리 VM IP/이름/**고정 MAC**,
  추가 host 목록, storage 경로, **secondary NFS 서버 IP(비우면 로컬)**, bridge/prefix/DNS, 이미지 파일명.
- SSH 키(`ssh/id_ed25519`)를 생성하고 각 KVM Host 에 공개키를 배포한 뒤 접속/NOPASSWD sudo 를 확인한다.
- 이미 쓰던 키가 있으면 `ssh/id_ed25519` 로 복사해 두면 재생성하지 않는다.

> **참고**: 이 스크립트와 install 은 폐쇄망 KVM 호스트에 python3 가 없어도 동작한다(순수 awk 파서 폴백).

---

## 7. config.yaml 필드 상세

`config.sample.yaml` 을 복사해 수정하거나 `prepare-install.sh` 로 생성한다.

```yaml
ssh_user: namuvirt                                   # 모든 KVM Host 공통 sudo 계정(root 아님)
ssh_private_key_path: /mnt/namuvirt/ssh/id_ed25519   # 컨테이너 내부 경로 — 그대로 둔다

kvm:
  os: rocky                       # Cluster 전체 OS: rocky | ubuntu (혼합 불가)
  master:                         # 관리 VM 을 올릴 물리 호스트(= 이 서버). 관리 대상 자동 포함.
    ip: 10.10.14.193
    nic: eno1                     # 미입력 시 default route 로 자동 탐지
    gateway: 10.10.14.1           # 미입력 시 자동 탐지
  hosts:                          # master 제외 추가 Host. 없으면 [] (master 재기재 금지)
    - ip: 10.10.14.195
    - ip: 10.10.14.196

management:
  vm_ip: 10.10.14.194
  vm_name: namuVIRT-management
  vm_mac: "52:54:00:0a:0e:c2"     # 관리 VM 고정 MAC(라이센스 바인딩 유리). 비우면 자동
  vm_vcpus: 8
  vm_ram_mb: 16384
  vm_disk_gb: 200
  rocky_cloudimg:    /mnt/namuvirt/images/NAMU-Rocky-8-10.qcow2
  systemvm_template: /mnt/namuvirt/images/SystemVM-Template-KVM.qcow2

network:
  bridge: cloudbr0
  prefix: 24
  dns: [8.8.8.8, 1.1.1.1]

# storage: primary/secondary 를 protocol 까지 각각 독립 구성 (v2)
storage:
  primary:
    protocol: nfs                 # nfs(공유) | local(호스트 로컬) | ceph(스텁)
    path: /export/primary
    export_host_ip: ""            # nfs 공유 시 단일 export 서버. 비우면 각 호스트 로컬 export
    # hosts:                      # (선택) 호스트별 path override
    #   10.10.14.195: { path: /data/primary }
  secondary:
    protocol: nfs
    path: /export/secondary
    export_host_ip: 10.10.14.193  # 관리 VM/SSVM 이 마운트할 export 서버. 비우면 로컬 디렉터리
```

| 필드 | 의미 | 비고 |
|------|------|------|
| `ssh_user` | 각 Host 공통 sudo 계정 | root 로 접속 안 함 |
| `ssh_private_key_path` | 컨테이너 내부 키 경로 | `/mnt/namuvirt/ssh/id_ed25519` 고정 |
| `kvm.os` | Cluster 전체 OS | `rocky`\|`ubuntu`, **혼합 불가** |
| `kvm.master.{ip,nic,gateway}` | 물리 마스터 | 관리 VM 생성 위치, 관리 대상 자동 포함 |
| `kvm.hosts[].ip` | 추가 KVM Host | master 는 **적지 않음**, 없으면 `[]` |
| `management.vm_ip` | 관리 VM IP | 미사용 IP |
| `management.vm_mac` | 관리 VM 고정 MAC | 라이센스 바인딩용. 비우면 libvirt 자동 |
| `management.vm_vcpus/vm_ram_mb/vm_disk_gb` | 관리 VM 사양 | §1.3 참고 |
| `management.rocky_cloudimg` | 관리 VM 골든 이미지 | `images/` 에 실제 파일 |
| `management.systemvm_template` | SystemVM 템플릿 | `images/` 에 실제 파일 |
| `network.bridge` | KVM bridge 이름 | 기본 `cloudbr0` |
| `network.prefix/dns` | 서브넷 prefix, DNS | |
| `storage.{primary,secondary}.protocol` | 스토리지 종류 | `nfs`\|`local`\|`ceph`(스텁) |
| `storage.{primary,secondary}.path` | 디렉터리 경로 | protocol=nfs/local 에서 사용 |
| `storage.{primary,secondary}.export_host_ip` | nfs 공유 export 서버 | secondary: 관리 VM/SSVM 마운트 주체. 비우면 로컬 |
| `storage.{primary,secondary}.hosts` | 호스트별 path override | 생략 시 공통 path 전체 적용 |

**핵심 규칙**: ① `kvm.os` 단일 ② master 를 `hosts` 에 중복 기재 금지 ③ `packages_dir` 적지 않음(이미지 내장).

---

## 8. Step ⑤ — preflight (설치 전 검증)

```bash
./install-namuvirt.sh --preflight
```
변경 없이 다음을 검사한다. 실패하면 설치를 시작하지 않는다.

- **로컬**: Docker 실행/권한 · Compose · 이미지 존재 · config 스키마 · SSH 키 존재/권한 · cloud image/template 존재 · logs 쓰기
- **원격**: SSH 접속 · NOPASSWD sudo · OS(Rocky 8/Ubuntu 24.04) · 동일 OS Cluster · `/dev/kvm` · NIC/gateway · 기존 libvirt domain 경고

---

## 9. Step ⑥ — 설치 (`install-namuvirt.sh`)

```bash
./install-namuvirt.sh install
./install-namuvirt.sh -K install       # NOPASSWD 없을 때: sudo 비밀번호 입력받아 설치
```

### 명령(command)

| 명령 | 역할 |
|------|------|
| `install` | 전체 설치: preflight → KVM Hosts → 관리 VM → 요약 |
| `--load-images` | `image-tar/*.tar` → docker load(강제 재적재) |
| `--preflight` | 로컬+원격 검증만(변경 없음) |
| `--tags <tag>` | 단계별 실행: `kvm_hosts` \| `management` \| `monitoring` \| `storage` \| `agent` |
| `collect-logs` | `logs/` 를 tar.gz 로 수집 |
| `--help` | 도움말 |

### 옵션

| 옵션 | 역할 |
|------|------|
| `-K`, `--ask-become-pass` | sudo(become) 비밀번호를 입력받아 사용. **KVM Host 계정에 NOPASSWD sudo 가 없을 때** 사용(모든 Host 가 동일 비밀번호여야 함). 위치 무관: `-K install` / `install -K` 모두 가능. NOPASSWD 가 있으면 불필요 |

- 실행 시 **시작/종료 시각·소요 시간**을 출력한다.
- 문제 단계만 재실행: 예) 관리 VM 만 → `./install-namuvirt.sh --tags management`
- KVM Host 는 여러 대여도 **병렬로 동시 설치**된다(20대까지 기본).
- `-K` 는 어느 명령과도 조합 가능: `-K --preflight`, `-K --tags kvm_hosts` 등.

### 외부 mount (현재 디렉터리 기준)
`config.yaml`, `ssh/`, `images/`, `logs/` 가 컨테이너의 `/mnt/namuvirt/` 로 mount 된다.
이미지에는 SSH 키/config/cloud image/template 를 넣지 않는다.

---

## 10. Step ⑦ — 설치 후 검증 (`verify-install.sh`)

```bash
./verify-install.sh          # 전체(KVM Host + 관리 VM)
```

| 옵션 | 역할 |
|------|------|
| (없음) | 전체 검증 |
| `--hosts` | KVM Host 만 |
| `--mgmt` | 관리 VM 만 |

- 모든 Host(master 포함) + 관리 VM 에 SSH 로 접속해 서비스·포트·엔드포인트를 점검하고 PASS/FAIL 요약을 출력한다.
- 종료코드: `0`=모든 필수 PASS, `1`=필수 FAIL 있음.

---

## 11. 설치 결과 / 접속

설치 요약(`logs/summary-*.txt`)과 함께 다음이 제공된다.

| 서비스 | URL / 확인 |
|--------|-----------|
| namuVIRT 관리 UI | `http://<관리VM IP>:8080/client/` |
| Grafana | `http://<관리VM IP>:3000` |
| Prometheus | `http://<관리VM IP>:9091` |
| KVM Host exporter | node `:9100` / process `:9256` / libvirt `:9177` |

관리 VM 서비스:
```bash
systemctl status cloudstack-management cloudstack-usage mariadb
```

로그:
```
logs/install-YYYYMMDD-HHMMSS.log
logs/preflight-YYYYMMDD-HHMMSS.log
logs/ansible-<tag>-YYYYMMDD-HHMMSS.log
logs/summary-YYYYMMDD-HHMMSS.txt
```

---

## 12. 설치 후 — SystemVM / Guest OS 템플릿 등록

설치(`install-namuvirt.sh`)는 KVM Host + 관리 VM 까지만 구성한다. **템플릿 등록은 설치와 분리된 운영 작업**으로,
번들의 **대화형 콘솔 `./upload-os-image.sh`** 로 처리한다(관리 VM 의 `cmk` 사용). 인자 없이 실행하면 메뉴가 뜬다.

```bash
cd release/namuvirt-installer-<version>
./upload-os-image.sh
#   1) check   2) list   3) infra   4) register
#   5) register-systemvm   6) seed-systemvm   0) 종료
```

| 대상 | 메뉴 | 요약 |
|------|------|------|
| **SystemVM 템플릿** (최초 부트스트랩) | **`6) seed-systemvm`** | 폐쇄망 최초엔 SSVM 이 없어 secondary storage 에 **직접 시드**해야 SSVM 이 뜬다(순환). |
| **게스트 OS 템플릿** | **`4) register`** | SSVM 이 뜬 뒤 등록. (원하면 CloudStack admin 웹콘솔의 *Register Template* URL 로도 가능) |

**순서**: ① admin *Add Zone*(존·스토리지·호스트) → **`3) infra`** 로 확인 → **`6) seed-systemvm`**
→ SSVM `Running`(`3) infra`) → **`4) register`**. SSVM 이 없으면 게스트 이미지를 받아올 주체가 없다.

> **자세한 화면·단계·트러블슈팅은 [UPLOAD-OS-IMAGE.md](UPLOAD-OS-IMAGE.md) 를 참고한다.**
> - §2 메뉴별 안내(check/list/infra/register/seed-systemvm) · §3 추천 순서 · §4 비대화형(자동화) · §5 트러블슈팅
> - `seed-systemvm` 은 **secondary 경로가 등록된 secondary storage 와 같은 위치**여야 한다(`3) infra` 로 대조).

---

## 13. 재설치 / 트러블슈팅

| 증상 | 조치 |
|------|------|
| preflight 실패 | 출력된 Host/항목 수정 후 재실행. 계정/sudo/OS/`/dev/kvm` 확인 |
| `Missing sudo password` (Gathering Facts 실패) | SSH 계정에 NOPASSWD sudo 가 없음. §2.1 처럼 NOPASSWD 설정, 또는 `-K` 로 비밀번호 입력: `./install-namuvirt.sh -K install` |
| SSH 키 배포 `Permission denied` | 2.1 계정·비밀번호, 2.2 `PasswordAuthentication yes` 재확인 |
| `docker info` 권한 오류 | `sudo usermod -aG docker <계정>` 후 `newgrp docker`(또는 재로그인) |
| `install-docker.sh` 오프라인이 `nothing provides tar` 로 실패 | 구버전 번들의 `docker-packages/rocky` 에 tar rpm 누락(minimal 호스트엔 tar 없음). tar 포함 최신 번들 사용, 또는 `tar-*.rpm` 을 `docker-packages/rocky/` 에 추가 후 재실행 |
| 특정 단계만 실패 | `./install-namuvirt.sh --tags <단계>` 로 재실행(대부분 idempotent) |
| 관리 VM 재생성 필요 | master 에서 `virsh destroy/undefine <vm_name>` 후 `--tags management` |
| 관리 VM 이 게이트웨이로 못 나감 | 브리지 netfilter 이슈 — 최신 번들은 자동 조치(`namuvirt-bridge-nf.service`) |
| 로그 수집 | `./install-namuvirt.sh collect-logs` → `logs/*.tar.gz` |

> 파괴적 reset/wipe 는 기본 명령에 포함되지 않는다(안전). 전체 리셋이 필요하면 제작자에게 문의한다.
