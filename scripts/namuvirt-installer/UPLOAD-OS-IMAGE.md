# OS 이미지 / 템플릿 등록 가이드 (`upload-os-image.sh`)

namuVIRT 설치가 끝난 뒤, **게스트 OS 템플릿**과 **SystemVM 템플릿**을 CloudStack 에 등록하는 방법이다.
`upload-os-image.sh` 는 설치(`install-namuvirt.sh`)와 **별개인 운영 도구**로, 관리 VM 에 SSH 접속해
관리 VM 의 `cmk`(CloudMonkey)로 템플릿을 등록한다.

> 이 문서는 **번들 디렉터리 안에서 실행**하는 것을 전제로 한다:
> `release/namuvirt-installer-<version>/` (여기에 `upload-os-image.sh`, `config.yaml`, `images/`, `ssh/` 가 있다)

---

## 0. 한눈에

```
release/namuvirt-installer-<version>/
  upload-os-image.sh        ← 실행 도구
  config.yaml               ← 관리 VM IP / ssh_user / key 경로를 여기서 읽음
  ssh/id_ed25519            ← 관리 VM 접속 키
  images/                   ← 등록할 qcow2 / ova 파일들 (여기 있어야 --file 로 지정)
    NAMU-Rocky-8-10.qcow2
    SystemVM-Template-KVM.qcow2
    NAMU-Ubuntu-24-04.qcow2
    CentOS-5-5-64-bit-no-GUI-KVM.qcow2
    SystemVM-Template-vSphere.ova           (VMware 환경용)
    CentOS-5-3-64-bit-no-GUI-vSphere.ova    (VMware 환경용)
```

`--file` 을 쓰면 로컬 파일을 **임시 HTTP 서버(설치 이미지 내장 python)로 잠깐 노출** → SSVM 이 받아가고
→ `isready=true` 까지 대기 → 임시 서버 자동 종료, 까지 한 번에 처리한다.

---

## 1. 전제조건

1. **번들 디렉터리에서 실행** (스크립트가 `config.yaml`·`ssh/`·`images/` 를 상대경로로 찾는다):
   ```bash
   cd release/namuvirt-installer-<version>
   ```
2. **등록할 이미지가 `images/` 안에 있을 것** (`--file images/<파일명>`).
3. **docker + 로드된 설치 이미지가 있을 것** — `--file` 의 임시 HTTP 서버로 쓰인다.
   (설치를 이 번들로 했다면 이미 충족.)
   - 임시 서버는 **`--network host`** 로 실행 호스트(마스터)의 포트(기본 8000)에 직접 bind 한다.
     따라서 그 포트가 **비어 있고**(`ss -ltnp | grep 8000`), **방화벽이 열려 있어야** SSVM 이 받아간다.
     (`-p` 포트매핑을 안 쓰므로 docker 의 iptables NAT 체인이 깨져 있어도 영향 없음.)
4. **cmk 설정** — 관리 VM 에서 1회:
   ```bash
   # 관리 VM(예: 10.10.14.194) 에 접속해서
   cmk set url http://<관리VM_IP>:8080/client/api
   cmk set username admin
   cmk set password <admin_pw>
   # 또는 apikey/secretkey 방식:
   #   cmk set apikey <API_KEY>; cmk set secretkey <SECRET_KEY>
   cmk sync
   ```

---

## 2. 실행 전 확인

```bash
# cmk 연결/동기화 확인
./upload-os-image.sh check

# 이미 등록된 템플릿 목록 (id/name/ostype/isready)
./upload-os-image.sh list
```

**zoneid / ostypeid** 는 등록 시 필요하다. 관리 VM 에서 조회:
```bash
cmk list zones filter=id,name
cmk list ostypes filter=id,description | grep -iE "rocky|ubuntu|centos"
```
- `--zone` = 위 zone 의 **id**
- `--ostype` = 위 ostype 의 **id** (게스트 템플릿 등록 시 필수)

---

## 3. 명령

### 대화형 메뉴 (권장) — 인자 없이 실행
```bash
./upload-os-image.sh          # (= ./upload-os-image.sh menu)
```
메뉴에서 **check / list / register / register-systemvm / seed-systemvm** 를 고르고, register 를 고르면:
1. `images/` 의 이미지 목록에서 **선택**
2. 템플릿 **이름** 입력(기본=파일명)
3. **Zone** 목록에서 선택 (cmk 자동 조회)
4. **Hypervisor** 선택 (KVM/VMware/…)
5. **Format** 선택 (파일 확장자 기준 추천)
6. (게스트 템플릿) **OS Type** 검색어 입력 → 목록에서 선택 → **ostypeid 자동 입력**
7. 요약 확인 후 등록 → `isready` 대기까지 자동

→ zoneid/ostypeid 를 손으로 찾을 필요가 없다. (cmk 설정은 §1 선행 필요)

### 명령 5종 (스크립트/CLI 용)

