# agent-devtools

Browser DevTools CLI for AI agents, built with Zig.

AI 에이전트를 위한 브라우저 개발자 도구 CLI. Chrome DevTools Protocol(CDP)을 직접 사용하여 기존 브라우저 도구들이 하지 못하는 네트워크 관찰, 웹앱 역공학, 플로우 녹화/재생을 제공합니다.

## Features

- **Network Observation** — 네트워크 요청/응답 캡처 및 필터링
- **Daemon Architecture** — 세션 기반 백그라운드 데몬, 다중 브라우저 동시 감시
- **Zero Dependencies** — Zig 단일 바이너리, 외부 런타임 불필요

### Coming Soon

- **Web App Reverse Engineering** — 트래픽 관찰로 API 스키마(OpenAPI) 자동 생성
- **Request Interception** — 요청/응답 가로채기, 목업, 지연 시뮬레이션
- **Flow Recording/Replay** — LLM 없이 기계적 비교, 토큰 비용 0
- **Baseline Diffing** — 시간축 디버깅, 변화 감지 및 보고

## Quick Start

```bash
# 페이지 열기 (Chrome 자동 시작)
agent-devtools open https://example.com

# 네트워크 요청 확인
agent-devtools network list

# API 요청만 필터링
agent-devtools network list api.example.com

# 다른 세션으로 동시 감시
agent-devtools --session=staging open https://staging.app.com

# 종료
agent-devtools close
```

## Architecture

```
┌─────────────┐     Unix Socket     ┌──────────────┐     WebSocket     ┌─────────┐
│  Zig CLI    │ ◄── JSON-line ────► │  Zig Daemon  │ ◄───────────────► │  Chrome  │
│ (즉시 종료)  │                     │ (백그라운드)   │                    │ (CDP)    │
└─────────────┘                     └──────────────┘                   └─────────┘
```

- 같은 바이너리가 CLI/데몬 두 역할 수행
- 세션별 독립 데몬으로 다중 브라우저 동시 감시
- Chrome DevTools Protocol로 직접 통신 (Playwright/Puppeteer 불필요)

## Build from Source

```bash
# Zig 0.15.2 필요
zig build
zig build test  # 244개 테스트
```

## License

MIT
