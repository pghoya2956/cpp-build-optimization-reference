# 측정 방법론 — 변수 통제·층 격리·ablation

이 문서는 본 레퍼런스 레포의 빌드 최적화 측정이 *어떻게* 신뢰성을 확보하는지 규정하는
권위 문서입니다. 측정 워크플로(`.github/workflows/build-benchmark.yml`), 측정 스크립트
(`bench/`), 셀 정의 SSOT(`bench/cells.tsv`)는 모두 이 문서의 설계를 구현한 것입니다.

## 단일 토글 측정의 한계

초기 측정은 `baseline` 프리셋 ↔ `optimized` 프리셋의 **단일 토글**이었습니다. "콜드 N배,
웜 N배" 같은 헤드라인 숫자는 다음 다섯 결함을 안고 있었습니다.

| 결함 | 내용 | 결과 |
|------|------|------|
| 기법별 ablation 미측정 | ccache·Ninja·mold·unity·PCH·split-dwarf를 한꺼번에 켜고 끔 | 각 기법이 *얼마* 기여했는지 알 수 없음 |
| 층 혼합 | 헤드라인이 `docker build` 전체 wall time = layer A(apt) + B(컴파일) + C(이미지 export)의 혼합 | 어느 층이 얼마 기여했는지 분리 안 됨 |
| mold 과대표현 | 단일 실행파일(`cbor` 1개 = 링크 1회) 구조라 mold 기여가 구조적으로 미미한데 다른 기법과 동등하게 나열 | 측정이 구조를 반영하지 못함 |
| 교란변수 방치 | unity build가 96 TU를 ~7개 unity 파일로 합쳐 ccache 웜 적중 단위를 축소 | 둘을 같이 켜고 재면 ccache의 진짜 효과가 가려짐 |
| 통제 미흡 | 측정 회차·중앙값/분산·콜드/웜 정의·환경 노이즈 통제가 "before/after 공정성" 수준 | "실험 신뢰성" 수준 미달 |

이 문서가 규정하는 측정 설계는 다섯 결함을 각각 변수 분해·층 격리·ablation 프로토콜·교란
분리·신뢰성 절차로 해소합니다.

## 실험 설계 — 변수 분해

논문급 측정의 출발점은 "무엇이 변하고(독립), 무엇을 재고(종속), 무엇을 고정하고(통제),
무엇이 결과를 오염시키는가(교란)"의 명시적 분해입니다.

### 독립변수 — 조작하는 것

토글하는 빌드 기법입니다. 6개 + 생성기/링커 짝 토글. 다중타깃·캐시 백엔드는 별도 측정 축
입니다(아래 "측정 매트릭스 분리" 참조).

| 기법 | 토글 키 | 격리 가능 여부 | 비고 |
|------|---------|----------------|------|
| Ninja 제너레이터 | `CMAKE_GENERATOR` (Ninja ↔ Unix Makefiles) | 단독 가능 | 다른 기법과 독립 |
| ccache 컴파일 캐시 | `CMAKE_CXX/CUDA_COMPILER_LAUNCHER` (ccache ↔ 없음) | 단독 가능 | warm 측정에서만 효과 |
| mold 링커 | `mold -run` 래핑 (적용 ↔ 미적용) | 단독 가능 | 단일타깃 구조에서 효과 미미 예상 — 다중타깃 변형에서 별도 측정 |
| unity build | `CMAKE_UNITY_BUILD` (ON ↔ OFF) | 단독 가능 | ccache와 교란 (아래) |
| PCH | `CMAKE_DISABLE_PRECOMPILE_HEADERS` (OFF ↔ ON) | 단독 가능 | unity와 부분 중첩(둘 다 헤더 파싱 amortize) |
| split DWARF | `-gsplit-dwarf` on/off (`CMAKE_CXX_FLAGS`) | 단독 가능 | 링크 부하 경감 → mold와 상호작용 |

> `CMAKE_DISABLE_PRECOMPILE_HEADERS`는 *의미가 반전*된 키입니다. PCH를 켜려면 이 변수를
> `OFF`로, 끄려면 `ON`으로 둡니다. 셀 정의(`bench/cells.tsv`)의 `pch` 컬럼은 "PCH가 켜졌는가"
> 기준이며, 측정 스크립트가 이 반전을 흡수합니다.

별도 측정 축의 변형 변수:

