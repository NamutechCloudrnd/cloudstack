# namuVIRT Build Guide (릴리스 번들 제작)

이 문서는 **인터넷이 되는 빌드 머신**에서 namuVIRT 설치 번들(`release/namuvirt-installer-<version>/`)을 만드는 전 과정을 다룬다.
흐름은 **① 패키지 다운로드 → ② 이미지 빌드 → ③ export(번들 생성)** 세 단계다.

> 이 문서는 **제작자(릴리스 엔지니어)** 용이다. 고객사 설치는 [INSTALL-GUIDE.md](INSTALL-GUIDE.md) 를 참고한다.

---

## 0. 전체 흐름 한눈에

```
[빌드 머신 — 인터넷 O]
  scripts/download-host-packages.sh        # KVM Host OS 패키지 (그룹별)       ┐ 끝에 버전/이름 dedup 자동
  scripts/download-monitoring-packages.sh  # Grafana rpm/deb + Prometheus   │ ← management 前에 실행
  scripts/download-management-packages.sh  # 관리 VM rpm 의존성(mgmt repo)     │   (grafana rpm 이 mgmt 입력)
  scripts/download-docker-packages.sh      # 폐쇄망 docker rpm/deb            ┘
        │  (packages/ 채움)
        ▼
  scripts/dedupe-versions.sh               # (필요 시) 같은 패키지 구버전 제거 — 최신만 유지.
        │                                  #  download-host-packages 가 자동 실행하므로 보통 생략.
        │                                  #  --packages-src 로 sample 을 섞었을 때만 수동 1회.
        ▼
  ./build-images.sh   --version 1.0.0      # 설치 이미지 3종 빌드 (버전 중복 있으면 감지해 중단)
        │
        ▼
  ./export-images.sh  --version 1.0.0      # 이미지 → tar + 번들 조립 + SHA256SUMS
        │
        ▼
  release/namuvirt-installer-1.0.0/        # ← 이 디렉터리를 폐쇄망에 반입(USB 등)
```

---

## 1. 빌드 환경 사전 요구사항

| 항목 | 요구 | 비고 |
|------|------|------|
| **인터넷** | 필요 | docker.io, download.docker.com, dnf/apt 미러 접근 |
| **Docker Engine** | 필요 | 이미지 빌드 + 패키지 다운로드 컨테이너 실행 |
| **Docker Buildx** | linux/amd64 크로스 빌드 시 필요 | Apple Silicon(arm64) 등에서 amd64 이미지 빌드할 때 (qemu 에뮬레이션) |
| **디스크 여유** | 20GB+ 권장 | 이미지 3종 + 패키지 + 번들 tar. macOS Docker 는 VM 디스크 고정이라 부족 시 빌드 실패 |
| **git** | 선택 | `--revision` 자동 채움용(없으면 `unknown`) |
| **bash / GNU coreutils** | 필요 | 스크립트 실행 |

> **Apple Silicon 주의**: 타깃 KVM 호스트는 항상 x86_64 이므로 이미지도 `linux/amd64` 로 빌드된다.
> arm 개발 머신에서는 buildx + qemu 로 크로스 빌드되어 느릴 수 있다. (`build-images.sh --platform` 으로 조정)

---

## 2. Step 1 — 패키지 준비 (`packages/`)

설치에 필요한 모든 패키지는 **이미지 안에 내장**된다. 빌드 전에 `packages/` 하위를 채운다.

### 2.1 packages/ 구조

