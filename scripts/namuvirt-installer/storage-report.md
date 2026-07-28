# namuVIRT Storage 검증 리포트

> `verify.md`의 Storage 검증 항목(6·7·8·D)을 실제 설치 코드와 대조해 판정한 문서.
> 판정 근거는 모두 아래 파일에서 확인한 **실제 코드 동작**이며, 추측은 "확인 불가"로 표기한다.

확인한 소스:
- `ansible/site.yml`
- `ansible/roles/preflight/tasks/load_config.yml`
- `ansible/roles/kvm_hosts/tasks/main.yml`
- `ansible/roles/kvm_hosts/tasks/storage/storage.yml`
- `ansible/roles/management/tasks/configure/main.yml`
- `ansible/roles/management/tasks/configure/nfs_mount.yml`
- `ansible/roles/management/tasks/configure/systemvm_template.yml`
- `config.sample.yaml`, `prepare-install.sh`

---

## ⚠️ v2 업데이트 안내 (스토리지 스키마 개편)

이 리포트의 §1~§3 본문은 **구 스키마(v1)** 기준 분석이다. 이후 아래 개편이 적용되었다(클린 브레이크):

- **config 스키마 변경**: `storage.{primary,secondary}`가 경로 문자열 → **`{protocol, path, export_host_ip, hosts}` dict**.
  - `protocol`: `nfs`(공유) | `local`(호스트 로컬) | `ceph`(스텁, 미구현)
  - `management.nfs_export_host_ip` **폐지** → `storage.secondary.export_host_ip`로 이동.
  - `storage.{primary,secondary}.hosts`로 **호스트별 path override** 지원(생략 시 공통 path 전체 적용).
- **KVM Host storage 역할이 protocol 디스패처로 재작성**: `storage.yml`이 `storage_nfs.yml`/`storage_local.yml`/`storage_ceph.yml`을 분기 호출. 새 스토리지 종류는 파일 추가만으로 확장.
- **효과**: v1의 "primary/secondary가 항상 동일하게 NFS export"·"protocol 개념 없음" 한계가 해소됨. 단 아래 §2·§3의 **CloudStack 등록은 여전히 수동**이고, secondary 로컬 모드의 SSVM 접근 함정도 원리상 동일하게 유효(그래서 `export_host_ip` 지정 권장).

구 스키마 서술(`nfs_export_host_ip`, 문자열 `storage.primary` 등)은 v2에서 각각 `storage.secondary.export_host_ip`, `storage.primary.path`로 읽는다.

---

## 0. 한눈에 보는 결론

| 구분 | 실제 동작 | 판정 |
|---|---|---|
| Primary Storage 디렉터리/Export 준비 | 자동 (모든 KVM Host 로컬 + NFS export) | ✅ 동작 |
| Primary Storage **CloudStack 등록** | **자동화 안 됨** — 운영자가 UI에서 수동 등록 | ⚠️ 수동 |
| Secondary Storage 디렉터리/Export 준비 | 자동 (모든 KVM Host) + 관리 VM 마운트 | ✅ 동작 |
| Secondary **로컬 모드**(`nfs_export_host_ip` 미지정) | 관리 VM **로컬 디렉터리** 사용, NFS export 안 함 | ❗ SSVM 접근 불가 위험 |
| Secondary **NFS 모드**(`nfs_export_host_ip` 지정) | 지정 호스트의 export를 관리 VM이 마운트 | ✅ 권장 |
| SystemVM Template 시드 | **설치 흐름에 포함**(`configure/main.yml` → `systemvm_template.yml`). 멱등 마커로 재실행 skip | ✅ 자동 |
| 폐쇄망 SystemVM 부트스트랩 | 인터넷 미사용. **번들 동봉 로컬 qcow2**를 설치 중 secondary에 시드 (§3.5) | ✅ 폐쇄망 지원 |