| 변형 | 토글 키 | 측정 목적 |
|------|---------|-----------|
| 다중 링크 타깃 | `CBOR_SPLIT_LIBS` (ON ↔ OFF — CMake `option`) | mold 기여도의 링크 타깃 수 의존성 측정 |
| 컴파일 캐시 백엔드 | ccache(로컬) ↔ sccache + S3 | ephemeral 러너 간 캐시 공유 여부 측정 |

### 종속변수 — 측정하는 것

| 변수 | 측정 단위 | 격리 구간 |
|------|-----------|-----------|
| layer A 시간 | 초 | apt 설치 buildx step 구간 |
| **layer B 컴파일 시간** | 초 | `cmake --build` 호출 구간만 (ablation의 핵심 종속변수) |
| layer C 시간 | 초 | 최종 이미지 export buildx step 구간 |
| `docker build` 전체 wall time | 초 | buildx 호출 전체 (참고용 — 헤드라인으로 쓰지 않음) |
| ccache 적중률 | % (hits/cacheable) | `ccache -z` → 빌드 → `--show-stats` |
| sccache 적중률 + S3 read/write 카운트 | %, 회 | `sccache --zero-stats` → 빌드 → `--show-stats` |
| 최종 이미지 크기 | GB | `docker image inspect` |

### 통제변수 — 고정하는 것

| 통제 대상 | 고정 값 / 절차 | 이유 |
|-----------|----------------|------|
| 러너 종류 | GitHub-hosted `ubuntu-latest` 단일. self-hosted 혼용 금지 | 하드웨어 노이즈 제거 |
| CUDA 베이스 이미지 | `nvidia/cuda:12.2.2-{devel,runtime}-ubuntu22.04` **단일 고정** | 드라이버 매칭 + 컴파일러(GCC 11) 고정 + 측정 환경 일관성 |
| 컴파일러 | GCC 11 (이미지 기본). ablation 전 구간 동일 | 컴파일러 버전이 측정을 오염시키지 않도록 |
| 소스 트리 | 동일 git revision의 96 TU. 측정 회기 중 불변 | 같은 소스 = 차이는 빌드 설정뿐 |
| 코어 수 | `nproc` 고정(러너 사양 기록). `--parallel` 인자 고정 | 병렬도 변동 차단 |
| 빌드 타입 | `CMAKE_BUILD_TYPE=Debug` 전 구간 동일 | `-g` 디버그 정보량 고정 (split-dwarf 측정 전제) |
| job pools | layer B ablation 시 `link_pool=2`로 *고정*(독립변수에서 제외) | 무제한 병렬 링크는 OOM 위험·노이즈원 |
| 잡 직렬화 | matrix `max-parallel: 1` | 동시 실행 부하로 인한 흔들림 제거 |
| 측정 경계 | 각 종속변수별 명시적 마커로 시작/끝 고정 | checkout·러너 setup·캐시 restore를 측정에서 배제 |
| S3 백엔드 | sccache 측정 회기 시작~종료 동안 S3 엔드포인트·백엔드 불변 | 백엔드 변경이 측정을 오염시키지 않도록 |

`CMAKE_JOB_POOLS`(링크 동시성 제한)는 시간 단축 *기법*이 아니라 OOM 방지·노이즈 통제
장치이므로 독립변수에서 제외하고 layer B 측정 전 구간 `link_pool=2`로 고정합니다.

### 교란변수 — 결과를 오염시키는 상호작용