```
packages/
  namuvirt/rocky/        cloudstack-*.rpm (관리/agent/usage/ui/common)   ← 수동 배치
  namuvirt/ubuntu/       cloudstack-*.deb                                 ← 수동 배치
  os-packages/rocky/     <그룹>/*.rpm (qemu-kvm, libvirt, nfs, java ...) + mgmt/(관리 VM offline repo)
  os-packages/ubuntu/    <그룹>/*.deb
  monitoring/common/     prometheus-*.tar.gz         ← download-monitoring-packages.sh
  monitoring/rocky/      grafana-*.x86_64.rpm        ← download-monitoring-packages.sh
  monitoring/ubuntu/     grafana_*_amd64.deb         ← download-monitoring-packages.sh
  exporters/             node/process/libvirt exporter tar.gz             ← download-monitoring-packages.sh
  vmware-conversion/     virt-v2v / nbdkit (선택)
  docker/rocky/          docker-ce rpm + repodata   ← download-docker-packages.sh
  docker/ubuntu/         docker-ce deb              ← download-docker-packages.sh
```

- `namuvirt/*` (cloudstack RPM/DEB) 와 `exporters` 는 **제품 아티팩트**라 수동 배치한다.
  개발 편의상 `build-images.sh --packages-src <dir>` 로 자동 스테이징할 수 있다(§3).
- `monitoring/` (Grafana/Prometheus) 는 `download-monitoring-packages.sh` 로 받는다(§2.3).
  ※ **management 前에 실행**해야 한다 — grafana rpm 이 `download-management-packages.sh` 의 입력이다.
- `os-packages/<os>/<그룹>/` (KVM Host 용) 는 `download-host-packages.sh` 로 받는다(§2.2).

### 2.2 KVM Host 용 OS 패키지 — `download-host-packages.sh`

KVM Host(Rocky/Ubuntu) 구성에 필요한 패키지를 **그룹별 의존성 closure** 로 받아
`packages/os-packages/{rocky,ubuntu}/<그룹>/` 에 채운다. (그룹: qemu-kvm libvirt network nfs iscsi vm-tools java chrony utils)

```bash
./scripts/download-host-packages.sh              # rocky + ubuntu 둘 다 (끝에 dedupe 자동)
./scripts/download-host-packages.sh --os rocky   # 하나만
./scripts/download-host-packages.sh --no-dedupe  # dedupe 생략
```

| 옵션 | 값 / 기본 | 역할 |
|------|-----------|------|
| `--os` | `all`(기본) \| `rocky` \| `ubuntu` | 받을 대상 OS |
| `--no-dedupe` | — | 완료 후 `dedupe-versions.sh`(구버전 제거) 자동 실행 생략 |

- Rocky: `rockylinux:8.10` 컨테이너(powertools/crb + epel) → 그룹별 `*.rpm`
- Ubuntu: `ubuntu:24.04` 컨테이너 → 그룹별 `*.deb`
- 각 그룹은 자기 closure 를 그대로 보유한다. 그룹 간 공유 rpm 을 `_base/` 공용 풀로 모으는 이름-중복 제거는 하지 않는다(끝에 구버전만 정리).
- 그룹별 패키지 목록은 스크립트 상단(컨테이너 스크립트 내 `declare -A G`)에서 **편집 가능**하다(환경에 맞게 조정).
- **base 도구(tar 등) 강제 확보**: 빌더 컨테이너에 미리 깔려 있는 도구(tar/gzip)는 "델타" 다운로드에서
  빠지지만, minimal 타깃(@core)엔 없을 수 있다. 스크립트가 `dnf download` 로 명시 패키지를 강제로 받아
  누락을 막는다. (tar 는 tar-once unarchive 에도 필요하므로 반드시 포함되어야 함)

### 2.3 모니터링 스택 (Grafana/Prometheus/Exporter) — `download-monitoring-packages.sh`

관리 VM 의 Prometheus/Grafana 와 KVM Host 의 exporter 3종을 공개 배포판에서 받아
`packages/monitoring/`·`packages/exporters/` 에 채운다. Grafana 의 **의존성**은 §2.4(mgmt closure)가
받으므로, 이 스크립트는 **§2.4 前에** 실행해야 한다.

