# DOBEDUB ComfyUI Sandbox — 이미지 2종 (같은 Dockerfile, build-arg 로 구분)
#   :cu130  Blackwell (B200 sm_100, RTX PRO 6000 sm_120)  ← 주력. NVFP4/INT8 가속(comfy-kitchen CUDA) 사용
#   :cu128  Hopper    (H100 NVL / H200 sm_90)             ← FP4 하드웨어 없음. 12.8/12.9 호스트까지 수용
# 모델은 이미지에 넣지 않음 → Global Volume(/workspace-global/models)
ARG CUDA_TAG=13.0.2-cudnn
ARG IMAGE_VARIANT=cu130

# ---------- Stage 1: SageAttention 휠 빌드 ----------
FROM nvidia/cuda:${CUDA_TAG}-devel-ubuntu24.04 AS sage-builder
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
ARG SAGE_REF=main
ARG SAGE_ARCHS="10.0;12.0"
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/* && python3.12 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install -U pip setuptools wheel ninja packaging \
 && pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url ${TORCH_INDEX} \
 && python -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda)" && nvcc --version
RUN git clone --depth 1 --branch ${SAGE_REF} https://github.com/thu-ml/SageAttention.git /src/SageAttention
# 패치: sm90 확장은 sm_90a 전용 플래그 / sageattn() 에 sm100(B200) 디스패치 추가
COPY patches/sage_patch.py /tmp/sage_patch.py
RUN python /tmp/sage_patch.py /src/SageAttention
# GitHub 러너(4 vCPU/16GB) OOM 방지 + sm90 확장의 -lcuda 는 툴킷 stub 으로 링크
ENV TORCH_CUDA_ARCH_LIST=${SAGE_ARCHS} EXT_PARALLEL=1 MAX_JOBS=2 NVCC_APPEND_FLAGS="--threads 2" \
    LIBRARY_PATH=/usr/local/cuda/lib64/stubs
RUN ls -la /usr/local/cuda/lib64/stubs/libcuda.so \
 && cd /src/SageAttention && python -m pip wheel . --no-build-isolation --no-deps -w /wheels && ls -la /wheels

# ---------- Stage 2: 최종 이미지 ----------
FROM nvidia/cuda:${CUDA_TAG}-runtime-ubuntu24.04
ARG IMAGE_VARIANT
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
ARG CUPY_PKG=cupy-cuda13x==14.2.0
ARG ORT_PKG=onnxruntime-gpu==1.28.0
ARG COMFYUI_REF=v0.37.0
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 IMAGE_VARIANT=${IMAGE_VARIANT}
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev build-essential git git-lfs ca-certificates \
      ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 libtcmalloc-minimal4 \
      openssh-server rsync wget curl tmux nano \
 && rm -rf /var/lib/apt/lists/* && python3.12 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# 1) torch
RUN pip install -U pip setuptools wheel \
 && pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url ${TORCH_INDEX}

# 2) ComfyUI 본체 (env/comfyui.commit 우선, 없으면 COMFYUI_REF)
COPY env/ /tmp/env/
RUN git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
 && REF=$( [ -s /tmp/env/comfyui.commit ] && cat /tmp/env/comfyui.commit || echo ${COMFYUI_REF} ) \
 && git -C /opt/ComfyUI checkout "$REF" && git -C /opt/ComfyUI log -1 --oneline

# 3) 커스텀 노드 (GIT=커밋 고정, REG=Registry 버전 고정, VENDOR=동봉 압축본; '#' 줄은 제외)
COPY install_nodes.py /tmp/install_nodes.py
COPY vendor/ /tmp/vendor/
RUN python /tmp/install_nodes.py /tmp/env/custom_nodes.txt /opt/ComfyUI/custom_nodes /tmp

# 4) Python 패키지: 기존 환경 freeze 를 --no-deps 로 재현 (apt 유래 패키지 제외)
RUN grep -viE '^(python-apt|dbus-python|PyGObject|launchpadlib|lazr\.|wadllib)' /tmp/env/requirements.lock.txt > /tmp/req.txt \
 && pip install --no-deps --no-build-isolation -r /tmp/req.txt

# 5) lock 에 빠진 의존성 보충 (설치 버전 고정 constraints → 누락분만 추가)
RUN pip freeze | grep -v ' @ ' > /tmp/pinned.txt \
 && pip install -r /opt/ComfyUI/requirements.txt -c /tmp/pinned.txt \
 && for r in /opt/ComfyUI/custom_nodes/*/requirements.txt; do \
      pip install -r "$r" -c /tmp/pinned.txt || echo "WARN: requirements 설치 실패 $r"; \
    done \
 && python -c "import mako, blake3, alembic, sqlalchemy; print('comfyui core deps OK')"

# 6) CUDA 버전별 패키지 + '가림' 패키지 정리
#    onnxruntime-gpu: 1.26.0 까지 CUDA12, 1.27+ CUDA13 / cupy: cuda12x·cuda13x
#    노드 requirements 가 끌고 온 onnxruntime(CPU판)·opencv-python(-headless) 제거
RUN pip uninstall -y onnxruntime onnxruntime-gpu opencv-python opencv-python-headless cupy-cuda12x cupy-cuda13x || true \
 && pip install --no-deps ${ORT_PKG} ${CUPY_PKG} $(grep -E '^opencv-contrib-python==' /tmp/req.txt) \
 && pip install --force-reinstall --no-deps $(grep -E '^opencv-contrib-python==' /tmp/req.txt) \
 && python -c "import onnxruntime as o; p=o.get_available_providers(); print(o.__version__, p); assert 'CUDAExecutionProvider' in p" \
 && python -c "import cv2; from cv2.ximgproc import guidedFilter; print('cv2', cv2.__version__, 'ximgproc OK')"

# 7) SageAttention (Stage 1 휠)
COPY --from=sage-builder /wheels/ /tmp/wheels/
RUN pip install --no-deps /tmp/wheels/sageattention-*.whl && rm -rf /tmp/wheels \
 && python -c "import torch, sageattention; print('torch', torch.__version__, torch.version.cuda, '| sageattention OK')" \
 && (pip check || echo 'pip check: 경고 확인')

COPY start.sh /start.sh
RUN chmod +x /start.sh
ENV LD_PRELOAD=libtcmalloc_minimal.so.4
EXPOSE 8188 8888 22
CMD ["/start.sh"]