**전체 판정: 수정(구성 선택) 후 설치 가능.**
설치기는 스토리지 "준비"까지만 자동화하고, CloudStack **등록은 운영자 몫**이다. 기본값(`nfs_export_host_ip` 공백)으로 두면 Secondary가 관리 VM 로컬 디렉터리가 되어 SSVM이 접근하지 못할 수 있으므로, 프로덕션에서는 `nfs_export_host_ip`를 반드시 지정해야 한다.

---

## 1. 핵심 동작 흐름 (실제 코드 기준)

### 1-1. `/export/primary`, `/export/secondary`는 어디에 생기나

`storage.yml`은 `kvm_hosts` 역할의 일부이고(`kvm_hosts/tasks/main.yml:7`), `site.yml`에서 이 역할은 **`kvm_hosts` 그룹 전체**(master + 추가 Host)에 적용된다(`site.yml:32-36`). 또한 preflight에서 master도 `kvm_hosts` 그룹에 포함된다(`load_config.yml:98-103`).

→ **결론: `10.10.10.3`, `10.10.10.4`, `10.10.10.5` 각각의 로컬 디스크에 `/export/primary`와 `/export/secondary`가 개별 생성되고, 각자 NFS export된다.** (확인됨, 추측 아님)

`storage.yml`이 각 호스트에서 하는 일:

1. `/export/primary`, `/export/secondary` 디렉터리 생성 — `owner=nobody`, `group=nobody(Rocky)/nogroup(Ubuntu)`, `mode=0777` (`storage.yml:7-17`)
2. `/etc/idmapd.conf`의 `Domain` 설정 (`storage.yml:19-37`)
3. `kvm_hosts` 그룹의 모든 IP에서 `/{prefix}` CIDR 목록 산출 (`storage.yml:39-51`)
4. `/etc/exports`에 두 경로를 등록 —
   옵션 `(rw,async,no_root_squash,no_subtree_check)`, 허용 대상은 위 CIDR (`storage.yml:53-64`)
5. `exportfs -ra` 적용 (`storage.yml:66-69`)
6. `rpcbind` + `nfs-server`(Ubuntu는 `nfs-kernel-server`) 기동 (`storage.yml:71-81`)

### 1-2. 관리 VM의 Secondary 처리 (`nfs_mount.yml`)

`configure/main.yml:7`에서 `nfs_mount.yml`이 관리 VM 내부에서 실행된다.

- `nfs_export_host_ip`가 **비어 있으면(기본값)** → NFS 마운트를 하지 않고 관리 VM **로컬 디렉터리** `/export/secondary`를 그대로 Secondary로 사용 (`nfs_mount.yml:5-6`, `load_config.yml:169-171`)
- `nfs_export_host_ip`가 **지정되면** → `/etc/fstab`에 항목 추가 후 `그 호스트:/export/secondary`를 관리 VM에 NFS 마운트 (`nfs_mount.yml:26-47`)

> ⚠️ 주의: 로컬 모드에서 관리 VM은 `/export/secondary` 디렉터리를 **생성만** 하고 **NFS export하지 않는다**(`nfs_mount.yml`에 `/etc/exports` 조작 없음). 즉 로컬 모드의 Secondary는 관리 VM 밖에서 네트워크로 접근할 수 없다.

### 1-3. SystemVM Template 시드

`systemvm_template.yml`은 `cloud-install-sys-tmplt -m {{ secondary_storage }} -u file://... -h kvm -F`로 템플릿을 Secondary에 시드하고 `.namuvirt-systemvm-seeded` 마커로 멱등성을 보장한다.

**이 태스크는 이제 설치 흐름에 포함된다** — `configure/main.yml`이 `start_management` 직후 `import_tasks: systemvm_template.yml`로 자동 호출한다. 전제조건(secondary 준비 `nfs_mount` → cloudstack-common `namuvirt_install` → DB `database_init` → `start_management`)을 만족하는 위치이며, 컨트롤러의 번들 qcow2를 관리 VM으로 copy 후 `file://`로 시드한다. 스크립트/원본 파일이 없으면 `fail`로 즉시 중단한다. `./upload-os-image.sh seed-systemvm`은 재시드/장애 복구용 수동 경로로 남는다.

### 1-4. CloudStack Zone/Storage 등록

