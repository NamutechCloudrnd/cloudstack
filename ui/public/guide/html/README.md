# Project Navigation System

동적 아코디언 메뉴를 이용한 프로젝트 네비게이션 시스템입니다.

## 📁 파일 구조

```
html/
├── index.html                   # 홈 페이지
├── menu-data.json              # 메뉴 데이터 (JSON)
├── menu-renderer.js            # 메뉴 생성 스크립트
├── style.css                   # 공유 스타일
├── PAGE-TEMPLATE.html          # 페이지 템플릿
├── README.md                   # 이 파일
│
├── 01_compute/
│   ├── 01_instances/
│   │   └── instances.html
│   ├── 02_instances_snapshots/
│   │   └── instances_snapshots.html
│   └── ...
│
├── 02_storage/
│   ├── 01_volumes/
│   │   └── volumes.html
│   └── ...
│
└── ... (다른 카테고리들)
```

## 🚀 빠른 시작

### 0. CORS 오류 해결 (로컬 테스트시)

**방법 A: Python 로컬 서버 (추천) ⭐**
```powershell
cd "your-path\html"
python -m http.server 8000
```
그 후 `http://localhost:8000` 접속

**방법 B: Node.js HTTP Server**
```powershell
npx http-server -p 8000
```

**방법 C: JavaScript 방식 (이미 적용됨) ✅**
- menu-data.js를 사용하여 CORS 없이 작동합니다
- menu-data.js를 menu-renderer.js 전에 로드해야 합니다

### 1. 홈 페이지 확인
```
index.html을 브라우저에서 열기 (로컬 서버 필수)
```

### 2. 새 페이지 만들기
`PAGE-TEMPLATE.html`을 복사하여 사용:

```bash
# 예: 01_compute/01_instances/instances.html 만들기
cp PAGE-TEMPLATE.html 01_compute/01_instances/instances.html
```

### 3. 상대경로 수정
파일을 만든 위치에 따라 상대경로를 조정:

```html
<!-- 뎁스 2 (01_compute/01_instances/instances.html) -->
<link rel="stylesheet" href="../../style.css">
<script src="../../menu-renderer.js"></script>

<!-- 뎁스 1 (docs/page.html) -->
<link rel="stylesheet" href="../style.css">
<script src="../menu-renderer.js"></script>

<!-- 뎁스 0 (index.html) -->
<link rel="stylesheet" href="./style.css">
<script src="./menu-renderer.js"></script>
```

## 🎨 색상 스키마

**Primary Accent Color: #9252f7** (바이올렛)

### 적용되는 곳
- 활성화된 메뉴 항목 텍스트
- 활성화된 메뉴 항목 좌측 테두리
- 활성화된 메뉴 항목 배경
- 메뉴 호버 상태
- 아코디언 헤더 호버

## ⚙️ 메뉴 수정 방법

### 새 카테고리 추가
`menu-data.json`에 다음을 추가:

```json
{
  "id": "15_new_category",
  "label": "New Category",
  "items": [
    {
      "id": "01_item",
      "label": "First Item",
      "path": "15_new_category/01_item/item.html"
    }
  ]
}
```

### 새 항목 추가
기존 카테고리의 `items` 배열에 추가:

```json
{
  "id": "02_new_item",
  "label": "New Item",
  "path": "01_compute/02_new_item/new_item.html"
}
```

## 🔧 JavaScript 주요 함수

### `getRelativeBasePath()`
현재 파일 위치를 기반으로 상대경로 계산

### `renderMenu()`
menu-data.json을 기반으로 메뉴 렌더링

### `highlightCurrentPage()`
현재 URL에 해당하는 메뉴 항목 자동 활성화

### `toggleAccordion(accordionDiv)`
아코디언 펼침/닫힘 (애니메이션 포함)

## 📱 반응형 디자인

- **Desktop**: 좌측 메뉴 (280px) + 우측 콘텐츠
- **Mobile** (< 768px): 메뉴를 상단에 표시

## 🎬 애니메이션 동작

### 페이지 로드시
- 아코디언 즉시 펼쳐짐 (애니메이션 없음)
- 빠르고 반응적

### 사용자 클릭시
- 아코디언 부드럽게 펼침/닫힘 (300ms)
- 우아한 사용자 경험

## 🐛 문제 해결

### 메뉴가 나타나지 않음
1. `menu-data.json` 경로 확인
2. 브라우저 콘솔에서 에러 메시지 확인
3. 상대경로 수정

### 페이지 링크가 작동하지 않음
1. `menu-data.json`의 path 확인
2. 실제 파일이 해당 경로에 존재하는지 확인
3. 상대경로 계산 확인

### 메뉴 항목이 활성화되지 않음
1. 현재 URL과 JSON의 path가 일치하는지 확인
2. 파일명 대소문자 확인
3. 브라우저 개발자 도구 → Console에서 경로 확인

## 📝 커스터마이징

### 색상 변경
`style.css`의 `:root` 변수 수정:

```css
:root {
  --color-accent: #your-color;
  --color-accent-light: rgba(your-r, your-g, your-b, 0.08);
  --color-accent-lighter: rgba(your-r, your-g, your-b, 0.15);
}
```

### 애니메이션 속도 변경
`style.css`의 transition 값 수정:

```css
.accordion-item.animated .accordion-content {
  transition: max-height 300ms ease-in-out; /* 300ms를 원하는 값으로 변경 */
}
```

### 메뉴 너비 변경
`style.css`의 `.menu-sidebar` 수정:

```css
.menu-sidebar {
  width: 280px; /* 원하는 너비로 변경 */
}
```

## 📚 참고 자료

- **HTML 표준**: https://html.spec.whatwg.org/
- **CSS Flexbox**: https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_Flexible_Box_Layout
- **JavaScript Fetch API**: https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API

## 💡 팁

1. **대량의 페이지 생성**: `PAGE-TEMPLATE.html`을 기반으로 스크립트 작성
2. **메뉴 관리**: `menu-data.json` 한 곳에서만 수정하면 모든 페이지에 반영
3. **개발 중 디버깅**: 브라우저 콘솔에서 `window.location.pathname` 확인

## ✅ 체크리스트

새 페이지 추가시:

- [ ] `PAGE-TEMPLATE.html` 복사
- [ ] 파일명을 의도한 이름으로 변경
- [ ] 상대경로 수정 (style.css, menu-renderer.js)
- [ ] 페이지 제목 수정 (`<title>`, `<h1>`)
- [ ] 콘텐츠 작성
- [ ] `menu-data.json`에 항목 추가
- [ ] 브라우저에서 테스트
- [ ] 메뉴에서 활성화 확인

## 📞 지원

문제가 발생하면:

1. 브라우저 콘솔 (F12) 확인
2. 파일 경로 및 상대경로 검증
3. `menu-data.json` 형식 검증 (JSON.parse 테스트)
