# cpp-build-optimization-reference

C++/CUDA 컨테이너 빌드 최적화의 **기법별 기여도를 변수 통제 ablation으로 측정**하는
레퍼런스 프로젝트.

의도적으로 무겁게 만든 동일한 C++/CUDA 코드(96개 동형 TU + CUDA 커널 3종)를, 빌드 기법만
하나씩 바꿔 가며 측정한다. "최적화를 다 켜니 N배 빨라졌다"는 단일 토글 헤드라인이 아니라
ccache·Ninja·mold·unity build·PCH·split-DWARF가 *각각 얼마나* 기여하는지 — 그리고 어떤
기법이 서로의 효과를 가리는지 — 를 분리해서 보인다.

> 측정을 *어떻게* 신뢰성 있게 설계했는지(독립/종속/통제/교란변수 분해, 층 격리, ablation
> 프로토콜)는 [`docs/measurement-methodology.md`](docs/measurement-methodology.md)에 있다.

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

## 측정 결과 — 단일 토글 헤드라인은 왜 무의미한가

`baseline ↔ optimized` 단일 토글은 6개 기법을 한꺼번에 켜고 끈다 — 어느 기법이 얼마
기여했는지 알 수 없다. 게다가 헤드라인 wall time은 layer A(apt) + B(컴파일) + C(이미지
export)의 혼합이다. 이 레포는 측정을 다시 설계했다 — `cmake --build` 구간(layer B)만
컨테이너 안의 마커로 격리하고, 기법을 baseline에 하나씩 누적 추가(프로토콜 A)하거나
optimized에서 하나씩 제거(프로토콜 B)해 잰다.

> 측정 환경: GitHub-hosted `ubuntu-latest`, `nvidia/cuda:12.2.2`, GCC 11, 각 셀 3회
> 중앙값. 값은 layer B(`cmake --build` 구간) 초. 전체 셀 정의는
> [`bench/cells.tsv`](bench/cells.tsv). 표의 값은 각각 독립 반올림했고 Δ는 반올림 전
> 중앙값의 차이다.

### 기법별 한계 기여 — 프로토콜 A (baseline에 누적 add)

| 추가 기법 | cold layer B | cold Δ | warm layer B | warm Δ |
|-----------|-------------:|-------:|-------------:|-------:|
| baseline (A0) | 268 s | — | 270 s | — |
| + Ninja | 265 s | +3 s | 272 s | −2 s |
| + ccache | 274 s | −9 s | **4 s** | **+268 s** |
| + PCH | 196 s | **+79 s** | 11 s | −7 s |
| + unity | **22 s** | **+174 s** | 11 s | +0.5 s |
| + split-DWARF | 31 s | −10 s | 16 s | −5 s |
| + mold | 29 s | +2 s | 15 s | +1 s |

읽는 법 — **기법마다 효과가 나타나는 구간이 다르다.** 6개를 한 표·한 숫자로 줄세울 수
없다는 것이 1차 결론이다.

- **ccache는 warm(증분 빌드)의 기법이다.** cold에는 −9 s(오히려 캐시 저장 오버헤드 —
  노이즈 범위), warm에는 268 s를 줄인다. 한 줄 고치고 다시 빌드하는 일상 루프에서만 의미.
- **unity build와 PCH는 cold(전체 재컴파일)의 기법이다.** unity가 174 s, PCH가 79 s를
  cold에서 줄인다. 둘의 warm Δ는 측정 노이즈 범위다.
- **Ninja·split-DWARF·mold는 이 워크로드에서 측정 바닥**이다 — Δ가 측정 분산(3회 min/max)
  안에 묻힌다. 은폐가 아니라 측정 결과다 (mold가 왜 그런지는 아래 다중타깃 절 참조).

### 잔여 기여 — 프로토콜 B (optimized에서 하나씩 제거)

| 제거 기법 | cold Δ | warm Δ | 한계 기여(A)와 대조 |
|-----------|-------:|-------:|---------------------|
| − ccache | +1 s | +16 s | warm: A에선 +268 s, B에선 +16 s |
| − unity | **+327 s** | −7 s | cold: A에선 +174 s, B에선 +327 s |
| − PCH | +0.2 s | −15 s | cold: A에선 +79 s, B에선 +0.2 s |
| − mold | −3 s | −1 s | 양쪽 모두 노이즈 |
| − split-DWARF | −6 s | −4 s | 양쪽 모두 노이즈 |
| − Ninja | +1 s | −5 s | 양쪽 모두 노이즈 |

**한계 기여(A)와 잔여 기여(B)의 괴리 자체가 결과다** — 괴리가 큰 기법 = 다른 기법과
상호작용(교란)이 큰 기법이다.

- **unity ↔ ccache** — ccache의 warm 기여는 A에서 +268 s, B에서 +16 s. unity가 96 TU를
  ~7개 unity 파일로 합치면 ccache의 캐시 단위가 96→7로 줄어, optimized 안에서는 ccache가
  되살릴 수 있는 게 거의 없다. 두 기법은 부분적으로 상충한다 — 측정으로 확인된 트레이드오프.
