# 레퍼런스 OSS 분석 — C++ 빌드 최적화 패턴 추출

이 문서는 본 샘플 프로젝트(`cpp-build-optimization-reference`)의 Dockerfile·CMake·CI 설계 근거다.
대규모 C++ 오픈소스가 실제로 운용하는 빌드 최적화 패턴을 추출하고, 본 샘플에 어떻게 이식할지 정리한다.

## 분석 대상

| 역할 | 프로젝트 | 무엇을 보는가 |
|------|----------|---------------|
| 주 레퍼런스 | ROS Navigation2 | multi-stage Dockerfile, 레이어 순서, `package.xml` 선복사, `--mixin` ccache·lld |
| 보조 레퍼런스 | Godot Engine | unity(SCU) 빌드, mold/lld 링커, 디버그 심볼 토글, CI 매트릭스 운용 |
| 대조군 | fmt (fmtlib/fmt) | 최적화를 *적용하지 않은* 평범한 CMake 라이브러리 — 본 샘플 `baseline`의 기준점 |

본 샘플은 ROS 실물(`colcon` 워크스페이스)을 포함하지 않는다 (D-04). Navigation2의 *Dockerfile 패턴*만
순수 C++/CUDA 프로젝트에 이식하고, ROS 특유 패턴(`colcon --mixin`, `package.xml` 선복사)은 이 문서에서 설명으로 남긴다.

---

## Navigation2 — multi-stage Dockerfile 패턴

