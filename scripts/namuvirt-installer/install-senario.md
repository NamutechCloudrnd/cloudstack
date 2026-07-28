# namuVIRT 설치 시나리오 — 전용 NFS 서버 구성

전용(외부) NFS 서버 한 대가 **primary + secondary 를 모두 공유**하고, KVM 호스트 2대와
관리 VM 이 그 NFS 를 사용하는 구성 예시다. (IP 대역: `10.10.12.0/24`)

---

## 1. 토폴로지

```
                        ┌──────────────────────────┐
                        │        NFS Server        │
                        │       10.10.12.190       │   ← 설치기 관리 대상 아님(수동 구성)
                        │  /export/primary         │
                        │  /export/secondary       │
                        └────────────┬─────────────┘
                                     │ NFS (10.10.12.0/24)
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
     ┌────────▼────────┐    ┌────────▼────────┐    ┌────────▼─────────┐
     │ KVM Host 01     │    │ KVM Host 02     │    │ Management VM    │
     │ 10.10.12.191    │    │ 10.10.12.192    │    │ 10.10.12.193     │
     │ (master)        │    │                 │    │ (master 위 VM)   │
     └─────────────────┘    └─────────────────┘    └──────────────────┘
              └───── cloudbr0 (관리 네트워크) ─────┘
```

| IP | 역할 | 관리 주체 |
|---|---|---|
| `10.10.12.190` | 전용 NFS 서버 (primary + secondary export) | **수동** (설치기 밖) |
| `10.10.12.191` | KVM Host 01 = **master** (관리 VM 을 여기에 생성) | 설치기 |
| `10.10.12.192` | KVM Host 02 | 설치기 |
| `10.10.12.193` | Management VM (master 위에서 실행) | 설치기(자동 생성) |
| `10.10.12.1` | 기본 게이트웨이 *(가정 — 실제 값으로 교체)* | - |

- OS: Rocky Linux 8 (Cluster 전체 동일 가정)
- 관리 브리지: `cloudbr0`, prefix `24`
- 이 구성을 **VM 으로 만들 때의 CPU/RAM/Disk 산정은 §10** 참고.

> **중요:** 관리 VM(`10.10.12.193`)은 별도 물리 서버가 아니라 **master(`10.10.12.191`) 위의 KVM VM** 이다.
> 다이어그램의 "Management" 박스는 이 VM 을 의미한다.

---

## 2. 역할 분담 (설치기 자동 vs 수동)

| 구성 요소 | 누가 하나 |
|---|---|
| NFS 서버(.190) 디렉터리/export/방화벽 | **수동** (§3) |
| KVM 호스트 준비(브리지·libvirt·에이전트) | 설치기 (`install`) |
| 관리 VM 생성 + CloudStack 설치 | 설치기 (`install`) |
| 관리 VM 이 secondary(.190) 마운트 + SystemVM 템플릿 시드 | 설치기 (`storage.secondary.export_host_ip` 기반, 설치 흐름 포함) |
| **Zone / Primary / Secondary CloudStack 등록, Zone 활성화** | **수동** (§6, CloudStack UI) |

---

## 3. 사전 준비 ① — 전용 NFS 서버 (10.10.12.190)

설치기는 이 서버를 건드리지 않으므로 **직접** 구성한다. (Rocky/RHEL 기준)

### 3-1. 디스크 세팅 (Rocky 표준)

디스크 3개 구성 예시: `sda` 40 GB(OS), `sdb` 100 GB(primary), `sdc` 100 GB(secondary).
primary/secondary 를 **각각 별도 디스크**에 두어 성능 간섭·동시 장애를 피한다.

**설치 화면(Anaconda) — Installation Destination**

- Local Standard Disks 에서 **`sda` 만 선택**한다. `sdb`/`sdc` 는 선택하지 않는다.
  (함께 선택하면 자동 파티셔닝이 세 디스크를 하나의 LVM VG 로 묶어 primary/secondary 물리 분리가 깨진다.)
- Storage Configuration 은 **Automatic** 으로 충분하다. 40 GB 기준 기본값은 `/boot` 1 GB + swap + 나머지 `/` (LVM).
  직접 잡으려면 Custom → Standard Partition 으로 `/boot` 1 GB, swap 4 GB, `/` 나머지.
- 소프트웨어 선택: **Minimal Install**.

**설치 후 — `sdb`/`sdc` 를 export 디스크로 마운트**