`configure/main.yml` 전체를 확인한 결과 **Zone·Pod·Cluster·Host·Primary·Secondary를 CloudStack에 등록하는 태스크가 없다**(`main.yml:16-17` 주석: "zone/secondary storage는 설치 후 운영자가 CloudStack에서 구성"). `deployDataCenter`/marvin/`createStoragePool` 류 호출도 코드베이스에 없다.

→ **결론: verify.md 9번 항목 중 Zone/Primary/Secondary 등록, System VM 기동, Zone 활성화는 모두 수동이다.**

---

## 2. Primary Storage 판정 (verify.md §6, §D)

| 항목 | 판정 |
|---|---|
| **실제 위치** | 각 KVM Host의 **로컬 디스크** `/export/primary` (master·host 모두 개별) |
| **접근 주체** | KVM Host(libvirt/qemu) ↔ Storage |
| **프로토콜** | 로컬 디렉터리 + NFS export 준비됨(v3/v4, `no_root_squash`) |
| **공유 여부** | 코드는 "각 호스트 로컬 디렉터리 + 각자 export"만 함. **자동 공유 마운트 없음** |
| **CloudStack 등록 방식** | **수동** (설치기는 등록하지 않음) |
| **멀티 KVM Host 지원** | 운영자 등록 방식에 전적으로 의존 (아래 위험 참조) |
| **장애 위험** | 아래 참조 |

### 위험

1. **공유 스토리지 오등록 위험 (High, verify.md:160-161).**
   각 호스트가 자기 로컬 `/export/primary`를 export한다. 운영자가 이를 클러스터 Primary로 등록할 때 실수하면(예: 호스트별 로컬 경로를 개별 Primary로) **live migration 불가**, 스케줄링 정합성 붕괴. 설치기는 이를 **방지하지 않는다** — 준비만 할 뿐 등록 판단은 운영자 몫.
   → 권장: **하나의 호스트(예: master `10.10.10.3`)의 `/export/primary`를 단일 NFS Primary**로 등록하고 모든 Host가 동일 URL(`nfs://10.10.10.3/export/primary`)을 바라보게 한다. 그래야 migration 가능.

2. **Primary/Secondary 동일 파일시스템·디스크 (Medium, verify.md:167-168).**
   `/export/primary`와 `/export/secondary`가 같은 `/export`(동일 물리 디스크)에 위치할 가능성이 높다. VM I/O(Primary)와 템플릿/스냅샷(Secondary)이 디스크를 공유하면 성능 간섭·동시 장애 위험.
   → 권장: 별도 디스크/마운트 분리.

3. **`no_root_squash` (Medium, 보안).**
   `storage.yml:58`에서 export 옵션에 `no_root_squash` 사용. CloudStack/qemu 호환을 위한 선택이지만 export 대상 CIDR을 KVM 서브넷으로 제한하고 있어(같은 파일) 완화됨. 폐쇄망 전제라면 수용 가능.

4. **용량 부족 검사 없음 (Low).** `storage.yml`에 여유 용량 확인 태스크가 없다. → preflight에 `df` 임계 검사 추가 권장.

---

## 3. Secondary Storage 판정 (verify.md §7, §D)

| 항목 | 판정 |
|---|---|
| **실제 위치** | 기본(로컬 모드): 관리 VM 내부 로컬 `/export/secondary` / NFS 모드: `nfs_export_host_ip` 호스트의 `/export/secondary` |
| **접근 주체** | SSVM(주), 관리 서버(템플릿 시드 시) |
| **프로토콜** | 로컬 dir 또는 NFS 마운트 |
| **공유 여부** | 로컬 모드 = 비공유(관리 VM 국한) / NFS 모드 = 공유 |
| **CloudStack 등록 방식** | **수동** (URL은 운영자가 지정) |
| **멀티 Host 지원** | NFS 모드에서만 안전 |
| **장애 위험** | 아래 참조 |

### 핵심 판정 — verify.md:195-197 질문에 대한 답

