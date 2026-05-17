# ccache 0% 적중 함정 3종 — 재현과 수정

컴파일 캐시(ccache/sccache)를 붙였는데 적중률이 **0%**로 나오는 건 흔한 일이다.
원인은 거의 항상 셋 중 하나다. 이 문서는 각 함정을 *왜 생기는지* → *어떻게 재현하는지*
→ *어떻게 고치는지* 순으로 정리한다. 본 프로젝트의 `optimized` 경로
(`docker/Dockerfile.optimized`)는 셋 다 미리 막아 둔 상태다.

ccache의 동작 전제: **컴파일러 + 전처리된 소스 + 옵션**을 해시해 키를 만들고,
같은 키면 오브젝트 파일을 그대로 꺼내 쓴다. 0% 적중 = 같은 빌드인데도 *키가 매번
달라진다*는 뜻이다.

## 함정 1 — 절대경로가 해시에 섞인다

### 왜

`-g` 디버그 빌드는 오브젝트에 소스 파일의 **절대경로**를 박는다. CI 러너는 매번
다른 경로에 체크아웃한다 (`/runner/_work/abc123/...`, `/workspace/...`).
경로가 키에 들어가면 러너가 바뀔 때마다, 빌드 디렉토리가 바뀔 때마다 키가 달라져
캐시가 통째로 미스난다.

### 재현

```bash
ccache -z
g++ -g -c /path/A/module_001.cpp -o /tmp/a.o      # store
ccache -z
g++ -g -c /path/B/module_001.cpp -o /tmp/b.o      # 같은 내용, 다른 경로 → miss
ccache --show-stats                               # cache hit 0
```

### 수정

ccache에 기준 디렉토리를 알려 주고, 컴파일러에는 디버그 경로를 상대화하라고 시킨다.

```bash
export CCACHE_BASEDIR=/workspace          # 이 아래 경로는 상대경로로 정규화
# 컴파일 플래그
-fdebug-prefix-map=/workspace=.           # 디버그 정보의 절대경로 제거
```

본 프로젝트: `Dockerfile.optimized`가 `ENV CCACHE_BASEDIR=/workspace`로 고정.
빌드가 항상 `/workspace`에서 일어나므로 경로 변동 자체가 없다 — 컨테이너 빌드의
구조적 이점이다.

## 함정 2 — `compiler_check` 기본값이 컴파일러 mtime

### 왜

ccache는 키에 "어떤 컴파일러인가"를 넣는다. 기본 방식(`mtime`)은 컴파일러
바이너리의 **수정 시각**을 쓴다. 그런데 컨테이너 이미지를 다시 빌드하면 `g++`
바이너리의 mtime이 매번 바뀐다 (apt가 새로 깐 파일이므로). 같은 버전·같은 내용의
컴파일러인데도 mtime이 달라 키가 미스난다.

### 재현

```bash
ccache -z
g++ -c module_001.cpp -o /tmp/a.o          # store
touch -d '2020-01-01' $(command -v g++)    # 컴파일러 mtime만 변경
g++ -c module_001.cpp -o /tmp/b.o          # 같은 컴파일러인데 miss
ccache --show-stats
```

### 수정

mtime 대신 컴파일러 바이너리의 **내용 해시**로 식별한다.

```bash
export CCACHE_COMPILERCHECK=content
```

본 프로젝트: `Dockerfile.optimized`가 `ENV CCACHE_COMPILERCHECK=content`로 설정.
이미지를 다시 빌드해 `g++` mtime이 바뀌어도 내용이 같으면 캐시가 산다.

## 함정 3 — `__DATE__` / `__TIME__` 매크로

### 왜

소스(또는 헤더)가 `__DATE__`·`__TIME__`·`__TIMESTAMP__` 매크로를 쓰면, 전처리
결과가 **빌드한 순간마다** 달라진다. ccache는 전처리된 소스를 해시하므로 키가
매번 바뀐다. 버전 배너에 빌드 시각을 박는 코드가 대표적인 원인이다.

### 재현

```bash
printf '#include <cstdio>\nint main(){printf("%%s\\n", __DATE__);}\n' > t.cpp
ccache -z
g++ -c t.cpp -o /tmp/a.o
g++ -c t.cpp -o /tmp/b.o     # __DATE__ 때문에 두 번째도 store만, 적중 0
ccache --show-stats
```

### 수정

ccache에 "이 매크로는 무시해도 된다"고 알린다.

```bash
export CCACHE_SLOPPINESS=time_macros
```

본 프로젝트: `Dockerfile.optimized`가 `CCACHE_SLOPPINESS=time_macros,pch_defines`로
설정. `time_macros`가 함정 3을, `pch_defines`는 PCH(precompiled header)를 함께
쓸 때 필요한 추가 항목이다. 단, `time_macros`는 빌드 시각이 *실제로 의미 있는*
산출물(릴리스 배너 등)에서는 캐시가 옛 시각을 줄 수 있으므로 빌드 잡에서만 켠다.

## 확인 방법

수정이 먹었는지는 `ccache --show-stats`로 본다.

```text
cacheable calls   192 / 192
  hits            190 / 192      <- 웜 빌드에서 이 수가 올라가면 정상
  misses            2 / 192
```

콜드 빌드는 당연히 0% (저장만) → 같은 소스로 웜 빌드 시 적중률이 뛰면 캐시가
제대로 동작하는 것이다. 적중률이 계속 0%면 위 함정 셋을 다시 점검한다.

## 정리

| 함정 | 증상 | 수정 |
|------|------|------|
| 절대경로 | 러너/디렉토리 바뀌면 전체 미스 | `CCACHE_BASEDIR` + `-fdebug-prefix-map` |
| `compiler_check` mtime | 이미지 재빌드마다 미스 | `CCACHE_COMPILERCHECK=content` |
| `__DATE__`/`__TIME__` | 매 빌드 미스 | `CCACHE_SLOPPINESS=time_macros` |

면접/과제에서 "캐시를 붙였는데 안 먹는다"는 단골 질문이다. 답은 거의 항상
"키가 매번 달라지는 이유를 찾아라"이고, 그 이유가 위 셋 중 하나다.
