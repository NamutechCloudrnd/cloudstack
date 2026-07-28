# os-images/ — 릴리즈 번들에 기본 포함할 OS 이미지 소스

`export-images.sh` 는 이 디렉터리의 **`bundle.list` 에 나열된 파일만** 번들의 `images/` 로 복사하고
`SHA256SUMS` 에 등록한다. 한 번 패키징하면 고객사가 이미지를 따로 배치하지 않아도 된다.

> 이 디렉터리에는 게스트 테스트용 이미지(CentOS, vSphere OVA 등)가 섞여 있을 수 있으므로,
> **glob 이 아니라 `bundle.list` 화이트리스트**로 번들 대상만 명시한다.

## bundle.list
 
```
# 한 줄에 파일명 하나 (os-images/ 기준), '#' 뒤는 주석
NAMU-Rocky-8-10.qcow2          # 관리 VM 골든 이미지 (cloud-init 기반, 필수)
# SystemVM-Template-KVM.qcow2  # 필요 시 주석 해제
```

## config.yaml 과의 관계

번들 `images/` 는 컨테이너의 `/mnt/namuvirt/images/` 로 mount 된다. `bundle.list` 에 넣은 파일명을
config 가 그대로 가리켜야 한다:

```yaml
management:
  rocky_cloudimg: /mnt/namuvirt/images/NAMU-Rocky-8-10.qcow2
```

## 옵션

```bash
./export-images.sh --version 1.0.0 --output release/namuvirt-installer-1.0.0
./export-images.sh ... --no-os-image            # OS 이미지 없이 패키징
./export-images.sh ... --os-images-src /other   # 다른 소스 디렉터리 사용
```

> 실제 qcow2 는 용량이 커서 보통 형상관리에 커밋하지 않는다(.gitkeep 와 bundle.list 만 유지).
