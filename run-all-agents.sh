#!/usr/bin/env bash
# run-all-agents.sh — start every agent and stream their logs live.
#
# Each agent's output is prefixed with a colour-coded label so all logs
# are visible in one terminal.  Logs are also written to files under
# ./logs/agents-<timestamp>/ for post-mortem analysis.
#
# Usage:
#   ./run-all-agents.sh                          # start everything (INFO level)
#   ./run-all-agents.sh --debug                  # start everything in DEBUG mode
#   ./run-all-agents.sh -d                       # shorthand for --debug
#   SKIP_AGENTS="trading-agent browser-agent" ./run-all-agents.sh
#   PYTHON_BIN=python3 ./run-all-agents.sh [--debug]
set -euo pipefail

# ── Parse flags ───────────────────────────────────────────────────────────────
DEBUG_MODE=0
for arg in "$@"; do
  case "$arg" in
    --debug|-d) DEBUG_MODE=1 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${ROOT_DIR}/logs/agents-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${LOG_DIR}"
LOCK_DIR="${ROOT_DIR}/.run-all-agents.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
LOCK_AGENT_PIDS_FILE="${LOCK_DIR}/agent_pids"
ORCHESTRATOR_URL="${ORCHESTRATOR_URL:-http://localhost:8000}"
PYTHON_BIN="${PYTHON_BIN:-python}"
SKIP_AGENTS="${SKIP_AGENTS:-}"      # space-separated agent names to skip
KILL_EXISTING="${KILL_EXISTING:-1}" # kill stale workers before start

# ── Debug mode env vars ───────────────────────────────────────────────────────
# LOG_LEVEL is read by all worker agents (via os.environ.get("LOG_LEVEL", "INFO"))
# ORCHESTRATOR_LOG_LEVEL is read by agent-orchestrator via pydantic settings
if [[ "${DEBUG_MODE}" == "1" ]]; then
  export LOG_LEVEL="DEBUG"
  export ORCHESTRATOR_LOG_LEVEL="debug"
fi

cleanup_previous_run() {
  if [[ "${KILL_EXISTING}" == "1" ]]; then
    # Cleanup for legacy script runs that didn't track real agent PIDs.
    pkill -f "python .*main.py --orchestrator-url ${ORCHESTRATOR_URL}" 2>/dev/null || true
  fi

  if [[ ! -d "${LOCK_DIR}" ]]; then
    return
  fi

  echo "Existing run detected. Stopping previous launcher and agents first..."

  if [[ -f "${LOCK_AGENT_PIDS_FILE}" ]]; then
    while read -r pid _name; do
      [[ -z "${pid}" ]] && continue
      kill -0 "${pid}" 2>/dev/null && kill "${pid}" 2>/dev/null || true
    done < "${LOCK_AGENT_PIDS_FILE}"
    sleep 1
    while read -r pid _name; do
      [[ -z "${pid}" ]] && continue
      kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
    done < "${LOCK_AGENT_PIDS_FILE}"
  fi

  if [[ -f "${LOCK_PID_FILE}" ]]; then
    old_launcher_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_launcher_pid}" ]] && kill -0 "${old_launcher_pid}" 2>/dev/null; then
      kill "${old_launcher_pid}" 2>/dev/null || true
      sleep 1
      kill -0 "${old_launcher_pid}" 2>/dev/null && kill -9 "${old_launcher_pid}" 2>/dev/null || true
    fi
  fi

  rm -rf "${LOCK_DIR}"
}

cleanup_previous_run
mkdir -p "${LOCK_DIR}"
echo "$$" > "${LOCK_PID_FILE}"
: > "${LOCK_AGENT_PIDS_FILE}"

# ── ANSI colours (8 distinct colours for agents) ──────────────────────────────
RESET='\033[0m'
COLOURS=(
  '\033[1;36m'   # bright cyan      – orchestrator
  '\033[1;32m'   # bright green     – task-planner
  '\033[1;33m'   # bright yellow    – task-executor
  '\033[1;35m'   # bright magenta   – task-scheduler
  '\033[1;34m'   # bright blue      – browser
  '\033[1;31m'   # bright red       – slack
  '\033[0;36m'   # cyan             – whatsapp
  '\033[0;33m'   # yellow           – trading
  '\033[0;32m'   # green            – filesystem
  '\033[0;35m'   # magenta          – code-execution
  '\033[1;37m'   # bright white     – avatar
  '\033[0;34m'   # blue             – document
  '\033[0;31m'   # red              – google-docs
  '\033[0;37m'   # white            – desktop
  '\033[1;32m'   # bright green     – research
  '\033[1;31m'   # bright red       – self-heal
)
_COLOUR_IDX=0

PIDS=()
TAIL_PIDS=()
NAMES=()
LOG_FILES=()

# ── Helpers ───────────────────────────────────────────────────────────────────

