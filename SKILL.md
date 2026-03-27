---
name: agent-devtools
description: Browser automation and web debugging CLI for AI agents. Use when the user needs to interact with websites, fill forms, click buttons, take screenshots, extract data, test web apps, inspect network traffic, reverse-engineer APIs, intercept requests, or record/diff network flows. Triggers include requests to "open a website", "fill out a form", "click a button", "take a screenshot", "scrape data", "test this web app", "login to a site", "inspect network requests", "find API endpoints", "mock an API", or any task requiring programmatic web interaction.
allowed-tools: Bash(agent-devtools:*), Bash(./zig-out/bin/agent-devtools:*)
---

# Browser Automation with agent-devtools

A Zig CLI that controls Chrome/Chromium via CDP (Chrome DevTools Protocol). Install via `zig build` and run `./zig-out/bin/agent-devtools`.

## Core Workflow

Every browser automation follows this pattern:

1. **Navigate**: `agent-devtools open <url>`
2. **Snapshot**: `agent-devtools snapshot -i` (get element refs like `@1`, `@2`)
3. **Interact**: Use refs to click, fill, select
4. **Re-snapshot**: After navigation or DOM changes, get fresh refs

```bash
agent-devtools open https://example.com/form
agent-devtools snapshot -i
# Output: @1 [input type="email"], @2 [input type="password"], @3 [button] "Submit"

agent-devtools fill @1 "user@example.com"
agent-devtools fill @2 "password123"
agent-devtools click @3
agent-devtools wait 2000
agent-devtools snapshot -i  # Check result
```

## Command Chaining

Commands can be chained with `&&` in a single shell invocation. The browser persists between commands via a background daemon.

```bash
# Chain open + wait + snapshot in one call
agent-devtools open https://example.com && agent-devtools wait 2000 && agent-devtools snapshot -i

# Chain multiple interactions
agent-devtools fill @1 "user@example.com" && agent-devtools fill @2 "password123" && agent-devtools click @3
```

**When to chain:** Use `&&` when you don't need to read the output of an intermediate command before proceeding. Run commands separately when you need to parse the output first (e.g., snapshot to discover refs, then interact using those refs).

## Interactive Mode (Pipe Mode)

For multi-step workflows, use `--interactive` (or `--pipe`) to keep a persistent connection. Send JSON or text commands on stdin, one per line. Responses and events stream on stdout as newline-delimited JSON.

```bash
# Start interactive mode
agent-devtools --interactive

# Send commands (stdin):
{"action":"open","url":"https://example.com"}
{"action":"snapshot"}
{"action":"click","url":"@1"}
snapshot -i

# Or use text commands:
open https://example.com
snapshot -i
click @1
fill @2 "hello"
```

Events (network, console, errors) are streamed automatically as they occur:

```json
{"event":"network","url":"/api/data","method":"GET","status":200}
{"event":"console","type":"log","text":"Hello"}
```

## Debug Mode (--debug)

Use `--debug` with `--interactive` to get automatic context after action commands. Debug mode queries the daemon before and after each action (click, fill, press, etc.) to detect:

- New network requests
- New console messages
- New errors
- URL changes

```bash
agent-devtools --interactive --debug
```

Response with debug context:

```json
{"success":true,"debug":{"new_requests":[...],"new_console":[...],"new_errors":[...],"url_changed":true}}
```

**When to use debug mode:** Use `--debug` when you need to understand the side effects of actions (e.g., "what API call did clicking Submit trigger?"). Omit it for simple interactions where you only care about success/failure.

**Note:** Debug mode adds ~500ms delay after each action command to capture async effects. Non-action commands (snapshot, screenshot, get, etc.) are not affected.

## Essential Commands