```bash
lsblk                       # sdb, sdc 가 비어 있는지 확인

sudo mkfs.xfs -L primary   /dev/sdb
sudo mkfs.xfs -L secondary /dev/sdc

sudo mkdir -p /export/primary /export/secondary
sudo blkid /dev/sdb /dev/sdc    # 아래 fstab 에 넣을 UUID 확인
```

장치명(`sdb`/`sdc`)은 재부팅 시 뒤바뀔 수 있으므로 **UUID 로 고정**한다. `/etc/fstab` 에 추가:

```
UUID=<sdb-uuid>  /export/primary    xfs  defaults  0 0
UUID=<sdc-uuid>  /export/secondary  xfs  defaults  0 0
```

```bash
sudo mount -a
df -h /export/primary /export/secondary   # 각각 100G 로 보이면 성공
```

> **순서 주의:** 마운트를 먼저 하고 §3-2 의 소유권/권한을 준다. 반대로 하면 마운트가 빈 XFS 로 디렉터리를
> 덮어써서 `nobody:nobody 777` 이 사라지고, KVM 호스트에서 쓰기 권한 오류가 난다.

### 3-2. NFS 구성

```bash
# 10.10.12.190 에서
sudo dnf install -y nfs-utils
sudo chown nobody:nobody /export/primary /export/secondary
sudo chmod 777 /export/primary /export/secondary

# 서브넷 전체에 export (no_root_squash: CloudStack/qemu 호환)
sudo tee /etc/exports >/dev/null <<'EOF'
/export/primary   10.10.12.0/24(rw,async,no_root_squash,no_subtree_check)
/export/secondary 10.10.12.0/24(rw,async,no_root_squash,no_subtree_check)
EOF
sudo exportfs -ra
sudo systemctl enable --now rpcbind nfs-server

# 방화벽
sudo firewall-cmd --permanent --add-service={nfs,rpc-bind,mountd}
sudo firewall-cmd --reload

# 확인
showmount -e localhost      # /export/primary, /export/secondary 가 보여야 함
```

> Ubuntu 라면: `apt install nfs-kernel-server`, 서비스명 `nfs-kernel-server`, 그룹 `nogroup`.

용량 권장: primary = 게스트 VM 디스크 총량, secondary = 템플릿/ISO/스냅샷 용량. **별도 물리 디스크** 권장.

---

## 4. 사전 준비 ② — KVM 호스트 (10.10.12.191, .192)

각 호스트에 미리 준비되어 있어야 하는 것(설치기가 하지 않음):

- `namuvirt` 계정 + **비밀번호 없는 sudo**(NOPASSWD). 없으면 설치 명령에 `-K` 사용.
- CPU 가상화(VT-x/AMD-V), `/dev/kvm` 사용 가능.
- 두 호스트 **동일 OS**(Rocky 8).
- 관리 네트워크에서 서로/NFS 서버(.190)와 통신 가능.

이미지 배치(설치 실행 서버 = master 의 `images/`):

- `NAMU-Rocky-8-10.qcow2` (관리 VM 골든 이미지)
- `SystemVM-Template-KVM.qcow2` (SystemVM 템플릿)

---

## 5. config.yaml

이 시나리오에 맞춘 값. `./prepare-install.sh` 대화형으로 생성하거나 아래를 직접 작성한다.

```yaml
ssh_user: namuvirt
ssh_private_key_path: /mnt/namuvirt/ssh/id_ed25519

kvm:
  os: rocky
  master:
    ip: 10.10.12.191
    nic: eno1
    gateway: 10.10.12.1
  hosts:
    - ip: 10.10.12.192

management:
  vm_ip: 10.10.12.193
  vm_name: namuVIRT-management
  vm_mac: ""
  vm_vcpus: 8
  vm_ram_mb: 16384
  vm_disk_gb: 200
  rocky_cloudimg: /mnt/namuvirt/images/NAMU-Rocky-8-10.qcow2
  systemvm_template: /mnt/namuvirt/images/SystemVM-Template-KVM.qcow2

network:
  bridge: cloudbr0
  prefix: 24
  dns: [8.8.8.8, 1.1.1.1]

# 전용 NFS 서버(.190)를 primary/secondary 공유 스토리지로 사용
storage:
  primary:
    protocol: nfs
    path: /export/primary
    export_host_ip: 10.10.12.190     # CloudStack Primary 등록 URL 힌트(§6). 자동화가 마운트하진 않음
  secondary:
    protocol: nfs
    path: /export/secondary
    export_host_ip: 10.10.12.190     # 관리 VM 이 시드용으로 이 서버의 secondary 를 마운트(자동)
```