| 교란 | 메커니즘 | 처리 |
|------|----------|------|
| **unity ↔ ccache** | unity build가 96 TU를 ~7개 unity 파일로 합침 → ccache 캐시 단위가 96→7로 축소. 한 unity 파일 내 한 TU만 바뀌어도 그 파일 전체 미스 | ccache와 unity를 **같은 셀에 같이 켜지 않음**. ccache 기여도는 unity OFF에서, unity 기여도는 ccache OFF(또는 cold)에서 측정. 둘 다 켠 셀로 *상호작용 자체*를 별도 수치화 |
| PCH ↔ unity | 둘 다 공용 헤더 파싱을 amortize → 한쪽이 켜져 있으면 다른 쪽 한계 기여가 줄어듦 | 누적 add에서 PCH를 unity보다 *먼저* 추가해 단독 기여 측정. leave-one-out은 *잔여* 기여 측정. 두 프로토콜 병행으로 순서 의존성을 드러냄 |
| split-dwarf ↔ mold | split-dwarf가 링크 입력 크기를 줄임 → mold의 절대 기여가 더 작아짐 | mold 측정 시 split-dwarf 상태를 명시. cold 첫 측정은 둘 다 off 기준에서 각각 단독 측정 |
| ccache cold/warm 상태 | ccache는 cold에서 0% 적중(저장만), warm에서만 효과 | ccache 기여도는 **warm 빌드에서만** 의미. cold ablation 표와 warm ablation 표를 분리 |
| 러너 인스턴스 변동 | GitHub-hosted 러너는 잡마다 다른 물리 머신일 수 있음 | 회차 측정 + 중앙값·분산(min/max) 보고로 흡수. 한 잡 안에서 cold→warm을 연속 측정해 같은 머신 공유. 단 — sccache 측정에서는 이 "러너 변동"이 *측정 대상* |
| sccache S3 왕복 ↔ 적중 | sccache는 적중해도 S3에서 오브젝트를 내려받음 → 같은 잡 안 warm에서는 로컬 ccache보다 느릴 수 있음 | sccache vs ccache 비교는 "어느 캐시가 빠른가"가 아님. *ephemeral 러너 간 공유*가 종속변수. 측정 셀을 "같은 러너 재빌드"와 "새 러너 재빌드"로 분리 |

## 측정 구간 격리 — layer A / B / C

단일 토글 측정의 가장 큰 결함은 헤드라인이 `docker build` 전체 wall time이라는 점입니다.
이를 세 구간으로 격리합니다.

```
docker buildx build  ──  전체 wall time (참고용)
  ├─ layer A   apt-get install 구간          ← buildx '#N DONE <t>s' 스텝 타임스탬프
  ├─ layer B   cmake --build 구간            ← ablation의 핵심 종속변수
  │             RUN 내부에서 date +%s.%N 마커로 START/END를 stdout에 출력
  └─ layer C   최종 이미지 export 구간        ← multi-stage 마지막 stage DONE 타임스탬프
```

### 격리 마커 규칙

| 층 | 측정 방법 | 마커 / 파싱 규칙 |
|----|-----------|------------------|
| layer A | buildx step 타임스탬프 | `docker buildx build --progress=plain` 출력에서 apt 설치 `RUN` 스텝의 `#N DONE <t>s` 추출 |
| layer B (단일타깃) | 컨테이너 내부 셸 마커 | `cmake --build`를 `S=$(date +%s.%N); …; E=$(date +%s.%N)`로 감싸 `LAYER_B_SECONDS=<float>` 한 줄 출력 |
| layer B (다중타깃) | 컴파일/링크 분리 마커 | 라이브러리 타깃 빌드 구간 → `LAYER_B_COMPILE_SECONDS=`, `--target cbor` 링크 구간 → `LAYER_B_LINK_SECONDS=` |
| layer C | buildx step 타임스탬프 | runtime stage의 `COPY --from=builder` + export 스텝 `#N DONE <t>s` 추출 |

설계 판단:

- **layer B를 컨테이너 *안에서* 재는 이유** — `docker buildx build`는 BuildKit 캐시 상태에
  따라 `RUN` 스텝을 통째로 건너뛸 수 있어, 호스트에서 `cmake --build` 구간만 떼어내기
  어렵습니다. 컨테이너 내부 마커가 가장 신뢰성 높은 layer B 경계입니다.
- **캐시 키 안정성** — layer B 마커의 `date +%s.%N`은 `RUN` 명령 *텍스트 안의 셸 변수 확장*
  이지 빌드 인자가 아닙니다. `RUN` 줄의 텍스트는 빌드 간 불변이고 BuildKit 캐시 키도
  불변입니다. 타임스탬프를 `ARG`/`ENV`로 주입하면 캐시가 매번 무효화되므로 — 마커는 `RUN`
  내부 셸에서만 평가합니다.
- **ablation의 1차 종속변수는 layer B 시간**입니다. `docker build` 전체 wall time은 "참고:
  컨테이너 오버헤드 포함" 컬럼으로 부차 기록하며 헤드라인으로 쓰지 않습니다.

측정 인프라는 ablation 측정 전용 Dockerfile에 layer B 마커를 삽입하고, 배포용
`Dockerfile.optimized`는 마커 없이 그대로 둡니다 — 측정 관심사와 배포 관심사를 분리합니다.

