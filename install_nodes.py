#!/usr/bin/env python3
"""env/custom_nodes.txt 를 읽어 커스텀 노드를 지정 버전으로 설치한다.
  GIT|폴더명|repo_url|commit[|fallback_ref]  -> git clone 후 commit 고정.
        commit 이 원격에 없으면(force-push 등) fallback_ref(태그/브랜치) → 없으면 기본 브랜치 HEAD 로 설치하고 WARN
  REG|폴더명|registry_id|version            -> Comfy Registry(api.comfy.org) 해당 버전 zip
  VENDOR|폴더명|tar.gz 경로(빌드 컨텍스트 기준)|메모 -> 저장소에 동봉한 압축본 (원격 저장소가 사라진 노드)
의존성(pip)은 여기서 설치하지 않는다. requirements.lock.txt 로 일괄 설치한다.
"""
import io, json, subprocess, sys, tarfile, urllib.request, zipfile
from pathlib import Path

LIST, DEST = Path(sys.argv[1]), Path(sys.argv[2])
CTX = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("/tmp")
API = "https://api.comfy.org"
failed, warned = [], []

def git(*a, **kw):
    return subprocess.run(["git", *a], check=True, **kw)

for line in LIST.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    kind, name, src, ver, *rest = line.split("|")
    target = DEST / name
    try:
        if kind == "GIT":
            git("clone", "--quiet", src, str(target))
            try:
                git("-C", str(target), "checkout", "--quiet", ver, stderr=subprocess.DEVNULL)
                used = ver
            except subprocess.CalledProcessError:
                fb = rest[0] if rest else None
                if fb:
                    git("-C", str(target), "checkout", "--quiet", fb)
                used = fb or "HEAD(default)"
                warned.append(f"{name}: commit {ver[:10]} 원격에 없음 → {used}")
            git("-C", str(target), "submodule", "update", "--init", "--recursive", "--quiet")
            ver = used
        elif kind == "REG":
            with urllib.request.urlopen(f"{API}/nodes/{src}/install?version={ver}", timeout=60) as r:
                info = json.load(r)
            url = info.get("downloadUrl") or info.get("download_url")
            if not url:
                raise RuntimeError(f"downloadUrl 없음: {info}")
            with urllib.request.urlopen(url, timeout=300) as r:
                zipfile.ZipFile(io.BytesIO(r.read())).extractall(target)
        elif kind == "VENDOR":
            target.mkdir(parents=True, exist_ok=True)
            with tarfile.open(CTX / src) as t:
                t.extractall(target, filter="data")
        else:
            raise RuntimeError(f"알 수 없는 유형 {kind}")
        print(f"[OK]   {kind} {name} @ {ver}")
    except Exception as e:  # noqa
        print(f"[FAIL] {kind} {name} @ {ver}: {e}", file=sys.stderr)
        failed.append(name)

for w in warned:
    print(f"[WARN] {w}")
if failed:
    print(f"설치 실패 {len(failed)}건: {failed}", file=sys.stderr)
    sys.exit(1)
