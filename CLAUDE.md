# agent-devtools

Browser DevTools CLI for AI agents, built with Zig.

## Project Info

- **GitHub**: ohah/agent-devtools
- **npm**: @ohah/agent-devtools
- **CLI 실행 명령**: agent-devtools
- **언어**: Zig 0.15.2
- **라이선스**: MIT
- **테스트**: 310개 (`zig build test`)

## Architecture

```
┌─────────────┐     Unix Socket     ┌──────────────┐     WebSocket     ┌─────────┐
│  Zig CLI    │ ◄── JSON-line ────► │  Zig Daemon  │ ◄───────────────► │  Chrome  │
│ (즉시 종료)  │                     │ (백그라운드)   │                    │ (CDP)    │
└─────────────┘                     └──────────────┘                   └─────────┘
```

- 같은 바이너리가 CLI/데몬 두 역할: `AGENT_DEVTOOLS_DAEMON=1` 환경변수로 구분
- 세션 기반 다중 데몬: `--session=NAME`으로 독립적인 Chrome 인스턴스 운영
- Unix Domain Socket (`{session}.sock`)으로 CLI ↔ Daemon 통신 (newline-delimited JSON)
- Chrome은 CDP(Chrome DevTools Protocol) WebSocket으로 제어
- Chrome for Testing 또는 시스템 Chrome에 `--remote-debugging-port`로 연결
- `--port=PORT`로 기존 Chrome에 연결 시 `/json/version` discovery (httpGet으로 GUID 포함 정확한 URL 획득)
- Target.createTarget → attachToTarget(flatten=true)으로 페이지 세션 획득
- Network.enable + Runtime.enable + Page.enable 상시 활성
- idle timeout 10분 (CLI 명령 없으면 데몬 자동 종료)
- Chrome 크래시 감지 (CDP 연속 실패 30회 시 자동 종료)

## Differentiation (기존 도구에 없는 것)

1. **웹앱 역공학** — 네트워크 트래픽 관찰 → API 엔드포인트 자동 발견 + 의미 있는 파라미터명 ({userId}, {postId})
2. **콘솔 로그 캡처** — Runtime.consoleAPICalled로 모든 JS 타입 정확 변환 (string, number, boolean, null, undefined, object, symbol, bigint, NaN, -0 등)
3. **네트워크 인터셉트** (Phase 4) — 요청/응답 가로채기, 목업, 지연 시뮬레이션
4. **플로우 녹화/재생** (Phase 5) — LLM 없이 기계적 비교, 토큰 비용 0

## Implementation Status

### ✅ Phase 1: CDP WebSocket 연결
- WebSocket 프레임 코덱 (RFC 6455 준수, 106개 테스트)
- WebSocket Client (TCP 연결 + 핸드셰이크 + 프레임 I/O, 동적 버퍼 64KB→16MB)
- Chrome 스폰 + DevToolsActivePort 폴링
- CDP 메시지 파싱/직렬화 (67개 테스트)
- httpGet: raw TCP HTTP 클라이언트 (SO_RCVTIMEO + Content-Length 조기 종료)
- discoverWsUrl: /json/version discovery + host/port 재작성

### ✅ Phase 2: 네트워크 관찰
- Network.enable + 이벤트 수집 (requestWillBeSent, responseReceived, loadingFinished/Failed)
- `network list [pattern]` — URL 패턴 필터링
- `network get <requestId>` — CDP Network.getResponseBody로 응답 본문 포함 상세 정보
- `network clear` — 수집 초기화

### ✅ Phase 3: 웹앱 역공학
- API 요청 자동 식별 (XHR/Fetch, JSON mime, /api/ 경로 패턴)
- 정적 리소스 자동 제외 (.js, .css, .png 등, query/fragment 처리)
- URL → 패턴 변환: /users/123 → /users/{userId}
- 의미 있는 파라미터명 (이전 세그먼트 기반, 복수형 자동 단수화)
- UUID, hex hash, 숫자 ID 자동 감지
- 응답 JSON 스키마 자동 추론 (재귀적 object/array/nested 지원)
- `analyze` 명령어
- OpenAPI YAML 출력은 미구현 (JSON 출력 제공, YAML은 외부 도구 `yq` 등으로 변환 가능)

### ✅ Phase 6: 데몬 아키텍처 (순서 앞당김)
- CLI/Daemon 같은 바이너리, 환경변수로 모드 분기
- Unix Domain Socket IPC (JSON-line 프로토콜, cdp.writeJsonString으로 이스케이프)
- ensureDaemon: 데몬 자동 스폰 + 준비 대기 (30초 타임아웃)
- 세션 기반 다중 데몬 지원 (`--session=NAME`)
- idle timeout 10분 자동 종료
- Chrome 크래시 감지 (CDP 연속 실패 30회)

### ✅ 보강 완료
- `console list/clear` — Runtime.consoleAPICalled 이벤트 수집
  - 모든 JS 타입 정확 변환 (RemoteObject: string/number/boolean/null/undefined/object/symbol/bigint/NaN/-0/Infinity)
  - 27개 테스트 (RemoteObject → text 변환)
- `status` — 데몬 상태 + 요청 수 + 콘솔 메시지 수
- `--headed` — 브라우저 창 표시 옵션
- `--port=PORT` — 기존 Chrome 연결 (/json/version discovery)

### ⬜ Phase 4: 네트워크 인터셉트
- CDP `Fetch.enable` + 요청/응답 조작
- `intercept` 명령어 (목업, 지연, 차단)

### ⬜ Phase 5: 플로우 녹화/재생
- 네트워크 패턴 + AX 상태 저장
- baseline 비교 + 변화 보고
- `record`, `replay`, `diff` 명령어

