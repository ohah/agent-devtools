# Full Command Reference

## Navigation
| Command | Description |
|---|---|
| `open <url>` | Navigate (aliases: navigate, goto) |
| `back` / `forward` / `reload` | History navigation |
| `pushstate <url>` | SPA client-side navigation (history.pushState) |
| `close` | Close browser + daemon |
| `url` / `title` | Get current URL / title |
| `content` / `setcontent <html>` | Get/set page HTML |
| `bringtofront` | Bring window to front |

## Snapshot + Interaction
| Command | Description |
|---|---|
| `snapshot -i` | Interactive elements only (recommended) |
| `snapshot -u` | Include link href URLs (combine: `-i -u`) |
| `snapshot -d <n>` | Limit output tree depth |
| `snapshot -s <sel>` | Only the subtree under a CSS selector |
| `snapshot -c / -C` | Compact / cursor (accepted; output already compact+cursor) |
| `snapshot` | Full accessibility tree |
| `find role/text/label/placeholder/alt/title/testid <v> [action]` | Locator query (+ optional click/fill/… action) |
| `find first/last/nth <role> <v> [--name N] [--exact]` | Ordinal locator |
| `click` / `dblclick` / `tap @ref` | Click / double-click / touch tap |
| `fill @ref "text"` | Clear + type |
| `type @ref "text"` | Type without clearing |
| `press <key>` | Press key (Enter, Tab, Escape) |
| `keydown` / `keyup <key>` | Single key event (hold/release modifier) |
| `keyboard type\|inserttext <text>` | Type into / insert into focused element |
| `swipe <dir> [distance]` | Touch swipe (up/down/left/right) |
| `hover` / `focus @ref` | Hover / focus |
| `check` / `uncheck @ref` | Checkbox |
| `select @ref "val"` | Dropdown |
| `clear` / `selectall @ref` | Clear / select all text |
| `scroll <dir> [px]` | Scroll (up/down/left/right) |
| `scroll to <x> <y>` | Scroll to coordinates |
| `scrollintoview @ref` | Scroll element into view |
| `drag @from @to` | Drag and drop |
| `upload @ref <file>` | Upload file |
| `dispatch @ref <event>` | Dispatch DOM event |
| `highlight @ref` | Highlight with overlay |

## Get Information
| Command | Description |
|---|---|
| `get text/html/value @ref` | Element content |
| `get attr @ref <name>` | Attribute value |
| `get count <css>` | Number of elements matching a CSS selector |
| `get cdp-url` | Connected CDP WebSocket URL |
| `is visible/enabled/checked @ref` | State check |
| `boundingbox @ref` | Bounding box |
| `styles @ref <prop>` | Computed CSS |

## Capture
| Command | Description |
|---|---|
| `screenshot [selector] [path]` | PNG; selector (@ref/CSS/plain) → element clip |
| `screenshot --full / --format png\|jpeg\|webp / --quality <n>` | Full page / format / JPEG quality |
| `pdf [path]` | PDF export |
| `eval <js>` / `eval --stdin` / `eval -b <base64>` | Run JS (inline / stdin / base64) |
| `vitals [url] [--json]` | Core Web Vitals (LCP/CLS/FCP/INP) + TTFB |
| `diff snapshot [-b file] [-s sel] [-d n]` | AX snapshot diff vs baseline file / last snapshot |
| `diff url <u1> <u2> [-s/-d]` | Snapshot diff of two URLs |
| `video/trace/profiler start/stop [path]` | Recording/profiling |

## React Introspection (requires `--enable=react-devtools` at launch)
| Command | Description |
|---|---|
| `react tree` | Component tree (JSON) |
| `react inspect <fiberId>` | Fiber props / hooks / state |
| `react renders start` / `stop` | Render profiling (fps, mounts, re-renders) |
| `react suspense [--only-dynamic]` | Suspense boundary analysis |

