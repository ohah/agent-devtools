# Full Command Reference

## Navigation
| Command | Description |
|---|---|
| `open <url>` | Navigate (aliases: navigate, goto) |
| `back` / `forward` / `reload` | History navigation |
| `close` | Close browser + daemon |
| `url` / `title` | Get current URL / title |
| `content` / `setcontent <html>` | Get/set page HTML |
| `bringtofront` | Bring window to front |

## Snapshot + Interaction
| Command | Description |
|---|---|
| `snapshot -i` | Interactive elements only (recommended) |
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

## Network
| Command | Description |
|---|---|
| `network list [pattern]` | List requests |
| `network get <id>` | Full request/response with body |
| `network clear` | Clear |
| `analyze` | API reverse engineering + schema |
| `intercept mock/fail/delay <pattern>` | Mock/block/delay |
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
| `storage local/session [key]` | Web storage |
| `state save/load/list` | Full state persistence |
| `credentials <user> <pass>` | HTTP auth |

## Other
| Command | Description |
|---|---|
| `tab list/new/close/switch/count` | Tab management |
| `console list/clear` | Console messages |
| `errors [clear]` | Page errors |
| `dialog accept/dismiss/info` | Dialog handling |
| `record/diff/replay <name>` | Network recording |
| `addscript <js>` / `addstyle <css>` | Page injection |
| `pause` / `resume` | JS debugging |
| `clipboard get/set` | Clipboard |
| `status` | Daemon status |
