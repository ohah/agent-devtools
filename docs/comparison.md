# agent-devtools vs agent-browser 비교

## 개요

| | agent-devtools | agent-browser |
|---|---|---|
| **언어** | Zig | Rust + Node.js |
| **배포** | 단일 바이너리 (~2MB) | npm 패키지 |
| **스레딩** | 멀티스레드 (워커 풀) | tokio async |
| **통신** | Unix Socket / TCP (Windows) | Unix Socket / TCP (Windows) |
| **AX Tree** | 100% 동일 (diff 0줄 검증) | 기준 구현 |
| **테스트** | 495개 유닛 | 44 E2E |

## 동일한 기능

두 도구 모두 지원하는 기능:

- AX 트리 스냅샷 (@ref 시스템, cursor:pointer 감지, ARIA 속성)
- 페이지 조작 (click, fill, type, press, hover, check, select, drag, upload)
- 정보 조회 (get text/html/value/attr, is visible/enabled/checked)
- 스크린샷/PDF
- JavaScript 실행 (eval)
- 탭 관리
- 쿠키/스토리지
- 디바이스 에뮬레이션
- 다이얼로그 처리
- HAR 내보내기
- 상태 저장/복원
- 시맨틱 쿼리 (find role/text/label)
- 상주 모드 (이벤트 스트리밍)
- 봇 감지 우회
- 멀티 세션
- 기존 Chrome 연결 + 자동 발견 (--auto-connect)
- 영상 녹화 (video start/stop)
- 트레이스/프로파일러 (trace/profiler start/stop)
- annotate 스크린샷 (screenshot --annotate)
- 스크린샷 비교 (diff-screenshot)
- 프록시 (--proxy, --proxy-bypass)
- 브라우저 확장 (--extension)
- 설정 파일 (agent-devtools.json / config.json)
- 인증 볼트 (auth save/login/list/show/delete)
- 콘텐츠 바운더리 (--content-boundaries)
- 도메인 제한 (--allowed-domains)

## agent-devtools만의 기능

| 기능 | 설명 |
|---|---|
| `analyze` | API 엔드포인트 자동 발견 + JSON 스키마 추론 |
| `intercept delay` | 네트워크 지연 시뮬레이션 (agent-browser는 mock/abort만) |
| `waitfor network/console/error/dialog` | 이벤트 기반 대기 (condition variable) |
| `--debug` 모드 | 액션 후 API 요청/에러/URL 변경 자동 감지 |
| `record`/`diff`/`replay` | 네트워크 상태 녹화/비교/재생 |
| `dispatch` | DOM 이벤트 직접 발송 |
| `pause`/`resume` | JS 실행 일시정지/재개 |
| `waitdownload` | 다운로드 완료 대기 |
| exit code 1 | interactive 모드 실패 시 (CI 연동) |

## agent-browser만의 기능

| 기능 | 설명 |
|---|---|
| iOS 시뮬레이터 | `-p ios` (Appium) |
| 스트리밍 | `stream enable` (WebSocket 서버) |
| 배치 실행 | `batch` (JSON 배열 일괄 실행) |

## 스냅샷 동일성 검증

4개 사이트에서 실제 비교 (diff 0줄):

| 사이트 | agent-browser | agent-devtools | diff |
|---|---|---|---|
| Google | 18줄 | 18줄 | **0** |
| httpbin (폼) | 16줄 | 16줄 | **0** |
| YouTube | 14줄 | 14줄 | **0** |
| GitHub (142줄) | 142줄 | 142줄 | **0** |

## 포지셔닝

- **일반 자동화**: 동일 (같은 CDP, 같은 AX tree)
- **웹앱 디버깅/역공학**: agent-devtools가 우위 (analyze, intercept, waitfor, --debug)
- **설치/배포**: agent-devtools가 간편 (단일 바이너리, 의존성 없음)
- **iOS/배치/스트리밍**: agent-browser가 우위
