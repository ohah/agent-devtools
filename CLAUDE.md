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
Zig CLI ── Unix Socket ──> Zig Daemon ── WebSocket ──> Chrome (CDP)
                                │
                           Network observation/intercept
                           API schema collection
                           Flow recording/comparison
                           Change detection
```

- Chrome은 CDP(Chrome DevTools Protocol) WebSocket으로 제어
- Chrome for Testing 또는 기존 Chrome에 `--remote-debugging-port`로 연결
- CLI와 Daemon은 같은 바이너리, 환경변수로 모드 구분
- Unix Domain Socket으로 CLI ↔ Daemon 통신 (newline-delimited JSON)

## Differentiation (기존 도구에 없는 것)

1. **웹앱 역공학** — 네트워크 트래픽 관찰 → API 스키마(OpenAPI) 자동 생성
2. **플로우 녹화/재생** — LLM 없이 기계적 비교, 토큰 비용 0
3. **시간축 디버깅** — baseline 대비 변화 감지 + 보고
4. **네트워크 인터셉트** — 요청/응답 가로채기, 목업, 지연 시뮬레이션

## Implementation Phases

### Phase 1: CDP WebSocket 연결 (핵심 관문)
- WebSocket 핸드셰이크 + 프레임 파싱 (RFC 6455)
- Chrome 스폰 (`--remote-debugging-port`) + 연결
- 기본 CDP 명령 송수신

### Phase 2: 네트워크 관찰
- CDP `Network.enable` + 이벤트 수신
- `network list`, `network get` 명령어

### Phase 3: 웹앱 역공학
- 트래픽 패턴 분석 → API 스키마(OpenAPI) 자동 생성
- `analyze` 명령어

### Phase 4: 네트워크 인터셉트
- CDP `Fetch.enable` + 요청/응답 조작
- `intercept` 명령어 (목업, 지연, 차단)

### Phase 5: 플로우 녹화/재생
- 네트워크 패턴 + AX 상태 저장
- baseline 비교 + 변화 보고
- `record`, `replay`, `diff` 명령어

### Phase 6: 데몬 분리 (필요 시)
- CLI/Daemon 아키텍처 분리
- Unix Domain Socket IPC
- 유휴 타임아웃, 프로세스 관리

## Project Structure

```
src/
├── main.zig          # CLI 진입점
├── websocket.zig     # WebSocket 클라이언트
├── cdp.zig           # CDP 프로토콜 메시지 처리
├── network.zig       # 네트워크 수집/필터링
├── snapshot.zig      # AX 트리 압축 + ref 시스템
└── root.zig          # 모듈 루트
```

## Testing

- Zig 내장 테스트 사용 (`test` 블록, 소스 파일 내 작성)
- `zig build test`로 전체 실행
- 유닛: WebSocket 프레임, CDP 메시지, 네트워크 필터링, AX 트리 압축
- 통합: 실제 Chrome 스폰 + CDP 연결 (Zig만으로 가능)

## Build & Run

```bash
zig build              # 빌드
zig build run          # 실행
zig build test         # 테스트
./zig-out/bin/agent-devtools   # 직접 실행
```

## Commands (planned)

```bash
agent-devtools analyze <url>                        # 웹앱 역공학
agent-devtools network list                         # 네트워크 로그
agent-devtools network get <requestId>              # 요청 상세
agent-devtools intercept <pattern> --mock <json>    # 응답 목업
agent-devtools intercept <pattern> --delay <ms>     # 지연
agent-devtools intercept <pattern> --fail           # 차단
agent-devtools record <name>                        # 플로우 녹화
agent-devtools replay <name>                        # 재생 + 비교
agent-devtools diff <baseline>                      # 변화 감지
```
