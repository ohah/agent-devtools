#!/bin/bash
# Template: Authenticated Session Workflow
# Usage: ./authenticated-session.sh <login-url>
set -euo pipefail
LOGIN_URL="${1:?Usage: $0 <login-url>}"

# Try loading saved state
if agent-devtools state load auth 2>/dev/null; then
    agent-devtools open "$LOGIN_URL"
    agent-devtools wait 3000
    CURRENT_URL=$(agent-devtools get url 2>/dev/null | tr -d '"')
    if [[ "$CURRENT_URL" != *"login"* ]]; then
        echo "Session restored"
        agent-devtools snapshot -i
        exit 0
    fi
fi

# Fresh login
agent-devtools open "$LOGIN_URL"
agent-devtools wait 3000
agent-devtools snapshot -i

# Customize refs:
# agent-devtools fill @e1 "$USERNAME"
# agent-devtools fill @e2 "$PASSWORD"
# agent-devtools click @e3
# agent-devtools wait 3000
# agent-devtools state save auth

agent-devtools close
