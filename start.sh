#!/usr/bin/env bash
# DOBEDUB ComfyUI Sandbox (Global Volume / 이미지 cu130=Blackwell, cu128=Hopper)
# - 모델: ComfyUI/models → Global Volume(/workspace-global/models) 디렉터리 링크 (다운로드도 Global Volume 에 저장)
# - 입력: ComfyUI/input  → Global Volume(/workspace-global/input) 디렉터리 링크
# - 워크플로/user: 기동 시 Global Volume → 로컬로 복원, 5분마다 Global Volume 에 백업 (DB 는 잠금 미지원이라 제외)
# - 출력: 로컬 디스크에 저장 → 5분마다 Global Volume에 백업 (Global Volume은 rename/lock 미지원)
set -u
GV="${GLOBAL_VOLUME_PATH:-/workspace-global}"
C=/opt/ComfyUI

# --- SSH (콘솔 SSH 접속용) ---
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p ~/.ssh && echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
  chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
  for t in rsa ecdsa ed25519; do f=/etc/ssh/ssh_host_${t}_key; [ -f $f ] || ssh-keygen -t $t -f $f -q -N ''; done
  service ssh start || echo "sandbox: SSH start failed" >&2
fi

# --- Jupyter (파일 업/다운로드용, JUPYTER_PASSWORD 있을 때만) ---
if [ -n "${JUPYTER_PASSWORD:-}" ]; then
  nohup jupyter lab --allow-root --no-browser --ip=0.0.0.0 --port=8888 \
    --ServerApp.token="$JUPYTER_PASSWORD" --ServerApp.root_dir=/ \
    --ServerApp.allow_origin_pat='https://.*\.proxy\.runpod\.net' > /var/log/jupyter.log 2>&1 &
fi

# 기본 실행 인자 (env COMFY_ARGS 로 덮어쓰기 가능)
#  - --cache-none 제거: 매 실행마다 로더 노드가 다시 돌아 모델을 Global Volume 에서 재로딩하는 것을 방지 (기본 RAM 압력 캐시 사용)
#  - --disable-pinned-memory 제거: B200(377GB)/RTX PRO 6000(188GB) RAM 에서 pinned 전송이 유리
#  - --enable-compress-response-body: object_info 6.2MB → 0.7MB (gzip)
: "${COMFY_ARGS:=--fast fp8_matrix_mult --use-sage-attention --enable-compress-response-body}"
: "${MANAGER_NETWORK_MODE:=offline}"   # 기동 시 Registry 204페이지 수집 생략 (노드 설치는 이미지 재빌드로만)

# --- GPU / 스택 확인 ---
python - <<'PY' || { echo "sandbox: GPU check FAILED" >&2; exit 1; }
import torch
torch.cuda.init(); n=torch.cuda.get_device_name(0); c=torch.cuda.get_device_capability(0)
(torch.zeros(8,device='cuda')+1).sum().item()
print(f"sandbox: GPU OK {n} (sm_{c[0]}{c[1]}) torch {torch.__version__} cuda {torch.version.cuda}")
import os
v=os.environ.get("IMAGE_VARIANT","?"); arch=c[0]*10+c[1]
if v=="cu128" and arch>=100: print(f"sandbox: WARNING Blackwell GPU(sm_{arch}) on cu128 image -> use :cu130 (NVFP4/INT8 가속, SageAttention)")
if v=="cu130" and arch<100: print(f"sandbox: WARNING Hopper GPU(sm_{arch}) on cu130 image -> use :cu128 (SageAttention sm_90)")
try:
    import comfy_kitchen  # noqa
    print("sandbox: image variant", v)
except Exception: pass
try:
    import sageattention; print("sandbox: sageattention", getattr(sageattention,'__version__','ok'))
except Exception as e: print("sandbox: sageattention FAIL", e)
try:
    import onnxruntime as ort; print("sandbox: onnxruntime providers", ort.get_available_providers())
