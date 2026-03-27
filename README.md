# agent-devtools

Browser DevTools CLI for AI agents, built with Zig.

AI 에이전트를 위한 브라우저 개발자 도구 CLI. Chrome DevTools Protocol(CDP)을 직접 사용하여 기존 브라우저 도구들이 하지 못하는 네트워크 관찰, 웹앱 역공학, 플로우 녹화/재생을 제공합니다.

## Features (planned)

- **Network Observation** — 네트워크 요청/응답 캡처 및 요약
- **Web App Reverse Engineering** — 트래픽 관찰로 API 스키마(OpenAPI) 자동 생성
- **Request Interception** — 요청/응답 가로채기, 목업, 지연 시뮬레이션
- **Flow Recording/Replay** — LLM 없이 기계적 비교, 토큰 비용 0
- **Baseline Diffing** — 시간축 디버깅, 변화 감지 및 보고

## Architecture

```
Zig CLI ── Unix Socket ──> Zig Daemon ── WebSocket ──> Chrome (CDP)
                                │
                           Network observation/intercept
                           API schema collection
                           Flow recording/comparison
                           Change detection
```

## Install

```bash
npm install -g @ohah/agent-devtools
```

## Usage

```bash
agent-devtools analyze https://some-app.com
agent-devtools network list
agent-devtools intercept "*/api/*" --mock '{}'
agent-devtools record login-flow
agent-devtools replay login-flow
agent-devtools diff baseline.json
```

## Build from source

```bash
zig build
```

## License

MIT