- **PCH ↔ unity** — PCH의 cold 기여는 A에서 +79 s, B에서 +0.2 s. unity가 켜져 있으면
  unity가 공용 헤더 파싱 amortize 역할을 흡수해 PCH가 따로 보탤 게 거의 없다.
- unity의 잔여 기여(B, +327 s)가 한계 기여(A, +174 s)보다 *큰* 이유 — A에서 unity를 더할
  땐 앞서 PCH가 cold를 이미 196 s까지 줄여놨지만, B에서 unity를 빼면 ccache·PCH가 켜져
  있어도 96 TU 전체 재컴파일을 막지 못한다.

### mold는 단일 실행파일에서 기여하지 않는다 — 정직한 음성 결과

mold는 `ld`(링커) 가속기다. 본 레포는 `add_executable(cbor)` 단일 타깃 = 빌드당 링크
1회 구조라 mold가 작용할 표면이 거의 없다. 96 TU를 16개 라이브러리로 쪼개 봐도:

| 빌드 구조 | mold off | mold on | mold Δ |
|-----------|---------:|--------:|-------:|
| 단일 실행파일 | 29.7 s | 28.8 s | +0.9 s |
| 16 STATIC lib | 71.4 s | 73.1 s | −1.8 s |
| 16 SHARED lib | 73.8 s | 72.1 s | +1.7 s |

STATIC으로 쪼개도 mold는 움직이지 않는다 — STATIC 아카이브는 `ar`로 만들어지고 `ar`은
링커가 아니다. SHARED(`.so` 16개 = `ld` 16회)에서조차 Δ가 노이즈인 건, 이 워크로드가
*컴파일 지배적*(라이브러리 컴파일 ~70 s vs 링크 ~3 s)이기 때문이다. mold의 가치는 링크가
빌드 시간을 지배하는 프로젝트(대형 단일 바이너리, 빈번한 풀 링크)에서 나온다 — 이 합성
워크로드는 거기 해당하지 않고, 측정은 그 사실을 숨기지 않고 보여준다.

### 로컬 캐시 vs 공유 원격 캐시 — ephemeral 러너

GitHub-hosted 러너는 잡마다 새 머신이다. ccache는 로컬 디스크 캐시라 잡이 갈리면 warm
적중이 0%로 증발한다. sccache는 컴파일 오브젝트를 공유 원격 캐시(여기서는 GitHub Actions
캐시)에 둬 ephemeral 러너 사이에서도 적중한다.

| 셀 | 캐시 | warm 시나리오 | layer B | 적중 |
|----|------|---------------|--------:|------|
| C1 | ccache 로컬 | 같은 잡 재빌드 | 15.9 s | 64 % |
| C2 | ccache 로컬 | **새 잡** 재빌드 | 29.6 s | **0 %** |
| C3 | sccache + GHA 캐시 | **새 잡** 재빌드 | **6.0 s** | 공유 캐시 적중 |

C2는 C1과 같은 빌드를 새 잡에서 돌린 것 — 로컬 캐시가 증발해 적중 0%, 사실상 cold다.
C3는 같은 새-잡 조건에서 공유 캐시로 적중한다. "어느 캐시가 절대적으로 빠른가"가 아니라 —
sccache는 적중해도 원격 왕복 비용이 있다 — *ephemeral 러너 간 캐시 공유 가능 여부*가 측정
대상이다. nvcc(CUDA) 캐싱은 sccache 지원이 제한적이라 C3에서도 CUDA launcher는 ccache로
둔다(비대칭).

## baseline vs optimized — 두 끝점은 무엇이 다른가

`baseline`/`optimized` CMake 프리셋은 코어 ablation의 양 끝점(셀 A0 / A6)이다.

| | `baseline` (A0) | `optimized` (A6) |
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
변수로 전달한다 — `CMakeLists.txt`에 박지 않는다. mold/ccache가 없는 환경은 `baseline`
프리셋으로 그대로 빌드된다(이식성).

## 재현

빌드는 전부 Docker 안에서 일어난다(호스트에 CUDA 툴체인 불요).

### 단순 before/after 데모

```bash
docker buildx build -f docker/Dockerfile.baseline  -t cbor:baseline  .
docker buildx build -f docker/Dockerfile.optimized -t cbor:optimized .
docker run --rm cbor:optimized   # CPU 경로 + (GPU 있으면) CUDA 커널, 없으면 graceful skip
```

### 기법별 ablation 측정

한 셀(`bench/cells.tsv`의 A0~C3)을 cold→warm으로 재는 것은:

```bash
./bench/measure-cell.sh A3        # A3 = baseline + Ninja + ccache + PCH
```

전체 ablation 매트릭스(코어 13셀 + 다중타깃 6셀 + 캐시백엔드 3셀)와 기여도 표는
`build-benchmark` 워크플로(`workflow_dispatch`)가 실행해 job summary에 출력한다. 무거운
TU 개수·템플릿 그리드 크기는 `bench/gen-sources.sh [TU_COUNT] [GRID_N]`로 재생성한다
(생성 파일은 커밋돼 있어 평소엔 실행 불요).

