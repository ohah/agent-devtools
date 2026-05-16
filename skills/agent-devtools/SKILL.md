---
name: agent-devtools
description: Browser automation and web debugging CLI for AI agents. Use when the user needs to interact with websites, fill forms, click buttons, take screenshots, extract data, test web apps, inspect network traffic, reverse-engineer APIs, intercept requests, record/diff network flows, measure Core Web Vitals, or introspect React apps (component tree, props/hooks/state, render profiling, Suspense). Triggers include requests to "open a website", "fill out a form", "click a button", "take a screenshot", "scrape data", "test this web app", "login to a site", "inspect network requests", "find API endpoints", "mock an API", "measure web vitals / performance", "inspect React components", or any task requiring programmatic web interaction.
allowed-tools: Bash(agent-devtools:*), Bash(./zig-out/bin/agent-devtools:*)
---

# Browser Automation with agent-devtools

Controls Chrome/Chromium via CDP. Browser persists via background daemon across commands.

## Core Workflow

1. `agent-devtools open <url>` — navigate
2. `agent-devtools snapshot -i` — get interactive element refs
3. Use refs (`@e1`, `@e2`) to interact
4. Re-snapshot after navigation or DOM changes

```bash
agent-devtools open https://example.com/form
agent-devtools snapshot -i
# Output:
# - textbox "Email" [ref=e1]
# - textbox "Password" [ref=e2]
# - button "Submit" [ref=e3]

agent-devtools fill @e1 "user@example.com"
agent-devtools fill @e2 "password123"
agent-devtools click @e3
agent-devtools snapshot -i  # Re-snapshot after submit
```

**Refs are invalidated on page changes.** Always re-snapshot after clicking links, submitting forms, or loading dynamic content.

## Commands

### Navigation
```
open <url>          Navigate (aliases: navigate, goto)
back / forward      History navigation
reload              Reload page
pushstate <url>     SPA client-side navigation (history.pushState)
close               Close browser + daemon
url / title         Get current URL / page title
```

### Snapshot + Interaction
```
snapshot -i         Interactive elements only (recommended)
snapshot -u         Include link href URLs (combine: snapshot -i -u)
snapshot            Full accessibility tree
click @e1           Click
dblclick @e1        Double-click
tap @e1             Touch tap
fill @e1 "text"     Clear + type
type @e1 "text"     Type (no clear)
press Enter         Press key
hover / focus @e1   Hover or focus
select @e1 "val"    Select dropdown
check / uncheck @e1 Checkbox
scroll down 500     Scroll (up/down/left/right)
drag @e1 @e2        Drag and drop
```

### Get Information
```
get text/html/value @e1    Element content
get attr @e1 href          Attribute value
get url / get title        Page info
is visible/enabled/checked @e1
boundingbox @e1            Bounding box {x,y,w,h}
styles @e1 color           Computed CSS value
```

### Find Elements (without snapshot)
```
find role button           Find by ARIA role
find text "Submit"         Find by text content
find label "Email"         Find by label
```

### Capture & Performance
```
screenshot [path]           PNG screenshot
screenshot --annotate [path] Screenshot with @ref labels overlay
diff-screenshot <baseline> [current] [--threshold N] [--output path]
pdf [path]                  Save as PDF
eval <js>                   Run JavaScript
video start/stop [path]     Record video (requires FFmpeg)
trace start/stop [path]     Chrome DevTools trace
profiler start/stop [path]  CPU profiler
vitals [url]                Core Web Vitals (LCP/CLS/FCP/INP) + TTFB
addscript <js>              Run script on every new page (returns identifier)
removeinitscript <id>       Remove a script added by addscript/--init-script
```

### React Introspection (requires `--enable=react-devtools` at launch)
```
react tree                  Component tree (JSON)
react inspect <fiberId>     Fiber props / hooks / state
react renders start         Begin render profiling
react renders stop          Profile (fps, mounts, re-renders, per-component)
react suspense [--only-dynamic]  Suspense boundary analysis
```
Launch the daemon with the hook installed before the page boots React:
```bash
agent-devtools --enable=react-devtools open https://myapp.com
agent-devtools react tree
```

