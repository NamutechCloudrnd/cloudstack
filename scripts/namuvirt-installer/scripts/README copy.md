# namuVIRT 패키지 빌드

이 레포지토리에서 CloudStack 패키지를 빌드합니다. non-OSS JAR는 `vendor/cloudstack-nonoss/`에 **커밋**되어 있습니다.

## 빠른 시작

```bash
# Rocky 8 — RPM (빌드 도구 없으면 자동 설치, sudo 사용 가능)
./build/rocky.sh

# Ubuntu — deb (빌드 도구 없으면 자동 설치, sudo 사용 가능)
./build/ubuntu.sh
```

**동작:** 호스트 deps 없으면 설치 → 소스 풀 빌드 → `build/packages/*/latest/`에 산출. git 상태·이전 산출물 재사용으로 빌드를 건너뛰지 않음.

산출물:

| 스크립트 | 패키지 경로 |
|----------|-------------|
| `./build/rocky.sh` | `build/packages/rpm/latest/*.rpm` |
| `./build/ubuntu.sh` | `build/packages/deb/latest/*.deb` |

매 빌드마다 `SHA256SUMS`, `BUILD_INFO.txt`가 생성됩니다 (브랜치·커밋은 메타데이터에만 기록, 경로에는 없음).

## 공통 옵션

| 플래그 | 설명 |
|--------|------|
| `--mode normal\|dev\|clean` | `normal`/`dev`: 테스트 스킵; `clean`: `mvn clean` 포함 |
| `--without-vmware` | OSS만 빌드 (noredist 생략) |
| `--dry-run` | 실행 계획만 출력 |
| `--no-auto-deps` | deps 자동 설치 생략 |

## 빌드 의존성 (자동 설치)

| OS | 스크립트 | 설치 내용 |
|----|----------|-----------|
| Rocky 8 | `build/lib/deps-rocky.sh` | Java 17, rpmbuild, Node, Maven `/opt/maven` |
| Ubuntu | `build/lib/deps-ubuntu.sh` | openjdk-17-jdk, maven, devscripts, nodejs/npm, python2 equivs 등 |

빌드 스크립트가 누락 시 자동 호출합니다. 일반 사용자로 실행하면 `sudo`로 deps 설치를 시도합니다.

수동 확인:

```bash
sudo ./build/lib/deps-rocky.sh --check-only
sudo ./build/lib/deps-ubuntu.sh --check-only
```

## non-OSS 모듈

`vendor/cloudstack-nonoss/README.md` 참고. noredist 빌드 전 JAR 10종이 모두 있어야 합니다.

## 디렉터리 구조

```text
build/
  rocky.sh          ubuntu.sh     ← 엔트리
  lib/              common, rocky, ubuntu, deps-rocky, deps-ubuntu
  packages/rpm/latest/
  packages/deb/latest/
vendor/cloudstack-nonoss/   ← JAR + install-non-oss.sh
```

`git checkout`, `git reset`, `git clean`은 **실행하지 않습니다**.
