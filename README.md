# comfyui-sandbox-global

DOBEDUB ComfyUI 샌드박스 이미지 2종. 모델은 이미지에 넣지 않고 **Global Volume `dobedub_comfyui_global` (`cmvg1al16000007ld31td00oc`)** 에서 읽는다.

| 태그 | 대상 GPU | CUDA / torch | SageAttention | 비고 |
| --- | --- | --- | --- | --- |
| `:cu130` (주력) | B200(sm_100), RTX PRO 6000(sm_120) | 13.0.2 / 2.11.0+cu130 | sm_100·sm_120 | NVFP4·INT8(comfy-kitchen CUDA) 가속, onnxruntime-gpu 1.28.0, cupy-cuda13x |
| `:cu128` | H100 NVL, H200(sm_90) | 12.8.1 / 2.11.0+cu128 | sm_90 | FP4 하드웨어 없음, onnxruntime-gpu 1.26.0, cupy-cuda12x |

GPU와 이미지가 맞지 않으면 기동 로그에 `sandbox: WARNING ... -> use :cu130/:cu128` 가 출력된다.

## 기동 최적화 (start.sh)
- 기본 인자: `--fast fp8_matrix_mult --use-sage-attention --enable-compress-response-body` (`COMFY_ARGS` 로 덮어쓰기)
  - `--cache-none` 제거 → 실행마다 모델을 Global Volume 에서 다시 읽지 않음
  - `--disable-pinned-memory` 제거 → 대용량 RAM 호스트에서 전송 효율
  - 응답 gzip → `object_info` 6.2MB → 0.7MB
- SageAttention 정확도 검사(SDPA 대비 cos>0.99) 실패 시 자동으로 sage 끄고 기동
- models: Global Volume 을 로컬 폴더 + 파일별 심볼릭 링크로 미러링 (목록 조회 로컬 속도)
- `PRELOAD_MODELS`: 지정 모델을 컨테이너 디스크로 백그라운드 복사 후 링크 교체 (NVMe 속도 로딩)
- `MANAGER_NETWORK_MODE=offline`(기본): 기동 시 Registry 수집 생략
- 워크플로·출력 5분 주기 Global Volume 백업 (mtime 미지원 → 체크섬/크기 비교)

## 커스텀 노드 (24개 활성)
`env/custom_nodes.txt` — `#` 로 시작하는 줄은 제외. 2026-10-20 UI 로딩 경량화로 19개 제외(주석에 사유).

## 구성
| 파일 | 역할 |
| --- | --- |
| `Dockerfile` | Stage1 SageAttention 휠 빌드(devel) → Stage2 runtime 이미지 |
| `env/custom_nodes.txt` | 커스텀 노드 43개 (GIT=커밋 고정 32, REG=Registry 버전 고정 11). `.disabled` 노드 제외 |
| `env/requirements.lock.txt` | 기존 Pod `.venv-cu128` 의 `pip freeze` (torch/nvidia/cupy/onnxruntime/sage 제외) |
| `env/comfyui.commit` | (선택) ComfyUI 커밋. 없으면 `v0.37.0` 태그 |
| `install_nodes.py` | custom_nodes.txt 설치기 |
| `start.sh` | SSH·Jupyter 기동, GPU/sage/onnxruntime 점검, models→Global Volume 연결, 워크플로·출력 5분 주기 백업 |

## 기존 환경 대비 변경
| 항목 | 기존 Pod (`0mwlplq8cvw6bj`) | 신규 이미지 |
| --- | --- | --- |
| torch | 2.10.0+cu130 | 2.11.0+cu128 |
| cupy | cupy-cuda13x 14.2.0 | cupy-cuda12x 14.2.0 |
| onnxruntime-gpu | 1.28.0 | 1.28.0 (CUDA 12 빌드) |
| sageattention | 2.2.0 (RTX PRO 6000 빌드) | main (sm_90/100/120 빌드) |
| 모델 경로 | 네트워크 볼륨 `/workspace/.../models` | Global Volume `/workspace-global/models` (symlink) |
| 출력/워크플로 | 네트워크 볼륨 | 로컬 디스크 + 5분마다 Global Volume 백업 |