### Network (unique feature)
```
network list [pattern]      List requests (filter by URL)
network get <id>            Full request/response with body
analyze                     API reverse engineering + schema
intercept mock "/api" '{}'  Mock response
intercept fail "/api"       Block request
intercept delay "/api" 3000 Delay request
  ... [--resource-type <csv>]  Limit rule to CDP resourceType (Document/XHR/Script/...)
har [file]                  Export HAR 1.2
```

### Wait
```
wait <ms>                   Wait milliseconds
waitforloadstate [ms]       Wait for page load
waitfor network <pat> [ms]  Wait for network request
waitfor console <pat> [ms]  Wait for console message
waitfor error [ms]          Wait for JS error
waitdownload [ms]           Wait for download
```

### Settings
```
set viewport 1920 1080     Viewport size
set media dark             Color scheme
set timezone Asia/Seoul    Timezone
set locale ko-KR           Locale
set device "iPhone 14"     Device emulation
set useragent "..."        User agent
set geolocation 37.5 127   Geolocation
set headers '{"X":"Y"}'    HTTP headers
set offline on             Offline mode
set ignore-https-errors    Ignore cert errors
set permissions grant geo  Grant permission
```

### Storage & State
```
cookies [list/set/get/clear]   Cookies
cookies set --curl <file>      Bulk import (JSON / cURL dump / Cookie header)
storage local [key]            localStorage
state save/load/list           Save/restore cookies + storage
credentials <user> <pass>      HTTP basic auth
```

### Tabs & Console
```
tab list / new / close / switch <n>
console list / clear
errors [clear]
dialog accept/dismiss/info  (alert/beforeunload auto-dismissed by default)
```

### Recording
```
record <name>    Save network state
diff <name>      Compare current vs recorded
replay <name>    Navigate + diff
```

### Auth Vault
```
auth save <name> --url <url> --username <user> --password <pass>
auth login <name>           Auto-login (navigate + fill + submit)
auth list / show / delete <name>
```

### Security & Config
```
--proxy <url>               Proxy server
--proxy-bypass <list>       Proxy bypass list
--extension <path>          Load Chrome extension
--allowed-domains <list>    Restrict navigation domains
--content-boundaries        Wrap output with boundary markers
--no-auto-dialog            Disable alert/beforeunload auto-dismiss
--init-script=<path>        Run a script before page JS (repeatable)
--enable=react-devtools     Install React DevTools hook (enables `react` cmds)
--auto-connect              Auto-discover running Chrome/Electron
agent-devtools.json         Config file (project or ~/.agent-devtools/config.json)
```

## Interactive Mode

`--interactive` for persistent sessions. Events stream automatically.

```bash
agent-devtools --interactive
> open https://example.com
< {"success":true}
< {"event":"network","url":"https://example.com/","method":"GET","status":200}
> snapshot -i
< {"success":true,"data":"- button \"Submit\" [ref=e1]\n"}
```

## Debug Mode

`--debug` with `--interactive` — action commands automatically include triggered API requests and URL changes. Static resources filtered.

```bash
agent-devtools --interactive --debug
> click @e3
< {"success":true,"debug":{"new_requests":[{"url":"/api/login","method":"POST","status":200}],"url_changed":true}}
```

## Deep-Dive Documentation

For detailed reference, see `references/`:
- [commands.md](references/commands.md) — Full command reference
- [debug-mode.md](references/debug-mode.md) — Debug mode details
- [patterns.md](references/patterns.md) — Common automation patterns

## Ready-to-Use Templates

Copy and customize these shell scripts from `templates/`:
- [form-automation.sh](templates/form-automation.sh) — Form fill + submit
- [authenticated-session.sh](templates/authenticated-session.sh) — Login + state persistence
- [api-discovery.sh](templates/api-discovery.sh) — API reverse engineering workflow
