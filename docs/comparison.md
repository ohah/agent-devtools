# agent-devtools vs agent-browser 비교

## 목적 차이

| | agent-devtools | agent-browser |
|---|---|---|
| **핵심 목적** | 브라우저 DevTools CLI (네트워크/디버깅) | 브라우저 자동화 CLI (페이지 조작) |
| **강점** | 네트워크 분석, API 역공학, 요청 인터셉트 | AX 트리 스냅샷, @ref 시스템, 빠른 조작 |
| **언어** | Zig | Rust |
| **개발자** | ohah | Vercel |

## 명령어 비교

### Navigation

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 페이지 열기 | `open <url>` ✅ | `open <url>` ✅ |
| 뒤로 | ❌ | `back` |
| 앞으로 | ❌ | `forward` |
| 새로고침 | ❌ | `reload` |
| 닫기 | `close` ✅ | `close` ✅ |
| 기존 Chrome 연결 | `--port=PORT` ✅ | `connect PORT` |

### Network (agent-devtools 강점)

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 요청 목록 | `network list [pattern]` ✅ | `network requests [--filter]` |
| 요청 상세 (응답 본문 포함) | `network get <requestId>` ✅ | ❌ |
| 요청 초기화 | `network clear` ✅ | ❌ |
| 요청 가로채기 | `intercept` (Phase 4) | `network route` |
| 요청 차단 | `intercept --fail` (Phase 4) | `network route --abort` |
| 응답 목업 | `intercept --mock` (Phase 4) | `network route --body` |
| 라우트 제거 | (Phase 4) | `network unroute` |

### Console (agent-devtools 전용)

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 콘솔 로그 목록 | `console list` ✅ | ❌ |
| 콘솔 초기화 | `console clear` ✅ | ❌ |

### Snapshot & Interaction (agent-browser 강점)

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| AX 트리 스냅샷 | ❌ | `snapshot -i/-c/-d/-s` |
| 요소 클릭 | ❌ | `click @e1` |
| 텍스트 입력 | ❌ | `fill @e2 "text"` |
| 키 입력 | ❌ | `press Enter` |
| 호버 | ❌ | `hover @e1` |
| 체크박스 | ❌ | `check/uncheck @e1` |
| 드롭다운 선택 | ❌ | `select @e1 "value"` |
| 스크롤 | ❌ | `scroll down 500` |
| 드래그 앤 드롭 | ❌ | `drag @e1 @e2` |
| 파일 업로드 | ❌ | `upload @e1 file.pdf` |

### Get Information

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 요소 텍스트 | ❌ | `get text @e1` |
| innerHTML | ❌ | `get html @e1` |
| 입력값 | ❌ | `get value @e1` |
| 속성 | ❌ | `get attr @e1 href` |
| 페이지 제목 | ❌ | `get title` |
| 현재 URL | ❌ | `get url` |
| 요소 수 | ❌ | `get count ".item"` |
| 바운딩 박스 | ❌ | `get box @e1` |
| 스타일 | ❌ | `get styles @e1` |

### Screenshot & Media

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 스크린샷 | ❌ | `screenshot [path]` |
| 풀페이지 스크린샷 | ❌ | `screenshot --full` |
| PDF | ❌ | `pdf output.pdf` |
| 비디오 녹화 | ❌ | `record start/stop` |

### Wait

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 요소 대기 | ❌ | `wait @e1` |
| 시간 대기 | ❌ | `wait 2000` |
| 텍스트 대기 | ❌ | `wait --text "..."` |
| URL 대기 | ❌ | `wait --url "..."` |
| 네트워크 idle | ❌ | `wait --load networkidle` |
| JS 조건 | ❌ | `wait --fn "..."` |

### Browser Settings

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 뷰포트 설정 | ❌ | `set viewport` |
| 디바이스 에뮬레이션 | ❌ | `set device` |
| 지오로케이션 | ❌ | `set geo` |
| 오프라인 모드 | ❌ | `set offline` |
| HTTP 헤더 | ❌ | `set headers` |
| 인증 | ❌ | `set credentials` |
| 다크 모드 | ❌ | `set media` |

### Cookies & Storage

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 쿠키 조회 | ❌ | `cookies` |
| 쿠키 설정 | ❌ | `cookies set` |
| 쿠키 삭제 | ❌ | `cookies clear` |
| localStorage | ❌ | `storage local` |
| sessionStorage | ❌ | `storage session` |

### Tabs & Frames

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 탭 목록 | ❌ | `tab` |
| 새 탭 | ❌ | `tab new` |
| 탭 전환 | ❌ | `tab N` |
| 탭 닫기 | ❌ | `tab close` |
| iframe 전환 | ❌ | `frame "#iframe"` |

### Daemon & Session

| 명령 | agent-devtools | agent-browser |
|---|---|---|
| 세션 지정 | `--session=NAME` ✅ | `--session NAME` |
| headed 모드 | `--headed` ✅ | `--headed` |
| 데몬 상태 | `status` ✅ | ❌ |
| idle timeout | 10분 자동 종료 ✅ | 설정 가능 |
| Chrome 경로 | `find-chrome` ✅ | `--executable-path` |

### agent-devtools 전용 (차별화 기능)

| 명령 | 상태 | 설명 |
|---|---|---|
| `network get <requestId>` | ✅ 구현 | 응답 본문 포함 상세 정보 |
| `console list/clear` | ✅ 구현 | 콘솔 로그 캡처 |
| `status` | ✅ 구현 | 데몬 상태 확인 |
| `analyze <url>` | Phase 3 | 웹앱 API 스키마 자동 생성 |
| `intercept` | Phase 4 | 요청/응답 조작, 목업, 지연 |
| `record/replay/diff` | Phase 5 | 플로우 녹화/재생, 변화 감지 |

## 토큰 효율성 비교

| | agent-devtools | agent-browser |
|---|---|---|
| 도구 스키마 오버헤드 | 0 (CLI) | 0 (CLI) |
| 네트워크 로그 출력 | JSON (수십 토큰) | ❌ 없음 |
| 스냅샷 | ❌ 미구현 | ~100-1000 토큰 |
| 스크린샷 | ❌ 미구현 | ~1000+ 토큰 (비전) |

## 아키텍처 비교

| | agent-devtools | agent-browser |
|---|---|---|
| 언어 | Zig 0.15.2 | Rust |
| Chrome 연결 | CDP WebSocket 직접 | CDP WebSocket 직접 |
| IPC | Unix Domain Socket (JSON-line) | Unix Domain Socket (JSON-line) |
| 데몬 모드 | 같은 바이너리 + 환경변수 | 같은 바이너리 + 환경변수 |
| 멀티 세션 | `--session=NAME` | `--session NAME` |
| Chrome 탐색 | DevToolsActivePort 폴링 | DevToolsActivePort + stderr 폴백 |
| HTTP discovery | raw TCP httpGet | reqwest 라이브러리 |

## 결론

- **agent-browser**는 브라우저 자동화에 특화 — 페이지 조작, 스냅샷, 테스트 자동화
- **agent-devtools**는 브라우저 디버깅에 특화 — 네트워크 분석, 콘솔 캡처, API 역공학
- 두 도구는 **경쟁이 아니라 보완 관계** — 함께 사용하면 자동화 + 디버깅을 모두 커버
- agent-devtools의 차별화는 Phase 3-5 (analyze, intercept, record/replay/diff)에서 완성