| 명령 | 용도 | 필수 인자 |
|------|------|-----------|
| `check` | cmk 연결 확인 | — |
| `list` | 등록 템플릿 목록 | — |
| `register` | **게스트 OS 템플릿** 등록 (SSVM 경유) | `--name` `--zone` `--ostype` + (`--file`/`--url`) |
| `register-systemvm` | **SystemVM 등록 (SSVM 경유)** — SSVM 이 이미 떠 있을 때(업데이트용) | `--name` `--zone` + (`--file`/`--url`) |
| **`seed-systemvm`** | **★ SystemVM 부트스트랩 시드 (SSVM 없이 직접, `cloud-install-sys-tmplt`)** — 폐쇄망 최초 필수 | (없음; `--file`/`--secondary`/`--hypervisor` 선택) |

> **register-systemvm vs seed-systemvm**: `register-systemvm` 은 **SSVM 이 받아가는** 방식이라 SSVM 이 있어야 한다.
> 최초 설치엔 SSVM 이 없으므로(SSVM 자체가 SystemVM 템플릿으로 만들어짐 → 순환) **반드시 `seed-systemvm`** 으로
> 먼저 시드해야 CloudStack 이 SSVM 을 부팅할 수 있다.

### 공통 옵션
| 옵션 | 기본 | 설명 |
|------|------|------|
| `--file <경로>` | — | 로컬 파일(권장). 임시 HTTP 서버 자동 기동 → 등록 → isready 대기 → 종료 |
| `--url <URL>` | — | 이미 HTTP 로 접근 가능한 이미지 URL (임시 서버 안 씀) |
| `--name <이름>` | — | 템플릿 이름 |
| `--zone <id>` | — | zoneid |
| `--ostype <id>` | — | ostypeid (게스트 템플릿 필수) |
| `--format` | `QCOW2` | 이미지 포맷. `.ova` 는 `OVA` |
| `--hypervisor` | `KVM` | `KVM` / `VMware` 등 |
| `--displaytext` | =name | 표시 이름 |
| `--serve-ip` | config master IP | 임시 서버 IP (SSVM 이 도달 가능해야 함). `--network host` 라 실행 호스트 IP |
| `--serve-port` | `8000` | 임시 서버 포트 (실행 호스트에 직접 bind — 비어 있어야 함) |
| `--wait-timeout` | `1800` | isready 대기 최대 초 |
| `-- <k=v ...>` | — | `--` 뒤는 cmk 로 그대로 전달(고급) |

---

## 4. 파일별 등록 명령 (KVM 환경 기준)

> `<...>_id` 는 §2 의 `cmk list ostypes` 에서 얻은 값으로 치환.

### 4.1 SystemVM 템플릿 — **최초엔 `seed-systemvm` (부트스트랩, 필수)**

CloudStack 의 SSVM/CPVM 은 **SystemVM 템플릿으로 만들어지는 인스턴스**다. 따라서 최초 설치 시엔 SSVM 이
없어 `register-systemvm`(SSVM 경유)으로는 못 넣는다(순환). **`cloud-install-sys-tmplt` 로 secondary storage 에
직접 시드**해야 한다 — 이게 `seed-systemvm`. **SSVM/인터넷 불필요(폐쇄망 OK).**

```bash
# ★ 최초 부트스트랩 — zone/secondary storage 준비 후, SSVM 부팅 전에 실행
./upload-os-image.sh seed-systemvm \
  --file images/SystemVM-Template-KVM.qcow2 \
  --secondary /export/secondary --hypervisor kvm
# (--file/--secondary/--hypervisor 생략 시: images/SystemVM-Template-KVM.qcow2,
#  config.yaml storage.secondary, kvm 을 기본값으로 사용)
```
→ 시드 완료 후 CloudStack 이 이 로컬 템플릿으로 **SSVM/CPVM 을 부팅**한다. (SSVM 이 `Running` 되면 이후
게스트 이미지는 §4.2 로 등록)

> `register-systemvm`(SSVM 경유)은 **이미 SSVM 이 떠 있을 때** SystemVM 을 교체/업데이트하는 용도다:
> ```bash
> ./upload-os-image.sh register-systemvm --file images/SystemVM-Template-KVM.qcow2 \
>   --name systemvm-kvm --zone 1 --hypervisor KVM --format QCOW2
> ```

### 4.2 게스트 OS 템플릿 (KVM)
```bash
# Ubuntu 24.04 게스트
./upload-os-image.sh register \
  --file images/NAMU-Ubuntu-24-04.qcow2 \
  --name "Ubuntu-24.04" --ostype <ubuntu24_id> --zone 1

# CentOS 5.5 게스트
./upload-os-image.sh register \
  --file images/CentOS-5-5-64-bit-no-GUI-KVM.qcow2 \
  --name "CentOS-5.5" --ostype <centos5_id> --zone 1

# (선택) Rocky 8 을 게스트 템플릿으로도 제공하려면
./upload-os-image.sh register \
  --file images/NAMU-Rocky-8-10.qcow2 \
  --name "Rocky-8" --ostype <rocky8_id> --zone 1
```

