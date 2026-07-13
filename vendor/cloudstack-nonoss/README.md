# cloudstack-nonoss (namuVIRT 4.22 최소 세트)

noredist (`-Dnoredist`) Maven 빌드에 필요한 JAR 모음입니다. **이 디렉터리에 커밋**되어 있으며, `./build/rocky.sh` 또는 `./build/ubuntu.sh` 실행 시 `install-non-oss.sh`가 `~/.m2`에 등록합니다.

## 필수 파일 (10종)

| 파일 | Maven 좌표 |
|------|------------|
| `vim25_80.jar` | `com.cloud.com.vmware:vmware-vim25:8.0` |
| `pbm_80.jar` | `com.cloud.com.vmware:vmware-pbm:8.0` |
| `nsx-java-sdk-4.1.0.2.0.jar` | `com.vmware:nsx-java-sdk:4.1.0.2.0` |
| `nsx-gpm-java-sdk-4.1.0.2.0.jar` | `com.vmware:nsx-gpm-java-sdk:4.1.0.2.0` |
| `nsx-policy-java-sdk-4.1.0.2.0.jar` | `com.vmware:nsx-policy-java-sdk:4.1.0.2.0` |
| `vapi-authentication-2.40.0.jar` | `com.vmware.vapi:vapi-authentication:2.40.0` |
| `vapi-runtime-2.40.0.jar` | `com.vmware.vapi:vapi-runtime:2.40.0` |
| `netris-java-sdk-1.0.0.jar` | `io.netris:netris-java-sdk:1.0.0` |
| `juniper-contrail-api-1.0-SNAPSHOT.jar` | `net.juniper.contrail:juniper-contrail-api:1.0-SNAPSHOT` |
| `juniper-tungsten-api-2.0.jar` | `net.juniper.tungsten:juniper-tungsten-api:2.0` |

출처: [shapeblue/cloudstack-nonoss](https://github.com/shapeblue/cloudstack-nonoss) — 또는 로컬 클론에서 복사 (예: `namuVIRT` 옆 `../cloudstack-nonoss`).

upstream `deps/`에 `vim25_80.jar`, `pbm_80.jar`만 있어도 noredist 빌드에는 **위 10종 전부**가 이 디렉터리에 있어야 합니다.

## 수동 등록

```bash
cd vendor/cloudstack-nonoss
./install-non-oss.sh
```

## 라이선스

서드파티 SDK — **내부 빌드용**. JAR 원본은 재배포하지 않으며, CloudStack 패키지(RPM/deb)에만 포함됩니다.
