#!/bin/bash
# Template: Form Automation Workflow
# Usage: ./form-automation.sh <form-url>
set -euo pipefail
FORM_URL="${1:?Usage: $0 <form-url>}"

agent-devtools open "$FORM_URL"
agent-devtools wait 3000
echo "Form structure:"
agent-devtools snapshot -i

# Customize refs based on snapshot output:
# agent-devtools fill @e1 "John Doe"
# agent-devtools fill @e2 "user@example.com"
# agent-devtools click @e3  # Submit

# Verify result
# agent-devtools snapshot -i
# agent-devtools screenshot /tmp/form-result.png

agent-devtools close
