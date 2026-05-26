# Agent Readiness Overview

Last updated: 2026-05-23

## ❌ NOT READY — Needs Attention (6 agents)

These agents are blocked from accepting traffic. Each has an `AGENT_STATUS.md` in its directory with fix instructions.

| Agent | Missing / Unset | Blocker Type |
|-------|----------------|--------------|
| **slack-connector-agent** | `slack_bot_token`, `slack_app_token`, `slack_signing_secret` | `required: true` in registration |
| **telegram-agent** | `telegram_bot_token` | `required: true` in registration |
| **whatsapp-connector-agent** | `whatsapp_access_token`, `whatsapp_phone_number_id`, `whatsapp_webhook_verify_token` | `required: true` in registration |
| **gmail-agent** | `gmail_address`, `gmail_app_password` | Functionally unusable without credentials |
| **google-docs-agent** | `credentials.json` (missing), `token.json` (missing) | OAuth files not present on disk |
| **serper-search-agent** | `serper_api_key` | Every search call will fail without it |

---

## ✅ READY (21 agents)

These agents have no mandatory unset parameters and can accept traffic as-is.

| Agent | Notes |
|-------|-------|
| **agent-orchestrator** | Core service — all settings have defaults |
| **avatar-agent** | No required credentials |
| **avatar-ui** | Frontend only — no runtime credentials needed |
| **browser-agent** | `anthropic_api_key` optional (falls back to orchestrator settings or env) |
| **chrome-extension** | Browser extension — no server credentials |
| **chrome-mcp-agent** | Connects to Chrome extension via WebSocket — no credentials needed |
| **cli** | CLI tool — no server credentials |
| **code-execution-agent** | Sandboxed execution — no external credentials |
| **desktop-agent** | Local desktop control — no external credentials |
| **document-agent** | Works with local files — no external credentials |
| **filesystem-agent** | Local filesystem access — no external credentials |
| **interactive-test-agent** | All settings have defaults; `ANTHROPIC_API_KEY` only needed for `llm` routing mode |
| **research-agent** | No required credentials |
| **self-heal-agent** | No required credentials |
| **skill-loader-agent** | No required credentials |
| **skill-writer-agent** | No required credentials |
| **summarize-agent** | No required credentials |
| **task-executor-agent** | No required credentials |
| **task-planner-agent** | No required credentials |
| **task-scheduler-agent** | No required credentials |
| **trading-agent** | CSV path is optional; agent works with dynamically supplied data |
| **workflow-validator-agent** | No required credentials |

---

## How to Unblock an Agent

1. Read the `AGENT_STATUS.md` in the agent's directory for exact steps
2. Supply the missing credentials via **one** of:
   - The orchestrator dashboard (Settings panel for the agent)
   - `PUT /api/v1/agents/{agent_id}/settings/{key}` REST API
   - `.env` file in the agent directory (before starting the agent)
3. Restart the agent — it will re-register and transition to `available`