### `prepare-install.sh` 대화형으로 만들 때 입력 값
- `kvm.os` → `rocky`
- master IP `10.10.12.191`, NIC `eno1`, gateway `10.10.12.1`
- 관리 VM IP `10.10.12.193`
- 추가 host `10.10.12.192`
- **primary storage** → protocol `nfs`, path `/export/primary`, nfs export 서버 IP `10.10.12.190`, 모든 호스트 동일 `y`
- **secondary storage** → protocol `nfs`, path `/export/secondary`, nfs export 서버 IP `10.10.12.190`, 모든 호스트 동일 `y`

---

## 6. 설치 실행 (master = 10.10.12.191 에서)

```bash
cd scripts/namuvirt-installer

# (1) config.yaml 생성 + SSH 키 배포 + 이미지/디렉터리 점검
./prepare-install.sh

# (2) 폐쇄망 컨테이너 이미지 반입 (필요 시)
./install-namuvirt.sh --load-images -K

# (3) 설치 전 검증만 (mutation 없음)
./install-namuvirt.sh --preflight -K

# (4) 전체 설치 (KVM Hosts → Management VM → CloudStack)
./install-namuvirt.sh install -K
```

- `-K` 는 KVM 계정에 NOPASSWD sudo 가 **없을 때만** 붙인다(있으면 생략).
- 설치가 끝나면 관리 VM 이 `.190:/export/secondary` 를 마운트하고 **SystemVM 템플릿 시드까지 자동 완료**된다
  (별도 `seed-systemvm` 불필요).

---

## 7. 설치 후 — CloudStack Zone / Storage 등록 (수동)

설치기는 스토리지 "준비"까지만 하고 CloudStack 등록은 하지 않는다. 관리 UI(`http://10.10.12.193:8080/client`)에서:

1. **Infrastructure → Zones → Add Zone** 로 Zone/Pod/Cluster/Host 생성.
2. **Primary Storage** 등록:
   - URL: `nfs://10.10.12.190/export/primary`
   - 전 호스트가 동일 공유 스토리지를 보므로 **VM live migration 가능**.
3. **Secondary Storage** 등록:
   - URL: `nfs://10.10.12.190/export/secondary`
   - 이미 SystemVM 템플릿이 시드돼 있어 SSVM/Console Proxy VM 이 이 템플릿으로 부팅된다.
4. Zone 활성화 → SSVM / CPVM 이 Running 되는지 확인.

> **반드시 `.190` URL 로 등록한다.** 아래 §9 참고대로 KVM 호스트에도 로컬 export 가 생기지만, 그것은 사용하지 않는다.

---

## 8. 검증 명령

```bash
# NFS 서버 (10.10.12.190)
showmount -e localhost
sudo exportfs -v

# KVM Host 01/02 (10.10.12.191, .192)
ip -br addr show cloudbr0            # 관리 IP 가 브리지에 있는지
systemctl is-active libvirtd         # 또는 virtqemud
showmount -e 10.10.12.190            # NFS 서버 export 가 보이는지

# Management VM (10.10.12.193)
mountpoint /export/secondary                        # .190 secondary 마운트 확인
ls /export/secondary/template/tmpl/1/3/             # SystemVM 템플릿 시드 확인
ls /export/secondary/.namuvirt-systemvm-seeded      # 시드 멱등 마커

# CloudStack (등록 후)
cloudmonkey list storagepools
cloudmonkey list imagestores
cloudmonkey list systemvms filter=name,state        # SSVM, CPVM 이 Running
```

---

## 9. 참고 / 주의

- **전용 NFS 서버는 설치기가 관리하지 않는다.** `.190` 의 export·방화벽·용량은 §3 처럼 직접 유지한다.
- **KVM 호스트의 로컬 export 부작용:** `storage.*.protocol: nfs` 이면 KVM 호스트(.191/.192)도 자기 로컬
  `/export/primary`·`/export/secondary` 를 export 한다. 이 시나리오에선 CloudStack 풀을 `.190` URL 로
  등록하므로 **이 로컬 export 는 사용되지 않는다**(무해하나 잉여). 완전히 제거하려면 "외부 NFS 마운트 전용"
  모드가 필요하며 현재는 미지원이다.
- `primary.export_host_ip` 는 자동화가 소비하지 않는 **문서용 값**(CloudStack 등록 URL 힌트)이다.
  `secondary.export_host_ip` 만 관리 VM 의 secondary 마운트에 실제 사용된다.
