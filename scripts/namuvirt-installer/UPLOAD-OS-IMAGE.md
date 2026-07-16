# OS 이미지 / 템플릿 등록 콘솔 (`upload-os-image.sh`)

namuVIRT(CloudStack) 설치 후 **SystemVM 템플릿**과 **게스트 OS 템플릿**을 등록하는 **대화형 콘솔**이다.
관리 VM 의 `cmk` 로 동작하며, 번들 디렉터리에서 인자 없이 실행하면 아래 메뉴가 뜬다.

```bash
cd release/namuvirt-installer-<version>
./upload-os-image.sh
```

```
                               _    __________  ______
   ____  ____ _____ ___  __  _| |  / /  _/ __ \/_  __/
  / __ \/ __ `/ __ `__ \/ / / / | / // // /_/ / / /
 / / / / /_/ / / / / / / /_/ /| |/ // // _, _/ / /
/_/ /_/\__,_/_/ /_/ /_/\__,_/ |___/___/_/ |_| /_/
  OS 이미지 / SystemVM 템플릿 등록 콘솔   관리 VM: 10.10.12.191
  ────────────────────────────────────────────────────────

  작업을 선택하세요:
     1) check   (cmk 연결 확인)
     2) list    (등록 템플릿 목록)
     3) infra   (zone/secondary/host/systemvm 확인)
     4) register (게스트 OS 템플릿 등록)
     5) register-systemvm (SystemVM 등록 — SSVM 경유, 업데이트용)
     6) seed-systemvm (SystemVM 부트스트랩 — SSVM 없이 직접 시드)
     0) 종료
  번호>
```

**화면 동작(공통):**
- 항목을 고르면 **화면이 정리(clear)** 되고, 배너 아래에 그 작업 결과만 나온다(스크롤 누적 없음).
- 결과를 본 뒤 **`Enter`** 를 누르면 메뉴로 돌아간다.
- **오류가 나도 콘솔이 종료되지 않는다.** 오류 메시지(예: `등록된 zone 이 없습니다`)를 보여준 뒤 메뉴로 복귀한다.
- 조회 결과가 없으면 `(조회된 결과가 없습니다)` 로 표시된다.

---

## 등록 방식 요약 (2-track)

| 대상 | 메뉴 | 이유 |
|------|------|------|
| **SystemVM** (최초 부트스트랩) | **`6) seed-systemvm`** | 폐쇄망 최초엔 SSVM 이 없어 secondary 에 **직접 시드**해야 SSVM 이 뜬다(순환). |
| **게스트 OS** | **`4) register`** | SSVM 이 뜬 뒤 등록. (원하면 CloudStack admin 웹콘솔의 *Register Template* 로도 가능) |

**권장 순서**: `3) infra` 로 존/스토리지 확인 → `6) seed-systemvm` → (SSVM `Running`) → `4) register`.

---

## 1. 사전 조건

1. **번들 디렉터리에서 실행** — 스크립트가 `config.yaml`·`ssh/`·`images/` 를 상대경로로 찾는다.
2. **cmk 설정** (최초 1회, 관리 VM):
   ```bash
   cmk set url http://<관리VM_IP>:8080/client/api
   cmk set username admin
   cmk set password <admin_pw>          # 또는 apikey/secretkey
   cmk sync
   ```
3. **존/스토리지 선구성** — admin 콘솔의 *Add Zone* 마법사로 물리망·파드·클러스터·primary/secondary
   storage·KVM 호스트를 먼저 구성한다. `3) infra` 로 비어 있지 않은지 확인한다.

---

## 2. 메뉴별 안내

### `1) check` — cmk 연결 확인
관리 VM 의 cmk 가 CloudStack API 에 붙는지 `cmk sync` 로 점검한다.
```
  ▸ cmk 연결 확인
  [00:12:03] 관리 VM(10.10.12.191) 에서 cmk sync ...
  ✔ cmk 연결 정상

  [Enter] 를 눌러 메뉴로 돌아갑니다...
```
실패하면 `✘ ERROR cmk sync/list 실패 …` 를 보여주고 메뉴로 복귀 → §1.2 의 cmk 설정을 확인한다.

