# DOBEDUB ComfyUI Sandbox — CUDA 12.8 / torch 2.11 / SageAttention (sm_90·sm_100·sm_120)
# 대상 GPU: H100 NVL·H200(sm_90), B200(sm_100), RTX PRO 6000(sm_120)  ※ B300(sm_103) 제외
# 모델은 이미지에 넣지 않음 → Global Volume(/workspace-global/models)에서 읽음
ARG CUDA_TAG=12.8.1-cudnn
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128

# ---------- Stage 1: SageAttention 휠 빌드 ----------
FROM nvidia/cuda:${CUDA_TAG}-devel-ubuntu24.04 AS sage-builder
ARG TORCH_VERSION TORCHVISION_VERSION TORCHAUDIO_VERSION TORCH_INDEX
ARG SAGE_REF=main
ARG SAGE_ARCHS="9.0;10.0;12.0"
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/* && python3.12 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install -U pip setuptools wheel ninja packaging \
 && pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url ${TORCH_INDEX} \
 && python -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda)" && nvcc --version
RUN git clone --depth 1 --branch ${SAGE_REF} https://github.com/thu-ml/SageAttention.git /src/SageAttention
COPY patches/sage_patch.py /tmp/sage_patch.py
RUN python /tmp/sage_patch.py /src/SageAttention
# GitHub 러너(4 vCPU/16GB) OOM 방지: 병렬도 최소화
ENV TORCH_CUDA_ARCH_LIST=${SAGE_ARCHS} EXT_PARALLEL=1 MAX_JOBS=2 NVCC_APPEND_FLAGS="--threads 2"
# sm_90 확장(_qattn_sm90)은 -lcuda 로 링크한다. 빌드 러너에는 GPU 드라이버(libcuda.so)가 없으므로
# CUDA 툴킷의 stub 라이브러리로 링크한다 (실행 시에는 호스트 드라이버의 libcuda.so.1 사용)
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs
RUN ls -la /usr/local/cuda/lib64/stubs/libcuda.so
RUN cd /src/SageAttention && python -m pip wheel . --no-build-isolation --no-deps -w /wheels && ls -la /wheels

# ---------- Stage 2: 최종 이미지 ----------
FROM nvidia/cuda:${CUDA_TAG}-runtime-ubuntu24.04
ARG TORCH_VERSION TORCHVISION_VERSION TORCHAUDIO_VERSION TORCH_INDEX
ARG COMFYUI_REF=v0.37.0
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev build-essential git git-lfs ca-certificates \
      ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 libtcmalloc-minimal4 \
      openssh-server rsync wget curl tmux nano \
 && rm -rf /var/lib/apt/lists/* && python3.12 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# 1) torch (cu128)
RUN pip install -U pip setuptools wheel \
 && pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url ${TORCH_INDEX}

# 2) ComfyUI 본체 (env/comfyui.commit 있으면 그 커밋, 없으면 COMFYUI_REF 태그)
COPY env/ /tmp/env/
RUN git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
 && REF=$( [ -s /tmp/env/comfyui.commit ] && cat /tmp/env/comfyui.commit || echo ${COMFYUI_REF} ) \
 && git -C /opt/ComfyUI checkout "$REF" && git -C /opt/ComfyUI log -1 --oneline

# 3) 커스텀 노드 (GIT=커밋 고정, REG=Registry 버전 고정)
COPY install_nodes.py /tmp/install_nodes.py
COPY vendor/ /tmp/vendor/
RUN python /tmp/install_nodes.py /tmp/env/custom_nodes.txt /opt/ComfyUI/custom_nodes /tmp

# 4) Python 패키지: 기존 .venv-cu128 의 freeze 그대로 (--no-deps: 버전 해석 없이 동일 재현)
#    Ubuntu 시스템 패키지(apt 유래)는 제외
RUN grep -viE '^(python-apt|dbus-python|PyGObject|launchpadlib|lazr\.|wadllib)' /tmp/env/requirements.lock.txt > /tmp/req.txt \
 && pip install --no-deps --no-build-isolation -r /tmp/req.txt \
 && grep -E '^[A-Za-z0-9_.-]+==' /tmp/req.txt > /tmp/constraints.txt

# 5) CUDA 12 대응 패키지 (기존 cu13 버전을 대체)
RUN pip install -c /tmp/constraints.txt cupy-cuda12x==14.2.0 onnxruntime-gpu==1.28.0

# 6) SageAttention (Stage 1 휠)
COPY --from=sage-builder /wheels/ /tmp/wheels/
RUN pip install --no-deps /tmp/wheels/sageattention-*.whl && rm -rf /tmp/wheels \
 && python -c "import torch, sageattention; print('torch', torch.__version__, torch.version.cuda, '| sageattention OK')" \
 && (pip check || echo 'pip check: 위 경고는 기존 환경에서도 있던 것인지 확인')

COPY start.sh /start.sh
RUN chmod +x /start.sh
ENV LD_PRELOAD=libtcmalloc_minimal.so.4
EXPOSE 8188 8888 22
CMD ["/start.sh"]