## 빌드
1. 이 폴더를 새 GitHub 저장소로 push (예: `changkyuneun-ux/comfyui-sandbox-global`)
2. Actions `build-and-push` 실행 → `ghcr.io/<owner>/comfyui-sandbox-global:cu128`
3. GHCR 패키지를 **Public** 으로 변경 (또는 RunPod에 레지스트리 인증 등록)

## Pod 설정
| 항목 | 값 |
| --- | --- |
| Image | `ghcr.io/<owner>/comfyui-sandbox-global:cu128` |
| GPU (우선순위) | B200 → H200 SXM → H200 NVL → H100 NVL → RTX PRO 6000 |
| CUDA | `minCudaVersion: 12.8` |
| 데이터센터 | 지정 안 함 |
| Global Volume | `cmvg1al16000007ld31td00oc` → `/workspace-global` |
| 컨테이너 디스크 | 150GB |
| 포트 | `8188/http`, `8888/http`, `22/tcp` |
| env | `JUPYTER_PASSWORD`(선택), `COMFY_ARGS`(선택, 기본 `--fast fp8_matrix_mult --use-sage-attention --cache-none --disable-pinned-memory`) |

## 기동 확인 (Pod 로그)
- `sandbox: GPU OK ... torch 2.11.0+cu128 cuda 12.8`
- `sandbox: sageattention ...` (FAIL 이면 해당 GPU 아키텍처 빌드 누락)
- `sandbox: onnxruntime providers [...'CUDAExecutionProvider'...]` (없으면 CPU 폴백 → WanAnimate 포즈 검출 느려짐)
- `sandbox: models -> /workspace-global/models`
- ComfyUI 로그 `Using sage attention`, 커스텀 노드 import 실패 0건

## 운영 규칙
- 모델 추가: Global Volume에 업로드 후 **Pod 재시작** (실행 중 Pod는 새 파일을 못 볼 수 있음)
- 커스텀 노드 추가: Manager로 설치하면 재시작 시 사라짐 → `env/custom_nodes.txt` 수정 후 재빌드
- 잔액 $0 → 15일 후 Global Volume 영구 삭제. 자동 충전 유지

## 진단·측정 원칙 (2026-10-20 재발 방지)
이번 작업에서 잘못된 결론이 나온 원인과, 이를 막기 위한 규칙.

| 실수 | 원인 | 규칙 |
| --- | --- | --- |
| "NVFP4 모델 없음" 판단 → cu128 채택 | `find models -iname ...` 가 심볼릭 링크 `models` 를 따라가지 않아 0건 | **검사 결과 0건이면 검사 자체를 의심**: `find -L`/경로 끝 `/` 사용, 전체 파일 수가 0이 아닌지 먼저 확인 |
| "노드 수가 많아 브라우저가 느림" | 새 Pod는 3초 넘은 파일만 골라 보고, 기존 Pod와 같은 지표로 비교하지 않음 | **A/B 동일 측정**: 두 서버에 `tools/measure_ui_load.js` 를 똑같이 실행해 p50/p90/전체 완료 시간을 표로 비교한 뒤에만 원인 판단 |
| "브라우저 45초 멈춤" | 측정 코드 자체가 45초 대기 → 도구 타임아웃을 브라우저 멈춤으로 오해 | **임의 대기 금지**: 측정 코드는 대기 없이 현재 상태만 읽는다. 기다려야 하면 짧은 폴링(≤10초)과 상한 횟수를 명시하고, 타임아웃은 '측정 실패'로 기록 |
| 저장된 워크플로만 보고 노드 제거 | 저장 안 한 워크플로(실행 기록)를 놓침 | 노드 사용 판단은 `tools/find_unused_nodes.py` (워크플로 + 실행기록 + 서브그래프) 결과로만 |
| 재시작 영향 사전 고지 누락 | 설정 변경이 Pod 재시작을 일으킴 | Pod 설정 변경 전 **재시작 여부·중단 예상 시간**을 먼저 고지 |

모든 결론에는 근거(측정값·로그 줄·조회 결과)를 함께 적고, 추정이면 '추정'이라고 명시한다.