except Exception as e: print("sandbox: onnxruntime FAIL", e)
PY

# --- SageAttention 정확도 검사 (실제 GPU에서 PyTorch SDPA와 비교). 실패하면 sage 없이 기동 ---
if [[ " $COMFY_ARGS " == *" --use-sage-attention "* ]]; then
  SAGE_RESULT=$(python - <<'PY' 2>&1 | tail -1
import torch, torch.nn.functional as F
try:
    from sageattention import sageattn
    torch.manual_seed(0)
    q, k, v = [torch.randn(1, 8, 1024, 128, device="cuda", dtype=torch.bfloat16) for _ in range(3)]
    o = sageattn(q, k, v, tensor_layout="HND", is_causal=False)
    r = F.scaled_dot_product_attention(q, k, v)
    cos = F.cosine_similarity(o.float().flatten(), r.float().flatten(), dim=0).item()
    print(("OK" if cos > 0.99 else "FAIL") + f" cos={cos:.5f}")
except Exception as e:
    print(f"FAIL {type(e).__name__}: {e}")
PY
)
  echo "sandbox: sage check $SAGE_RESULT"
  if [[ "$SAGE_RESULT" != OK* ]]; then
    COMFY_ARGS=$(echo " $COMFY_ARGS " | sed 's/ --use-sage-attention / /')
    echo "sandbox: WARNING sage disabled -> PyTorch attention"
  fi
fi

# --- 모델 / 입력: Global Volume 디렉터리를 그대로 연결 ---
#   2026-10-21 측정(6bkuxq8m8yrela, 모델 422개): 목록 조회 파일별 링크 2ms vs Global Volume 직접 8ms → 링크 미러 불필요.
#   디렉터리 링크라서 Civicomfy 등 노드가 ComfyUI/models 에 받는 모델도 Global Volume 에 저장되고,
#   새 파일은 폴더 mtime 이 바뀌어 UI 새로고침(R)만으로 목록에 나타난다. (삭제는 mtime 미반영 → 재시작 시 정리)
link_dir() {  # $1=ComfyUI 쪽 경로, $2=Global Volume 쪽 경로
  mkdir -p "$2"
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    cp -rn "$1/." "$2/" 2>/dev/null || true      # 이미지 기본 파일(예제 등)은 없을 때만 복사
    mv "$1" "$1.image"
  fi
  ln -sfn "$2" "$1"
  echo "sandbox: $1 -> $(readlink "$1")"
}
if [ -d "$GV/models" ]; then
  link_dir "$C/models" "$GV/models"
  link_dir "$C/input"  "$GV/input"
else
  echo "sandbox: WARNING $GV/models 없음 (Global Volume 미연결?) -> 이미지 기본 폴더로 기동" >&2
fi

# --- 사용자 폴더(user/) 복원 + 주기 백업 ---
#   기존 네트워크 볼륨 환경은 user/ (설정, 워크플로, ComfyUI-Manager 캐시)가 볼륨에 남아 있었다.
#   컨테이너 디스크에 두면 재시작마다 초기화되므로 Global Volume 에 보관/복원한다. (DB·로그 제외)
mkdir -p "$C/user" "$GV/user"
USER_EXCL="--exclude=*.db --exclude=*.db-* --exclude=*.log --exclude=*.lock --exclude=__pycache__"
rsync -rl --inplace --no-perms --no-owner --no-group $USER_EXCL "$GV/user/" "$C/user/" 2>&1 | grep -v "failed to set times" || true
# --- ComfyUI-Manager 네트워크 모드 ---
MCFG="$C/user/__manager/config.ini"; mkdir -p "$(dirname "$MCFG")"
if [ -f "$MCFG" ] && grep -q '^network_mode' "$MCFG"; then sed -i "s/^network_mode.*/network_mode = $MANAGER_NETWORK_MODE/" "$MCFG"
else printf '[default]\nnetwork_mode = %s\n' "$MANAGER_NETWORK_MODE" >> "$MCFG"; fi
echo "sandbox: ComfyUI-Manager network_mode=$MANAGER_NETWORK_MODE"

