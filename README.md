# cpp-build-optimization-reference

C++/CUDA 컨테이너 빌드 최적화를 **before → after로 직접 측정**할 수 있는 레퍼런스 프로젝트.

의도적으로 무겁게 만든 동일한 C++/CUDA 코드를 두 경로로 빌드한다 — 최적화를 하나도
적용하지 않은 `baseline`, 3층 모범사례를 전부 적용한 `optimized`. 같은 소스, 빌드
설정만 다르므로 측정값의 차이는 순수하게 빌드 기법의 효과다.

## 느린 컨테이너 빌드는 세 개의 독립된 층이다

"C++/GPU 컨테이너 CI 빌드가 느리다"는 한 문제가 아니라 **세 개의 직교하는 문제**다.
이 프로젝트는 셋을 분리해 각각의 처방을 실증한다.

| 층 | 느린 이유 | 처방 |
|----|-----------|------|
| A. Docker 이미지 레이어 | 매 빌드가 apt·의존성 설치를 재실행 | multi-stage · 레이어 순서 · cache mount |
| B. 컴파일 | 소스 → 오브젝트 재컴파일 + 링크 | ccache · Ninja · mold · unity build · PCH |
| C. 이미지 크기 | devel 툴체인·CUDA SDK가 최종 이미지에 잔류 | `cuda:devel` → `cuda:runtime` 분리 |

A는 "명령 재실행을 피함", B는 "컴파일 자체를 빠르게", C는 "결과물을 가볍게" — 서로
보완하지 셋 중 하나로 대체되지 않는다. 기법별 레퍼런스 OSS 근거는
[`docs/reference-analysis.md`](docs/reference-analysis.md).

## 측정 결과

로컬 측정 — Apple Silicon (10-core, arm64), Docker Desktop VM 16.7 GB,
`nvidia/cuda:12.2.2`, 3회 중앙값. CI(GitHub Actions) 측정은 `build-benchmark`
워크플로의 job summary 참조.

| variant | 콜드 빌드 | 웜 빌드 (소스 1줄 변경) | 최종 이미지 |
|---------|----------|------------------------|------------|
| `baseline` | 65 s | 64 s | 10.3 GB |
| `optimized` | 26 s | 7 s | 3.63 GB |
| **개선** | **2.5×** | **9.1×** | **2.8× 작게** |

`baseline`은 웜 빌드가 콜드와 거의 같다 — `COPY . `로 소스를 먼저 복사해 한 줄만
바꿔도 apt 레이어부터 전부 무효화되기 때문이다(층 A 실패). `optimized`는 의존성
레이어가 캐시되고 ccache가 살아 웜 빌드가 9배 빠르다.

## baseline vs optimized — 무엇이 다른가

| | `baseline` | `optimized` |
|---|---|---|
| 제너레이터 | Unix Makefiles | Ninja |
| 컴파일 캐시 | 없음 | ccache (`compiler_check=content` 등 함정 회피) |
| 링커 | GNU ld | mold (`mold -run`) |
| 디버그 정보 | 인라인 | split DWARF (`-gsplit-dwarf`) |
| 유닛화 | 없음 | unity build + PCH |
| Docker stage | 단일 (`cuda:devel`) | multi-stage (`devel` → `runtime`) |
| 레이어 순서 | 소스 먼저 COPY | 의존성 매니페스트 먼저 |
| BuildKit 캐시 | 없음 | apt + ccache cache mount |

`optimized`의 최적화 플래그는 CMake **프리셋**(`CMakePresets.json`)의 네이티브 캐시
변수로 전달한다 — `CMakeLists.txt`에 박지 않는다. mold/ccache가 없는 환경은
`baseline` 프리셋으로 그대로 빌드된다(이식성).

## 로컬 재현

빌드는 전부 Docker 안에서 일어난다(호스트에 CUDA 툴체인 불요).

```bash
# baseline — 최적화 전
docker buildx build -f docker/Dockerfile.baseline  -t cbor:baseline  .

# optimized — 최적화 후
docker buildx build -f docker/Dockerfile.optimized -t cbor:optimized .

# 실행 — CPU 경로 + (GPU 있으면) CUDA 커널, GPU 없으면 graceful skip
docker run --rm cbor:optimized
```