### `2) list` — 등록된 템플릿 목록
현재 등록된 템플릿(id/name/ostype/공개/isready)을 보여준다.
```
  ▸ 등록된 템플릿 (templates)
    id                                    name          ostypename    ispublic  isready
    ...                                   Ubuntu-24.04  Ubuntu ...     true      true
```
아직 없으면 `(조회된 결과가 없습니다)`.

### `3) infra` — 인프라 현황 (★ 등록 전 먼저 확인)
zone·secondary storage·host·systemvm 을 한 화면에 보여준다. **어느 항목이든 비면 그 자리에 `(조회된 결과가 없습니다)`** 가 뜬다.
```
  ▸ Zones
    (조회된 결과가 없습니다)
  ▸ Secondary storage (imagestores)
    (조회된 결과가 없습니다)
  ▸ Hosts (KVM / Routing)
    (조회된 결과가 없습니다)
  ▸ SystemVMs
    (조회된 결과가 없습니다)
```
위처럼 **Zones 가 비어 있으면 존 부트스트랩이 안 된 것** — admin 콘솔의 *Add Zone* 으로 존/스토리지/호스트를
먼저 구성한다. (전부 채워져야 seed/register 가 의미 있다.)

### `4) register` — 게스트 OS 템플릿 등록
`images/` 이미지를 골라 게스트 템플릿으로 등록한다. **등록된 zone 이 없으면 진행하지 않고 안내**한다.
순서대로 화면이 나온다(각 단계는 번호로 선택):

```
  ▸ images/ 이미지 선택
     1) images/NAMU-Ubuntu-24-04.qcow2
     2) images/CentOS-5-5-64-bit-no-GUI-KVM.qcow2
     3) images/NAMU-Rocky-8-10.qcow2
  번호> 1

  템플릿 이름 [NAMU-Ubuntu-24-04]: Ubuntu-24.04

  ▸ Zone 선택
     1) zone1  [<zoneid>]
  번호> 1

  ▸ Hypervisor 선택
     1) KVM   2) VMware   3) XenServer   4) 직접입력
  번호> 1

  ▸ Format 선택 (파일 기준 추천=QCOW2)
     1) QCOW2  2) OVA  3) RAW  4) VHD  5) VMDK
  번호> 1

  ▸ OS Type 선택        # OS 검색어(ubuntu/centos 등) 입력 → 목록에서 선택 → ostypeid 자동
  ...

  ── 등록 요약 ──────────────────────────────
    file/name/zone/hypervisor/format/ostype ...
  이대로 등록? (Y/n): Y
```
`Y` 하면 로컬 파일을 임시 HTTP 서버로 잠깐 노출 → SSVM 이 받아감 → `isready=true` 까지 대기 후 임시 서버를 내린다.
zoneid/ostypeid 를 손으로 찾을 필요가 없다.

### `5) register-systemvm` — SystemVM 등록 (SSVM 경유, 업데이트용)
**이미 SSVM 이 떠 있을 때** SystemVM 템플릿을 교체/업데이트하는 용도다. 흐름은 `4) register` 와 유사하되 ostype 는 선택.
> 최초 설치엔 SSVM 이 없으므로 이 항목이 아니라 **`6) seed-systemvm`** 을 써야 한다.

### `6) seed-systemvm` — SystemVM 부트스트랩 시드 (최초 필수)
SSVM 없이 `cloud-install-sys-tmplt` 로 secondary storage 에 **직접 시드**한다(폐쇄망 OK).
```
  ▸ images/ 이미지 선택
     1) images/SystemVM-Template-KVM.qcow2
  번호> 1

  secondary storage 경로 [/export/secondary]:

  ▸ SystemVM Hypervisor
     1) kvm   2) vmware   3) xenserver
  번호> 1

  ── SystemVM 시드 요약 (부트스트랩) ─────────
    file / secondary / hypervisor ...
  이대로 시드? (Y/n): Y
```
> ★ **`secondary` 경로 주의**: 존에 **등록된 secondary storage 와 물리적으로 같은 위치**여야 한다.
> 관리 VM 이 그 NFS 를 마운트하는지 `mountpoint /export/secondary` 로 확인한다. 로컬 빈 디렉터리면
> 시드가 엉뚱한 곳에 들어가 SSVM 이 안 뜬다. (`3) infra` 의 imagestores url 과 대조)