```bash
./scripts/download-monitoring-packages.sh                 # prometheus + grafana rpm/deb + exporter 3종
./scripts/download-monitoring-packages.sh --os rocky      # grafana 는 rocky 만 (prometheus/exporter 는 항상)
GRAFANA_VER=11.6.1 PROM_VER=2.55.1 ./scripts/download-monitoring-packages.sh   # 버전 고정
```
- Grafana OSS: `rpm.grafana.com`/`apt.grafana.com`(rpm 은 x86_64 만), Prometheus/Exporter: github releases.
- 산출:
  - `monitoring/common/prometheus-*.tar.gz`, `monitoring/rocky/grafana-*.x86_64.rpm`, `monitoring/ubuntu/grafana_*_amd64.deb`
  - `exporters/{node_exporter,process-exporter,prometheus-libvirt-exporter}-*.linux-amd64.tar.gz`
- exporter 버전 env: `NODE_EXPORTER_VER` / `PROCESS_EXPORTER_VER` / `LIBVIRT_EXPORTER_VER`.
- 이미 받은 파일은 skip(idempotent). 버전 미지정 시 저장소 최신을 받는다(배포 땐 고정 권장).
- github 자산 naming 이 달라 직접 URL 이 404 면 github API 로 `linux-amd64.tar.gz` 자산을 자동 탐색한다.

### 2.4 관리 VM 용 rpm 의존성 closure — `download-management-packages.sh`

관리 VM(Rocky 8)은 폐쇄망이라 dnf 미러를 못 쓴다. cloudstack/grafana + Java/DB/NFS 등의 **의존성 전체**를
`rocky:8.10` 컨테이너로 받아 `packages/os-packages/rocky/mgmt/` 에 offline repo(+repodata)로 만든다.

```bash
./scripts/download-management-packages.sh
```
- 전제: `packages/namuvirt/rocky/cloudstack-*.rpm` **및** `packages/monitoring/rocky/grafana-*.rpm` 이 미리 있어야 한다
  (그 의존성을 받으므로). 없으면 스크립트가 즉시 실패한다(빈 mgmt 방지 하드닝).
- 산출: `packages/os-packages/rocky/mgmt/*.rpm` + `repodata/` → 관리 이미지에 내장되어 `nvoffline` repo 로 설치된다.

### 2.5 폐쇄망 Docker 설치 패키지 — `download-docker-packages.sh`

고객 kvm.master 에 docker 를 폐쇄망에서 깔 수 있도록 docker-ce 세트의 rpm/deb 를 받는다.

```bash
./scripts/download-docker-packages.sh              # rocky + ubuntu 둘 다
./scripts/download-docker-packages.sh --os rocky   # 하나만
```

| 옵션 | 값 | 역할 |
|------|-----|------|
| `--os` | `all`(기본) \| `rocky` \| `ubuntu` | 받을 대상 OS 선택 |

- Rocky: `rockylinux/rockylinux:8.10` 컨테이너 → `packages/docker/rocky/*.rpm` + repodata
- Ubuntu: `ubuntu:24.04` 컨테이너 → `packages/docker/ubuntu/*.deb`
- 환경변수 `ROCKY_IMAGE` / `UBUNTU_IMAGE` 로 베이스 이미지 override 가능.
- 산출물은 이미지가 아니라 **릴리스 번들의 `docker-packages/`** 로 담긴다(export 단계, §4).

### 2.5 관리 VM 골든 이미지 / SystemVM 템플릿 — `os-images/`

번들에 포함할 게스트/관리 이미지는 `os-images/` 에 두고, **화이트리스트** `os-images/bundle.list` 로 지정한다.
(glob 이 아니라 목록에 있는 파일만 담아, 테스트 이미지가 섞여 들어가는 것을 막는다.)

```
# os-images/bundle.list (현재)
NAMU-Rocky-8-10.qcow2                    # 관리 VM 골든 이미지 (필수)
SystemVM-Template-KVM.qcow2              # CloudStack SystemVM (KVM, 필수)
SystemVM-Template-vSphere.ova            # (선택) vSphere 환경용
NAMU-Ubuntu-24-04.qcow2                  # Ubuntu 게스트 템플릿 제공용 (관리 VM 용 아님)
CentOS-5-3-64-bit-no-GUI-vSphere.ova     # (선택) 게스트 샘플
CentOS-5-5-64-bit-no-GUI-KVM.qcow2       # (선택)
```