next_colour() {
  echo "${COLOURS[$_COLOUR_IDX]}"
  _COLOUR_IDX=$(( (_COLOUR_IDX + 1) % ${#COLOURS[@]} ))
}

is_skipped() {
  local name="$1"
  for skip in $SKIP_AGENTS; do
    [[ "$skip" == "$name" ]] && return 0
  done
  return 1
}

# start_agent NAME DIR CMD [ARGS...]
#   Launches the agent as a background process and writes logs to LOG_DIR.
start_agent() {
  local name="$1"
  local dir="$2"
  shift 2

  if is_skipped "$name"; then
    printf '  \033[2mSkipping %s (in SKIP_AGENTS)\033[0m\n' "$name"
    return
  fi

  local colour
  colour=$(next_colour)
  # Pad label to 24 chars so columns line up.
  local label
  label=$(printf "%-24s" "$name")
  local logfile="${LOG_DIR}/${name}.log"

  (
    cd "${ROOT_DIR}/${dir}"
    if [[ -f ".env" ]]; then
      set -a
      # shellcheck disable=SC1091
      source ".env"
      set +a
    fi
    # Replace shell with agent process so captured PID is the real agent PID.
    exec env RUN_ALL_AGENTS=1 "$@" >> "$logfile" 2>&1
  ) &

  local pid=$!
  PIDS+=("$pid")
  NAMES+=("$name")
  LOG_FILES+=("$logfile")
  printf '%s %s\n' "$pid" "$name" >> "${LOCK_AGENT_PIDS_FILE}"

  # Stream logfile with colored prefixes in this terminal.
  (
    touch "$logfile"
    tail -n 0 -F "$logfile" 2>/dev/null | while IFS= read -r line; do
      printf "${colour}[%s]${RESET} %s\n" "$label" "$line"
    done
  ) &
  local tail_pid=$!
  TAIL_PIDS+=("$tail_pid")

  printf "${colour}Started %-24s${RESET} pid=%-6s log=%s\n" "$name" "$pid" "$logfile"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
  printf '\n\033[1mStopping all agents …\033[0m\n'
  for i in "${!PIDS[@]}"; do
    local pid="${PIDS[$i]}"
    local name="${NAMES[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      printf '  stopping %-24s (pid=%s)\n' "$name" "$pid"
      kill "$pid" 2>/dev/null || true
    fi
  done
  for tail_pid in "${TAIL_PIDS[@]}"; do
    kill -0 "$tail_pid" 2>/dev/null && kill "$tail_pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done
  for tail_pid in "${TAIL_PIDS[@]}"; do
    kill -0 "$tail_pid" 2>/dev/null && kill -9 "$tail_pid" 2>/dev/null || true
  done
  printf '\033[1mAll agents stopped.\033[0m\n'
  rm -rf "${LOCK_DIR}"
}

trap cleanup INT TERM EXIT

# ── Banner ────────────────────────────────────────────────────────────────────

printf '\n\033[1mZybOS — starting all agents\033[0m\n'
printf 'Orchestrator URL : %s\n' "$ORCHESTRATOR_URL"
printf 'Log directory    : %s\n' "$LOG_DIR"
if [[ "${DEBUG_MODE}" == "1" ]]; then
  printf 'Log level        : \033[1;33mDEBUG\033[0m\n'
else
  printf 'Log level        : INFO\n'
fi
[[ -n "$SKIP_AGENTS" ]] && printf 'Skipping         : %s\n' "$SKIP_AGENTS"
printf '\n'

# ── Start agents (orchestrator first, then workers) ───────────────────────────

start_agent "agent-orchestrator" "agent-orchestrator" \
  "${PYTHON_BIN}" main.py

# Give the orchestrator a moment to open its port before agents connect.
sleep 2

start_agent "task-planner-agent"   "task-planner-agent"   "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "task-executor-agent"  "task-executor-agent"  "LOG_MESSAGE_BODIES=true ${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "task-scheduler-agent" "task-scheduler-agent" "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "browser-agent"        "browser-agent"        "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "slack-connector-agent"    "slack-connector-agent"    "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "whatsapp-connector-agent" "whatsapp-connector-agent" "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "serper-search-agent"      "serper-search-agent"      "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "gmail-agent"              "gmail-agent"              "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "summarize-agent"          "summarize-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "trading-agent"            "trading-agent"            "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "filesystem-agent"         "filesystem-agent"         "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "code-execution-agent"     "code-execution-agent"     "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "avatar-agent"             "avatar-agent"             "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "document-agent"           "document-agent"           "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "google-docs-agent"        "google-docs-agent"        "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "desktop-agent"            "desktop-agent"            "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "research-agent"           "research-agent"           "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "self-heal-agent"          "self-heal-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "workflow-validator-agent"          "workflow-validator-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
#start_agent "chrome-mcp-agent"          "chrome-mcp-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "skill-loader-agent"          "skill-loader-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "skill-writer-agent"          "skill-writer-agent"          "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "skill-forge-agent"           "skill-forge-agent"           "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "telegram-agent"              "telegram-agent"              "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"
start_agent "youtube-agent"               "youtube-agent"               "${PYTHON_BIN}" main.py --orchestrator-url "${ORCHESTRATOR_URL}"

printf '\n\033[1mAll agents started. Press Ctrl+C to stop.\033[0m\n\n'

# Keep the script alive; all log lines stream in real-time above.
wait
