#!/usr/bin/env python3
"""env/custom_nodes.txt 를 읽어 커스텀 노드를 지정 버전으로 설치한다.
  GIT|폴더명|repo_url|commit   -> git clone 후 commit 고정
  REG|폴더명|registry_id|ver   -> Comfy Registry(api.comfy.org)에서 해당 버전 zip 설치
의존성(pip)은 여기서 설치하지 않는다. requirements.lock.txt 로 일괄 설치한다.
"""
import io, json, subprocess, sys, urllib.request, zipfile
from pathlib import Path

LIST, DEST = Path(sys.argv[1]), Path(sys.argv[2])
API = "https://api.comfy.org"
failed = []

def get_json(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)

for line in LIST.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    kind, name, src, ver = line.split("|")
    target = DEST / name
    try:
        if kind == "GIT":
            subprocess.run(["git", "clone", "--quiet", src, str(target)], check=True)
            subprocess.run(["git", "-C", str(target), "checkout", "--quiet", ver], check=True)
            subprocess.run(["git", "-C", str(target), "submodule", "update", "--init", "--recursive", "--quiet"], check=True)
        elif kind == "REG":
            info = get_json(f"{API}/nodes/{src}/install?version={ver}")
            url = info.get("downloadUrl") or info.get("download_url")
            if not url:
                raise RuntimeError(f"downloadUrl 없음: {info}")
            with urllib.request.urlopen(url, timeout=300) as r:
                zipfile.ZipFile(io.BytesIO(r.read())).extractall(target)
        else:
            raise RuntimeError(f"알 수 없는 유형 {kind}")
        print(f"[OK]   {kind} {name} @ {ver}")
    except Exception as e:  # noqa
        print(f"[FAIL] {kind} {name} @ {ver}: {e}", file=sys.stderr)
        failed.append(name)

if failed:
    print(f"설치 실패 {len(failed)}건: {failed}", file=sys.stderr)
    sys.exit(1)