시드 후 CloudStack 이 SSVM/CPVM 을 부팅한다 → `3) infra` 의 **SystemVMs** 에서 `Running` 확인.

### `0) 종료`
콘솔을 끝낸다.

---

## 3. 추천 순서

```
3) infra          # 존/스토리지/호스트가 등록됐는지 확인 (비어 있으면 admin Add Zone 먼저)
6) seed-systemvm  # ★ SystemVM 부트스트랩 시드 (SSVM 뜨기 전, 최초 1회)
3) infra          # SystemVMs 가 Running 인지 확인
4) register       # 게스트 OS 템플릿 등록 (SSVM 이 받아감)
2) list           # isready=true 확인
```

---

## 4. (자동화) 비대화형 실행

메뉴 없이 인자로 직접 실행할 수 있다(반복/스크립트용):
```bash
./upload-os-image.sh infra
./upload-os-image.sh seed-systemvm --file images/SystemVM-Template-KVM.qcow2 --hypervisor kvm
./upload-os-image.sh register --file images/NAMU-Ubuntu-24-04.qcow2 \
  --name "Ubuntu-24.04" --ostype <ostypeid> --zone <zoneid>
```
주요 옵션: `--file`(로컬,권장) / `--url` / `--name` / `--zone`(id) / `--ostype`(id, 게스트 필수) /
`--format`(기본 QCOW2, `.ova`=OVA) / `--hypervisor`(기본 KVM) / `--serve-ip` / `--serve-port`(8000) /
`--wait-timeout`(1800) / `-- <k=v ...>`(cmk 로 그대로 전달). 전체는 `./upload-os-image.sh --help`.

---

## 5. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `3) infra` 의 Zones 가 `(조회된 결과가 없습니다)` | 존 부트스트랩 미완료. admin *Add Zone* 으로 존·스토리지·호스트 먼저 구성 |
| `register` 진입 시 `등록된 zone 이 없습니다` | 위와 동일 — 존을 먼저 만든 뒤 재시도 |
| `check` 가 실패 (`cmk sync/list 실패`) | 관리 VM cmk url/자격증명 확인 — `cmk set url http://<VM_IP>:8080/client/api`, `cmk sync` |
| `seed-systemvm` 후에도 SSVM 이 안 뜸 | (a) `secondary` 가 등록된 secondary NFS 와 다른 위치(`mountpoint`·imagestores url 대조) (b) SystemVM 템플릿 버전 불일치(`cmk list configurations name=minreq.sysvmtemplate.version`) (c) 존 Enabled·호스트 Up 여부 |
| `register` 후 `isready` 안 됨 | SSVM 이 임시 HTTP 서버에 도달 못 함. `--serve-ip`/`--serve-port`, 방화벽 확인 |
| `--file 은 docker 가 필요하다` / `임시 서버 이미지 없다` | 실행 호스트에 docker + 로드된 `namuvirt-*-setup` 이미지 필요(임시 HTTP 서버용) |
| `포트 8000 사용중` | `ss -ltnp \| grep 8000` 확인, `docker rm -f $(docker ps -aq --filter name=namuvirt-imgserve)` 정리, 또는 `--serve-port` 변경 |
| `.ova` 등록 실패 | VMware 하이퍼바이저 클러스터가 없는 KVM 존엔 등록 불가. KVM 파일만 |

> 조회/등록이 안 될 때는 먼저 `1) check` 로 cmk 연결을, `3) infra` 로 존/스토리지/호스트를 확인한다.