> **"`nfs_export_host_ip`가 비어 있을 때 Secondary를 관리 VM 로컬 디렉터리로 쓰는 구성이 실제 CloudStack Secondary로 정상 동작하는가?"**

**부분적으로만. 프로덕션에서는 위험하다.** 근거:

- CloudStack Secondary의 주 접근 주체는 **SSVM**이며, SSVM은 Secondary를 **NFS로 마운트**해서 접근한다(verify.md:369).
- 로컬 모드에서 관리 VM은 `/export/secondary`를 **로컬 dir로만 두고 NFS export하지 않는다**(`nfs_mount.yml`에 export 없음). 따라서 SSVM이 `nfs://관리VM-IP/export/secondary`로 접근하려 해도 **export가 없어 마운트 실패** 가능.
- 즉 로컬 모드는 "관리 서버에서 템플릿을 로컬 파일로 시드"하는 초기/검증 용도로는 되지만, **SSVM이 네트워크로 접근해야 하는 정식 Secondary로는 부적합**.

### 위험

1. **로컬 모드 Secondary의 SSVM 접근 불가 (High, verify.md:185-186, 195-197).**
   → 권장: **프로덕션은 `nfs_export_host_ip`를 반드시 지정**(예: `10.10.10.3`). 그러면 관리 VM이 master의 export를 마운트하고, CloudStack Secondary를 `nfs://10.10.10.3/export/secondary`로 등록하면 SSVM·관리 VM 모두 동일 NFS를 공유한다. KVM Host들은 이미 Secondary도 export하므로(§1-1) 별도 NFS 서버 불필요.

2. **로컬 디렉터리 사용 시 재부팅/백업/용량 (Medium, verify.md:191).** 관리 VM 디스크에 종속되어 백업·용량 관리가 어렵다.

3. **SystemVM 시드 — 설치 흐름에 포함됨 (해소, verify.md:187-190).**
   `configure/main.yml`이 `start_management` 직후 `systemvm_template.yml`을 자동 실행해 secondary에 시드 + DB 등록한다(멱등 마커 `.namuvirt-systemvm-seeded`). 따라서 운영자가 `seed-systemvm`을 별도로 돌릴 필요가 없어졌다. 다만 **secondary가 SSVM이 접근 가능한 실제 스토리지여야** 시드가 유효하므로 로컬 모드 함정(§3 위험 1)은 그대로 유효 → `nfs_export_host_ip` 지정 권장. 이후 게스트 이미지는 `register`(SSVM 경유). 상세는 §3.5, [[project_cloudstack_systemvm_bootstrap]].

---

## 3.5. 폐쇄망 SystemVM 부트스트랩 (Zone 등록 시 템플릿 출처)

> 핵심 질문: **"Zone 등록 시 CloudStack이 SSVM/CPVM을 최초 생성하는데, 그 템플릿을 폐쇄망에서 어디서 가져오나?"**
> 답: **외부에서 안 가져온다. 폐쇄망 번들에 동봉된 로컬 qcow2를 Zone 등록 *전에* secondary storage로 시드해두고 CloudStack이 그것을 쓴다.**

### 일반 CloudStack과의 차이

- 표준 CloudStack: SystemVM 템플릿을 `download.cloudstack.org`에서 인터넷으로 내려받음 → **폐쇄망 불가**.
- namuVIRT: 이 경로를 **완전히 우회**. 인터넷 접근 0회로 부트스트랩한다.

### 템플릿 출처 (확인된 코드)

- 파일: `images/SystemVM-Template-KVM.qcow2` — config.yaml `management.systemvm_template`, 기본 `/mnt/namuvirt/images/SystemVM-Template-KVM.qcow2`
- 제공 방식: 설치 이미지에 넣지 않고 **외부 mount**(`/mnt/namuvirt/images/`)로 공급 (`systemvm_template.yml:3`). 즉 설치 매체 제작 시 인터넷 되는 환경에서 미리 받아 번들에 동봉.

### 시드 흐름 — **설치 중 자동 실행** (`configure/main.yml` → `systemvm_template.yml`)