### 2.6 os-packages 중복 제거 (버전/이름)

`download-host-packages.sh` 가 다운로드 직후 자동 호출하므로 보통 수동 실행 불필요.

**버전 중복 제거 — `dedupe-versions.sh`** (같은 패키지의 구버전 삭제, 최신만 유지)
섞인 소스로 `el8` / `el8_10.x` 등 두 버전이 들어오면 설치 시 dnf 가
`cannot install both X-v1 and X-v2 ... conflicting requests` 로 실패한다. 이를 막는다.
```bash
./scripts/dedupe-versions.sh              # rocky + ubuntu (rocky: repomanage, ubuntu: dpkg 비교)
./scripts/dedupe-versions.sh --os rocky   # 하나만
```

> 그룹 간 공유 rpm 을 `_base/` 공용 풀로 모으던 이름-중복 제거(`dedupe-os-packages.sh`)는 더 이상
> 사용하지 않는다. 각 그룹이 자기 closure 를 그대로 보유한다(`java/` `utils/` 등이 비지 않음).

---

## 3. Step 2 — 이미지 빌드 (`build-images.sh`)

설치 컨테이너 이미지 **3종**을 빌드한다. 베이스는 `python:3.12-slim` 이며, Ansible + `packages/` 가 내장된다.

| 이미지 | 용도 |
|--------|------|
| `namuvirt-management-setup:<ver>` | 관리 VM 생성 + namuVIRT 관리/DB/Prometheus/Grafana 설치 |
| `namuvirt-host-setup-rocky:<ver>` | Rocky 8 KVM Host 구성 |
| `namuvirt-host-setup-ubuntu:<ver>` | Ubuntu 24.04 KVM Host 구성 |

```bash
./build-images.sh --version 1.0.0
# 개발: sample 패키지 디렉터리에서 스테이징하며 빌드
./build-images.sh --version 1.0.0 --packages-src /path/to/namuVIRT-packages
```

### 옵션

| 옵션 | 값 / 기본 | 역할 |
|------|-----------|------|
| `--version` | 예 `1.0.0` (기본 `dev`) | 이미지 태그 및 OCI `image.version` 라벨 |
| `--revision` | git short SHA (기본: 자동/`unknown`) | OCI `image.revision` 라벨 |
| `--packages-src <dir>` | 없음 | 이 디렉터리에서 `os-packages/monitoring/exporters/vmware-conversion` 을 `packages/` 로 스테이징. 미지정 시 `packages/` 에 이미 있는 파일 사용 |
| `--platform <p>` | `linux/amd64` | 빌드 타깃 플랫폼(타깃 호스트가 x86_64 라 기본 amd64) |
| `--prune-cache` | — | 빌드 전 docker 빌드캐시 정리(`docker builder prune -f`) |
| `--no-prune` | — | 캐시 정리 안 함 |
| (기본) | 대화형 | `--prune-cache`/`--no-prune` 둘 다 없으면 디스크 사용량을 보여주고 정리 여부를 물음 |
| `--help` | — | 도움말 |

빌드가 하는 일: 패키지 소스 검증 → (스테이징) → Ansible 복사 → 이미지 3종 빌드 → OCI 라벨 주입 →
`ansible syntax-check` 스모크 테스트. **시작/종료 시각과 소요 시간**을 출력한다.

> manifest·checksum·image-ids 등 **검증 아티팩트는 build 가 아니라 export 가**
> 고객 번들(`release/namuvirt-installer-<version>/`) 안에 생성한다. 서버가 그 번들 안에서
> `sha256sum -c SHA256SUMS` 로 검증하기 때문. (build 는 이미지만 만든다.)