```bash
# Navigation
agent-devtools open <url>              # Navigate (aliases: goto, navigate)
agent-devtools back                    # Go back
agent-devtools forward                 # Go forward
agent-devtools reload                  # Reload page
agent-devtools close                   # Close browser + daemon

# Snapshot
agent-devtools snapshot                # Full accessibility tree
agent-devtools snapshot -i             # Interactive elements only (recommended)

# Interaction (use @refs from snapshot)
agent-devtools click @1                # Click element
agent-devtools dblclick @1             # Double-click
agent-devtools fill @2 "text"          # Clear and type text
agent-devtools type @2 "text"          # Type without clearing
agent-devtools select @1 "option"      # Select dropdown option
agent-devtools check @1                # Check checkbox
agent-devtools uncheck @1              # Uncheck checkbox
agent-devtools press Enter             # Press key
agent-devtools hover @1                # Hover over element
agent-devtools focus @1                # Focus element
agent-devtools scroll down 500         # Scroll page
agent-devtools scrollintoview @1       # Scroll element into view
agent-devtools drag @1 @2              # Drag and drop
agent-devtools upload @1 ./file.txt    # Upload file
agent-devtools clear @1                # Clear input (Ctrl+A + Backspace)
agent-devtools selectall @1            # Select all text (Ctrl+A)
agent-devtools dispatch @1 input       # Dispatch DOM event

# Get information
agent-devtools get text @1             # Get element text
agent-devtools get html @1             # Get innerHTML
agent-devtools get value @1            # Get input value
agent-devtools get attr @1 href        # Get attribute
agent-devtools get url                 # Get current URL
agent-devtools get title               # Get page title
agent-devtools is visible @1           # Check visibility
agent-devtools is enabled @1           # Check if enabled
agent-devtools is checked @1           # Check if checked
agent-devtools boundingbox @1          # Get bounding box
agent-devtools styles @1 color         # Get computed CSS style

# Wait
agent-devtools wait 2000               # Wait milliseconds
agent-devtools waitload                # Wait for page load
agent-devtools waitload 10000          # Wait with timeout

# Capture
agent-devtools screenshot              # Screenshot (PNG)
agent-devtools screenshot output.png   # Screenshot to file
agent-devtools pdf output.pdf          # Save as PDF

# JavaScript
agent-devtools eval "document.title"   # Evaluate JS expression

# Clipboard
agent-devtools clipboard get           # Read clipboard
agent-devtools clipboard set "text"    # Write to clipboard

# Mouse
agent-devtools mouse move 100 200     # Move mouse
agent-devtools mouse down              # Mouse button down
agent-devtools mouse up                # Mouse button up
```

## Network Inspection (Unique Feature)

All network requests are captured automatically. Inspect them to understand API calls:

```bash
agent-devtools network list            # All requests
agent-devtools network list /api       # Filter by URL pattern
agent-devtools network get <requestId> # Full request/response detail (including body)
agent-devtools network clear           # Clear captured requests
```

## Console Capture (Unique Feature)

Capture all browser console output with accurate JS type conversion:

```bash
agent-devtools console list            # All console messages
agent-devtools console clear           # Clear
```

## API Reverse Engineering (Unique Feature)

Automatically discover API endpoints, extract meaningful parameter names, and infer response JSON schemas:

```bash
agent-devtools analyze                 # Analyze all captured API requests
```

## Network Intercept (Unique Feature)

Mock, block, or delay network requests using CDP Fetch domain:

```bash
agent-devtools intercept mock "/api/users" '{"users":[]}'   # Mock response
agent-devtools intercept fail "/api/analytics"               # Block request
agent-devtools intercept delay "/api/slow" 3000              # Add 3s delay
agent-devtools intercept remove "/api/users"                 # Remove rule
agent-devtools intercept list                                # List active rules
agent-devtools intercept clear                               # Clear all rules
```

## Flow Recording (Unique Feature)

Record network state and diff against current state to detect changes (zero LLM token cost):

```bash
agent-devtools record baseline         # Save current network state
# ... perform actions or wait ...
agent-devtools diff baseline           # Compare current vs recorded
```

## HAR Export

```bash
agent-devtools har                     # Export as HAR 1.2
agent-devtools har capture.har         # Export to file
```

## Tabs

```bash
agent-devtools tab list                # List tabs
agent-devtools tab new https://x.com   # New tab
agent-devtools tab switch 1            # Switch to tab (0-based)
agent-devtools tab close               # Close current tab
agent-devtools window new              # New window
```