## ablation 프로토콜

기여도를 두 방향으로 측정해 교차검증합니다. 한 방향만 쓰면 기법 추가 *순서*에 결과가
종속됩니다(특히 PCH↔unity 같은 중첩 기법). 이 프로토콜은 코어 측정 축(단일타깃
`CBOR_SPLIT_LIBS=OFF`, ccache 로컬 캐시)에 적용됩니다.

### 프로토콜 A — 누적 add

baseline에서 시작해 기법을 하나씩 누적 추가합니다. 각 단계의 layer B 시간 차이 = 그
기법의 *한계(marginal) 기여*.

```
A0  baseline (모든 기법 off)
A1  A0 + Ninja
A2  A1 + ccache
A3  A2 + PCH          ← unity보다 먼저 (교란 처리: PCH 단독 기여 측정)
A4  A3 + unity
A5  A4 + split-dwarf
A6  A5 + mold         = optimized
```

추가 순서 근거: 생성기(Ninja)를 먼저(다른 기법의 토대), 캐시(ccache) 다음, 헤더 amortize
기법은 PCH→unity 순(PCH 단독 기여를 unity가 흡수하기 전에 측정), 링크 관련
(split-dwarf→mold)을 마지막에 둡니다.

### 프로토콜 B — leave-one-out

optimized에서 시작해 기법을 하나씩 *제거*합니다. optimized 시간과의 차이 = 그 기법의
*잔여(residual) 기여* (다른 기법이 모두 켜진 상태에서의 기여).

```
B0  optimized (전부 on)  ← A6와 동일 셀, 재측정하지 않음
B1  B0 − ccache
B2  B0 − unity
B3  B0 − PCH
B4  B0 − mold
B5  B0 − split-dwarf
B6  B0 − Ninja
```

### 두 프로토콜의 해석

- **한계 기여(A) ≠ 잔여 기여(B)** 인 기법 = 다른 기법과 상호작용이 큰 기법입니다. 둘의
  괴리 자체가 분석 대상입니다(예: PCH가 A에서 크고 B에서 작으면 → unity가 PCH 역할을
  상당 부분 대체).
- mold는 단일타깃에서 A·B 양쪽 모두 작게 나올 것으로 예상합니다. 그 "양쪽 모두 작음"이
  단일타깃 구조적 미미함의 근거가 되고, 다중타깃 변형의 측정값과 대비됩니다.
- 콘텐츠·README의 기여도 표는 **A(한계 기여)를 주 표로, B(잔여 기여)를 교차검증 표**로
  제시합니다.

### 토글 메커니즘

CMake 프리셋만으로는 6개 기법의 2^6 조합을 표현하기 번거롭습니다. `baseline` 프리셋을
토대로 `-D` 캐시변수 오버라이드로 기법을 켭니다.

```bash
# 예: A3 (baseline + Ninja + ccache + PCH)
cmake --preset baseline \
  -G Ninja \
  -D CMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -D CMAKE_CUDA_COMPILER_LAUNCHER=ccache \
  -D CMAKE_DISABLE_PRECOMPILE_HEADERS=OFF
```

- ablation 셀별 토글 조합은 `bench/cells.tsv`(SSOT)가 표로 들고 있고, 워크플로 매트릭스가
  셀 ID를 받아 해당 `-D` 세트를 적용합니다.
- mold는 CMake 변수가 아니라 `mold -run` 래핑이므로 빌드 명령 레벨에서 토글합니다(셀
  정의의 `mold` 컬럼).
- 다중타깃은 `-D CBOR_SPLIT_LIBS=ON`, sccache는 `-D CMAKE_CXX_COMPILER_LAUNCHER=sccache`
  + sccache 환경변수로 토글합니다.
- 기존 `baseline`/`optimized` 프리셋은 양 끝점(A0, B0=A6) 검증용으로 유지합니다 — `-D`
  오버라이드 조합이 프리셋과 동치인지 sanity check합니다.

> 설계 판단: 프리셋을 13개 만들지 않고 `-D` 오버라이드로 가는 이유 — 프리셋 폭증은
> 유지보수 부담이고, 셀 정의를 한 곳(SSOT)에 두면 ablation 표와 토글이 자동 일치합니다.

### 측정 매트릭스 분리 — 셀 곱집합 폭증 방지

