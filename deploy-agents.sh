#!/usr/bin/env bash
# deploy-agents.sh — build and run every agent in its own Docker container.
#
# Uses docker-compose.sidecar.yml (one service per agent).
#
# Usage:
#   ./deploy-agents.sh up              # build (if needed) + start all agents
#   ./deploy-agents.sh up --build      # force rebuild, then start all
#   ./deploy-agents.sh down            # stop + remove all containers
#   ./deploy-agents.sh restart         # down + up
#   ./deploy-agents.sh restart <svc>   # restart a single agent (e.g. trigger-router)
#   ./deploy-agents.sh rebuild <svc>   # rebuild + restart a single agent
#   ./deploy-agents.sh build           # build all images without starting
#   ./deploy-agents.sh build <svc>     # build a single image
#   ./deploy-agents.sh ps              # show running containers + health
#   ./deploy-agents.sh logs            # stream all container logs
#   ./deploy-agents.sh logs <svc>      # stream logs for one service
#   ./deploy-agents.sh shell <svc>     # open bash inside a running container
#   ./deploy-agents.sh pull            # pull base images (useful before rebuild)
#   ./deploy-agents.sh prune           # remove stopped containers + dangling images
#
# Environment:
#   Copy .env.sidecar.example → .env.sidecar and fill in any values you need.
#   Secrets that cannot be set via the dashboard (e.g. TELEGRAM_BOT_TOKEN) must
#   be set there.  All other API keys are configured through the dashboard at
#   http://localhost:8000 after first boot.
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.sidecar.yml"
ENV_FILE="${SCRIPT_DIR}/.env.sidecar"
PROJECT_NAME="zyb"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

log()  { printf "${CYAN}[deploy]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[deploy]${RESET} ✓ %s\n" "$*"; }
warn() { printf "${YELLOW}[deploy]${RESET} ⚠ %s\n" "$*"; }
err()  { printf "${RED}[deploy]${RESET} ✗ %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

compose() {
    local env_args=()
    if [[ -f "${ENV_FILE}" ]]; then
        env_args=(--env-file "${ENV_FILE}")
    fi
    docker compose \
        -f "${COMPOSE_FILE}" \
        -p "${PROJECT_NAME}" \
        "${env_args[@]}" \
        "$@"
}

ensure_env_file() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        if [[ -f "${SCRIPT_DIR}/.env.sidecar.example" ]]; then
            warn ".env.sidecar not found — copying from .env.sidecar.example"
            cp "${SCRIPT_DIR}/.env.sidecar.example" "${ENV_FILE}"
            warn "Edit ${ENV_FILE} and add Telegram/WhatsApp tokens if needed, then re-run."
        else
            warn ".env.sidecar not found — using defaults only."
            warn "Create ${ENV_FILE} to set TELEGRAM_BOT_TOKEN and other startup secrets."
        fi
    fi
}

cmd_up() {
    ensure_env_file
    local extra_args=("$@")
    log "Starting all agents (sidecar mode)..."
    compose up --detach "${extra_args[@]}"
    ok "All agents started."
    printf "\n  Dashboard  → ${BOLD}http://localhost:${ORCHESTRATOR_PORT:-8000}${RESET}\n"
    printf "  Status     → ${BOLD}./deploy-agents.sh ps${RESET}\n"
    printf "  Logs       → ${BOLD}./deploy-agents.sh logs${RESET}\n\n"
}

cmd_down() {
    log "Stopping all agents..."
    compose down
    ok "All containers stopped and removed."
}

cmd_build() {
    local svc="${1:-}"
    if [[ -n "${svc}" ]]; then
        log "Building image for: ${svc}"
        compose build "${svc}"
        ok "Built: ${svc}"
    else
        log "Building all agent images..."
        compose build
        ok "All images built."
    fi
}

cmd_restart() {
    local svc="${1:-}"
    if [[ -n "${svc}" ]]; then
        log "Restarting: ${svc}"
        compose restart "${svc}"
        ok "Restarted: ${svc}"
    else
        log "Restarting all agents..."
        compose down
        ensure_env_file
        compose up --detach
        ok "All agents restarted."
    fi
}

cmd_rebuild() {
    local svc="${1:-}"
    [[ -z "${svc}" ]] && die "Usage: $0 rebuild <service-name>"
    log "Rebuilding and restarting: ${svc}"
    compose build "${svc}"
    compose up --detach --no-deps "${svc}"
    ok "Rebuilt and restarted: ${svc}"
}

cmd_ps() {
    compose ps
}

cmd_logs() {
    local svc="${1:-}"
    if [[ -n "${svc}" ]]; then
        compose logs --follow --tail=100 "${svc}"
    else
        compose logs --follow --tail=50
    fi
}

cmd_shell() {
    local svc="${1:-}"
    [[ -z "${svc}" ]] && die "Usage: $0 shell <service-name>"
    local container
    container=$(compose ps -q "${svc}" 2>/dev/null | head -1)
    [[ -z "${container}" ]] && die "Service '${svc}' is not running."
    docker exec -it "${container}" bash
}

cmd_pull() {
    log "Pulling base images..."
    compose pull --ignore-pull-failures 2>/dev/null || true
    ok "Base images up to date."
}

cmd_prune() {
    log "Removing stopped containers and dangling images..."
    docker container prune -f
    docker image prune -f
    ok "Pruned."
}

cmd_help() {
    sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── Argument dispatch ─────────────────────────────────────────────────────────
ACTION="${1:-help}"
shift || true
ARG="${1:-}"

case "${ACTION}" in
    up)        cmd_up "$@" ;;
    down)      cmd_down ;;
    build)     cmd_build "${ARG}" ;;
    restart)   cmd_restart "${ARG}" ;;
    rebuild)   cmd_rebuild "${ARG}" ;;
    ps)        cmd_ps ;;
    logs)      cmd_logs "${ARG}" ;;
    shell)     cmd_shell "${ARG}" ;;
    pull)      cmd_pull ;;
    prune)     cmd_prune ;;
    help|--help|-h) cmd_help ;;
    *)         err "Unknown command: ${ACTION}"; cmd_help; exit 1 ;;
esac