## Browser Settings

```bash
agent-devtools set viewport 1920 1080  # Set viewport size
agent-devtools set media dark          # Dark mode
agent-devtools set offline on          # Offline mode
```

## Cookies & Storage

```bash
agent-devtools cookies                 # List cookies
agent-devtools cookies set name value  # Set cookie
agent-devtools cookies clear           # Clear cookies
agent-devtools storage local           # List localStorage
agent-devtools storage local key       # Get specific key
agent-devtools storage session         # List sessionStorage
```

## State Management

```bash
agent-devtools state save mystate      # Save cookies + storage
agent-devtools state load mystate      # Restore saved state
agent-devtools state list              # List saved states
```

## HTTP Auth & Downloads

```bash
agent-devtools credentials user pass   # Set HTTP basic auth
agent-devtools download-path ./dl      # Set download directory
```

## Page Injection

```bash
agent-devtools addstyle "body{background:red}"  # Inject CSS
```

## JS Debugging

```bash
agent-devtools pause                   # Pause JS execution
agent-devtools resume                  # Resume JS execution
```

## Common Patterns

### Form Submission

```bash
agent-devtools open https://example.com/signup
agent-devtools snapshot -i
agent-devtools fill @1 "Jane Doe"
agent-devtools fill @2 "jane@example.com"
agent-devtools select @3 "California"
agent-devtools check @4
agent-devtools click @5
agent-devtools wait 2000
agent-devtools snapshot -i  # Verify result
```

### Authentication with State Persistence

```bash
# Login once and save state
agent-devtools open https://app.example.com/login
agent-devtools snapshot -i
agent-devtools fill @1 "$USERNAME"
agent-devtools fill @2 "$PASSWORD"
agent-devtools click @3
agent-devtools wait 3000
agent-devtools state save auth

# Reuse in future sessions
agent-devtools state load auth
agent-devtools open https://app.example.com/dashboard
```

### Data Extraction

```bash
agent-devtools open https://example.com/products
agent-devtools snapshot -i
agent-devtools get text @5           # Get specific element text
agent-devtools eval "document.body.innerText"  # Get all page text
```

### API Discovery Workflow

```bash
agent-devtools open https://app.example.com
agent-devtools snapshot -i
agent-devtools click @3              # Trigger some action
agent-devtools wait 2000
agent-devtools network list /api     # See what API calls were made
agent-devtools network get 5         # Get full request/response detail
agent-devtools analyze               # Auto-discover API patterns + schemas
```

### Mock API for Testing

```bash
agent-devtools intercept mock "/api/users" '[{"id":1,"name":"Test"}]'
agent-devtools open https://app.example.com/users
agent-devtools snapshot -i           # See the app with mocked data
agent-devtools intercept clear       # Remove all mocks
```

### Parallel Sessions

```bash
agent-devtools --session=site1 open https://site-a.com
agent-devtools --session=site2 open https://site-b.com

agent-devtools --session=site1 snapshot -i
agent-devtools --session=site2 snapshot -i
```

### Connect to Existing Chrome

```bash
# Connect to Chrome with remote debugging enabled on port 9222
agent-devtools --port=9222 snapshot -i
```

### Visual Browser (Debugging)

```bash
agent-devtools --headed open https://example.com
```

## Ref Lifecycle (Important)

Refs (`@1`, `@2`, etc.) are invalidated when the page changes. Always re-snapshot after:

- Clicking links or buttons that navigate
- Form submissions
- Dynamic content loading (dropdowns, modals)

```bash
agent-devtools click @5              # Navigates to new page
agent-devtools snapshot -i           # MUST re-snapshot
agent-devtools click @1              # Use new refs
```

## Session Management and Cleanup

Always close your browser session when done to avoid leaked processes:

```bash
agent-devtools close                         # Close default session
agent-devtools --session=myapp close         # Close specific session
```

## Status

```bash
agent-devtools status                # Daemon status (request/console/error counts)
```
