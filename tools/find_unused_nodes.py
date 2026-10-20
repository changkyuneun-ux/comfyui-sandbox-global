#!/usr/bin/env python3
"""사용하지 않는 커스텀 노드 묶음 찾기 (실행 중인 ComfyUI 서버 기준).

사용 근거로 보는 것 (모두 합산):
  1) 저장된 워크플로      /api/userdata?dir=workflows   (UI 형식·API 형식 모두)
  2) 실행 기록(history)   /api/history                  ← 저장 안 한 워크플로도 실행했다면 잡힘
  3) 서브그래프 블루프린트 /api/global_subgraphs
  4) 추가 파일(선택)      --extra 경로의 .json 파일들(로컬 워크플로 폴더 등)
노드 → 묶음 대응은 /api/object_info 의 python_module 로 판정.

사용 예 (Pod 터미널):
  python find_unused_nodes.py                       # localhost:8188
  python find_unused_nodes.py --server https://<pod>-8188.proxy.runpod.net --extra ./workflows
  python find_unused_nodes.py --json report.json    # 결과 저장
"""
import argparse, glob, json, os, sys, urllib.parse, urllib.request
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("--server", default="http://127.0.0.1:8188")
ap.add_argument("--extra", action="append", default=[], help="추가로 검사할 워크플로 폴더/파일")
ap.add_argument("--history", type=int, default=10000, help="history 조회 개수")
ap.add_argument("--json", help="결과 JSON 저장 경로")
a = ap.parse_args()
S = a.server.rstrip("/")

def get(path):
    with urllib.request.urlopen(S + path, timeout=120) as r:
        return json.load(r)

oi = get("/api/object_info")
def pack_of(t):
    m = (oi.get(t) or {}).get("python_module", "")
    return m[len("custom_nodes."):].split(".")[0] if m.startswith("custom_nodes.") else "(core)"

all_packs = defaultdict(int)
for t in oi:
    all_packs[pack_of(t)] += 1

def collect(o, acc):
    if isinstance(o, list):
        for x in o: collect(x, acc)
    elif isinstance(o, dict):
        if isinstance(o.get("class_type"), str): acc.add(o["class_type"])                      # API 형식
        if isinstance(o.get("type"), str) and ("widgets_values" in o or "inputs" in o) and ("id" in o or "pos" in o):
            acc.add(o["type"])                                                                    # UI 형식(서브그래프 포함)
        for v in o.values():
            if isinstance(v, (dict, list)): collect(v, acc)

sources = {}  # 출처 → 노드 타입 집합
# 1) 저장된 워크플로
try:
    for f in get("/api/userdata?dir=workflows&recurse=true"):
        if f.endswith(".json"):
            try: s=set(); collect(get("/api/userdata/" + urllib.parse.quote("workflows/" + f, safe="")), s); sources["workflow:" + f] = s
            except Exception as e: print("WARN 워크플로 읽기 실패", f, e, file=sys.stderr)
except Exception as e: print("WARN 워크플로 목록 실패", e, file=sys.stderr)
# 2) 실행 기록
try:
    for pid, v in get(f"/api/history?max_items={a.history}").items():
        s=set(); collect((v.get("prompt") or [None, None, {}])[2], s); sources["history:" + pid[:8]] = s
except Exception as e: print("WARN history 실패", e, file=sys.stderr)
# 3) 서브그래프 블루프린트
try:
    for k in get("/api/global_subgraphs"):
        try: s=set(); collect(get("/api/global_subgraphs/" + k), s); sources["subgraph:" + k[:8]] = s
        except Exception: pass
except Exception: pass
# 4) 추가 파일
for p in a.extra:
    for f in ([p] if os.path.isfile(p) else glob.glob(os.path.join(p, "**", "*.json"), recursive=True)):
        try: s=set(); collect(json.load(open(f)), s); sources["file:" + os.path.basename(f)] = s
        except Exception: pass

used = defaultdict(lambda: defaultdict(set))   # pack → node → {출처}
unknown = defaultdict(set)
for src, types in sources.items():
    for t in types:
        if t in oi: used[pack_of(t)][t].add(src)
        elif not (len(t) == 36 and t.count("-") == 4) and t not in ("Note", "MarkdownNote", "Reroute", "PrimitiveNode"):
            unknown[t].add(src)

custom = sorted(p for p in all_packs if p != "(core)")
used_packs = sorted(p for p in custom if p in used)
unused = sorted((p for p in custom if p not in used), key=lambda p: -all_packs[p])

print(f"\n검사한 출처 {len(sources)}개 (워크플로 {sum(k.startswith('workflow:') for k in sources)}, "
      f"실행기록 {sum(k.startswith('history:') for k in sources)}, 서브그래프 {sum(k.startswith('subgraph:') for k in sources)}, "
      f"추가파일 {sum(k.startswith('file:') for k in sources)})")
print(f"전체 노드 {sum(all_packs.values())}개 = 기본 {all_packs['(core)']} + 커스텀 {sum(all_packs[p] for p in custom)} ({len(custom)}개 묶음)\n")
print("■ 사용 중인 묶음")
for p in used_packs:
    nodes = used[p]
    print(f"  {p} ({all_packs[p]}개 중 {len(nodes)}개 사용): " + ", ".join(sorted(nodes))[:200])
print(f"\n■ 사용 흔적 없는 묶음 (제거 후보, 노드 수 많은 순) — 제거 시 {sum(all_packs[p] for p in unused)}개 노드 감소")
for p in unused:
    print(f"  {p}: {all_packs[p]}개")
if unknown:
    print("\n■ 정의를 찾을 수 없는 노드 (설치 안 됨/비활성 묶음, 또는 화면 전용 노드)")
    for t, s in sorted(unknown.items()):
        print(f"  {t}  ← {', '.join(sorted(s))[:120]}")
print("\n주의: 화면 전용 노드(예: rgthree 의 Bypasser/Muter 계열)와 UI 확장 기능만 쓰는 묶음은 '사용 흔적 없음'으로 나올 수 있음")

if a.json:
    json.dump({"used": {p: {n: sorted(s) for n, s in v.items()} for p, v in used.items()},
               "unused": {p: all_packs[p] for p in unused},
               "unknown": {t: sorted(s) for t, s in unknown.items()},
               "all_packs": dict(all_packs)}, open(a.json, "w"), ensure_ascii=False, indent=1)
    print("저장:", a.json)
