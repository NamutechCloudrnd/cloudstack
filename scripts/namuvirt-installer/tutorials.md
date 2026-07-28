# namuVIRT 사용자 튜토리얼 (User Tutorials)

## 1. 문서 개요

### 1.1 목적

이 문서는 namuVIRT 를 도입한 사용자가 실제 운영 환경에서 자주 수행하는 작업을
**시나리오(따라 하기) 형태**로 안내하기 위한 사용자 튜토리얼(User Tutorials) 이다.

사용자 매뉴얼(User Manual) 이 각 메뉴/기능의 "무엇을 하는가"를 설명한다면,
본 튜토리얼은 하나의 목표(예: HA VM 만들기, Kubernetes 클러스터 구성)를 달성하기 위해
여러 기능을 **어떤 순서로 조합해서 사용하는가**를 다룬다.

- **대상 독자**: namuVIRT 를 사용하는 인프라/플랫폼 운영자, 서비스 담당자
- **선행 조건**: namuVIRT 설치 및 Zone/Primary/Secondary Storage 등록이 완료되어
  포털 로그인이 가능한 상태 (설치는 [INSTALL-GUIDE.md](INSTALL-GUIDE.md) 참고)
- **표기 규칙**
  - 포털 메뉴 경로는 `Infrastructure > Hosts` 와 같이 `>` 로 표기한다.
  - 각 튜토리얼의 상세 화면/그림은 포털 내 **가이드(Guide)** 의
    `tutorial` 문서(`01_compute` / `02_network` / `03_infrastructure`)에서 확인한다.

### 1.2 문서 구성 (장별)

| 장 | 제목 | 내용 | 비고 |
|----|------|------|------|
| **1장** | 개요 / 시작하기 | 문서 목적, 대상 독자, 선행 조건, 포털 접속 및 공통 사전 준비 | *작성 완료(별도)* |
| **2장** | Tutorials | 기능별 시나리오 가이드 — Compute / Network / Infrastructure 3개 영역으로 구성 | 본 문서 §2 |

> 1장(개요/시작하기)은 별도로 작성되어 있으므로 본 문서에서는 다루지 않는다.
> 아래 2장은 각 튜토리얼이 **무엇을 다루는지**와 **어떤 순서로 학습/수행하면 좋은지**를
> 안내하는 가이드다. 각 항목의 상세 절차·화면은 포털 가이드의 `tutorial` HTML 문서에 담겨 있다.

---

## 2. Tutorials

튜토리얼은 사용자가 다루는 리소스 계층에 따라 **Compute → Network → Infrastructure**
3개 영역으로 나뉜다. 각 영역 안에서는 **기본 → 고급(특수 워크로드)** 순으로
메뉴를 정렬하여, 처음 접하는 사용자가 위에서부터 순서대로 따라 하며 익힐 수 있도록 했다.

| 영역 | 문서 | 다루는 튜토리얼 수 |
|------|------|------------------|
| 2.1 Compute | `tutorial/01_compute.html` | 6 |
| 2.2 Network | `tutorial/02_network.html` | 3 |
| 2.3 Infrastructure | `tutorial/03_infrastructure.html` | 1 |

> **작성 상태** 표기: ✅ 작성 완료 / 🚧 준비 중

### 2.1 Compute

가상머신(인스턴스) 생성과 운영에 관한 튜토리얼이다. 가장 기본이 되는 VM 생성부터
시작해 가용성·자동확장·특수 하드웨어·컨테이너·이관 순으로 심화된다.

| 순서 | 튜토리얼 | 요약 | 상태 |
|------|----------|------|------|
| 1 | **Template 기반 VM 생성** | 등록된 템플릿(이미지)을 기반으로 인스턴스를 생성하는 가장 기본적인 절차. 이후 모든 Compute 시나리오의 출발점이다. | 🚧 |
| 2 | **HA 환경 구성** | 호스트 장애를 감지해 동일 클러스터 내 다른 호스트에서 인스턴스를 자동 재시작하는 고가용성 구성. HA 활성화(글로벌/Zone) → HA Compute Offering → HA VM 생성 → Dedicated HA Host(tag 기반) 순으로 진행. **Shared Storage(NFS/iSCSI) 필요, Local Storage 미지원, 클러스터에 호스트 2대 이상 필요.** | ✅ |
| 3 | **AutoScaling Groups** | 로드밸런서에 연결된 VM 그룹의 인스턴스 수를 모니터링 지표·정책에 따라 자동 Scale-in/out. 사전작업(Dynamic Scaling 활성화 Compute Offering, Public IP + AutoScale Load Balancer Rule) → 그룹 생성 → Apache Bench 부하 테스트로 SCALING 동작 확인. | ✅ |
| 4 | **GPU Passthrough** | 물리 GPU 를 VM 에 PCI Passthrough 로 전달. 호스트 사전작업(IOMMU 활성화, VFIO 드라이버 바인딩) → Host/GPU Card 등록 확인 → GPU Compute Offering 생성(Root Disk 최소 20GB, 권장 100GB) → VM 생성 → 게스트에서 `lspci`/`nvidia-smi` 로 인식 확인. | ✅ |
| 5 | **Kubernetes Cluster 환경 구성 및 운영** | CKS(CloudStack Kubernetes Service) 기반 클러스터 구성/운영. Kubernetes 사용 설정(글로벌, endpoint.url) → CKS ISO 등록 → Guest Network(선택) → Compute Offering → 클러스터 생성(HA·노드 루트 디스크 크기 산정) → kubeconfig 다운로드로 API 접근. | ✅ |
| 6 | **VMware to KVM 마이그레이션** | VMware 가상머신을 KVM(namuVIRT)으로 변환·이관하는 절차. | 🚧 |

### 2.2 Network

게스트 네트워크와 격리·연결 구성에 관한 튜토리얼이다. 단일 네트워크 구성에서
VPC, 외부 연결(VPN) 순으로 확장된다.

| 순서 | 튜토리얼 | 요약 | 상태 |
|------|----------|------|------|
| 1 | **Network 구성** | Guest Network(격리/공유) 생성 및 기본 네트워크 구성. | 🚧 |
| 2 | **VPC 구성** | VPC(Virtual Private Cloud) 와 Tier·라우팅 구성. | 🚧 |
| 3 | **VPN 구성** | Site-to-Site / Remote Access VPN 을 통한 외부 연결 구성. | 🚧 |

### 2.3 Infrastructure

물리 인프라(하이퍼바이저 클러스터) 확장에 관한 튜토리얼이다.

| 순서 | 튜토리얼 | 요약 | 상태 |
|------|----------|------|------|
| 1 | **KVM Multi Cluster 환경 구성** | 다중 KVM 클러스터를 구성해 자원 풀을 확장·분리하는 절차. | 🚧 |

---

> **작성 안내**: 🚧(준비 중) 항목은 포털 가이드의 해당 `tutorial` HTML(`01_compute`,
> `02_network`, `03_infrastructure`)에서 본문이 채워지는 대로 본 표의 상태를 ✅ 로 갱신한다.