> macOS 에서 빌드캐시가 쌓이면 컨테이너 내부 apt/dnf 가 "no space" 로 실패할 수 있다. 그럴 땐 `--prune-cache`.

---

## 4. Step 3 — 번들 생성 (`export-images.sh`)

빌드된 이미지를 tar 로 저장하고, 고객 반입용 번들을 조립한다.

```bash
./export-images.sh --version 1.0.0
./export-images.sh --version 1.0.0 --output release/namuvirt-installer-1.0.0
./export-images.sh --version 1.0.0 --os rocky        # Rocky host 이미지만 번들
```

### 옵션

| 옵션 | 값 / 기본 | 역할 |
|------|-----------|------|
| `--version` | 예 `1.0.0` (기본 `dev`) | 번들에 담을 이미지 태그 |
| `--output <dir>` | 기본 `release/namuvirt-installer-<ver>` | 번들 출력 경로 |
| `--os` | `all`(기본) \| `rocky` \| `ubuntu` | 번들에 포함할 **host 이미지 / docker 패키지** 선택 (management 는 항상 포함) |
| `--with-os-image` | — | **os-images(골든/템플릿 qcow2·ova)를 번들에 포함** (기본은 제외) |
| `--os-images-src <dir>` | 기본 `<하네스루트>/os-images` | `--with-os-image` 시 이미지 소스 경로 |
| `--no-os-image` | — | os-images 제외 (기본과 동일 — 하위호환) |
| `--help` | — | 도움말 |

> **os-images 는 기본적으로 번들에 넣지 않는다.** 수 GB 이미지가 릴리스 tar 마다 중복되어 용량이
> 과도해지므로 이미지는 **별도 관리**한다. 번들의 `images/` 는 빈 채로 나가고 고객이 그 위치에 배치한다.
> 한 번에 같이 담으려면 `--with-os-image` 를 준다.

export 가 하는 일:
1. `docker save` 로 이미지 → `image-tar/*.tar`
2. 실행 스크립트/문서 복사(`install-namuvirt.sh`, `prepare-install.sh`, `install-docker.sh`, `verify-install.sh`, `upload-os-image.sh`, `INSTALL-GUIDE.md`, `config.sample.yaml`, `README.md`, `scripts/`)
3. `docker-packages/<os>/` 번들(§2.3) — 없으면 경고(온라인 docker 설치만 가능)
4. (`--with-os-image` 인 경우만) `os-images/bundle.list` → `images/` 번들(§2.5). 기본은 `images/` 빈 채로 둠
5. `manifest.yaml`(version/revision/이미지 sha256) + `image-ids.txt` + `SHA256SUMS` 생성 (모두 번들 안)

**시작/종료 시각·소요 시간**을 출력한다.

---

## 5. 산출물 — 릴리스 번들 구조

```
release/namuvirt-installer-1.0.0/
  install-namuvirt.sh          고객 설치 엔트리포인트
  prepare-install.sh            설치 전 대화형 준비
  install-docker.sh             docker 부트스트랩(폐쇄망 오프라인 지원)
  verify-install.sh             설치 후 검증
  upload-os-image.sh            OS/SystemVM 이미지 업로드(운영 도구)
  config.sample.yaml            config 템플릿
  INSTALL-GUIDE.md              설치 가이드(이 번들의 유일한 문서)
  README.md
  image-tar/                    namuvirt-*-setup_1.0.0.tar (3종)
  docker-packages/{rocky,ubuntu}/   폐쇄망 docker rpm/deb
  images/                       기본 빈 디렉터리(고객이 골든 이미지·SystemVM 템플릿 배치). --with-os-image 시 포함
  ssh/                          (빈 디렉터리 — 고객이 키 배치)
  logs/                         (빈 디렉터리)
  scripts/                      호스트측 헬퍼(detect-host-os/collect-logs/print-summary)
  manifest.yaml                 버전/revision/이미지 tar sha256
  image-ids.txt                 이미지 docker Id (load 후 대조용)
  SHA256SUMS                    전체 파일 무결성
```