- 게이트웨이 `10.10.12.1` 은 가정값이다 — 실제 환경 값으로 교체할 것.
- primary/secondary 를 같은 물리 디스크에 두면 성능 간섭·동시 장애 위험이 있다(§3 용량 권장 참고).
- 스토리지 스키마 상세는 `config.sample.yaml`, 판정 근거는 `storage-report.md` 참고.

---

## 10. VM 리소스 산정 (이 구성을 VM 으로 만들 때)

이 랩은 **중첩 가상화(nested virtualization)** 다: KVM 호스트 자체가 VM 이고, 그 안에서 다시 게스트/시스템 VM 이 돈다.
사용자가 직접 만드는 VM 은 **3대**(NFS 서버, KVM Host 01, KVM Host 02)이며,
**관리 VM(`10.10.12.193`)은 설치기가 KVM Host 01(master) 안에서 자동 생성**하므로 그 리소스는 **master 예산에 포함**된다.

### 권장 사양 (랩 기준)

| 사용자가 만드는 VM | vCPU | RAM | Disk | nested virt |
|---|---|---|---|---|
| **NFS Server** (`.190`) | 2 | 4 GB | OS(`sda`) 40 GB + `/export/primary`(`sdb`) 100 GB + `/export/secondary`(`sdc`) 100 GB ≈ **240 GB** | 불필요 |
| **KVM Host 01 = master** (`.191`) | 12 | 32 GB | OS 40 GB + 관리 VM 200 GB ≈ **260 GB** | **필수** |
| **KVM Host 02** (`.192`) | 6 | 12 GB | OS 40 GB (게스트 디스크는 NFS 에 저장) | **필수** |

> **관리 VM** (설치기 자동 생성, master 내부): `vm_vcpus: 8` / `vm_ram_mb: 16384`(16 GB) / `vm_disk_gb: 200`
> — config.yaml 의 값이며 위 **master 예산에 이미 포함**했다(그래서 master 를 크게 잡음).

**master 를 크게 잡는 이유:** 관리 VM(8 vCPU·16 GB·200 GB) + host OS/에이전트(≈4 GB) + 시스템 VM(SSVM·CPVM·VR, 합 ≈2.5 GB) + 게스트 여유가 모두 이 안에서 돈다. 게스트 VM 디스크는 NFS(.190)로 빠지므로 master 로컬 디스크는 주로 **관리 VM 200 GB** 때문에 크다.

물리 하이퍼바이저 합계(대략): **vCPU ≈ 20**(오버커밋 가능), **RAM ≈ 48 GB**, **Disk ≈ 540 GB**.

### 리소스를 줄이려면 (econo)

물리 자원이 빠듯하면 config.yaml 의 관리 VM 사양을 낮춘다 → master VM 도 그만큼 축소 가능:

```yaml
management:
  vm_vcpus: 4
  vm_ram_mb: 8192      # 8 GB
  vm_disk_gb: 100
```
→ 이 경우 master 는 **8 vCPU / 16 GB / OS 40 GB + 100 GB ≈ 160 GB** 로 낮출 수 있다.
(CloudStack 시스템 오퍼링을 줄이면 시스템 VM RAM 도 더 절약 가능. 안정성은 권장 사양이 낫다.)

### 중첩 가상화 활성화 (KVM Host 01/02 VM)

이 VM 들은 내부에서 다시 VM 을 돌려야 하므로 **물리 하이퍼바이저**에서 nested virt 를 켜고 CPU 를 그대로 노출해야 한다.

```bash
# (물리 호스트) Intel 예시 — 모듈에 nested 활성화
cat /sys/module/kvm_intel/parameters/nested       # Y 여야 함 (AMD 는 kvm_amd)
# 꺼져 있으면: echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-nested.conf
#              sudo modprobe -r kvm_intel && sudo modprobe kvm_intel

# KVM Host VM 정의 시 CPU 를 host-passthrough(또는 host-model)로 노출
#   virt-install ... --cpu host-passthrough
#   (virt-manager: CPU → "Copy host CPU configuration")
```

```bash
# (KVM Host VM 내부) 확인 — 둘 다 성공해야 게스트/시스템 VM 이 뜬다
grep -Ec 'vmx|svm' /proc/cpuinfo     # > 0
ls -l /dev/kvm                       # 존재
```

> nested virt 미설정 시 KVM Host 는 뜨지만 그 위의 게스트/시스템 VM(SSVM·CPVM) 이 부팅되지 않는다.