```
images/SystemVM-Template-KVM.qcow2  (폐쇄망 번들 로컬 파일, 컨트롤러 외부 mount)
   │  (1) copy: 컨트롤러 → 관리 VM {{ work_dir }}/systemvm/   (systemvm_template.yml)
   ▼
관리 VM: sudo cloud-install-sys-tmplt -m {{ secondary }} -u file://.../<파일> -h kvm -F
   │  (2) secondary storage에 이미지 배치 + cloud DB(vm_template)에 "SystemVM 템플릿"으로 등록
   │      멱등: {{ secondary }}/.namuvirt-systemvm-seeded 마커 (creates:) → 재실행 skip
   ▼
{{ secondary }}/template/tmpl/1/3/   ← 시드 완료 (설치가 끝나면 이미 존재)
   │
   │  (3) 운영자가 CloudStack UI에서 Zone 등록
   ▼
CloudStack이 SSVM / Console Proxy VM / Virtual Router 생성 시
secondary storage의 이 로컬 템플릿을 복사해 부팅  →  인터넷 접근 0회
```

> 참고: `./upload-os-image.sh seed-systemvm`은 동일 로직을 임시 HTTP(`file://` 대신 `http://`)로 수행하는 **수동/재시드용** 경로로 남아 있다. 설치 자동화가 실패했거나 secondary URL을 나중에 바꿔 재시드할 때 사용한다.

### 반드시 지켜야 할 조건

1. **`cloud-install-sys-tmplt`는 단순 파일 복사가 아니다.** secondary에 이미지 배치 + **cloud DB에 SystemVM 템플릿으로 등록**을 함께 수행한다. 그래서 Zone 등록 시 CloudStack이 "템플릿이 이미 있다"고 인식하고 SSVM/CPVM/VR을 즉시 찍어낸다.
2. **시드는 설치 중 완료되고, Zone 등록은 그 이후.** 시드가 `start_management` 직후 자동 실행되므로, 설치가 정상 종료되면 Zone 등록 전에 이미 시드가 끝나 있다. (시드 전에 Zone을 만들면 SSVM/CPVM이 영영 안 뜨는데, 설치 흐름이 순서를 보장한다.)
3. **자동 시드는 `file://` 직접 방식(순환 회피).** SSVM 자체가 SystemVM 템플릿으로 만들어지는 인스턴스라 `register-systemvm`(SSVM 경유)은 최초엔 순환이다. `systemvm_template.yml`은 `cloud-install-sys-tmplt`를 `file://`로 직접 호출해 이 순환을 끊는다. 이후 업데이트/게스트 이미지는 `register`(SSVM 경유).
4. **secondary가 시드 대상과 동일해야 한다.** 시드 `-m` 경로(`storage.secondary`)와, 나중에 CloudStack에 등록하는 Secondary URL이 **같은 실제 스토리지**를 가리켜야 SSVM이 시드된 템플릿을 본다. → §3의 로컬 모드 함정과 직결: 로컬 모드로 관리 VM 안에만 시드하면 SSVM이 접근 못 한다. **`nfs_export_host_ip` 지정(NFS 모드)** 이 폐쇄망에서도 안전한 조합.
5. **누락 시 즉시 중단(fail).** `systemvm_template.yml`은 `cloud-install-sys-tmplt` 스크립트나 번들 qcow2가 없으면 명확한 메시지로 설치를 중단시킨다(경고 후 진행 → 조용한 SSVM 부팅 실패 방지).

### 폐쇄망 체크리스트

```bash
# (0) 번들에 SystemVM 템플릿 qcow2 가 동봉되어 있는지 (설치 매체 제작 시점)
ls -lh /mnt/namuvirt/images/SystemVM-Template-KVM.qcow2

# (1) 시드는 설치 중 자동 수행됨 — 설치 후 결과만 확인 (관리 VM)
ls /export/secondary/template/tmpl/1/3/
ls /export/secondary/.namuvirt-systemvm-seeded          # 멱등 마커
cloudmonkey list templates templatefilter=all name=systemvm   # DB 등록 확인

# (2) 이후 Zone 등록 → SSVM/CPVM 자동 생성
cloudmonkey list systemvms filter=name,state            # Running 확인

# (참고) 자동 시드 실패/재시드 시 수동 경로 (임시 HTTP 방식)
./upload-os-image.sh seed-systemvm --file images/SystemVM-Template-KVM.qcow2 --secondary /export/secondary --hypervisor kvm
```

