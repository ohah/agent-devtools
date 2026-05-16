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
| `snapshot` | Full accessibility tree |
| `click` / `dblclick` / `tap @ref` | Click / double-click / touch tap |
| `fill @ref "text"` | Clear + type |
| `type @ref "text"` | Type without clearing |
| `press <key>` | Press key (Enter, Tab, Escape) |
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
| `is visible/enabled/checked @ref` | State check |
| `boundingbox @ref` | Bounding box |
| `styles @ref <prop>` | Computed CSS |

## Find Elements
| Command | Description |
|---|---|
| `find role/text/label/placeholder/testid <value>` | Semantic query |

## Capture
| Command | Description |
|---|---|
| `screenshot [path]` | PNG screenshot |
| `pdf [path]` | PDF export |
| `eval <js>` | Run JavaScript |
| `vitals [url]` | Core Web Vitals (LCP/CLS/FCP/INP) + TTFB |
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
| `network list [pattern]` | List requests |
| `network get <id>` | Full request/response with body |
| `network clear` | Clear |
| `analyze` | API reverse engineering + schema |
| `intercept mock/fail/delay <pattern>` | Mock/block/delay |
| `intercept ... --resource-type <csv>` | Limit to CDP resourceType (Document/XHR/Script/…) |
| `intercept remove/list/clear` | Manage rules |
| `har [file]` | Export HAR 1.2 |

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
| `cookies set --curl <file>` | Bulk import (JSON / cURL dump / Cookie header) |
| `storage local/session [key]` | Web storage |
| `state save/load/list` | Full state persistence |
| `credentials <user> <pass>` | HTTP auth |

## Other
| Command | Description |
|---|---|
| `tab list/new/close/switch/count` | Tab management |
| `console list/clear` | Console messages |
| `errors [clear]` | Page errors |
| `dialog accept/dismiss/info` | Dialog handling (alert/beforeunload auto-dismissed by default) |
| `record/diff/replay <name>` | Network recording |
| `addscript <js>` / `addstyle <css>` | Page injection |
| `removeinitscript <id>` | Remove script added by addscript/--init-script |
| `pause` / `resume` | JS debugging |
| `clipboard get/set` | Clipboard |
| `status` | Daemon status |

## Launch Flags (set on the command that starts the daemon)
| Flag | Description |
|---|---|
| `--enable=react-devtools` | Install React DevTools hook → enables `react …` |
| `--init-script=<path>` | Run a script before page JS (repeatable) |
| `--no-auto-dialog` | Disable alert/beforeunload auto-dismiss |
| `--proxy/--proxy-bypass/--extension` | Chrome launch options |
| `--allowed-domains <list>` | Restrict navigation domains |
| `--auto-connect` | Attach to running Chrome/Electron |
