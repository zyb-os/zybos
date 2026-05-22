# ZybOS ZybOS — CLI Installer

Install and manage the ZybOS multi-agent platform on macOS, Linux, or Windows with a single command.

---

## One-command install

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ZybOS/agent-orchestrator/main/cli/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ZybOS/agent-orchestrator/main/cli/install.ps1 | iex
```

That's it. The installer will:

1. Detect your platform and Python version (3.10+ required)
2. Download the source from GitHub
3. Create isolated virtual environments for each agent
4. Write a config file at `~/.zybos/config.env`
5. Install the `zybos` CLI command to `~/.local/bin`
6. Register a system service (launchd on macOS, systemd on Linux, Task Scheduler on Windows)

---

## After installing

```bash
zybos start       # start all agents
zybos status      # check what's running
zybos logs -f     # stream live logs
```

Open the dashboard at **http://localhost:8000** once agents are running.

---

## Options

### macOS / Linux (`install.sh`)

| Flag | Default | Description |
|---|---|---|
| `--dir PATH` | `~/.zybos` | Installation directory |
| `--repo URL` | `ZybOS/agent-orchestrator` | GitHub repo to clone |
| `--branch NAME` | `main` | Branch or tag |
| `--agents "a b"` | core set | Space-separated subset of agents |
| `--all-agents` | — | Install every available agent |
| `--no-service` | — | Skip service registration |
| `--python PATH` | auto-detected | Explicit python3 binary |
| `--uninstall` | — | Remove a previous installation |

**Examples:**

```bash
# Install only the core orchestrator and planner
bash install.sh --agents "agent-orchestrator task-planner-agent"

# Install everything into a custom directory
bash install.sh --all-agents --dir /opt/zybos

# Install a specific release
bash install.sh --branch v1.2.0
```

### Windows (`install.ps1`)

```powershell
# Custom install directory
.\install.ps1 -InstallDir "C:\ZybOS"

# Install all agents
.\install.ps1 -AllAgents

# Install a subset
.\install.ps1 -Agents "agent-orchestrator task-planner-agent"

# Skip Task Scheduler registration
.\install.ps1 -NoService
```

---

## Core agents installed by default

| Agent | Description |
|---|---|
| `agent-orchestrator` | Central WebSocket hub and dashboard |
| `task-planner-agent` | LLM-based workflow planner |
| `task-executor-agent` | Step-by-step workflow executor |
| `task-scheduler-agent` | Cron-style task scheduler |
| `browser-agent` | Playwright browser automation |
| `slack-connector-agent` | Slack ↔ orchestrator bridge |
| `gmail-agent` | Gmail read/send integration |
| `summarize-agent` | Document and thread summarisation |
| `filesystem-agent` | Sandboxed file operations |
| `code-execution-agent` | Multi-language sandboxed code runner |
| `self-heal-agent` | Agent health monitoring and recovery |
| `workflow-validator-agent` | Workflow schema validation |
| `skill-loader-agent` | Dynamic skill installation |
| `skill-writer-agent` | LLM-assisted skill authoring |
| `telegram-agent` | Telegram ↔ orchestrator bridge |

Additional agents available with `--all-agents`: `whatsapp-connector-agent`, `serper-search-agent`, `document-agent`, `google-docs-agent`, `research-agent`, `avatar-agent`.

---

## CLI reference

```
zybos <command> [options]

  start   [agent]            Start all agents, or a single named agent
  stop    [agent]            Stop all agents, or a single named agent
  restart [agent]            Restart all agents, or a single named agent
  status                     Show running / stopped state
  logs    [agent] [-f]       Show recent logs; -f to stream live
  update                     Pull latest code and reinstall dependencies
  service install|uninstall  Register or remove the OS service
  uninstall                  Remove the entire installation
```

---

## Updating

```bash
zybos update
```

Downloads the latest source from GitHub, syncs agent files, and reinstalls dependencies. Running agents are not automatically restarted — run `zybos restart` afterwards.

---

## Uninstalling

```bash
zybos uninstall
```

Or on Windows:

```powershell
.\install.ps1 -Uninstall
```

Stops all agents, removes the service registration, and deletes the installation directory.

---

## Requirements

| | Requirement |
|---|---|
| Python | 3.10 or later |
| macOS | 12 Monterey or later |
| Linux | Ubuntu 20.04+ / Debian 11+ / Raspberry Pi OS (64-bit) |
| Windows | Windows 10 / Server 2019 or later, PowerShell 5.1+ |

Optional system packages (only needed for specific agents):

- `brew install poppler tesseract` — macOS, for `document-agent`
- `sudo apt-get install poppler-utils tesseract-ocr` — Linux, for `document-agent`
- Playwright browsers: installed automatically when `browser-agent` is included
