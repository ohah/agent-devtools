# Debug Mode

## Usage
```bash
agent-devtools --interactive --debug
```

## What it does
After action commands (click, fill, press, type, select, check, uncheck, tap, hover, drag, dispatch, open), debug mode automatically:
1. Queries daemon status before the action
2. Executes the action
3. Waits 500ms for async effects
4. Queries status again
5. If changes detected, fetches details and appends to response

## Response format
```json
{
  "success": true,
  "debug": {
    "new_requests": [{"url": "/api/login", "method": "POST", "status": 200}],
    "new_console": [{"type": "log", "text": "logged in"}],
    "new_errors": [{"description": "TypeError: ..."}],
    "url_changed": true
  }
}
```

## Filtering
- Static resources (JS/CSS/images/fonts) are excluded
- Tracking pixels (gen_204, client_204) are excluded
- Only API requests are shown

## When to use
- **Development**: Use --debug to understand side effects of actions
- **Testing/CI**: Omit --debug for minimal output and faster execution

## Non-action commands
snapshot, screenshot, get, is, set, network, console, cookies, eval, wait — these are NOT affected by debug mode.
