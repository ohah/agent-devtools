# agent-devtools

Browser DevTools CLI for AI agents, built with Zig.

## Project Info

- **GitHub**: ohah/agent-devtools
- **npm**: @ohah/agent-devtools
- **CLI 실행 명령**: agent-devtools
- **언어**: Zig 0.15.2
- **라이선스**: MIT
- **테스트**: 495개 (`zig build test`)
- **CLI 명령**: 90+개

## Architecture

```
┌─────────────┐     Unix Socket     ┌──────────────┐     WebSocket     ┌─────────┐
│  Zig CLI    │ ◄── JSON-line ────► │  Zig Daemon  │ ◄───────────────► │  Chrome  │
│ (즉시 종료)  │                     │ (백그라운드)   │                    │ (CDP)    │
└─────────────┘                     └──────────────┘                   └─────────┘
```

- 같은 바이너리가 CLI/데몬 두 역할: `AGENT_DEVTOOLS_DAEMON=1` 환경변수로 구분
- 세션 기반 다중 데몬: `--session=NAME`으로 독립적인 Chrome 인스턴스 운영
- DaemonContext 구조체로 세션 상태 통합 관리
- Unix Domain Socket (`{session}.sock`)으로 CLI ↔ Daemon 통신 (newline-delimited JSON)
- Chrome은 CDP(Chrome DevTools Protocol) WebSocket으로 제어
- `--port=PORT`로 기존 Chrome에 연결 시 `/json/version` discovery
- Target.createTarget → attachToTarget(flatten=true)으로 페이지 세션 획득
- Network.enable + Runtime.enable + Page.enable 상시 활성
- idle timeout 10분, Chrome 크래시 감지 (CDP 연속 실패 30회)

## Differentiation

agent-browser의 모든 핵심 기능을 포함하면서, 추가로:

1. **웹앱 역공학** — API 엔드포인트 자동 발견 + 의미 있는 파라미터명 + 응답 JSON 스키마 추론
2. **콘솔 로그 캡처** — 모든 JS 타입 정확 변환 (27개 RemoteObject 테스트)
3. **네트워크 인터셉트** — CDP Fetch 도메인으로 목업/차단/지연
4. **플로우 녹화/재생** — 기계적 비교로 변화 감지 (LLM 토큰 비용 0)
5. **네트워크 상세** — 응답 본문 포함 요청 상세, URL 필터링

## Implementation Status — 모든 Phase 완료 ✅

### ✅ Phase 1: CDP WebSocket 연결
- WebSocket 프레임 코덱 (RFC 6455, 106개 테스트)
- WebSocket Client (동적 버퍼 64KB→16MB)
- Chrome 스폰 + DevToolsActivePort 폴링
- CDP 메시지 파싱/직렬화 (67개 테스트)
- httpGet + discoverWsUrl (/json/version discovery)

### ✅ Phase 2: 네트워크 관찰
- network list/get/clear

### ✅ Phase 3: 웹앱 역공학
- API 요청 자동 식별 + 정적 리소스 제외
- URL → 패턴 변환 (/users/123 → /users/{userId})
- 응답 JSON 스키마 자동 추론
- analyze 명령어

### ✅ Phase 4: 네트워크 인터셉트
- CDP Fetch.enable + requestPaused 처리
- intercept mock/fail/delay/remove/list/clear

### ✅ Phase 5: 플로우 녹화/재생
- record/diff 명령어

### ✅ Phase 6: 데몬 아키텍처
- CLI/Daemon 같은 바이너리, DaemonContext 구조체
- Unix Domain Socket IPC, ensureDaemon
- 세션 기반 다중 데몬, idle timeout, Chrome 크래시 감지

### ✅ Snapshot + 페이지 조작 (agent-browser 동일)
- AX 트리 스냅샷 (트리 구조, parentId 기반 깊이 인덴테이션)
- @ref 시스템 (interactive/content roles)
- click/dblclick/fill/type/press/hover/scroll/scrollintoview/focus/drag/upload
- get text/html/value/attr, is visible/enabled/checked
- DOM.resolveNode + Runtime.callFunctionOn 방식

