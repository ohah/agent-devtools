#!/bin/bash
# Template: API Discovery Workflow
# Usage: ./api-discovery.sh <app-url>
set -euo pipefail
APP_URL="${1:?Usage: $0 <app-url>}"

agent-devtools open "$APP_URL"
agent-devtools wait 3000
agent-devtools snapshot -i

# Interact with the app to trigger API calls
# agent-devtools click @e1
# agent-devtools wait 2000

# Discover APIs
echo "=== Network Requests ==="
agent-devtools network list /api

echo "=== API Analysis ==="
agent-devtools analyze

echo "=== HAR Export ==="
agent-devtools har api-capture.har

agent-devtools close