4개 조합(baseline/optimized × cold/warm)을 측정하려면:

```bash
# 콜드: 빌드 캐시 비우고 측정
docker buildx prune -af
time docker buildx build --no-cache -f docker/Dockerfile.optimized -t cbor:optimized .

# 웜: 소스 한 줄 바꾸고 재측정
time docker buildx build           -f docker/Dockerfile.optimized -t cbor:optimized .

# 빌드 로그에서 지표 추출
./bench/parse-build-log.sh <buildlog>
```

무거운 TU 개수·템플릿 그리드 크기는 `bench/gen-sources.sh [TU_COUNT] [GRID_N]`로
재생성한다 (생성 파일은 커밋돼 있어 평소엔 실행 불요).

## CUDA 커널 — 빌드 게이트와 런타임 검증의 분리

`src/cuda/kernels.cu`의 커널 3종(`vector_add`/`saxpy`/`matmul`)은 CPU 레퍼런스
구현과 같은 입력으로 대조된다(`src/main.cpp`).

- **컴파일 검증**: CI(`build-benchmark` 워크플로)는 CPU 러너에서 nvcc 컴파일까지만
  보증한다 — 컴파일에는 GPU가 필요 없다.
- **런타임 검증**: 커널이 실제 GPU에서 올바른 결과를 내는지는 GPU 노드에서만
  확인할 수 있다. `deploy/gpu-verify-job.yaml`이 단발성 K8s Job으로 `./cbor`를
  GPU 노드에서 실행해 CPU 기준값과 대조한다.

```bash
kubectl apply  -f deploy/gpu-verify-job.yaml
kubectl wait --for=condition=complete --timeout=300s job/cbor-gpu-verify
kubectl logs job/cbor-gpu-verify
kubectl delete job cbor-gpu-verify
```

## 알아 둘 것 (insights)

- **ccache 0% 적중 함정** — 절대경로·`compiler_check` mtime·`__DATE__` 매크로.
  재현과 수정은 [`docs/ccache-cache-miss-traps.md`](docs/ccache-cache-miss-traps.md).
- **unity build ↔ ccache granularity 트레이드오프** — unity build는 96개 TU를
  ~7개로 합쳐 콜드 빌드를 줄이지만, 캐시 단위도 줄어 ccache의 증분 적중률이 낮아진다.
  두 기법은 부분적으로 상충한다.
- **컴파일엔 GPU가 필요 없다** — nvcc는 CPU 러너 + `cuda:devel` 이미지로 충분하다.
  GPU 러너는 GPU 런타임 검증 잡에만 라우팅한다.
- **LTO는 적용하지 않는다** — 링크 시간을 크게 늘려 테스트/CI 빌드엔 이득이 없다.
- **분산 컴파일(distcc/sccache-dist)은 향후 옵션** — 상주 빌드 서버 인프라를
  요구한다. 컴파일 캐시만으로 충분하지 않을 때 검토. `sccache` + S3(MinIO) 백엔드는
  ephemeral 러너 간 캐시 공유의 정답이며 향후 변형으로 둔다.

## 구조

```
├── CMakeLists.txt            CXX + CUDA, 최소 — 플래그는 프리셋이 운반
├── CMakePresets.json         baseline / optimized 프리셋
├── cmake/BuildOptions.cmake  최적화 표면(주석) + PCH 적용
├── src/
│   ├── main.cpp              CPU + GPU 엔트리, CPU/GPU 대조
│   ├── core/                 무거운 생성 TU 96개 + 무거운 헤더
│   └── cuda/kernels.cu       CUDA 커널 3종 + CPU 레퍼런스
├── docker/
│   ├── Dockerfile.baseline   "before" — 최적화 없음
│   ├── Dockerfile.optimized  "after"  — 3층 전부 적용
│   └── apt-packages.txt      의존성 매니페스트 (선복사용)
├── bench/                    소스 생성기 + 빌드 로그 파서
├── deploy/gpu-verify-job.yaml  GPU 런타임 검증 K8s Job
├── docs/                     레퍼런스 분석 + ccache 함정
└── .github/workflows/build-benchmark.yml
```