### ✅ 브라우저 제어
- screenshot/pdf
- back/forward/reload, eval, get url/title, wait
- tab list/new/close
- cookies list/set/clear, storage local/session
- set viewport/media/offline
- mouse move/down/up

### ✅ 콘솔 캡처
- console list/clear
- 모든 JS 타입 정확 변환 (27개 RemoteObject 테스트)

### ✅ 프록시 / 확장 / 설정파일 / 도메인 제한 / 인증 보관
- `--proxy`, `--proxy-bypass` — Chrome 프록시 설정
- `--extension` — Chrome 확장 로딩 (headless 자동 비활성)
- `agent-devtools.json` 또는 `~/.agent-devtools/config.json` 설정파일
- `--allowed-domains` — 도메인 제한 (네비게이션 차단)
- `--content-boundaries` — 콘텐츠 출력 경계 마커
- `auth save/login/list/show/delete` — 인증 프로필 저장 + 자동 로그인

### ✅ 성능 분석 / 영상 녹화 / 스크린샷 비교
- `video start/stop [path]` — 비디오 녹화 (FFmpeg, WebM/MP4)
- `trace start/stop [path]` — Chrome DevTools 트레이스
- `profiler start/stop [path]` — CPU 프로파일러
- `screenshot --annotate` — @ref 오버레이 스크린샷
- `diff-screenshot <baseline> [current]` — 스크린샷 픽셀 비교

## Project Structure

```
src/
├── main.zig          # CLI + 데몬 모드 + DaemonContext + 90+ 핸들러
├── daemon.zig        # 데몬 프로토콜, Unix Socket, ensureDaemon
├── websocket.zig     # WebSocket 프레임 코덱 + Client + Connection (RFC 6455)
├── cdp.zig           # CDP 메시지 파싱/직렬화 + writeJsonString
├── chrome.zig        # Chrome 프로세스 관리 (discovery, httpGet, launch)
├── network.zig       # 네트워크 이벤트 수집/필터링 (Collector)
├── analyzer.zig      # API 분석 + JSON 스키마 추론
├── interceptor.zig   # 네트워크 인터셉트 (InterceptorState, matchPattern)
├── recorder.zig      # 플로우 녹화/재생/비교
├── snapshot.zig      # AX 트리 스냅샷 + @ref + 페이지 조작 CDP 명령
├── png.zig           # PNG 디코딩 + 픽셀 비교 (diff-screenshot)
└── root.zig          # 모듈 루트

docs/
└── comparison.md     # agent-devtools vs agent-browser 비교

reference/            # 참조 코드 (gitignored)
├── agent-browser/    # vercel-labs/agent-browser (Rust)
└── cdp-protocol/     # ChromeDevTools/devtools-protocol (JSON spec)
```

## Testing

- Zig 내장 테스트 (`test` 블록, 소스 파일 내)
- `zig build test` → 495개
- 유닛 + 통합 (실제 Chrome E2E 확인)

### 테스트 분포

| 모듈 | 수 | 내용 |
|---|---|---|
| websocket.zig | 106 | RFC 6455 프레임, 마스킹, 핸드셰이크, Connection, URL 파싱 |
| main.zig | 105 | RemoteObject 변환, 도메인 제한, 콘텐츠 경계, isPlannedCommand, config, auth, video |
| cdp.zig | 67 | 메시지 파싱/직렬화, 에러 코드, 편의 명령, JSON 이스케이프 |
| chrome.zig | 47 | DevToolsActivePort, /json/version, URL 재작성, discovery, proxy, extensions |
| snapshot.zig | 37 | RefMap, buildSnapshot, extractBoxCenter |
| analyzer.zig | 35 | isApiRequest, pathToPattern, inferJsonSchema |
| daemon.zig | 23 | 소켓 경로, 직렬화, 파싱, writeJsonValue |
| png.zig | 22 | PNG 디코딩, 픽셀 비교, diff-screenshot |
| interceptor.zig | 17 | matchPattern, InterceptorState |
| network.zig | 11 | Collector lifecycle, filterByUrl |
| response_map.zig | 10 | ResponseMap |
| recorder.zig | 9 | saveRecording, loadRecording, diffRequests |
| root.zig | 1 | 모듈 참조 |

### 테스트 작성 원칙