→ 관련 메모: [[project_cloudstack_systemvm_bootstrap]], [[project_namuvirt_installer]]

---

## 4. Ceph(세프) 적용 가능성 (verify.md §8)

현재 코드는 **NFS 경로만 구현**하며 Ceph 관련 로직은 없다(확인됨). 전환 시 방향만 정리:

- **Primary → Ceph RBD**: 각 KVM Host에 `ceph-common`, `/etc/ceph/ceph.conf`, `client.<user>` keyring, libvirt secret(`virsh secret-define` + `secret-set-value`) 필요. CloudStack Primary 등록 시 `rbd://<user>:<secret>@<mon-host>/<pool>` 형태로 Monitor 주소·Pool·사용자·인증키 지정. RBD 사용 시 `/export/primary` 경로는 불필요.
- **Secondary → RBD 직접 사용 불가.** CephFS + NFS-Ganesha로 NFS export하거나, RGW를 S3 호환 Secondary(Object Storage)로 사용. RGW는 스냅샷·일부 기능 제약 있음.
- Primary·Secondary를 **동일 Ceph 클러스터**에 두면 장애 도메인이 겹쳐 클러스터 장애 시 동시 마비. 분리 권장.

이 부분은 현재 스크립트 범위 밖이므로 별도 구현 과제로 분류한다.

---

## 5. 권장 config.yaml (프로덕션)

```yaml
management:
  vm_ip: 10.10.10.10
  # ...
  nfs_export_host_ip: 10.10.10.3   # ★ 지정: master export를 Secondary로 사용 (로컬 모드 회피)

storage:
  primary: /export/primary
  secondary: /export/secondary
```

이후 CloudStack UI/API에서 **수동** 등록:
- Primary: `nfs://10.10.10.3/export/primary` (단일 공유 Primary, 전 Host 공유 → migration 가능)
- Secondary: `nfs://10.10.10.3/export/secondary`
- 최초 SystemVM 시드: `./upload-os-image.sh seed-systemvm`

---

## 6. 설치 후 확인 명령

```bash
# (각 KVM Host: 10.10.10.3/.4/.5) export 확인
sudo exportfs -v
showmount -e 127.0.0.1
systemctl is-active nfs-server rpcbind   # Ubuntu: nfs-kernel-server

# (관리 VM 10.10.10.10) Secondary 마운트/시드 확인
mountpoint /export/secondary || echo "로컬 모드(비공유)"
ls -la /export/secondary/template/tmpl/1/3/   # SystemVM 템플릿 시드 여부
ls /export/secondary/.namuvirt-systemvm-seeded

# (관리 VM) SSVM이 Secondary NFS에 접근 가능한지
showmount -e 10.10.10.3

# CloudStack 등록/기동 상태 (수동 등록 이후)
cloudmonkey list storagepools
cloudmonkey list imagestores
cloudmonkey list systemvms   # SSVM, Console Proxy VM 이 Running 인지
```

---

## 7. verify.md 원칙 대비 요약

- Storage 경로는 **단순 로컬 경로**로 준비되고 **NFS export만 자동**이며, "공유 스토리지"인지는 **운영자의 CloudStack 등록에 달려 있다** (verify.md:366).
- Primary 접근 주체 = KVM Host, Secondary 접근 주체 = SSVM. **로컬 모드 Secondary는 SSVM이 접근 못 하는 구조적 위험**이 있다 (verify.md:367-369).
- "문제가 있을 수 있다"가 아니라: **로컬 모드(`nfs_export_host_ip` 공백) + 다중 Host에서 SSVM 접근/마이그레이션이 깨진다.** 확인 명령은 §6, 수정안은 §5.