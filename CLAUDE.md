# agent-devtools

Browser DevTools CLI for AI agents, built with Zig.

## Project Info

- **GitHub**: ohah/agent-devtools
- **npm**: @ohah/agent-devtools
- **CLI 실행 명령**: agent-devtools
- **언어**: Zig 0.15.2
- **라이선스**: MIT

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
- Target.createTarget → attachToTarget(flatten=true)으로 페이지 세션 획득

## Differentiation (기존 도구에 없는 것)

1. **웹앱 역공학** — 네트워크 트래픽 관찰 → API 스키마(OpenAPI) 자동 생성
2. **플로우 녹화/재생** — LLM 없이 기계적 비교, 토큰 비용 0
3. **시간축 디버깅** — baseline 대비 변화 감지 + 보고
4. **네트워크 인터셉트** — 요청/응답 가로채기, 목업, 지연 시뮬레이션

## Implementation Status

### ✅ Phase 1: CDP WebSocket 연결
- WebSocket 프레임 코덱 (RFC 6455 준수, 99개 테스트)
- WebSocket Client (TCP 연결 + 핸드셰이크 + 프레임 I/O)
- Chrome 스폰 + DevToolsActivePort 폴링
- CDP 메시지 파싱/직렬화 (67개 테스트)

### ✅ Phase 2: 네트워크 관찰
- Network.enable + 이벤트 수집 (requestWillBeSent, responseReceived, loadingFinished/Failed)
- `network list [pattern]` 명령어
- URL 패턴 필터링

### ✅ Phase 6: 데몬 아키텍처 (순서 앞당김)
- CLI/Daemon 같은 바이너리, 환경변수로 모드 분기
- Unix Domain Socket IPC (JSON-line 프로토콜)
- ensureDaemon: 데몬 자동 스폰 + 준비 대기
- 세션 기반 다중 데몬 지원
- `open <url>`, `close` 명령어

### ⬜ Phase 3: 웹앱 역공학
- 트래픽 패턴 분석 → API 스키마(OpenAPI) 자동 생성
- `analyze` 명령어

### ⬜ Phase 4: 네트워크 인터셉트
- CDP `Fetch.enable` + 요청/응답 조작
- `intercept` 명령어 (목업, 지연, 차단)

### ⬜ Phase 5: 플로우 녹화/재생
- 네트워크 패턴 + AX 상태 저장
- baseline 비교 + 변화 보고
- `record`, `replay`, `diff` 명령어

### ⬜ 추가 계획
- idle timeout (데몬 자동 종료)
- Chrome 크래시 감지
- `status` 명령 (데몬 상태 확인)
- `network get <requestId>` (응답 본문 포함)
- Skills (SKILL.md) — Claude Code 연동
- npm 배포 구조

## Project Structure

```
src/
├── main.zig          # CLI 진입점 + 데몬 모드 분기
├── daemon.zig        # 데몬 프로토콜, Unix Socket, ensureDaemon
├── websocket.zig     # WebSocket 프레임 코덱 + Client + Connection
├── cdp.zig           # CDP 메시지 파싱/직렬화 (Network, Fetch, Target, Page, Runtime)
├── chrome.zig        # Chrome 프로세스 관리 (discovery, path, args, launch)
├── network.zig       # 네트워크 이벤트 수집/필터링
└── root.zig          # 모듈 루트

reference/            # 참조 코드 (gitignored)
├── agent-browser/    # vercel-labs/agent-browser (Rust)
└── cdp-protocol/     # ChromeDevTools/devtools-protocol (JSON spec)
```

## Testing

- Zig 내장 테스트 사용 (`test` 블록, 소스 파일 내 작성)
- `zig build test`로 전체 실행 (현재 244개)
- 유닛: WebSocket 프레임, CDP 메시지, 네트워크 필터링, 데몬 프로토콜
- 통합: 실제 Chrome 스폰 + CDP 연결 (E2E 동작 확인)

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
zig build test         # 테스트
./zig-out/bin/agent-devtools   # 직접 실행
```

## Commands

### 구현 완료

```bash
agent-devtools open <url>                          # 페이지 열기 (데몬 자동 시작)
agent-devtools network list [pattern]              # 네트워크 요청 목록 (URL 필터 가능)
agent-devtools close                               # 브라우저 + 데몬 종료
agent-devtools find-chrome                         # Chrome 경로 탐색
agent-devtools --session=NAME <command>             # 세션별 독립 데몬
agent-devtools --help / --version                  # 도움말 / 버전
```

### 구현 예정

```bash
agent-devtools network get <requestId>             # 요청 상세 (응답 본문)
agent-devtools analyze <url>                       # 웹앱 역공학 (API 스키마)
agent-devtools intercept <pattern> --mock <json>   # 응답 목업
agent-devtools intercept <pattern> --delay <ms>    # 지연
agent-devtools intercept <pattern> --fail          # 차단
agent-devtools record <name>                       # 플로우 녹화
agent-devtools replay <name>                       # 재생 + 비교
agent-devtools diff <baseline>                     # 변화 감지
agent-devtools status                              # 데몬 상태 확인
```