### 4.3 VMware(vSphere) 파일 — **VMware 클러스터/존이 있을 때만**
```bash
./upload-os-image.sh register-systemvm \
  --file images/SystemVM-Template-vSphere.ova \
  --name "systemvm-vsphere" --zone <vmware_zone> --hypervisor VMware --format OVA

./upload-os-image.sh register \
  --file images/CentOS-5-3-64-bit-no-GUI-vSphere.ova \
  --name "CentOS-5.3" --ostype <centos5_id> --zone <vmware_zone> --hypervisor VMware --format OVA
```

---

## 5. 파일별 요약표

| images/ 파일 | 종류 | 명령 | 하이퍼바이저/포맷 | 비고 |
|---|---|---|---|---|
| `SystemVM-Template-KVM.qcow2` | SystemVM | `register-systemvm` | KVM / QCOW2 | KVM 존 필수 |
| `NAMU-Rocky-8-10.qcow2` | 관리 VM 골든 | (설치가 사용) | KVM / QCOW2 | 게스트 템플릿 등록은 **선택** |
| `NAMU-Ubuntu-24-04.qcow2` | 게스트 | `register` | KVM / QCOW2 | `--ostype` 필요 |
| `CentOS-5-5-...-KVM.qcow2` | 게스트 | `register` | KVM / QCOW2 | `--ostype` 필요 |
| `SystemVM-Template-vSphere.ova` | SystemVM | `register-systemvm` | VMware / OVA | **VMware 존에서만** |
| `CentOS-5-3-...-vSphere.ova` | 게스트 | `register` | VMware / OVA | **VMware 존에서만** |

---

## 6. 추천 순서

```bash
cd release/namuvirt-installer-<version>
./upload-os-image.sh check                         # 1) cmk 연결 확인
./upload-os-image.sh seed-systemvm                 # 2) ★ SystemVM 부트스트랩 시드 (SSVM 뜨기 전, 최초 1회)
#    → CloudStack 이 SSVM/CPVM 부팅 (cmk list systemvms 로 Running 확인)
# 3) SSVM 이 Running 된 뒤, 게스트 템플릿들 register (--ostype 지정)
./upload-os-image.sh list                          # 4) isready=true 확인
```

- **순서 주의**: SSVM 이 없으면 게스트 템플릿을 받아올 주체가 없다. 그래서 **seed-systemvm → SSVM Running →
  게스트 register** 순서다. `cmk list systemvms filter=name,state` 로 SSVM 이 `Running` 인지 확인 후 진행.
- 각 `register --file` 은 SSVM 다운로드/변환이 끝날 때까지(`isready`) 기다렸다가 임시 서버를 내린다.
  오래 걸리면 `--wait-timeout` 을 늘린다.

---

## 7. 주의사항 / 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `관리 VM 에 cmk 가 없다` | 관리 VM 에 cmk 설치 + `cmk set url/username/apikey; cmk sync` |
| `cmk sync/list 실패` | url/자격증명 확인. `cmk set url http://<VM_IP>:8080/client/api` |
| `--file 은 docker 가 필요하다` | 관리 VM(또는 실행 호스트)에 docker + 로드된 설치 이미지 필요(임시 서버용) |
| `임시 서버로 쓸 namuvirt 설치 이미지가 없다` | `docker images` 로 `namuvirt-*-setup` 이미지 확인 (설치 시 load 됨) |
| `iptables: No chain/target/match by that name` (임시 서버 기동 실패) | KVM 호스트의 firewalld/iptables 커스텀으로 docker `DOCKER` NAT 체인이 깨진 경우. 임시 서버는 `--network host` 로 실행하므로 보통 영향 없지만, 그래도 나면 `sudo systemctl restart docker` 로 체인 재생성 후 재시도 |
| `포트 8000 사용중` (임시 서버 기동 실패) | 다른 프로세스/이전 잔여 컨테이너가 8000 점유. `ss -ltnp \| grep 8000` 확인, `docker rm -f $(docker ps -aq --filter name=namuvirt-imgserve)` 정리, 또는 `--serve-port` 변경 |
| 등록은 됐는데 `isready` 안 됨 | SSVM 이 `--serve-ip:포트` 에 도달 못 함(방화벽/네트워크). `--serve-ip`/`--serve-port` 조정 후 재시도 |
| `.ova` 등록 실패 | VMware 하이퍼바이저 클러스터가 없는 KVM 존에는 등록 불가. KVM 파일만 등록 |
| `--ostype (ostypeid) 가 필요하다` | 게스트 템플릿은 ostypeid 필수 — `cmk list ostypes` 로 조회 |
| `--zone 가 필요하다` | zoneid 필수 — `cmk list zones` 로 조회 |

> 전체 옵션은 `./upload-os-image.sh --help` 로도 볼 수 있다.