변형 축이 둘(다중타깃·캐시 백엔드) 늘면서 전체 13셀 × 다중타깃 2 × 캐시백엔드 2를
곱하면 52셀로 폭증합니다. 이를 피하려고 측정을 3개 독립 매트릭스로 나눕니다 — *곱집합이
아니라 합집합*입니다.

| 매트릭스 | 셀 | 고정 조건 | 측정 목적 |
|----------|-----|-----------|-----------|
| 코어 ablation | 13셀 (A0~A6, B1~B6) | 단일타깃·ccache·로컬 캐시 | 6개 기법 기여도 (주 산출) |
| 다중타깃 변형 | 6셀 (`CBOR_SPLIT_LIBS`{none,static,shared}×`mold`) | optimized 설정 기준 | mold 구조 의존성 |
| 캐시 백엔드 변형 | ~3셀 (ccache 같은잡 / ccache 새잡 / sccache 새잡) | optimized 설정 기준 | ephemeral 캐시 공유 |

셀 수는 13 + 6 + 3 = ~22셀 × cold/warm × N=3 수준에 머뭅니다.

## 다중 링크 타깃 변형 — mold 구조 의존성 측정

본 레포는 `add_executable(cbor ...)` 단일 타깃 = 빌드당 링크 1회 구조입니다. mold는
링커이므로 링크 호출 1회에만 작용합니다. 96 TU 컴파일이 빌드 시간을 지배하는 구조에서
mold 기여는 구조적으로 미미할 수밖에 없습니다 — 단일타깃 ablation에서는 이 미미함을
정직하게 측정합니다.

### static 분할로는 부족하다 — `ar` ≠ `ld`

mold 효과의 구조 의존성을 보이려는 첫 시도는 96 TU를 STATIC 라이브러리로 쪼개는 것이었
습니다. 그러나 **STATIC 아카이브는 `ar`로 만들어지고 `ar`은 링커가 아닙니다.** mold는
`ld`(실행파일·공유 라이브러리 링크)를 대체하는 도구이고 `ar`은 건드리지 않습니다. 96 TU를
16 STATIC lib으로 쪼개도 — `ar` 아카이브가 16회 늘 뿐 — 최종 `cbor` 실행파일 링크는
여전히 `ld`(mold) **1회**입니다. mold의 작업량은 분할해도 늘지 않습니다.

mold 호출 횟수를 실제로 곱하려면 **SHARED 라이브러리**가 필요합니다 — `.so` 하나하나가
`ld` 링크입니다. 그래서 `CBOR_SPLIT_LIBS`를 3값으로 둡니다.

```
CBOR_SPLIT_LIBS=none (기본)
  add_executable(cbor  main.cpp kernels.cu  module_000..095.cpp)
  → ld 링크 1회

CBOR_SPLIT_LIBS=static
  add_library(cbor_mod_NN STATIC ...)  × 16     →  ar 아카이브 16회 + ld 링크 1회
  → mold 작용 = 1회 (단일타깃과 동일 — ar 은 mold 무관)

CBOR_SPLIT_LIBS=shared
  add_library(cbor_mod_NN SHARED ...)  × 16     →  ld 링크 16회 + ld 링크 1회
  → mold 작용 = 17회 (분할 수에 비례)
```

설계 원칙:

- **소스 재작성 아님** — `module_*.cpp` 파일 자체는 한 글자도 바뀌지 않습니다.
  `cmake/generated_sources.cmake`가 들고 있는 TU 목록을 `CBOR_SPLIT_LIBS` 분기에서
  `add_library` 그룹으로 묶을지 단일 `add_executable`에 넣을지만 가릅니다. 세 변형 모두
  같은 TU·같은 동작·같은 산출 `cbor`이며 링크 단위(granularity)만 다릅니다.
- **별도 측정 축** — 다중타깃 변형은 코어 ablation과 같은 표에 섞지 않습니다. 빌드 구조가
  다르므로 절대 시간을 직접 비교하면 부정직합니다. 각 변형은 자기 mold off/on 대비로만
  비교합니다.
- **측정 셀** — `CBOR_SPLIT_LIBS={none,static,shared}` × `mold={off,on}` = 6셀(M1~M6).
  종속변수는 layer B 시간 + 링크 구간만 분리한 시간. mold 기여가 (a) none→static에서
  평탄(`ar`은 mold 무관), (b) static→shared에서 상승하는 곡선이 — mold가 *링커*이고
  링크 타깃 수에 의존한다는 구조 의존성의 측정 근거입니다.
