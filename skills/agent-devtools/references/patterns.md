# Common Automation Patterns

## Form Submission
```bash
agent-devtools open https://example.com/signup
agent-devtools snapshot -i
agent-devtools fill @e1 "Jane Doe"
agent-devtools fill @e2 "jane@example.com"
agent-devtools select @e3 "California"
agent-devtools check @e4
agent-devtools click @e5
agent-devtools snapshot -i  # Verify result
```

## Login + State Persistence
```bash
agent-devtools open https://app.example.com/login
agent-devtools snapshot -i
agent-devtools fill @e1 "user@example.com"
agent-devtools fill @e2 "password123"
agent-devtools click @e3
agent-devtools wait 3000
agent-devtools state save auth

# Reuse later
agent-devtools state load auth
agent-devtools open https://app.example.com/dashboard
```

## API Discovery
```bash
agent-devtools open https://app.example.com
agent-devtools snapshot -i
agent-devtools click @e3
agent-devtools network list /api
agent-devtools network get <requestId>
agent-devtools analyze
```

## Mock API for Testing
```bash
agent-devtools intercept mock "/api/users" '[{"id":1,"name":"Test"}]'
agent-devtools open https://app.example.com/users
agent-devtools snapshot -i
agent-devtools intercept clear
```

## Mobile Device Testing
```bash
agent-devtools set device "iPhone 14"
agent-devtools open https://example.com
agent-devtools snapshot -i
agent-devtools tap @e1
```

## Debug API Calls (--debug mode)
```bash
agent-devtools --interactive --debug
> open https://app.example.com
> snapshot -i
> click @e5
< {"success":true,"debug":{"new_requests":[{"url":"/api/login","method":"POST","status":200}],"url_changed":false}}
```

## Parallel Sessions
```bash
agent-devtools --session=site1 open https://site-a.com
agent-devtools --session=site2 open https://site-b.com
agent-devtools --session=site1 snapshot -i
agent-devtools --session=site2 snapshot -i
```

## Connect to Existing Chrome
```bash
agent-devtools --port=9222 snapshot -i
```

## E2E Test (CI)
```bash
cat tests/login.txt | agent-devtools --interactive
# exit 0 = pass, exit 1 = fail
```
