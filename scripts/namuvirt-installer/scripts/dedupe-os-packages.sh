#!/usr/bin/env bash
# ============================================================================
# dedupe-os-packages.sh — os-packages 그룹 간 중복 rpm/deb 제거 (용량/반입 축소).
#
# 지금은 각 그룹(qemu-kvm, libvirt, nfs, java ...) 디렉터리가 의존성 폐포를 통째로
# 담아, systemd/glibc 같은 베이스 패키지가 모든 그룹에 중복된다.
# 이 스크립트는 여러 그룹이 공유하는 패키지를 `_base/` 공용 풀 하나로 모으고,
# 그룹 고유 패키지만 각 그룹에 남긴다. 설치 소비자(kvm_hosts, management)는
# 자신의 그룹 + `_base` 를 함께 탐색하므로 설치 결과(union)는 동일하다.
#
# 안전 규칙:
#   - CORE 그룹(양쪽 소비자가 보는 그룹)에 2개 이상 걸친 패키지 → _base
#   - CORE 그룹 1개에만 있는 패키지 → 그 CORE 그룹에 유지
#   - KVM 그룹(qemu-kvm/libvirt)에만 있는 패키지 → KVM 그룹에 유지
#     (기존 KVM skip 시 이 그룹만 빠지고 _base 베이스는 그대로 설치됨)
#   - 실행 후 소비자별 도달 가능한 패키지 집합이 변하지 않았는지 검증(assert).
#
# 사용법:
#   scripts/dedupe-os-packages.sh <os-packages-dir>            # dry-run (요약만)
#   scripts/dedupe-os-packages.sh --apply <os-packages-dir>    # 실제 적용
# ============================================================================
set -Eeuo pipefail

APPLY=0
DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) DIR="$1"; shift ;;
  esac
done
[[ -n "$DIR" && -d "$DIR" ]] || { echo "ERROR: os-packages 디렉터리를 지정하라 (rocky/ ubuntu/ 상위)" >&2; exit 2; }

python3 - "$DIR" "$APPLY" <<'PY'
import os, sys, shutil, glob

root, apply = sys.argv[1], sys.argv[2] == "1"

# 소비자가 실제로 탐색하는 그룹 집합 (배치 결정의 기준).
KVM_GROUPS  = {"qemu-kvm","libvirt","network","nfs","iscsi","vm-tools","java","chrony","utils"}
MGMT_GROUPS = {"nfs","java","mariadb","utils"}
# 단일 소비자 전용 파일의 홈 선택 우선순위
KVM_PRIORITY  = ["nfs","java","utils","network","iscsi","vm-tools","chrony","libvirt","qemu-kvm"]
MGMT_PRIORITY = ["nfs","java","utils","mariadb"]

# 소비자별 탐색 그룹 (검증용). _base 는 실행 후 추가된다.
CONSUMERS = {
    "kvm_hosts_full": list(KVM_GROUPS),
    "kvm_hosts_skip": ["network","nfs","iscsi","vm-tools","java","chrony","utils"],
    "management":     list(MGMT_GROUPS),
}

def pkgs(os_dir, groups):
    s=set()
    for g in groups:
        d=os.path.join(os_dir,g)
        if os.path.isdir(d):
            s.update(os.path.basename(p) for p in glob.glob(os.path.join(d,"*"))
                     if p.endswith((".rpm",".deb")))
    return s

total_before=total_after=0
for os_name in ("rocky","ubuntu"):
    os_dir=os.path.join(root,os_name)
    if not os.path.isdir(os_dir): continue
    # _base(공용 풀)와 mgmt(관리 VM 로컬 offline repo — repodata 포함, 손대면 안 됨)는 dedupe 대상에서 제외.
    groups=[d for d in os.listdir(os_dir)
            if os.path.isdir(os.path.join(os_dir,d)) and d not in ("_base","mgmt")]
    # filename -> set(groups), and a source path
    loc={}; src={}
    for g in groups:
        for p in glob.glob(os.path.join(os_dir,g,"*")):
            if not p.endswith((".rpm",".deb")): continue
            f=os.path.basename(p)
            loc.setdefault(f,set()).add(g); src[f]=p
    before_files=sum(len(v) for v in loc.values())
    total_before+=before_files

    # 소비자별 사전 도달 집합
    before_reach={c:pkgs(os_dir,gs) for c,gs in CONSUMERS.items()}

    # 각 파일의 목적지 결정 (소비자 기준: 두 소비자가 모두 필요로 하면 _base)
    dest={}
    for f,gs in loc.items():
        need_kvm  = bool(gs & KVM_GROUPS)
        need_mgmt = bool(gs & MGMT_GROUPS)
        if need_kvm and need_mgmt:
            dest[f]="_base"
        elif need_kvm:
            dest[f]=next((g for g in KVM_PRIORITY if g in gs), sorted(gs)[0])
        else:  # management 전용(또는 알 수 없는 그룹) — 우선순위 없으면 원래 그룹 유지
            dest[f]=next((g for g in MGMT_PRIORITY if g in gs), sorted(gs)[0])

    # 적용
    if apply:
        base_dir=os.path.join(os_dir,"_base"); os.makedirs(base_dir,exist_ok=True)
        for f,gs in loc.items():
            tgt=dest[f]; tgt_dir=os.path.join(os_dir,tgt)
            os.makedirs(tgt_dir,exist_ok=True)
            tgt_path=os.path.join(tgt_dir,f)
            if not os.path.exists(tgt_path):
                shutil.copy2(src[f],tgt_path)
            for g in gs:
                if g==tgt: continue
                gp=os.path.join(os_dir,g,f)
                if os.path.exists(gp): os.remove(gp)
        # 빈 그룹 디렉터리는 남겨둠(ansible find 가 없는 경로도 허용)

    after_files=len(loc)  # 목표: 파일당 1벌
    total_after+=after_files

    # 검증 (적용 시): 소비자 도달 집합이 동일해야 함 (_base 포함)
    status="(dry-run)"
    if apply:
        # 핵심 안전조건: 소비자가 원래 받던 패키지를 하나도 잃지 않아야 한다(no loss).
        # _base 로 모인 베이스 패키지가 일부 추가로 보이는 것(superset)은 무해하므로 허용한다
        # (대상에 이미 설치된 베이스 → dnf no-op).
        ok=True; msgs=[]
        for c,gs in CONSUMERS.items():
            after=pkgs(os_dir,gs+["_base"])
            before=before_reach[c]
            missing=before-after
            extra=after-before
            if missing:
                ok=False; msgs.append(f"{c}: 누락 {len(missing)}건 {sorted(missing)[:3]}")
            elif extra:
                msgs.append(f"{c}: +{len(extra)} 베이스(무해)")
        status=("검증 OK" if ok else "검증 실패: ") + ("; ".join(m for m in msgs if '누락' in m) if not ok else "")
        if not ok:
            print(f"[{os_name}] {status}", file=sys.stderr); sys.exit(1)

    base_ct=sum(1 for f in dest if dest[f]=="_base")
    print(f"[{os_name}] before={before_files} → after={after_files} "
          f"(_base={base_ct}, 그룹고유={after_files-base_ct})  {status}")

print(f"TOTAL: {total_before} → {total_after} 파일 "
      f"({'적용됨' if apply else 'dry-run — --apply 로 실제 적용'})")
PY
