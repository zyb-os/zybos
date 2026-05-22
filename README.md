# ZybOS

Umbrella repository for the ZybOS multi-agent platform. All components live in their own repos and are wired together here as git submodules.

## Components

| Submodule | Description |
|-----------|-------------|
| [agent-orchestrator](https://github.com/zyb-os/agent-orchestrator) | Central FastAPI WebSocket hub — agent registry, routing, LLM proxy, Cortex memory, dashboard |
| [browser-agent](https://github.com/zyb-os/browser-agent) | Playwright/Claude browser automation agent |
| [slack-connector-agent](https://github.com/zyb-os/slack-connector-agent) | Slack Socket Mode ↔ orchestrator bridge |
| [task-planner-agent](https://github.com/zyb-os/task-planner-agent) | LLM-based workflow planner |
| [task-executor-agent](https://github.com/zyb-os/task-executor-agent) | Step-by-step workflow executor with SQLite persistence |
| [task-scheduler-agent](https://github.com/zyb-os/task-scheduler-agent) | Cron-based task scheduling agent |
| [telegram-agent](https://github.com/zyb-os/telegram-agent) | Telegram ↔ orchestrator bridge |
| [whatsapp-connector-agent](https://github.com/zyb-os/whatsapp-connector-agent) | WhatsApp ↔ orchestrator bridge |
| [gmail-agent](https://github.com/zyb-os/gmail-agent) | Gmail read/send agent |
| [google-docs-agent](https://github.com/zyb-os/google-docs-agent) | Google Docs read/write agent |
| [research-agent](https://github.com/zyb-os/research-agent) | Web research agent |
| [serper-search-agent](https://github.com/zyb-os/serper-search-agent) | Serper.dev search agent |
| [filesystem-agent](https://github.com/zyb-os/filesystem-agent) | Sandboxed file system operations agent |
| [code-execution-agent](https://github.com/zyb-os/code-execution-agent) | Multi-language sandboxed code execution agent |
| [document-agent](https://github.com/zyb-os/document-agent) | PDF/image text extraction agent |
| [trading-agent](https://github.com/zyb-os/trading-agent) | Market data and trading advisory agent |
| [self-heal-agent](https://github.com/zyb-os/self-heal-agent) | Self-healing / auto-improvement agent |
| [skill-loader-agent](https://github.com/zyb-os/skill-loader-agent) | Dynamic skill loading from MCP registry |
| [skill-writer-agent](https://github.com/zyb-os/skill-writer-agent) | Skill authoring agent |
| [summarize-agent](https://github.com/zyb-os/summarize-agent) | Text summarisation agent |
| [workflow-validator-agent](https://github.com/zyb-os/workflow-validator-agent) | Workflow validation agent |
| [avatar-agent](https://github.com/zyb-os/avatar-agent) | Animated avatar interface with voice interaction |
| [avatar-ui](https://github.com/zyb-os/avatar-ui) | Avatar frontend UI |
| [chrome-extension](https://github.com/zyb-os/chrome-extension) | Chrome extension for browser integration |
| [chrome-mcp-agent](https://github.com/zyb-os/chrome-mcp-agent) | Chrome MCP bridge agent |
| [desktop-agent](https://github.com/zyb-os/desktop-agent) | Desktop automation agent |
| [interactive-test-agent](https://github.com/zyb-os/interactive-test-agent) | Interactive testing agent |

## Quick start

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/zyb-os/zybos.git

# Or if already cloned
git submodule update --init --recursive

# Pull latest for all submodules
git submodule update --remote --merge
```

## Working with submodules

Each submodule is an independent repo. To update a specific agent after making changes:

```bash
cd <agent-name>
# make changes, commit, push
cd ..
git add <agent-name>
git commit -m "Update <agent-name> to latest"
git push
```