- **반드시 공식 문서/RFC/스펙을 직접 참조하고 작성**
  - WebSocket: [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455)
  - CDP: [공식 문서](https://chromedevtools.github.io/devtools-protocol/) + `reference/cdp-protocol/json/`
- 경계값, 에러 경로, 라운드트립 테스트 필수
- `testing.allocator`로 메모리 누수 자동 감지
- 회귀 테스트 방지: 작성된 테스트는 삭제하지 않음

## Build & Run

```bash
zig build              # 빌드
zig build test         # 테스트 (495개)
./zig-out/bin/agent-devtools --help
```

## Commands — 전체 90+개

### Navigation
```bash
agent-devtools open <url>              # 페이지 열기 (데몬 자동 시작)
agent-devtools back                    # 뒤로
agent-devtools forward                 # 앞으로
agent-devtools reload                  # 새로고침
agent-devtools close                   # 브라우저 + 데몬 종료
```

### Snapshot + Interaction (@ref)
```bash
agent-devtools snapshot [-i]           # AX 트리 (-i: interactive only)
agent-devtools click @ref              # 클릭
agent-devtools dblclick @ref           # 더블클릭
agent-devtools fill @ref "text"        # 입력 (clear + type)
agent-devtools type @ref "text"        # 타이핑
agent-devtools press <key>             # 키 입력
agent-devtools hover @ref              # 호버
agent-devtools focus @ref              # 포커스
agent-devtools scroll <dir> [px]       # 스크롤
agent-devtools scrollintoview @ref     # 요소 스크롤
agent-devtools drag @from @to          # 드래그 앤 드롭
agent-devtools upload @ref <file>      # 파일 업로드
agent-devtools check @ref              # 체크박스 체크 (click)
agent-devtools uncheck @ref            # 체크박스 해제 (checked일 때만 click)
agent-devtools clear @ref              # 입력값 지우기 (Ctrl+A + Backspace)
agent-devtools selectall @ref          # 전체 선택 (Ctrl+A)
agent-devtools select @ref "value"     # 드롭다운 선택
agent-devtools dispatch @ref <event>   # DOM 이벤트 디스패치 (input, change, blur 등)
```

### Get Information
```bash
agent-devtools get url                 # 현재 URL
agent-devtools get title               # 페이지 제목
agent-devtools get text @ref           # 요소 텍스트
agent-devtools get html @ref           # innerHTML
agent-devtools get value @ref          # input 값
agent-devtools get attr @ref <name>    # 요소 속성
agent-devtools is visible @ref         # 가시성
agent-devtools is enabled @ref         # 활성화
agent-devtools is checked @ref         # 체크 상태
agent-devtools boundingbox @ref        # 바운딩 박스 {x, y, width, height}
agent-devtools styles @ref <prop>      # 계산된 CSS 스타일 값
```

### Screenshot & PDF
```bash
agent-devtools screenshot [--full] [path]  # PNG 스크린샷 (--full: 전체 페이지)
agent-devtools screenshot --annotate [path]  # @ref 오버레이 스크린샷
agent-devtools diff-screenshot <baseline> [current] [--threshold N] [--output path]
agent-devtools pdf [path]              # PDF 저장
```

### JavaScript
```bash
agent-devtools eval <expression>       # JS 실행
agent-devtools wait <ms>               # 대기
agent-devtools pause                   # JS 실행 일시정지 (Debugger.pause)
agent-devtools resume                  # JS 실행 재개 (Debugger.resume)
agent-devtools waitload [timeout_ms]   # 페이지 로드 완료 대기
```

### Clipboard
```bash
agent-devtools clipboard get           # 클립보드 읽기
agent-devtools clipboard set <text>    # 클립보드 쓰기
```

### Network (차별화)
```bash
agent-devtools network requests [--filter pattern] [--clear]  # 요청 목록/초기화
agent-devtools network get <requestId> # 요청 상세 (응답 본문)
agent-devtools network clear           # 수집 초기화
```

### Console (차별화)
```bash
agent-devtools console                 # 콘솔 로그 (no subcommand = list)
agent-devtools console --clear         # 초기화
```

### Analysis (차별화)
```bash
agent-devtools analyze                 # API 역공학 + 스키마
```

### Intercept (차별화)
```bash
agent-devtools intercept mock <pattern> <json>
agent-devtools intercept fail <pattern>
agent-devtools intercept delay <pattern> <ms>
agent-devtools intercept remove <pattern>
agent-devtools intercept list
agent-devtools intercept clear
```

### Recording (차별화)
```bash
agent-devtools record <name>           # 네트워크 상태 녹화
agent-devtools diff <name>             # 녹화 vs 현재 비교
```

### Tabs
```bash
agent-devtools tab list                # 탭 목록
agent-devtools tab new [url]           # 새 탭
agent-devtools tab close               # 탭 닫기
agent-devtools tab switch <index>      # 탭 전환 (0-based 인덱스)
agent-devtools window new [url]        # 새 창 열기 (탭 아님)
```

### Browser Settings
```bash
agent-devtools set viewport <w> <h>    # 뷰포트
agent-devtools set media <scheme>      # 다크/라이트 모드
agent-devtools set offline on/off      # 오프라인 모드
```

### Cookies & Storage
```bash
agent-devtools cookies [list]          # 쿠키 목록
agent-devtools cookies set <n> <v>     # 쿠키 설정
agent-devtools cookies clear           # 쿠키 삭제
agent-devtools storage local [key]     # localStorage
agent-devtools storage session [key]   # sessionStorage
```

### Mouse
```bash
agent-devtools mouse move <x> <y>
agent-devtools mouse down
agent-devtools mouse up
```

### HTTP Auth & Downloads
```bash
agent-devtools credentials <user> <pw> # HTTP basic auth 설정
agent-devtools download-path <dir>     # 다운로드 디렉토리 설정
```

### HAR Export
```bash
agent-devtools har [filename]          # 네트워크 데이터를 HAR 1.2로 내보내기
```

### State Management
```bash
agent-devtools state save <name>       # 쿠키 + localStorage + sessionStorage 저장
agent-devtools state load <name>       # 저장된 상태 복원
agent-devtools state list              # 저장된 상태 목록
```

### Page Injection
```bash
agent-devtools addstyle <css>          # <style> 태그 추가
```

### Performance (차별화)
```bash
agent-devtools video start [path]      # 비디오 녹화 시작 (FFmpeg 필요)
agent-devtools video stop              # 비디오 녹화 중지
agent-devtools trace start             # Chrome DevTools 트레이스 시작
agent-devtools trace stop [path]       # 트레이스 중지 + 저장
agent-devtools profiler start          # CPU 프로파일러 시작
agent-devtools profiler stop [path]    # 프로파일러 중지 + 저장
```

### Auth Vault (차별화)
```bash
agent-devtools auth save <name> --url <url> --username <user> --password <pass>
agent-devtools auth login <name>       # 자동 로그인 (URL 이동 + 필드 채우기 + 제출)
agent-devtools auth list               # 저장된 인증 프로필 목록
agent-devtools auth show <name>        # 인증 프로필 (비밀번호 마스킹)
agent-devtools auth delete <name>      # 인증 프로필 삭제
```

### Status & Session
```bash
agent-devtools status                  # 데몬 상태
agent-devtools --session=NAME          # 세션별 독립 데몬
agent-devtools --headed                # 브라우저 창 표시
agent-devtools --port=PORT             # 기존 Chrome 연결
agent-devtools --auto-connect          # 실행 중인 Chrome 자동 탐지 연결
agent-devtools --proxy=URL             # 프록시 서버
agent-devtools --proxy-bypass=LIST     # 프록시 바이패스 목록
agent-devtools --extension=PATH        # Chrome 확장 로딩
agent-devtools --allowed-domains=LIST  # 도메인 제한
agent-devtools --content-boundaries    # 콘텐츠 경계 마커
agent-devtools find-chrome             # Chrome 경로
```

### Config File
```
./agent-devtools.json 또는 ~/.agent-devtools/config.json
지원 필드: headed, proxy, proxy_bypass, user_agent, extensions
CLI 플래그가 설정파일 값을 덮어씀
```

### 구현 예정
```bash
(현재 모든 계획된 기능이 구현 완료됨)
```