- **링크 구간 분리** — static·shared 변형에서는 `cmake --build`를 컴파일 단계(라이브러리
  타깃)와 링크 단계(`--target cbor`)로 나눠 따로 잽니다(위 layer B 다중타깃 마커).

## 컴파일 캐시 백엔드 변형 — ephemeral 러너 캐시 공유 측정

GitHub-hosted 러너는 매 실행 새 머신이라 로컬 캐시가 증발합니다. ccache는 로컬 디스크
캐시이므로 잡이 갈리면 warm 적중이 0%입니다. sccache는 컴파일 오브젝트를 *공유 원격
캐시*에 저장합니다 → 모든 실행/러너가 같은 캐시를 공유 → ephemeral 러너 사이에서도 warm
캐시가 영속됩니다.

이 레포는 그 공유 원격 캐시로 **GitHub Actions 캐시**(`sccache`의 `gha` 백엔드)를 씁니다.
원래 S3 호환 오브젝트 스토리지를 후보로 검토했으나, 측정 환경(GitHub-hosted 러너)에서
바로 도달 가능하고 추가 인프라가 필요 없는 GitHub Actions 캐시가 더 적합합니다 — 비교의
본질은 "로컬 캐시 vs 공유 원격 캐시"이지 특정 스토리지 제품이 아닙니다.

비교의 핵심 종속변수는 *ephemeral 러너 간 warm 적중 여부*입니다. "어느 캐시가 절대적으로
빠른가"가 아닙니다 — sccache는 적중해도 원격 캐시 왕복이 있어 같은 머신 안에서는 로컬
ccache보다 느릴 수 있습니다. 측정 셀을 두 가지 warm으로 나눕니다.

| warm 시나리오 | ccache 예상 | sccache + gha 예상 | 측정 목적 |
|---------------|-------------|--------------------|-----------|
| 같은 잡 재빌드 (1줄 변경) | 적중 (캐시 마운트 영속) | 적중 | ccache가 빠를 수 있음 — 로컬 디스크 |
| 새 잡/러너 재빌드 (ephemeral 시뮬레이션) | **0% — 캐시 증발** | **적중 — 공유 캐시** | sccache의 본질적 이점이 드러나는 지점 |

설정 세부:

- sccache 셀은 **C++ 컴파일 캐싱만** 비교 대상으로 삼습니다. sccache의 nvcc(CUDA) 캐싱은
  ccache보다 지원이 제한적이므로, sccache 셀에서도 CUDA launcher는 ccache로 둡니다 — 이
  비대칭을 측정 캡션에 명기합니다.
- sccache는 `SCCACHE_GHA_ENABLED=true`로 GitHub Actions 캐시 백엔드를 켜고,
  `ACTIONS_RUNTIME_TOKEN`·`ACTIONS_RESULTS_URL`로 캐시 서비스에 접속합니다. 이 토큰·URL은
  워크플로의 `ghaction-github-runtime` 스텝이 노출하며, 빌드 컨테이너에는 BuildKit
  `--mount=type=secret`으로만 전달 — yaml·이미지 레이어에 평문으로 박지 않습니다.
- sccache cold/warm 정의: cold = 해당 캐시 키가 비어 있는 상태(예: 첫 측정 회기). warm =
  같은 캐시 키 재사용. ccache cold/warm(로컬 캐시 비움) 정의와 분리 표기합니다.
- sccache 통계 경계: 빌드 전 `sccache --zero-stats`, 후 `sccache --show-stats`로
  `Compile requests`·`Cache hits`/`Cache misses`를 확인합니다 — 새 잡 warm에서 적중이 0이면
  캐시 공유 실패를 의심합니다.

## 측정 신뢰성 절차