# --- 대형 모델 로컬 캐시 (선택) ---
#   PRELOAD_MODELS="text_encoders/a.safetensors,unet/b.safetensors" (models/ 기준 상대경로, 콤마 구분)
#   Global Volume → 컨테이너 디스크(/opt/model-cache)로 백그라운드 복사.
#   /opt/model-cache 를 extra_model_paths.yaml 의 우선 경로(is_default)로 등록 → 같은 파일명이면 로컬 사본을 먼저 읽는다.
#   복사 중(.part)이거나 아직 없으면 Global Volume 원본을 읽는다. 디스크 여유가 부족하면 건너뜀.
#   주의: models 가 Global Volume 링크이므로 $C/models 아래에 링크/파일을 만들지 않는다 (원본 덮어쓰기 방지).
if [ -n "${PRELOAD_MODELS:-}" ] && [ -d "$GV/models" ]; then
  mkdir -p /opt/model-cache
  { echo "preload_cache:"; echo "    base_path: /opt/model-cache"; echo "    is_default: true"
    echo "$PRELOAD_MODELS" | tr ',' '\n' | xargs -n1 | cut -d/ -f1 | sort -u | while read -r t; do
      [ -n "$t" ] && { mkdir -p "/opt/model-cache/$t"; echo "    $t: $t"; }; done
  } > "$C/extra_model_paths.yaml"
  echo "sandbox: extra_model_paths.yaml -> $(grep -c ':' "$C/extra_model_paths.yaml") lines (preload 우선 경로)"
  ( IFS=',' ; for rel in $PRELOAD_MODELS; do
      rel="$(echo "$rel" | xargs)"; src="$GV/models/$rel"; dst="/opt/model-cache/$rel"
      [ -f "$src" ] || { echo "sandbox: preload SKIP (없음) $rel"; continue; }
      need=$(( $(stat -c %s "$src") / 1048576 + 2048 )); free=$(df -Pm /opt | awk 'NR==2{print $4}')
      [ "$free" -gt "$need" ] || { echo "sandbox: preload SKIP (디스크 부족 need=${need}MB free=${free}MB) $rel"; continue; }
      mkdir -p "$(dirname "$dst")"; t0=$(date +%s)
      if rsync -a --inplace "$src" "$dst.part" && mv "$dst.part" "$dst"; then
        echo "sandbox: preload OK $rel ($(( $(stat -c %s "$dst") / 1073741824 ))GB, $(( $(date +%s) - t0 ))s)"
      else echo "sandbox: preload FAIL $rel"; rm -f "$dst.part"; fi
    done; echo "sandbox: preload done" ) &
fi

# --- 워크플로 복원 + 주기 백업 / 출력 주기 백업 ---
WF="$C/user/default/workflows"; mkdir -p "$WF" "$C/output" "$GV/workflows" "$GV/output"
cp -rn "$GV/workflows/." "$WF/" 2>/dev/null || true
# Global Volume 은 파일 시간(mtime) 설정을 지원하지 않음 → -t 없이, 비교는 체크섬(워크플로)/크기(출력)로
SYNC="rsync -rl --inplace --no-perms --no-owner --no-group --omit-dir-times"
( while true; do sleep "${SYNC_INTERVAL:-300}"
    $SYNC --checksum "$WF/" "$GV/workflows/" 2>&1 | grep -v "failed to set times" || true
    $SYNC --checksum $USER_EXCL "$C/user/" "$GV/user/" 2>&1 | grep -v "failed to set times" || true
    $SYNC --size-only "$C/output/" "$GV/output/" 2>&1 | grep -v "failed to set times" || true
  done ) &

echo "sandbox: starting ComfyUI ${COMFY_ARGS}"
cd "$C" && exec python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header ${COMFY_ARGS}
