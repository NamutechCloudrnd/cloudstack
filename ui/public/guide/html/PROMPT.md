# 요청: 동적 네비게이션 시스템 구축 (JSON + JavaScript)

## 목표
- JSON 파일로 폴더 구조 정의
- JavaScript로 메뉴를 동적으로 자동 생성
- 각 HTML 페이지마다 별도 라우트 경로 (01_compute/01_instances/instances.html 등)
- 모든 HTML 페이지는 공통 메뉴 포함

## 아키텍처

```
index.html                                    ← 홈 페이지
├─ 01_compute/01_instances/instances.html    ← 라우트: /01_compute/01_instances/instances.html
├─ 02_storage/01_volumes/volumes.html        ← 라우트: /02_storage/01_volumes/volumes.html
├─ ...
│
├─ menu-data.json                            ← 공유 메뉴 데이터 (모든 페이지에서 로드)
├─ menu-renderer.js                          ← 메뉴 생성 및 활성화 로직 (공유)
├─ style.css                                 ← 공유 스타일
└─ shared/
    ├─ menu-template.html                    ← 메뉴 HTML 템플릿 (선택사항)
    └─ menu-init.js                          ← 메뉴 초기화 스크립트
```

## 1. JSON 구조 (menu-data.json)

```json
{
  "menu": [
    {
      "id": "01_compute",
      "label": "Compute",
      "items": [
        {
          "id": "01_instances",
          "label": "Instances",
          "path": "01_compute/01_instances/instances.html"
        },
        {
          "id": "02_instances_snapshots",
          "label": "Instances Snapshots",
          "path": "01_compute/02_instances_snapshots/instances_snapshots.html"
        },
        {
          "id": "03_kubernetes",
          "label": "Kubernetes",
          "path": "01_compute/03_kubernetes/kubernetes.html"
        },
        {
          "id": "04_autoscaling_groups",
          "label": "Autoscaling Groups",
          "path": "01_compute/04_autoscaling_groups/autoscaling_groups.html"
        },
        {
          "id": "05_instance_groups",
          "label": "Instance Groups",
          "path": "01_compute/05_instance_groups/instance_groups.html"
        },
        {
          "id": "06_ssh_key_pairs",
          "label": "SSH Key Pairs",
          "path": "01_compute/06_ssh_key_pairs/ssh_key_pairs.html"
        },
        {
          "id": "07_user_data_library",
          "label": "User Data Library",
          "path": "01_compute/07_user_data_library/user_data_library.html"
        },
        {
          "id": "08_cni_configuration",
          "label": "CNI Configuration",
          "path": "01_compute/08_cni_configuration/cni_configuration.html"
        },
        {
          "id": "09_affinity_groups",
          "label": "Affinity Groups",
          "path": "01_compute/09_affinity_groups/affinity_groups.html"
        }
      ]
    },
    {
      "id": "02_storage",
      "label": "Storage",
      "items": [
        {
          "id": "01_volumes",
          "label": "Volumes",
          "path": "02_storage/01_volumes/volumes.html"
        },
        {
          "id": "02_volume_snapshots",
          "label": "Volume Snapshots",
          "path": "02_storage/02_volume_snapshots/volume_snapshots.html"
        },
        {
          "id": "03_snapshot_policies",
          "label": "Snapshot Policies",
          "path": "02_storage/03_snapshot_policies/snapshot_policies.html"
        },
        {
          "id": "04_backups",
          "label": "Backups",
          "path": "02_storage/04_backups/backups.html"
        },
        {
          "id": "05_backup_schedules",
          "label": "Backup Schedules",
          "path": "02_storage/05_backup_schedules/backup_schedules.html"
        },
        {
          "id": "06_buckets",
          "label": "Buckets",
          "path": "02_storage/06_buckets/buckets.html"
        },
        {
          "id": "07_shared_filesystems",
          "label": "Shared Filesystems",
          "path": "02_storage/07_shared_filesystems/shared_filesystems.html"
        }
      ]
    },
    {
      "id": "03_network",
      "label": "Network",
      "items": [
        {
          "id": "01_guest_networks",
          "label": "Guest Networks",
          "path": "03_network/01_guest_networks/guest_networks.html"
        },
        {
          "id": "02_vpc",
          "label": "VPC",
          "path": "03_network/02_vpc/vpc.html"
        },
        {
          "id": "03_security_group",
          "label": "Security Group",
          "path": "03_network/03_security_group/security_group.html"
        },
        {
          "id": "04_vnf_appliances",
          "label": "VNF Appliances",
          "path": "03_network/04_vnf_appliances/vnf_appliances.html"
        },
        {
          "id": "05_public_ip_addresses",
          "label": "Public IP Addresses",
          "path": "03_network/05_public_ip_addresses/public_ip_addresses.html"
        },
        {
          "id": "06_as_numbers",
          "label": "AS Numbers",
          "path": "03_network/06_as_numbers/as_numbers.html"
        },
        {
          "id": "07_site_to_site_vpn",
          "label": "Site to Site VPN",
          "path": "03_network/07_site_to_site_vpn/site_to_site_vpn.html"
        },
        {
          "id": "08_vpn_connections",
          "label": "VPN Connections",
          "path": "03_network/08_vpn_connections/vpn_connections.html"
        },
        {
          "id": "09_network_acls",
          "label": "Network ACLs",
          "path": "03_network/09_network_acls/network_acls.html"
        },
        {
          "id": "10_vpn_users",
          "label": "VPN Users",
          "path": "03_network/10_vpn_users/vpn_users.html"
        },
        {
          "id": "11_vpn_customer_gateway",
          "label": "VPN Customer Gateway",
          "path": "03_network/11_vpn_customer_gateway/vpn_customer_gateway.html"
        },
        {
          "id": "12_guest_vlan",
          "label": "Guest VLAN",
          "path": "03_network/12_guest_vlan/guest_vlan.html"
        },
        {
          "id": "13_ipv4_subnets",
          "label": "IPv4 Subnets",
          "path": "03_network/13_ipv4_subnets/ipv4_subnets.html"
        }
      ]
    },
    {
      "id": "04_images",
      "label": "Images",
      "items": [
        {
          "id": "01_templates",
          "label": "Templates",
          "path": "04_images/01_templates/templates.html"
        },
        {
          "id": "02_isos",
          "label": "ISOs",
          "path": "04_images/02_isos/isos.html"
        },
        {
          "id": "03_kubernetes_isos",
          "label": "Kubernetes ISOs",
          "path": "04_images/03_kubernetes_isos/kubernetes_isos.html"
        }
      ]
    },
    {
      "id": "05_events",
      "label": "Events",
      "items": [
        {
          "id": "01_events",
          "label": "Events",
          "path": "05_events/01_events/events.html"
        }
      ]
    },
    {
      "id": "06_projects",
      "label": "Projects",
      "items": [
        {
          "id": "01_projects",
          "label": "Projects",
          "path": "06_projects/01_projects/projects.html"
        }
      ]
    },
    {
      "id": "07_roles",
      "label": "Roles",
      "items": [
        {
          "id": "01_roles",
          "label": "Roles",
          "path": "07_roles/01_roles/roles.html"
        }
      ]
    },
    {
      "id": "08_accounts",
      "label": "Accounts",
      "items": [
        {
          "id": "01_accounts",
          "label": "Accounts",
          "path": "08_accounts/01_accounts/accounts.html"
        }
      ]
    },
    {
      "id": "09_domains",
      "label": "Domains",
      "items": [
        {
          "id": "01_domains",
          "label": "Domains",
          "path": "09_domains/01_domains/domains.html"
        }
      ]
    },
    {
      "id": "10_infrastructure",
      "label": "Infrastructure",
      "items": [
        {
          "id": "01_summary",
          "label": "Summary",
          "path": "10_infrastructure/01_summary/summary.html"
        },
        {
          "id": "02_zones",
          "label": "Zones",
          "path": "10_infrastructure/02_zones/zones.html"
        },
        {
          "id": "03_pods",
          "label": "Pods",
          "path": "10_infrastructure/03_pods/pods.html"
        },
        {
          "id": "04_clusters",
          "label": "Clusters",
          "path": "10_infrastructure/04_clusters/clusters.html"
        },
        {
          "id": "05_hosts",
          "label": "Hosts",
          "path": "10_infrastructure/05_hosts/hosts.html"
        },
        {
          "id": "06_primary_storage",
          "label": "Primary Storage",
          "path": "10_infrastructure/06_primary_storage/primary_storage.html"
        },
        {
          "id": "07_secondary_storage",
          "label": "Secondary Storage",
          "path": "10_infrastructure/07_secondary_storage/secondary_storage.html"
        },
        {
          "id": "08_backup_repository",
          "label": "Backup Repository",
          "path": "10_infrastructure/08_backup_repository/backup_repository.html"
        },
        {
          "id": "09_object_storage",
          "label": "Object Storage",
          "path": "10_infrastructure/09_object_storage/object_storage.html"
        },
        {
          "id": "10_system_vms",
          "label": "System VMs",
          "path": "10_infrastructure/10_system_vms/system_vms.html"
        },
        {
          "id": "11_virtual_routers",
          "label": "Virtual Routers",
          "path": "10_infrastructure/11_virtual_routers/virtual_routers.html"
        },
        {
          "id": "12_internal_lb",
          "label": "Internal LB",
          "path": "10_infrastructure/12_internal_lb/internal_lb.html"
        },
        {
          "id": "13_management_servers",
          "label": "Management Servers",
          "path": "10_infrastructure/13_management_servers/management_servers.html"
        },
        {
          "id": "14_cpu_sockets",
          "label": "CPU Sockets",
          "path": "10_infrastructure/14_cpu_sockets/cpu_sockets.html"
        },
        {
          "id": "15_dbusage_server",
          "label": "DB Usage Server",
          "path": "10_infrastructure/15_dbusage_server/dbusage_server.html"
        },
        {
          "id": "16_alerts",
          "label": "Alerts",
          "path": "10_infrastructure/16_alerts/alerts.html"
        }
      ]
    },
    {
      "id": "11_offerings",
      "label": "Offerings",
      "items": [
        {
          "id": "01_compute_offerings",
          "label": "Compute Offerings",
          "path": "11_offerings/01_compute_offerings/compute_offerings.html"
        },
        {
          "id": "02_system_offerings",
          "label": "System Offerings",
          "path": "11_offerings/02_system_offerings/system_offerings.html"
        },
        {
          "id": "03_disk_offerings",
          "label": "Disk Offerings",
          "path": "11_offerings/03_disk_offerings/disk_offerings.html"
        },
        {
          "id": "04_backup_offerings",
          "label": "Backup Offerings",
          "path": "11_offerings/04_backup_offerings/backup_offerings.html"
        },
        {
          "id": "05_network_offerings",
          "label": "Network Offerings",
          "path": "11_offerings/05_network_offerings/network_offerings.html"
        },
        {
          "id": "06_vpc_offerings",
          "label": "VPC Offerings",
          "path": "11_offerings/06_vpc_offerings/vpc_offerings.html"
        }
      ]
    },
    {
      "id": "12_configuration",
      "label": "Configuration",
      "items": [
        {
          "id": "01_global_settings",
          "label": "Global Settings",
          "path": "12_configuration/01_global_settings/global_settings.html"
        },
        {
          "id": "02_ldap_configuration",
          "label": "LDAP Configuration",
          "path": "12_configuration/02_ldap_configuration/ldap_configuration.html"
        },
        {
          "id": "03_oauth_configuration",
          "label": "OAuth Configuration",
          "path": "12_configuration/03_oauth_configuration/oauth_configuration.html"
        },
        {
          "id": "04_hypervisor_capabilities",
          "label": "Hypervisor Capabilities",
          "path": "12_configuration/04_hypervisor_capabilities/hypervisor_capabilities.html"
        },
        {
          "id": "05_guest_os_categories",
          "label": "Guest OS Categories",
          "path": "12_configuration/05_guest_os_categories/guest_os_categories.html"
        },
        {
          "id": "06_guest_os",
          "label": "Guest OS",
          "path": "12_configuration/06_guest_os/guest_os.html"
        },
        {
          "id": "07_guest_os_mappings",
          "label": "Guest OS Mappings",
          "path": "12_configuration/07_guest_os_mappings/guest_os_mappings.html"
        },
        {
          "id": "08_gpu_card_types",
          "label": "GPU Card Types",
          "path": "12_configuration/08_gpu_card_types/gpu_card_types.html"
        }
      ]
    },
    {
      "id": "13_extensions",
      "label": "Extensions",
      "items": [
        {
          "id": "01_extensions",
          "label": "Extensions",
          "path": "13_extensions/01_extensions/extensions.html"
        }
      ]
    },
    {
      "id": "14_tools",
      "label": "Tools",
      "items": [
        {
          "id": "01_comments",
          "label": "Comments",
          "path": "14_tools/01_comments/comments.html"
        },
        {
          "id": "02_usage",
          "label": "Usage",
          "path": "14_tools/02_usage/usage.html"
        },
        {
          "id": "03_import_export_instances",
          "label": "Import Export Instances",
          "path": "14_tools/03_import_export_instances/import_export_instances.html"
        },
        {
          "id": "04_import_data_volumes",
          "label": "Import Data Volumes",
          "path": "14_tools/04_import_data_volumes/import_data_volumes.html"
        },
        {
          "id": "05_webhooks",
          "label": "Webhooks",
          "path": "14_tools/05_webhooks/webhooks.html"
        }
      ]
    }
  ]
}
```