---

## 6. 번들 검증

```bash
cd release/namuvirt-installer-1.0.0
sha256sum -c SHA256SUMS        # 전 파일 무결성 확인 (반입 후 고객도 동일 실행)
```

---

## 6.5 산출물 정리 — `clean.sh` (레이어별)

`installer-harness` 는 빌드 워크스페이스라 각 단계 산출물이 쌓인다. `clean.sh` 로 **소스(레이어)별**로
골라 지운다. **`os-images/`(수 GB)는 어떤 옵션으로도 삭제하지 않는다.**

| 레이어 옵션 | 지우는 대상 | 산출 스크립트 |
|------|------|------|
| `--host-packages` | `packages/os-packages` KVM Host 그룹 (mgmt 제외) | download-host-packages.sh |
| `--mgmt-packages` | `packages/os-packages/rocky/mgmt` | download-management-packages.sh |
| `--docker-packages` | `packages/docker` | download-docker-packages.sh |
| `--staged` | `packages/{monitoring,exporters,vmware-conversion}` | build-images.sh 스테이징 |
| `--images` | docker 이미지 `namuvirt-*-setup` | build-images.sh |
| `--release` | `release/` | export-images.sh |
| `--namuvirt` | `packages/namuvirt` (제품 rpm, 수동) | — |

```bash
./clean.sh --dry-run             # 지울 대상만 표시(안전 확인)
./clean.sh                       # 기본: namuvirt·os-images 만 빼고 전부
./clean.sh --release             # export-images 결과만
./clean.sh --images              # build-images 결과(도커 이미지)만
./clean.sh --host-packages       # KVM Host 패키지만 (mgmt 보존)
./clean.sh --mgmt-packages --docker-packages   # 조합 가능
./clean.sh --all                 # 위 전부 + namuvirt (os-images 만 보존)
./clean.sh -y                    # 확인 프롬프트 없이
```

- **레이어 여러 개 조합 가능**. 아무것도 안 주면 기본 세트(namuvirt 제외 전부).
- **항상 보존**: `os-images/`, (기본) `packages/namuvirt/`.
- 패키지 삭제 후 이미지 COPY 대상 디렉터리는 **빈 디렉터리로 재생성**(`.gitkeep`)되어 다음 빌드 `COPY` 가 안 깨진다.
- (하위호환) `--release-only`/`--images-only`/`--packages-only` 도 동작한다.

---

## 7. 트러블슈팅

| 증상 | 원인 / 조치 |
|------|-------------|
| 빌드 중 apt/dnf "No space left" | docker 빌드캐시 누적 → `./build-images.sh --prune-cache` |
| `docker-packages 번들 없음` 경고 | `scripts/download-docker-packages.sh` 를 export 전에 실행 |
| `bundle.list 항목이 없다` 경고 | `os-images/` 에 해당 파일 배치 또는 `bundle.list` 수정 |
| Rocky rpm 다운로드 0개 | GPG 키 사전 import 필요 — 최신 스크립트가 처리함(구버전이면 스크립트 갱신) |
| 폐쇄망 설치 시 `nothing provides tar`(등 base 도구) | minimal 타깃엔 tar 등이 없는데 빌더 컨테이너엔 미리 깔려 델타에서 누락. 최신 `download-docker-packages.sh`/`download-host-packages.sh`(tar 강제 확보)로 재다운로드 |
| 설치 시 `cannot install both X-v1 and X-v2 ... conflicting requests` | os-packages 에 같은 패키지가 두 버전 존재. `./scripts/dedupe-versions.sh` 로 구버전 제거 후 재빌드 (build-images.sh 가 스테이징 시 자동 수행) |
| arm 머신에서 빌드 느림/실패 | `--platform linux/amd64` + buildx/qemu 확인. 가능하면 x86 빌드 머신 사용 |
