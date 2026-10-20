#!/usr/bin/env bash
# DOBEDUB ComfyUI Sandbox (Global Volume / CUDA 12.8)
# - 모델: Global Volume(/workspace-global/models)을 ComfyUI/models 로 연결 (읽기 위주)
# - 워크플로: 기동 시 Global Volume → 로컬로 복사, 저장분은 주기적으로 Global Volume에 백업
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
    --ServerApp.token="$JUPYTER_PASSWORD" --ServerApp.root_dir=/ > /var/log/jupyter.log 2>&1 &
fi

# --- GPU / 스택 확인 ---
python - <<'PY' || { echo "sandbox: GPU check FAILED" >&2; exit 1; }
import torch
torch.cuda.init(); n=torch.cuda.get_device_name(0); c=torch.cuda.get_device_capability(0)
(torch.zeros(8,device='cuda')+1).sum().item()
print(f"sandbox: GPU OK {n} (sm_{c[0]}{c[1]}) torch {torch.__version__} cuda {torch.version.cuda}")
try:
    import sageattention; print("sandbox: sageattention", getattr(sageattention,'__version__','ok'))
except Exception as e: print("sandbox: sageattention FAIL", e)
try:
    import onnxruntime as ort; print("sandbox: onnxruntime providers", ort.get_available_providers())
except Exception as e: print("sandbox: onnxruntime FAIL", e)
PY

# --- 모델: Global Volume 연결 ---
if [ -d "$GV/models" ]; then
  rm -rf "$C/models" && ln -s "$GV/models" "$C/models"
  echo "sandbox: models -> $GV/models"
else
  echo "sandbox: WARNING $GV/models 없음 (Global Volume 미연결?)" >&2
fi

# --- 워크플로 복원 + 주기 백업 / 출력 주기 백업 ---
WF="$C/user/default/workflows"; mkdir -p "$WF" "$C/output" "$GV/workflows" "$GV/output"
cp -rn "$GV/workflows/." "$WF/" 2>/dev/null || true
SYNC="rsync -rlt --inplace --no-perms --no-owner --no-group"
( while true; do sleep "${SYNC_INTERVAL:-300}"
    $SYNC "$WF/" "$GV/workflows/"
    $SYNC "$C/output/" "$GV/output/"
  done ) &

: "${COMFY_ARGS:=--fast fp8_matrix_mult --use-sage-attention --cache-none --disable-pinned-memory}"
echo "sandbox: starting ComfyUI ${COMFY_ARGS}"
cd "$C" && exec python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header ${COMFY_ARGS}
