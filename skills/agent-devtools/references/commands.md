# Command Reference

Complete reference for all agent-devtools commands.

## Navigation

```bash
agent-devtools open <url>              # Navigate to URL (starts daemon if needed)
agent-devtools back                    # Go back
agent-devtools forward                 # Go forward
agent-devtools reload                  # Reload page
agent-devtools close                   # Close browser and stop daemon
```

## Snapshot (page analysis)

```bash
agent-devtools snapshot                # Full accessibility tree with depth
agent-devtools snapshot -i             # Interactive elements only (recommended)
```

## Interactions (use @refs from snapshot)

```bash
agent-devtools click @e1               # Click
agent-devtools dblclick @e1            # Double-click
agent-devtools fill @e2 "text"         # Clear and type
agent-devtools type @e2 "text"         # Type without clearing
agent-devtools press Enter             # Press key
agent-devtools hover @e1               # Hover
agent-devtools focus @e1               # Focus element
agent-devtools check @e1               # Check checkbox
agent-devtools select @e1 "value"      # Select dropdown option
agent-devtools scroll down 500         # Scroll (up/down/left/right, default 300px)
agent-devtools scrollintoview @e1      # Scroll element into view
agent-devtools drag @e1 @e2            # Drag and drop
agent-devtools upload @e1 file.pdf     # Upload file
```

## Get Information

```bash
agent-devtools get url                 # Get current URL
agent-devtools get title               # Get page title
agent-devtools get text @e1            # Get element text (innerText)
agent-devtools get html @e1            # Get innerHTML
agent-devtools get value @e1           # Get input value
agent-devtools get attr @e1 href       # Get attribute
```

## Check State

```bash
agent-devtools is visible @e1          # Check if visible
agent-devtools is enabled @e1          # Check if enabled
agent-devtools is checked @e1          # Check if checked
```

## Screenshots and PDF

```bash
agent-devtools screenshot              # Return base64 PNG
agent-devtools screenshot path.png     # Save to file
agent-devtools pdf output.pdf          # Save as PDF
```

## JavaScript

```bash
agent-devtools eval "1 + 2"            # Execute JS, return result
agent-devtools wait 2000               # Wait milliseconds
```

## Network (DevTools feature)

```bash
agent-devtools network list            # List all captured requests
agent-devtools network list api        # Filter by URL pattern
agent-devtools network get <requestId> # Get request details with response body
agent-devtools network clear           # Clear collected requests
```

## Console (DevTools feature)

```bash
agent-devtools console list            # List console messages (log/warn/error)
agent-devtools console clear           # Clear console messages
```

## API Analysis (DevTools feature)

```bash
agent-devtools analyze                 # Discover API endpoints + response schemas
```

## Network Interception (DevTools feature)

```bash
agent-devtools intercept mock <pattern> <json>   # Return mock response
agent-devtools intercept fail <pattern>          # Block matching requests
agent-devtools intercept delay <pattern> <ms>    # Delay requests
agent-devtools intercept remove <pattern>        # Remove rule
agent-devtools intercept list                    # List active rules
agent-devtools intercept clear                   # Remove all rules
```

## Flow Recording (DevTools feature)

```bash
agent-devtools record <name>           # Save network state to file
agent-devtools diff <name>             # Compare recording vs current state
```

## Tabs

```bash
agent-devtools tab list                # List all tabs
agent-devtools tab new [url]           # Open new tab
agent-devtools tab close               # Close current tab
```

## Browser Settings

```bash
agent-devtools set viewport 1920 1080  # Set viewport size
agent-devtools set media dark          # Emulate color scheme
agent-devtools set offline on          # Toggle offline mode
```

## Cookies and Storage

```bash
agent-devtools cookies                 # List cookies
agent-devtools cookies set name value  # Set cookie
agent-devtools cookies clear           # Clear cookies
agent-devtools storage local           # Get all localStorage
agent-devtools storage local key       # Get specific key
agent-devtools storage local set k v   # Set value
agent-devtools storage local clear     # Clear all
```

## Mouse Control

```bash
agent-devtools mouse move 100 200      # Move mouse
agent-devtools mouse down              # Press button
agent-devtools mouse up                # Release button
```

## Status and Session

```bash
agent-devtools status                  # Daemon status (requests, console count)
agent-devtools --session=NAME          # Use named session (independent daemon)
agent-devtools --headed                # Show browser window
agent-devtools --port=PORT             # Connect to existing Chrome
agent-devtools find-chrome             # Find Chrome executable
```