## CUDA 커널 — 빌드 게이트와 런타임 검증의 분리

`src/cuda/kernels.cu`의 커널 3종(`vector_add`/`saxpy`/`matmul`)은 CPU 레퍼런스 구현과
같은 입력으로 대조된다(`src/main.cpp`).

- **컴파일 검증**: CI는 CPU 러너에서 nvcc 컴파일까지만 보증한다 — 컴파일에는 GPU가 필요
  없다.
- **런타임 검증**: 커널이 실제 GPU에서 올바른 결과를 내는지는 GPU 노드에서만 확인할 수
  있다. `deploy/gpu-verify-job.yaml`이 단발성 K8s Job으로 `./cbor`를 GPU 노드에서 실행해
  CPU 기준값과 대조한다. 로그는 CUDA 디바이스 발견 여부(디바이스 부재 ↔ 드라이버/런타임
  불일치 에러를 분리), 디바이스 식별(이름·compute capability·SM 수·메모리·드라이버/런타임
  버전), 커널별 device 실행을 명시적으로 찍는다.
- **CPU-only 대조**: `deploy/cpu-contrast-job.yaml`이 같은 이미지를 GPU 미할당으로 돌려
  graceful CPU-only skip 경로를 보인다. 두 Job 로그를 나란히 읽는 것이 "GPU 사용함/안 함"을
  가르는 방법이다.

```bash
kubectl apply  -f deploy/gpu-verify-job.yaml
kubectl wait --for=condition=complete --timeout=300s job/cbor-gpu-verify
kubectl logs job/cbor-gpu-verify
kubectl delete job cbor-gpu-verify
```

## 알아 둘 것 (insights)

- **ccache 0% 적중 함정** — 절대경로·`compiler_check` mtime·`__DATE__` 매크로.
  재현과 수정은 [`docs/ccache-cache-miss-traps.md`](docs/ccache-cache-miss-traps.md).
- **unity ↔ ccache는 측정된 트레이드오프** — unity build는 96 TU를 ~7개로 합쳐 cold
  빌드를 크게 줄이지만, 캐시 단위도 96→7로 줄여 ccache의 증분 적중 가치를 잠식한다.
  프로토콜 A의 ccache warm 한계 기여(+268 s)와 프로토콜 B의 잔여 기여(+16 s) 괴리가 그
  수치다(위 측정 결과 참조).
- **mold는 링크 지배 프로젝트의 기법** — 단일 실행파일·컴파일 지배 워크로드에서는 mold의
  기여가 측정 노이즈 안에 묻힌다. 링크 호출 수와 링크 비중이 큰 프로젝트에서 의미가 있다.
- **컴파일엔 GPU가 필요 없다** — nvcc는 CPU 러너 + `cuda:devel` 이미지로 충분하다.
  GPU 러너는 GPU 런타임 검증 잡에만 라우팅한다.
- **LTO는 적용하지 않는다** — 링크 시간을 크게 늘려 테스트/CI 빌드엔 이득이 없다.

## 구조

```
├── CMakeLists.txt            CXX + CUDA, 최소 — 플래그는 프리셋이 운반
│                             CBOR_SPLIT_LIBS(none/static/shared) 다중타깃 분기
├── CMakePresets.json         baseline / optimized 프리셋
├── cmake/BuildOptions.cmake  최적화 표면(주석) + PCH 적용
├── src/
│   ├── main.cpp              CPU + GPU 엔트리, CPU/GPU 대조
│   ├── core/                 무거운 생성 TU 96개 + 무거운 헤더
│   └── cuda/kernels.cu       CUDA 커널 3종 + CPU 레퍼런스
├── docker/
│   ├── Dockerfile.baseline   "before" — 최적화 없음
│   ├── Dockerfile.optimized  "after"  — 3층 전부 적용 (배포 이미지)
│   └── Dockerfile.ablation   layer B 마커 삽입 — ablation 측정 전용
├── bench/
│   ├── cells.tsv             ablation 셀 정의 SSOT (A0~C3)
│   ├── measure-cell.sh       한 셀 cold→warm 측정
│   ├── summarize-cell.sh     N-run 중앙값 + 분산
│   ├── parse-build-log.sh    layer A/B/C 마커 + 캐시 통계 파싱
│   ├── contribution-table.sh 기여도 표 렌더
│   └── gen-sources.sh        무거운 TU 생성기
├── deploy/
│   ├── gpu-verify-job.yaml   GPU 런타임 검증 K8s Job
│   └── cpu-contrast-job.yaml 같은 이미지 GPU 미할당 대조 Job
├── docs/
│   ├── measurement-methodology.md  측정 설계 권위 문서 (변수 통제·층 격리·ablation)
│   ├── reference-analysis.md       기법별 레퍼런스 OSS 근거
│   └── ccache-cache-miss-traps.md  ccache 0% 적중 함정
└── .github/workflows/        publish-image (컴파일 게이트) · build-benchmark (측정)
```