## Network
| Command | Description |
|---|---|
| `network requests [--filter p] [--type t] [--method m] [--status s]` | List/filter (status `404` or `4xx`) |
| `network get <id>` | Full request/response with body |
| `network clear` | Clear |
| `network har start` / `har stop [path]` | HAR capture session start / stop+export |
| `network unroute [pattern]` | Remove intercept rule(s) |
| `analyze` | API reverse engineering + schema |
| `intercept mock/fail/delay <pattern>` | Mock/block/delay |
| `intercept ... --resource-type <csv>` | Limit to CDP resourceType (Document/XHR/Script/…) |
| `intercept remove/list/clear` | Manage rules |
| `har [file]` | Export HAR 1.2 (one-shot) |

## Wait
| Command | Description |
|---|---|
| `wait <ms>` | Wait milliseconds |
| `waitforloadstate [ms]` | Page load |
| `waitforurl <pat> [ms]` | URL match |
| `waitforfunction <expr> [ms]` | JS condition |
| `waitfor network/console/error/dialog [ms]` | Event wait |
| `waitdownload [ms]` | Download complete |

## Settings
| Command | Description |
|---|---|
| `set viewport/media/offline` | Display settings |
| `set timezone/locale/geolocation` | Location emulation |
| `set device/useragent/headers` | Device/network |
| `set ignore-https-errors` | Cert errors |
| `set permissions grant <perm>` | Permissions |

## Storage
| Command | Description |
|---|---|
| `cookies list/set/get/clear` | Cookies |
| `cookies set <n> <v> [--domain --path --httpOnly --secure --sameSite --expires]` | Cookie attributes |
| `cookies set --curl <file>` | Bulk import (JSON / cURL dump / Cookie header) |
| `storage local/session [key]` | Web storage |
| `state save/load/list` | Full state persistence |
| `state clear [name\|--all] / show <n> / clean --older-than <days> / rename <a> <b>` | State mgmt |
| `credentials <user> <pass>` | HTTP auth |

## Other
| Command | Description |
|---|---|
| `tab list` | List tabs (each has stable id) |
| `tab new [--label <name>] [url]` | New tab; optional label for later reference |
| `tab close/switch <id\|index\|label>` / `tab count` | Tab mgmt (id/label preferred over index) |
| `connect <port\|ws-url\|http-url>` | Attach to existing Chrome (sugar for --port/--cdp) |
| `mouse move/down/up [button] / wheel <dx> <dy>` | Mouse events (button: left/right/middle) |
| `batch [--bail] [cmd...]` | Run inline args (or stdin lines if none); --bail stops on first failure |
| `doctor [--json]` | Diagnose install (version/Chrome/sessions/config) |
| `profiles` | List Chrome profiles (for `--profile=<name>`) |
| `console list/clear` | Console messages |
| `errors [clear]` | Page errors |
| `dialog accept/dismiss/info` | Dialog handling (alert/beforeunload auto-dismissed by default) |
| `record/diff/replay <name>` | Network recording |
| `addscript <js>` / `addstyle <css>` | Page injection |
| `removeinitscript <id>` | Remove script added by addscript/--init-script |
| `pause` / `resume` | JS debugging |
| `clipboard get/set` (aliases: paste/copy, read/write) | Clipboard |
| `set viewport <w> <h> [scale]` | Viewport + deviceScaleFactor |
| `set media <scheme> [reduced-motion]` | prefers-color-scheme + prefers-reduced-motion |
| `status` | Daemon status |

## Launch Flags (set on the command that starts the daemon)
모든 값 플래그는 `--flag value`와 `--flag=value` 둘 다 허용.
| Flag | Description |
|---|---|
| `--port <p>` / `--cdp <url>` | Attach to existing Chrome (CDP port / ws\|http endpoint) |
| `--executable-path <bin>` | Specific Chrome/Chromium binary |
| `--args "<a> <b>"` | Extra space-separated Chrome launch args |
| `--ignore-https-errors` | Ignore TLS cert errors on launch |
| `--enable=react-devtools` | Install React DevTools hook → enables `react …` |
| `--profile=<name>` | Reuse a Chrome profile's login state (see `profiles`) |
| `--init-script=<path>` | Run a script before page JS (repeatable) |
| `--no-auto-dialog` | Disable alert/beforeunload auto-dismiss |
| `--proxy/--proxy-bypass/--extension` | Chrome launch options |
| `--allowed-domains <list>` | Restrict navigation domains |
| `--auto-connect` | Attach to running Chrome/Electron |
