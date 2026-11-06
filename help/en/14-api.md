---
title: Local API
icon: network
keywords: API OpenAI Anthropic Claude Code curl port 8080 key server network
---
While the engine runs, other programs can use the model at `http://127.0.0.1:8080`:
- **OpenAI**: `/v1/chat/completions` (and `/v1/responses`)
- **Anthropic**: `/v1/messages`

## Examples
Claude Code with the local model:
```
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
```
Any OpenAI-compatible program:
```
curl http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

## From another computer
By default the API only listens on this Mac. Under Settings → Engine, set the address to `0.0.0.0` **and** an API key. Then restart the engine.