## 2. 요구사항

### HTML 구조 (모든 페이지 공통)
**각 HTML 파일 (index.html, instances.html, volumes.html 등)**
```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="[상대경로]/style.css">
  <title>Page Title</title>
</head>
<body>
  <div class="container">
    <!-- 좌측 메뉴 컨테이너 (공유) -->
    <aside id="menu-sidebar" class="menu-sidebar"></aside>
    
    <!-- 우측 콘텐츠 -->
    <main class="content">
      <h1>페이지 제목</h1>
      <p>페이지별 고유 콘텐츠...</p>
    </main>
  </div>

  <!-- 공유 메뉴 초기화 스크립트 -->
  <script src="[상대경로]/menu-data.json" type="application/json" id="menu-data"></script>
  <script src="[상대경로]/menu-renderer.js"></script>
</body>
</html>
```

### JavaScript (menu-renderer.js - 공유)
- `menu-data.json` 로드
- DOM의 `#menu-sidebar`에 아코디언 메뉴 동적 생성
- **현재 URL을 기반으로 활성화된 메뉴 항목 자동 감지** (페이지 로드시)
  - 현재 페이지 URL과 JSON의 path 매칭
  - 매칭되는 메뉴 항목 자동 활성화
  - 해당 아코디언 **즉시 펼치기 (애니메이션 없음)**
