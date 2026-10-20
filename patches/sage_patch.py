#!/usr/bin/env python3
"""SageAttention 소스 패치 (빌드 전 적용).

1) setup.py: _qattn_sm90 확장을 sm_90a 로만 컴파일.
   원본은 모든 확장에 같은 -gencode 목록을 써서, 9.0 과 10.0/12.0 을 함께 빌드하면
   wgmma(sm_90a 전용) 명령을 sm_100a/sm_120a 용으로도 컴파일하다 ptxas 오류로 실패한다.
2) sageattention/core.py: 자동 디스패치 sageattn() 에 sm100(B200) 추가.
   원본은 sm100 에서 ValueError → ComfyUI 가 PyTorch attention 으로 폴백.
   빌드는 HAS_SM100 일 때 sm89 계열 커널을 sm_100a 로 컴파일하므로 그 경로를 사용한다.
   공식 지원 경로가 아니므로 start.sh 가 기동 시 실제 GPU 에서 정확도를 검사한다.
"""
import sys
from pathlib import Path

root = Path(sys.argv[1])

# ---- 1) setup.py
p = root / "setup.py"; s = p.read_text()
anchor = '    if HAS_SM90:\n        ext_modules.append(\n            CUDAExtension(\n                name="sageattention._qattn_sm90",'
if anchor not in s:
    sys.exit("patch: setup.py 의 _qattn_sm90 블록을 찾지 못함")
define = (
    "    # [patch] sm90 전용 플래그: 다른 아키텍처의 -gencode 를 제거하고 sm_90a 만 남김\n"
    "    NVCC_FLAGS_SM90 = []\n    _skip = False\n    for _f in NVCC_FLAGS:\n"
    "        if _skip:\n            _skip = False\n            continue\n"
    "        if _f == \"-gencode\":\n            _skip = True\n            continue\n"
    "        NVCC_FLAGS_SM90.append(_f)\n"
    "    NVCC_FLAGS_SM90 += [\"-gencode\", \"arch=compute_90a,code=sm_90a\"]\n\n")
s = s.replace(anchor, define + anchor, 1)
a = s.index('name="sageattention._qattn_sm90"'); b = s.index("extra_link_args", a)
blk = s[a:b]; nb = blk.replace('"nvcc": NVCC_FLAGS}', '"nvcc": NVCC_FLAGS_SM90}', 1)
if nb == blk:
    sys.exit("patch: _qattn_sm90 의 nvcc 플래그를 찾지 못함")
p.write_text(s[:a] + nb + s[b:]); print("patch: setup.py _qattn_sm90 -> sm_90a only")

# ---- 2) core.py
p = root / "sageattention" / "core.py"; s = p.read_text()
anchor = '    elif arch == "sm120":\n'
if anchor not in s:
    sys.exit("patch: core.py 디스패치 블록을 찾지 못함")
if 'arch == "sm100"' not in s:
    add = ('    elif arch == "sm100":  # [patch] B200: sm_100a 로 컴파일된 sm89 계열 fp8 커널 사용\n'
           '        return sageattn_qk_int8_pv_fp8_cuda(q, k, v, tensor_layout=tensor_layout, is_causal=is_causal, '
           'qk_quant_gran="per_warp", sm_scale=sm_scale, return_lse=return_lse, pv_accum_dtype="fp32+fp32")\n')
    s = s.replace(anchor, add + anchor, 1); p.write_text(s)
print("patch: core.py sageattn() sm100 dispatch added")