| 항목 | 절차 | 이유 |
|------|------|------|
| 회차 | 각 셀 **N=3회 이상** 측정, 중앙값 보고 + 분산(min/max) 병기 | 단발 측정은 러너 노이즈를 측정값으로 오인 |
| cold 청결 (ccache) | cold 셀: `docker buildx prune -af` + ccache 캐시 미마운트(또는 `ccache -C`) | BuildKit·ccache 잔류 캐시가 cold를 오염 |
| cold 청결 (sccache) | cold 셀: 전용 prefix `s3://<bucket>/<cell>/` 삭제 + `docker buildx prune -af` | 원격 버킷 잔류 오브젝트가 sccache cold를 오염 |
| ccache 통계 경계 | 빌드 직전 `ccache -z`, 직후 `--show-stats` | 해당 빌드만의 적중률 격리 |
| sccache 통계 경계 | 빌드 직전 `sccache --zero-stats`, 직후 `--show-stats`로 S3 read/write 확인 | 적중률 + S3 권한 정상 여부 격리 |
| cold/warm 정의 (ccache) | cold = 빈 캐시 + BuildKit prune 직후. warm = 같은 셀 cold 직후 같은 빌더에서 1줄 변경 후 재빌드 | 모호한 cold/warm 제거 |
| cold/warm 정의 (sccache) | cold = 버킷 prefix 빈 상태. warm = 같은 prefix 재사용. 추가로 "새 잡/러너" warm을 별도 측정 | sccache의 cold/warm은 원격 버킷 상태가 가름 |
| 잡 직렬화 | matrix `max-parallel: 1` | 동시 실행 흔들림 제거 |
| 같은 머신 cold→warm | cold와 warm을 같은 잡·같은 buildx 빌더에서 연속 실행 | warm이 cold의 캐시를 봐야 함. 단 sccache "새 잡" warm 셀은 의도적으로 별 잡에서 실행 |
| 노이즈 보고 | 분산이 중앙값의 일정 비율(예: >15%)을 넘는 셀은 표에 ⚠ 표기 + 재측정 또는 해석 주의 명기 | 신뢰 못 할 셀을 숨기지 않음 |
| 측정 환경 캡션 | 러너 사양·CUDA 이미지 태그·`nproc`·측정 회차·중앙값 여부·S3 백엔드를 모든 표에 캡션으로 명기 | 재현 가능성 |

## 합성 워크로드 — 내적/외적 타당도

본 레포의 96 TU는 `bench/gen-sources.sh`가 생성한 합성 워크로드입니다. 이를 한계가 아니라
**내적 타당도(internal validity)의 강점**으로 다룹니다.

- **강점(내적 타당도)** — TU 수·템플릿 grid 크기·헤더 구성이 완전히 제어·재현 가능합니다.
  96 TU가 모두 동형(同形)이라 ablation 셀 간 워크로드 분산이 없습니다. 측정값 차이가
  순수하게 빌드 설정에서 온다는 보장은 합성 워크로드라서 가능합니다.
- **한계(외적 타당도)** — 실제 대형 C++ 프로젝트는 TU 크기·의존 그래프·링크 타깃 수가
  불균일합니다. 본 측정의 기여도 *비율*을 실제 프로젝트에 그대로 옮길 수 없습니다. 특히
  mold 기여도는 링크 타깃 수에 강하게 의존합니다 — 다중타깃 변형이 바로 이 외적 타당도
  한계를 *측정으로* 보여주는 장치입니다.
- 측정 결과 서술은 이 둘을 명시적으로 구분합니다 — "합성이라 못 믿는다"가 아니라 "합성이라
  변수 통제가 되고, 그래서 기법 *간 상대 비교*는 신뢰할 수 있다. 단 *절대 비율*의 실프로젝트
  일반화는 외적 타당도 한계가 있다."

## 런타임 GPU 검증

빌드 측정과 별개로, 산출 이미지가 *런타임에 GPU를 실제로 쓰는지*를 GPU 노드 배포로
검증합니다(`deploy/gpu-verify-job.yaml`). 검증 Job 로그는 (a) CUDA 디바이스 발견 여부,
(b) 각 커널이 device에서 실행됐다는 명시적 출력, (c) 디바이스 식별 정보를 명확히 찍어
"GPU 사용함/안 함"이 한눈에 판정되도록 합니다. GPU 미할당 대조 실행으로 graceful skip
경로도 함께 확인합니다.

## 셀 정의 SSOT

ablation 측정 셀의 단일 진실 공급원은 `bench/cells.tsv`입니다. 측정 스크립트와 워크플로
매트릭스는 모두 이 파일을 셀 ID로 참조하므로, 셀 정의와 ablation 표가 자동으로 일치합니다.
컬럼 의미와 `-D` 매핑은 그 파일 상단 주석에 정의돼 있습니다.
