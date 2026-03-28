# agent-devtools

**Browser DevTools CLI for AI agents, built with Zig.**

AI 에이전트를 위한 브라우저 개발자 도구 CLI

[![npm](https://img.shields.io/npm/v/@ohah/agent-devtools)](https://www.npmjs.com/package/@ohah/agent-devtools)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-495-brightgreen)]()
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange)]()

A single native binary that controls Chrome via CDP (Chrome DevTools Protocol). Zero dependencies. No Playwright, no Puppeteer, no Node.js runtime required for the daemon.

**What makes it different:** Beyond standard browser automation, agent-devtools provides **network observation**, **API reverse engineering**, **request interception**, **flow recording/diffing**, and **console capture** -- capabilities not found in other browser CLIs.

## Installation

### npm (recommended)

```bash
npm install -g @ohah/agent-devtools
```

### Project-level dependency

```bash
npm install @ohah/agent-devtools
```

### Skills (for AI agents)

Add the skill to your AI coding assistant (Claude Code, Codex, Cursor, Gemini CLI, etc.):

```bash
npx skills add ohah/agent-devtools
```

### Build from source

Requires [Zig 0.15.2](https://ziglang.org/download/):

```bash
git clone https://github.com/ohah/agent-devtools
cd agent-devtools
zig build
zig build test    # 382 tests
```

The binary is at `./zig-out/bin/agent-devtools`.

## Quick Start

```bash
# Navigate to a page (Chrome starts automatically)
agent-devtools open https://example.com

# Get the accessibility tree with interactive element refs
agent-devtools snapshot -i
# Output:
# - textbox "Email" [ref=e1]
# - textbox "Password" [ref=e2]
# - button "Sign In" [ref=e3]

# Interact using refs
agent-devtools fill @e1 "user@example.com"
agent-devtools fill @e2 "password123"
agent-devtools click @e3

# Re-snapshot after page changes (refs are invalidated on navigation)
agent-devtools snapshot -i

# Take a screenshot
agent-devtools screenshot login-result.png

# Close browser + daemon
agent-devtools close
```

### Network observation workflow

```bash
agent-devtools open https://app.example.com
agent-devtools network list              # See all requests
agent-devtools network list api          # Filter by URL pattern
agent-devtools network get <requestId>   # Full request/response with body
agent-devtools analyze                   # API reverse engineering + JSON schema
agent-devtools har export.har            # Export as HAR 1.2
```

### Interactive mode

```bash
agent-devtools --interactive
> open https://example.com
< {"success":true}
> snapshot -i
< {"success":true,"data":"- button \"Submit\" [ref=e1]\n"}
> click @e1
< {"success":true}
```

### Debug mode

Pair `--debug` with `--interactive` -- action commands automatically include triggered API requests and URL changes:

```bash
agent-devtools --interactive --debug
> click @e3
< {"success":true,"debug":{"new_requests":[{"url":"/api/login","method":"POST","status":200}],"url_changed":true}}
```

## Commands

### Navigation

| Command | Description |
|---------|-------------|
| `open <url>` | Navigate to URL (aliases: `navigate`, `goto`) |
| `back` / `forward` | History navigation |
| `reload` | Reload page |
| `close` | Close browser + daemon |

### Snapshot + Interaction

| Command | Description |
|---------|-------------|
| `snapshot [-i]` | Accessibility tree (`-i` for interactive only) |
| `click @ref` | Click element |
| `dblclick @ref` | Double-click |
| `tap @ref` | Touch tap |
| `fill @ref "text"` | Clear + type |
| `type @ref "text"` | Type (no clear) |
| `press <key>` | Press key (Enter, Tab, Control+a) |
| `hover @ref` | Hover |
| `focus @ref` | Focus |
| `select @ref "val"` | Select dropdown |
| `check` / `uncheck @ref` | Checkbox |
| `clear @ref` | Clear input (Ctrl+A + Backspace) |
| `selectall @ref` | Select all text |
| `scroll <dir> [px]` | Scroll (up/down/left/right) |
| `scrollintoview @ref` | Scroll element into view |
| `drag @from @to` | Drag and drop |
| `upload @ref <file>` | Upload file |
| `dispatch @ref <event>` | Dispatch DOM event |

### Get Information

| Command | Description |
|---------|-------------|
| `get text @ref` | Element text content |
| `get html @ref` | innerHTML |
| `get value @ref` | Input value |
| `get attr @ref <name>` | Element attribute |
| `get url` / `get title` | Page URL / title |
| `is visible @ref` | Check visibility |
| `is enabled @ref` | Check if enabled |
| `is checked @ref` | Check if checked |
| `boundingbox @ref` | Bounding box `{x, y, width, height}` |
| `styles @ref <prop>` | Computed CSS value |

### Find Elements

| Command | Description |
|---------|-------------|
| `find role <role>` | Find by ARIA role |
| `find text "Submit"` | Find by text content |
| `find label "Email"` | Find by label |

### Capture + Performance

| Command | Description |
|---------|-------------|
| `screenshot [path]` | PNG screenshot |
| `screenshot --annotate` | Screenshot with @ref labels overlay |
| `diff-screenshot <a> [b]` | Pixel diff between screenshots |
| `pdf [path]` | Save as PDF |
| `eval <js>` | Run JavaScript |
| `video start/stop [path]` | Record video (requires FFmpeg) |
| `trace start/stop [path]` | Chrome DevTools trace |
| `profiler start/stop [path]` | CPU profiler |

### Network (unique to agent-devtools)

| Command | Description |
|---------|-------------|
| `network list [pattern]` | List requests (filter by URL) |
| `network get <id>` | Full request/response with body |
| `network clear` | Clear collected data |
| `analyze` | API reverse engineering + JSON schema |
| `har [filename]` | Export HAR 1.2 |

### Intercept (unique to agent-devtools)

| Command | Description |
|---------|-------------|
| `intercept mock <pattern> <json>` | Mock response |
| `intercept fail <pattern>` | Block request |
| `intercept delay <pattern> <ms>` | Delay request |
| `intercept remove <pattern>` | Remove rule |
| `intercept list` / `clear` | List / clear all rules |

### Console (unique to agent-devtools)

| Command | Description |
|---------|-------------|
| `console list` | View console messages |
| `console clear` | Clear console |
| `errors [clear]` | View / clear JS errors |

### Recording (unique to agent-devtools)

| Command | Description |
|---------|-------------|
| `record <name>` | Save current network state |
| `diff <name>` | Compare current vs recorded |
| `replay <name>` | Navigate + diff automation |

### Wait

| Command | Description |
|---------|-------------|
| `wait <ms>` | Wait milliseconds |
| `waitforloadstate [ms]` | Wait for page load |
| `waitfor network <pat> [ms]` | Wait for network request |
| `waitfor console <pat> [ms]` | Wait for console message |
| `waitfor error [ms]` | Wait for JS error |
| `waitdownload [ms]` | Wait for download |

### Tabs + Windows

| Command | Description |
|---------|-------------|
| `tab list` | List open tabs |
| `tab new [url]` | Open new tab |
| `tab close` | Close current tab |
| `tab switch <n>` | Switch to tab (0-based) |
| `window new [url]` | Open new window |

### Cookies + Storage

| Command | Description |
|---------|-------------|
| `cookies [list]` | List cookies |
| `cookies set <name> <val>` | Set cookie |
| `cookies clear` | Clear cookies |
| `storage local [key]` | Get localStorage |
| `storage session [key]` | Get sessionStorage |

### State Management

| Command | Description |
|---------|-------------|
| `state save <name>` | Save cookies + localStorage + sessionStorage |
| `state load <name>` | Restore saved state |
| `state list` | List saved states |

### Auth Vault

| Command | Description |
|---------|-------------|
| `auth save <name> --url <url> --username <user> --password <pw>` | Store credentials |
| `auth login <name>` | Auto-login (navigate + fill + submit) |
| `auth list` / `show` / `delete <name>` | Manage vault |

### Browser Settings

| Command | Description |
|---------|-------------|
| `set viewport <w> <h>` | Viewport size |
| `set device "iPhone 14"` | Device emulation |
| `set media dark` / `set offline on` | Color scheme, offline mode |
| `set timezone` / `set locale` | Timezone, locale |
| `set useragent` / `set geolocation` | User agent, geolocation |
| `set headers '{"X":"Y"}'` | Extra HTTP headers |
| `set ignore-https-errors` / `set permissions` | HTTPS errors, permissions |

### Mouse, Clipboard, Dialog, and More

| Command | Description |
|---------|-------------|
| `mouse move/down/up` | Mouse control |
| `clipboard get/set` | Clipboard access |
| `dialog accept/dismiss/info` | JS dialog handling |
| `credentials <user> <pw>` | HTTP basic auth |
| `download-path <dir>` | Download directory |
| `addstyle <css>` | Inject CSS |
| `pause` / `resume` | JS execution control |
| `status` / `find-chrome` | Daemon status, Chrome path |

For the full command reference with examples, see [SKILL.md](SKILL.md).

## Authentication

### State persistence

Save and restore login sessions across browser restarts:

```bash
# Login once
agent-devtools open https://app.example.com/login
agent-devtools snapshot -i
agent-devtools fill @e1 "user@example.com"
agent-devtools fill @e2 "password"
agent-devtools click @e3

# Save authenticated state
agent-devtools state save myapp

# Restore later (cookies + localStorage + sessionStorage)
agent-devtools state load myapp
agent-devtools open https://app.example.com/dashboard
```

### Auth vault

Store credentials locally for auto-login:

```bash
# Save credentials
agent-devtools auth save github --url https://github.com/login --username user --password pass

# Auto-login (navigates, fills, submits)
agent-devtools auth login github
```

## Sessions

Run multiple isolated browser instances simultaneously:

```bash
# Different sessions with independent Chrome instances
agent-devtools --session=prod open https://app.com
agent-devtools --session=staging open https://staging.app.com

# Each session has its own cookies, storage, and navigation history
agent-devtools --session=prod network list
agent-devtools --session=staging network list

# Check daemon status
agent-devtools --session=prod status
```

### Connect to existing Chrome / Electron

```bash
# Auto-discover running Chrome (checks user data dirs + common ports)
agent-devtools --auto-connect snapshot -i

# Or specify port manually
agent-devtools --port=9222 snapshot -i

# Electron apps (launched with --remote-debugging-port)
/Applications/Slack.app/Contents/MacOS/Slack --remote-debugging-port=9222
agent-devtools --port=9222 snapshot -i
```

## Configuration

Create `agent-devtools.json` in your project root or `~/.agent-devtools/config.json` for user-level defaults.

| Flag / Variable | Description |
|------|-------------|
| `--session=NAME` | Isolated session name |
| `--headed` | Show browser window (not headless) |
| `--port=PORT` | Connect to existing Chrome by port |
| `--auto-connect` | Auto-discover running Chrome/Electron |
| `--interactive` | Persistent stdin/stdout session |
| `--debug` | Include network/URL changes in responses |
| `--proxy <url>` | Proxy server |
| `--proxy-bypass <list>` | Proxy bypass list |
| `--extension <path>` | Load Chrome extension |
| `--allowed-domains <list>` | Restrict navigation domains |
| `--content-boundaries` | Wrap output in boundary markers |
| `AGENT_DEVTOOLS_SESSION` | Session name (env var) |
| `AGENT_DEVTOOLS_DAEMON=1` | Run in daemon mode (env var) |

## Security

- **Domain allowlist** -- Restrict navigation to trusted domains: `--allowed-domains "example.com,*.example.com"`
- **Content boundaries** -- Wrap output in delimiters so LLMs can distinguish tool output from untrusted page content: `--content-boundaries`
- **Proxy support** -- Route all traffic through a proxy: `--proxy http://localhost:8080`

## Interactive Mode (Pipe Mode)

Use `--interactive` for persistent stdin/stdout sessions, ideal for AI agent integrations and CI pipelines:

```bash
agent-devtools --interactive
> open https://example.com
< {"success":true}
< {"event":"network","url":"https://example.com/","method":"GET","status":200}
> snapshot -i
< {"success":true,"data":"- button \"Submit\" [ref=e1]\n"}
> close
< {"success":true}
```

- One command per line, JSON responses
- Network and console events stream automatically
- Pair with `--debug` for action-triggered API request tracking

## Architecture

```
┌─────────────┐    Unix Socket     ┌──────────────┐    WebSocket     ┌─────────┐
│   Zig CLI   │ ◄─ JSON-line ───► │  Zig Daemon  │ ◄──────────────► │  Chrome  │
│ (stateless) │                    │ (background) │                   │  (CDP)   │
└─────────────┘                    └──────────────┘                  └─────────┘
```

- **Single binary** -- Same executable acts as both CLI and daemon (`AGENT_DEVTOOLS_DAEMON=1`)
- **Session-based** -- Each `--session` gets its own daemon + Chrome instance
- **Unix Domain Socket** -- CLI communicates with daemon via `{session}.sock` (newline-delimited JSON)
- **Direct CDP** -- No Playwright/Puppeteer intermediary. WebSocket to Chrome's DevTools protocol
- **Auto-lifecycle** -- Daemon starts on first command, idle timeout after 10 minutes
- **Crash detection** -- Monitors CDP health (30 consecutive failures triggers shutdown)
- **Multi-threaded** -- Concurrent event processing for network, console, and page events

## Comparison with agent-browser

agent-devtools includes all core browser automation features from [agent-browser](https://github.com/vercel-labs/agent-browser), plus additional DevTools capabilities:

| Feature | agent-browser | agent-devtools |
|---------|:---:|:---:|
| Page navigation | Yes | Yes |
| AX tree snapshot + @ref | Yes | Yes |
| Click, fill, type, press | Yes | Yes |
| Screenshot / PDF | Yes | Yes |
| Cookies / storage | Yes | Yes |
| Tab management | Yes | Yes |
| Device emulation | Yes | Yes |
| Eval JavaScript | Yes | Yes |
| Network observation | Yes | Yes |
| HAR export | Yes | Yes |
| Console capture | Yes | Yes |
| **API reverse engineering** | No | **Yes (analyze + JSON schema)** |
| **Request interception** | Route (mock/abort) | **intercept (mock/fail/delay)** |
| **Flow recording/diffing** | No | **Yes (record + diff)** |
| **Debug mode (--debug)** | No | **Yes (action → API correlation)** |
| **Event wait (waitfor)** | No | **Yes (network/console/error/dialog)** |
| Runtime | Rust | Zig |
| Dependencies | npm + Rust binary | Zero (single Zig binary) |

## Platforms

| Platform | Status |
|----------|--------|
| macOS ARM64 (Apple Silicon) | Supported |
| macOS x64 | Supported |
| Linux x64 | Supported |
| Linux ARM64 | Supported |

## License

[MIT](LICENSE)