- **클릭 이벤트: 사용자가 메뉴 헤더/항목 클릭시**
  - 해당 아코디언 펼침/닫힘 **애니메이션 적용**
  - 메뉴 항목 클릭시 해당 HTML로 직접 이동 (window.location.href)
- 현재 선택된 항목 하이라이트

**애니메이션 동작 차이:**
```
페이지 로드시 → 자동 펼침 (애니메이션 없음)
  - 현재 메뉴 항목 즉시 활성화
  - 아코디언 즉시 펼쳐짐
  - transition/animation 클래스 미적용

사용자 클릭시 → 펼침/닫힘 (애니메이션 있음)
  - animation 클래스 적용
  - 부드러운 펼침/닫힘 효과
  - duration: ~300ms
```

### CSS (style.css - 공유)
- 깔끔한 2컬럼 레이아웃 (좌측 메뉴 + 우측 콘텐츠)
- **조건부 아코디언 애니메이션**
  - `.accordion-item.animated` 클래스가 있을 때만 animation 적용
  - 페이지 로드시: 애니메이션 클래스 없음 (instant)
  - 사용자 클릭시: 애니메이션 클래스 추가 (smooth transition)
  - duration: ~300ms, easing: ease-in-out
- **현재 선택 항목 강조 (Accent Color: #9252f7)**
  - `.active` 클래스: 텍스트 색상 #9252f7
  - `.active` 클래스: 배경색 또는 좌측 테두리 #9252f7
  - 호버 상태도 동일 색상 사용
- 상대경로 기반 레이아웃 (모든 뎁스에서 사용 가능하도록)

## 3. 기능 요구사항

### 핵심 기능
- ✅ JSON에서 메뉴 데이터 로드
- ✅ 아코디언 형태로 렌더링 (1뎁스 = 헤더, 2뎁스 = 아이템)
- ✅ 각 항목 클릭시 해당 .html 페이지로 직접 이동 (window.location.href)
- ✅ **현재 URL 기반으로 활성화된 메뉴 항목 자동 감지**
- ✅ **활성화된 아코디언 자동 펼치기 (애니메이션 없음)**
- ✅ **사용자 클릭시 아코디언 펼침/닫힘 (애니메이션 있음)**

### 애니메이션 조건부 동작

#### 시나리오 1: 페이지 로드시 (URL 변경 후 렌더링)
```
1. 메뉴 렌더링
2. 현재 URL 감지
3. 해당 메뉴 항목 찾기
4. .active 클래스 적용 (하이라이트)
5. 해당 아코디언 즉시 펼치기 (animated 클래스 제외)
6. 애니메이션 없음 - 즉시 표시
```

#### 시나리오 2: 사용자가 아코디언 헤더 클릭
```
1. 클릭 감지
2. .animated 클래스 추가
3. 아코디언 펼침/닫힘 애니메이션 시작
4. 300ms 부드러운 transition
```

### URL 기반 활성화 로직
```javascript
// 예시: 현재 URL이 /01_compute/01_instances/instances.html 이면
// 자동으로 "Compute" 아코디언을 펼침 (애니메이션 없음)
// "Instances" 메뉴 항목을 활성화 (하이라이트)

// 상대경로 처리:
// /index.html → relative path: ./
// /01_compute/01_instances/instances.html → relative path: ../../
// /02_storage/01_volumes/volumes.html → relative path: ../../
```

### 클래스 구조 및 색상
```html
<!-- 일반 아코디언 헤더 -->
<div class="accordion-header">Compute</div>

<!-- 활성화되었을 때 (페이지 로드 - 애니메이션 없음) -->
<div class="accordion-item open">
  <div class="accordion-header">Compute</div>
  <div class="accordion-content">
    <!-- 활성화된 메뉴 항목 -->
    <div class="menu-item active">
      <a href="...">Instances</a>
    </div>
    <!-- 비활성화된 메뉴 항목 -->
    <div class="menu-item">
      <a href="...">Snapshots</a>
    </div>
  </div>
</div>

<!-- 사용자 클릭시 (애니메이션 있음) -->
<div class="accordion-item open animated">
  <div class="accordion-header">Compute</div>
  <div class="accordion-content">...</div>
</div>
```

### 색상 정의 (CSS Variables 권장)
```css
:root {
  --color-accent: #9252f7;  /* 메뉴 강조 색상 */
  --color-accent-hover: #8240e0;  /* 호버 상태 (옵션) */
}

/* 활성화된 메뉴 항목 */
.menu-item.active a {
  color: var(--color-accent);  /* #9252f7 */
  font-weight: 500;
  background-color: rgba(146, 82, 247, 0.08);  /* 연한 배경 */
  border-left: 3px solid var(--color-accent);
  padding-left: calc(1rem - 3px);
}

.menu-item.active a:hover {
  background-color: rgba(146, 82, 247, 0.15);
}

/* 아코디언 헤더 호버 */
.accordion-header:hover {
  color: var(--color-accent);
}
```

### 상대경로 처리
- menu-data.json의 path는 상대경로로 작동
- CSS/JavaScript의 경로도 상대경로 계산 필요
- 모든 뎁스 (1뎁스, 2뎁스, 3뎁스)에서 정상 작동

## 4. 장점
- 진정한 페이지 네비게이션 (각 페이지 독립적)
- JSON만 수정하면 메뉴 자동 업데이트
- JavaScript 변경 없이 새로운 섹션/항목 추가 가능
- 검색 엔진 최적화 (SEO 친화적)
- 북마크 및 직접 URL 접근 가능
- 브라우저 뒤로가기 정상 작동
- 유지보수성 높음
- 확장성 우수

## 5. 색상 스키마 (필수)

**Primary Accent Color: #9252f7 (바이올렛)**

```
활성화된 메뉴 항목 텍스트색: #9252f7
활성화된 메뉴 항목 배경: rgba(146, 82, 247, 0.08) (연한 바이올렛)
활성화된 메뉴 항목 좌측 테두리: #9252f7 (3px)
호버 상태 배경: rgba(146, 82, 247, 0.15) (더 진한 바이올렛)
```

## 6. 선택사항
- 현재 페이지 경로를 콘솔에 출력 (디버깅용)
- 활성화된 메뉴 항목의 아이콘 표시
- 메뉴 검색 기능
- 모바일 메뉴 토글 버튼
- 다크 모드 지원 (선택사항)

---

## 📝 구현 방식 설명

### 방식: 멀티 페이지 애플리케이션 (MPA)
- 각 HTML 파일은 **독립적인 페이지**
- 메뉴는 **공유 JavaScript**로 모든 페이지에 삽입
- 메뉴 클릭 → 페이지 이동 (window.location.href)
- 페이지 로드 시 → 현재 URL 감지 → 해당 메뉴 자동 활성화

### URL 매칭 알고리즘
```javascript
// 현재 페이지: /01_compute/01_instances/instances.html
// 또는: ./01_compute/01_instances/instances.html
// 또는: 상대경로: ../../../01_compute/01_instances/instances.html

// menu-data.json의 path와 비교:
// "path": "01_compute/01_instances/instances.html"

// 알고리즘:
// 1. 현재 window.location.pathname 추출
// 2. path의 정규화 (상대경로 제거)
// 3. 경로 비교 및 활성화
```

### 상대경로 계산
```
index.html (뎁스 0) → menu-data.json: ./menu-data.json
01_compute/01_instances/instances.html (뎁스 2) → menu-data.json: ../../menu-data.json
```
JavaScript에서 자동으로 현재 뎁스를 감지하고 상대경로 계산

### 파일 배치
```
html/
├── index.html
├── menu-data.json        ← 모든 페이지에서 로드
├── menu-renderer.js      ← 모든 페이지에서 로드
├── style.css             ← 모든 페이지에서 로드
├── 01_compute/
│   ├── 01_instances/
│   │   └── instances.html (menu-renderer.js 포함)
│   ├── 02_instances_snapshots/
│   │   └── instances_snapshots.html (menu-renderer.js 포함)
│   └── ...
├── 02_storage/
│   ├── 01_volumes/
│   │   └── volumes.html (menu-renderer.js 포함)
│   └── ...
└── ...
```

### 애니메이션 구현 로직

#### CSS
```css
/* 아코디언 기본 상태 - 애니메이션 없음 */
.accordion-content {
  max-height: 0;
  overflow: hidden;
}

/* open 상태 - 높이 변경만 (애니메이션 없음) */
.accordion-item.open .accordion-content {
  max-height: 500px; /* 또는 적절한 값 */
}

/* animated 클래스가 있을 때만 transition 적용 */
.accordion-item.animated .accordion-content {
  transition: max-height 300ms ease-in-out;
}
```

#### JavaScript 로직
```javascript
// 페이지 로드시: animated 클래스 없이 펼치기
function initializeMenu() {
  const currentPath = getCurrentPagePath();
  const menuItem = findMenuItemByPath(currentPath);
  
  if (menuItem) {
    // animated 클래스 없음 = 애니메이션 없음
    accordion.classList.add('open');
    menuItem.classList.add('active');
  }
}

// 사용자 클릭시: animated 클래스 추가해서 펼치기
function toggleAccordion(accordion) {
  // animated 클래스 추가 = 애니메이션 있음
  accordion.classList.add('animated');
  accordion.classList.toggle('open');
}
```

#### 결과
- **페이지 로드**: 아코디언이 "팍" 하고 즉시 펼쳐짐
- **메뉴 클릭**: 아코디언이 "슈우우윽" 하고 부드럽게 펼쳐짐

---

## 📊 색상 정의 상세

### CSS Variables 설정
```css
:root {
  /* Primary Colors */
  --color-accent: #9252f7;           /* 메뉴 활성화 색상 (바이올렛) */
  --color-accent-light: rgba(146, 82, 247, 0.08);   /* 배경: 매우 연함 */
  --color-accent-lighter: rgba(146, 82, 247, 0.15); /* 배경: 호버 상태 */
  
  /* Text & Border */
  --color-text-default: #333;
  --color-text-light: #666;
  --color-border: #ddd;
  
  /* Background */
  --color-bg-main: #fff;
  --color-bg-sidebar: #f9f9f9;
}
```

### 적용 위치
| 요소 | 색상 | 값 |
|------|------|-----|
| 활성화된 메뉴 항목 텍스트 | var(--color-accent) | #9252f7 |
| 활성화된 메뉴 항목 배경 | var(--color-accent-light) | rgba(146, 82, 247, 0.08) |
| 활성화된 메뉴 항목 좌측 테두리 | var(--color-accent) | #9252f7 |
| 호버 상태 배경 | var(--color-accent-lighter) | rgba(146, 82, 247, 0.15) |
| 아코디언 헤더 호버 텍스트 | var(--color-accent) | #9252f7 |
| 아코디언 펼침 화살표 (활성) | var(--color-accent) | #9252f7 |