### ⬜ 추가 계획
- 기본 명령어: screenshot, eval, back/forward/reload, get url/title, wait
- Collector 용량 제한 (LRU eviction)
- console.zig 분리 (main.zig에서 독립 모듈로)
- OpenAPI YAML 출력 (현재 JSON, YAML 변환은 외부 도구로 가능)
- Skills (SKILL.md) — Claude Code 연동
- npm 배포 구조
- CI 테스트 (GitHub Actions)

## Project Structure

```
src/
├── main.zig          # CLI 진입점 + 데몬 모드 (runDaemon, handleCommand)
├── daemon.zig        # 데몬 프로토콜, Unix Socket, ensureDaemon, DaemonOptions
├── websocket.zig     # WebSocket 프레임 코덱 + Client + Connection (RFC 6455)
├── cdp.zig           # CDP 메시지 파싱/직렬화 + writeJsonString (Network, Fetch, Target, Page, Runtime)
├── chrome.zig        # Chrome 프로세스 관리 (discovery, httpGet, path, args, launch)
├── network.zig       # 네트워크 이벤트 수집/필터링 (Collector)
├── analyzer.zig      # API 엔드포인트 분석 (isApiRequest, pathToPattern, analyzeRequests)
└── root.zig          # 모듈 루트

docs/
└── comparison.md     # agent-devtools vs agent-browser 비교

reference/            # 참조 코드 (gitignored)
├── agent-browser/    # vercel-labs/agent-browser (Rust)
└── cdp-protocol/     # ChromeDevTools/devtools-protocol (JSON spec)
```

## Testing

- Zig 내장 테스트 사용 (`test` 블록, 소스 파일 내 작성)
- `zig build test`로 전체 실행 (현재 310개)
- 유닛: WebSocket 프레임, CDP 메시지, 네트워크 필터링, 데몬 프로토콜, API 분석, RemoteObject 변환
- 통합: 실제 Chrome 스폰 + CDP 연결 (E2E 동작 확인)

### 테스트 분포

| 모듈 | 테스트 수 | 내용 |
|---|---|---|
| websocket.zig | 106 | RFC 6455 프레임, 마스킹, 핸드셰이크, Connection, URL 파싱 |
| cdp.zig | 67 | 메시지 파싱/직렬화, 에러 코드, 편의 명령, JSON 이스케이프 |
| chrome.zig | 41 | DevToolsActivePort, /json/version, URL 재작성, Chrome 인자, discovery |
| main.zig | 31 | RemoteObject 변환 (18개 JS 타입), isPlannedCommand |
| analyzer.zig | 35 | isApiRequest, extractPath, isLikelyId, pathToPattern, inferJsonSchema, serialize |
| daemon.zig | 18 | 소켓 경로, 직렬화, 파싱, 라운드트립, writeJsonValue |
| network.zig | 11 | Collector lifecycle, filterByUrl, formatRequestLine |
| root.zig | 1 | 모듈 참조 |

### 테스트 작성 원칙

- **테스트 코드는 반드시 공식 문서/RFC/스펙을 직접 참조하고 작성할 것**
  - WebSocket: [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455)
  - CDP: [Chrome DevTools Protocol 공식 문서](https://chromedevtools.github.io/devtools-protocol/)
  - CDP JSON 스펙: `reference/cdp-protocol/json/browser_protocol.json`
  - 기억이나 추측에 의존하지 않고, 스펙 원문을 확인한 후 테스트 작성
- 경계값 테스트 필수 (boundary conditions)
- 에러 경로 빠짐없이 테스트
- 라운드트립 테스트 (encode → decode → 비교)
- `testing.allocator` 사용으로 메모리 누수 자동 감지
- 회귀 테스트 방지: 한번 작성된 테스트는 삭제하지 않음

## Build & Run

```bash
zig build              # 빌드
zig build run          # 실행
zig build test         # 테스트 (310개)
./zig-out/bin/agent-devtools   # 직접 실행
```

## Commands

### 구현 완료

```bash
agent-devtools open <url>                          # 페이지 열기 (데몬 자동 시작)
agent-devtools network list [pattern]              # 네트워크 요청 목록 (URL 필터)
agent-devtools network get <requestId>             # 요청 상세 (응답 본문 포함)
agent-devtools network clear                       # 수집 초기화
agent-devtools console list                        # 콘솔 로그 목록
agent-devtools console clear                       # 콘솔 초기화
agent-devtools analyze                             # API 엔드포인트 분석
agent-devtools status                              # 데몬 상태 확인
agent-devtools close                               # 브라우저 + 데몬 종료
agent-devtools find-chrome                         # Chrome 경로 탐색
agent-devtools --session=NAME <command>             # 세션별 독립 데몬
agent-devtools --headed <command>                  # 브라우저 창 표시
agent-devtools --port=PORT <command>               # 기존 Chrome 연결
agent-devtools --help / --version                  # 도움말 / 버전
```

### 구현 예정

```bash
agent-devtools intercept <pattern> --mock <json>   # 응답 목업
agent-devtools intercept <pattern> --delay <ms>    # 지연
agent-devtools intercept <pattern> --fail          # 차단
agent-devtools record <name>                       # 플로우 녹화
agent-devtools replay <name>                       # 재생 + 비교
agent-devtools diff <baseline>                     # 변화 감지
agent-devtools screenshot [path]                   # 스크린샷
agent-devtools eval <expression>                   # JS 실행
agent-devtools back / forward / reload             # 네비게이션
agent-devtools get url / get title                 # 페이지 정보
agent-devtools wait <ms>                           # 대기
```