출처: [`ros-navigation/navigation2` Dockerfile @ 855ba78](https://github.com/ros-navigation/navigation2/blob/855ba78e14c69839cb7a798ce2634293d5150dc0/Dockerfile)

### stage 구성

```
FROM $FROM_IMAGE AS cacher       # 매니페스트·의존성 소스만 모으는 stage
FROM $FROM_IMAGE AS builder      # 실제 colcon build
FROM builder     AS tester       # colcon test
FROM builder     AS dever        # 개발용(추가 툴)
FROM caddy:builder AS caddyer
FROM dever       AS visualizer
FROM tester      AS exporter
```

`cacher` → `builder` 분리가 핵심. `cacher`는 "무엇을 빌드할지"(매니페스트·의존성 목록)만 추려서
`builder`로 넘기고, `builder`는 그걸 받아 컴파일만 한다.

### 패턴 1 — `package.xml` 매니페스트 선복사 (제로 코스트 캐시 보존)

`cacher` stage가 소스 전체에서 `package.xml`만 추려낸다:

```dockerfile
RUN find . -name "package.xml" | xargs cp --parents -t /tmp/opt
```

**왜 중요한가**: ROS 의존성 설치(`rosdep install`)는 `package.xml`의 의존성 선언만 읽는다.
`package.xml`만 먼저 복사해 의존성 레이어를 만들면, *소스 코드만 바뀐 커밋*에서는 의존성 설치 레이어가
Docker 레이어 캐시로 그대로 재사용된다. 소스를 통째로 `COPY` 먼저 하면 매 커밋 캐시가 깨진다.

**본 샘플 이식**: 본 샘플엔 `package.xml`이 없다. 대응물 = **의존성 매니페스트 선복사**.
`apt` 패키지 목록(`docker/apt-packages.txt`)과 `CMakeLists.txt`를 소스 `.cpp`/`.cu`보다 먼저 `COPY` →
의존성 설치 레이어를 소스 변경과 분리한다 (층 A: Dockerfile 레이어 순서).

### 패턴 2 — `colcon --mixin "release ccache lld"`

```dockerfile
ARG UNDERLAY_MIXINS="release ccache lld"
ARG OVERLAY_MIXINS="release ccache lld"
colcon build --symlink-install --mixin $UNDERLAY_MIXINS
```

`mixin`은 빌드 옵션 묶음의 이름(ROS `colcon-mixin-repository`). `release`(최적화 플래그) +
`ccache`(컴파일 캐시 launcher) + `lld`(빠른 링커)를 한 토큰으로 켠다.

**본 샘플 이식**: `colcon` 대신 **CMake Presets**(`CMakePresets.json`). `baseline` 프리셋과
`optimized` 프리셋으로 옵션 묶음을 분리 — `mixin`의 CMake 네이티브 대응물이다.
`ccache` → `CMAKE_CXX_COMPILER_LAUNCHER`, `lld` → 본 샘플은 `mold`(`-fuse-ld=mold`)로 대체.

### 패턴 3 — `CCACHE_DIR`를 ARG로 워크스페이스 내부에 고정

```dockerfile
ARG CCACHE_DIR="$UNDERLAY_WS/.ccache"
```

ccache 디렉토리를 워크스페이스 하위 고정 경로로 둬서 stage 간/볼륨 마운트로 넘기기 쉽게 한다.

**본 샘플 이식 + 보강**: Navigation2 Dockerfile에는 BuildKit `--mount=type=cache`가 *없다*.
본 샘플은 여기서 한 발 더 나가 `RUN --mount=type=cache,target=/ccache`로
ccache 디렉토리를 BuildKit 캐시 마운트로 영속화한다 (리서치 문서 층 A의 cache mount 항목).
→ Navigation2 대비 "개선점"으로 README에 명시할 포인트.

---

## Godot — CI 빌드 최적화 운용 패턴

출처: [`godotengine/godot` `.github/workflows/linux_builds.yml` @ 321b8c9](https://github.com/godotengine/godot/blob/321b8c944fa32ee94eef44a56925105d7091be03/.github/workflows/linux_builds.yml)

Godot은 SCons 빌드라 CMake와 빌드 시스템은 다르지만, **CI 매트릭스에서 빌드 옵션을 조합 운용하는
방식**이 본 샘플의 `build-benchmark.yml` 설계에 직접 참고된다.

### 패턴 1 — unity 빌드(SCU)를 매트릭스 엔트리별 토글

```
scu_build=yes        # "Editor with doubles and GCC sanitizers" 엔트리
```

SCU(Single Compilation Unit) = unity build. Godot은 *모든* 엔트리에 켜지 않고
특정 매트릭스 엔트리에서만 켠다. unity 빌드는 콜드 빌드를 줄이지만 증분 빌드를 느리게 해서다.

**본 샘플 이식**: `optimized` 프리셋에 `CMAKE_UNITY_BUILD=ON`, `baseline`은 OFF.
"CI 콜드 빌드엔 unity ON, 개발자 로컬 증분엔 OFF"라는 리서치 문서의 트레이드오프를
프리셋 2개로 실증한다.

### 패턴 2 — 링커를 매트릭스 엔트리별로 선택

```
linker=mold          # doubles/sanitizers 빌드
linker=lld           # clang sanitizers / ThreadSanitizer 빌드
uses: rui314/setup-mold@v1   # proj-test 빌드에서 mold 설치
```

Godot은 mold와 lld를 엔트리 성격에 맞춰 갈라 쓴다 (mold는 GCC LTO 미지원 → LTO 엔트리는 lld).

**본 샘플 이식**: `optimized` 프리셋에 `-fuse-ld=mold`. mold 설치는 `rui314/setup-mold` 액션을
CI에서 그대로 차용. `baseline`은 기본 GNU ld → before/after 링크 시간 대비가 드러난다.

### 패턴 3 — 디버그 심볼 토글로 산출물 부피 통제

```
debug_symbols=no     # "Editor with doubles and GCC sanitizers" 엔트리
```

**본 샘플 이식**: 본 샘플은 디버그 심볼을 *끄지 않고* `-gsplit-dwarf`로 분리한다
(리서치 문서 층 B). 심볼을 유지하면서 증분 링크를 줄이는 게 목적 — Godot의 "끄기"보다
"분리하기"가 디버깅 가능성을 보존하므로 본 샘플엔 더 적합.

### 패턴 4 — CI 캐시는 매트릭스 키별 분리

```
uses: ./.github/actions/godot-cache-restore
cache-name: ${{ matrix.cache-name }}      # 예: "linux-editor-mono"
```

각 매트릭스 엔트리가 독립 캐시 키를 가진다. baseline 캐시와 optimized 캐시가 섞이면
적중률 측정이 오염된다.

**본 샘플 이식**: `build-benchmark.yml`의 baseline/optimized × cold/warm 4조합이
각각 독립 캐시 스코프를 갖도록 설계한다. cold 측정 직전 `ccache -z` +
`docker buildx prune`으로 캐시를 비우는 청결 절차도 여기서 근거.

> Godot CI 자체에는 ccache/sccache 설정이 없다(SCons 자체 캐시 사용). 컴파일 캐시 설정은
> Navigation2의 `--mixin ccache`와 리서치 문서를 따른다.

---

## fmt — 대조군 (최적화 미적용 기준점)

출처: [`fmtlib/fmt`](https://github.com/fmtlib/fmt)

fmt는 평범한 modern CMake 라이브러리다. Ninja 강제·ccache·multi-stage·unity 같은 최적화 장치가
프로젝트 차원에서 *기본 적용되어 있지 않다* — `cmake -S . -B build && cmake --build build`가 전부.

**대조군으로 쓰는 이유**: 본 샘플의 `baseline` 경로는 "최적화를 모르는 평범한 C++ 프로젝트"를
재현해야 공정한 before가 된다. fmt가 그 모습이다 — 단일 stage, `COPY . .` 먼저, Make 제너레이터,
캐시 없음. 본 샘플 `Dockerfile.baseline`/`baseline` 프리셋은 의도적으로 이 수준으로 작성한다.

---

## 3층 멘탈 모델 ↔ 레퍼런스 패턴 매핑

C++ 빌드 최적화 3층 멘탈 모델(A 컨테이너 / B 컴파일 / C 이미지 크기)의 각 기법이
어느 레퍼런스에서 검증된 패턴인지, 본 샘플 어디에 적용되는지 추적하는 표.

| 층 | 기법 | 레퍼런스 근거 | 본 샘플 적용 위치 |
|----|------|---------------|-------------------|
| A | multi-stage (devel→runtime) | Navigation2 `cacher`/`builder`/`tester` stage 분리 | `docker/Dockerfile.optimized` |
| A | 레이어 순서 (의존성 위, 소스 아래) | Navigation2 `package.xml` 선복사 | `Dockerfile.optimized` — `apt-packages.txt` 선복사 |
| A | BuildKit cache mount (apt/ccache) | Navigation2엔 없음 — 본 샘플 개선점 | `Dockerfile.optimized` `RUN --mount=type=cache` |
| A | registry remote cache (`type=gha`) | 일반 BuildKit best practice | `build-benchmark.yml` (향후 `--cache-to/from`) |
| B | 컴파일 캐시 ccache | Navigation2 `--mixin ccache`, `CCACHE_DIR` ARG | `optimized` 프리셋 `CMAKE_CXX/CUDA_COMPILER_LAUNCHER` |
| B | 캐시 0% 적중 함정 3종 | 일반 ccache 운용 지식 | `docs/ccache-cache-miss-traps.md` |
| B | Ninja 제너레이터 | CMake 표준 | `optimized` 프리셋 `"generator": "Ninja"` |
| B | mold 링커 | Godot `linker=mold`, `setup-mold` 액션 | `Dockerfile.optimized` `mold -run` |
| B | `-gsplit-dwarf` | Godot은 `debug_symbols=no`(끄기) — 본 샘플은 분리로 보강 | `optimized` 프리셋 `CMAKE_CXX_FLAGS` |
| B | unity build | Godot `scu_build=yes` 엔트리별 토글 | `optimized` 프리셋 `CMAKE_UNITY_BUILD` |
| B | PCH | CMake 표준 `target_precompile_headers` | `cmake/BuildOptions.cmake` |
| B | job pools (동시 링크 제한) | 대규모 병렬 빌드 OOM 방지 통념 | `optimized` 프리셋 `CMAKE_JOB_POOLS` |
| C | devel→runtime 베이스 교체 | Navigation2 multi-stage 산출물만 COPY | `Dockerfile.optimized` `cuda:devel`→`cuda:runtime` |
| C | 부피 제거 (`--no-install-recommends` 등) | Navigation2/일반 best practice | `Dockerfile.optimized` runtime stage |

매핑 안 되는 항목 = 레퍼런스에 없거나 본 샘플이 개선하는 부분:
- **BuildKit cache mount**: Navigation2 Dockerfile엔 없음 → 본 샘플이 추가하는 개선점.
- **sccache + S3(MinIO)**: 어느 레퍼런스도 안 씀 → ephemeral 러너 간 캐시 공유의 정답, 향후 변형으로 둔다.

---

## 본 샘플 이식 요약

| Navigation2/Godot가 한 것 | 본 샘플(순수 C++/CUDA)에서의 대응물 |
|---------------------------|--------------------------------------|
| `colcon --mixin` 옵션 묶음 | `CMakePresets.json`의 `baseline`/`optimized` 프리셋 |
| `package.xml` 선복사 | `apt-packages.txt` + `CMakeLists.txt` 선복사 |
| `colcon --parallel-workers` | CMake `JOB_POOLS`(compile/link 풀 분리) |
| Godot SCons `scu_build` | CMake `CMAKE_UNITY_BUILD` |
| Godot `linker=mold` | `-fuse-ld=mold` (`optimized` 프리셋) |
| ROS `cacher`/`builder` stage | `cuda:devel` builder → `cuda:runtime` runtime stage |

ROS·SCons 같은 도메인 빌드 시스템 의존을 걷어내고 **CMake + Docker BuildKit 네이티브**로만
3층 기법을 재현하는 것이 본 샘플의 설계 의도다.
