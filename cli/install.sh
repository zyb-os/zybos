#!/usr/bin/env bash
# install.sh — ZybOS CLI installer for macOS, Ubuntu, Raspberry Pi.
#
# One-line install (downloads everything automatically):
#   curl -fsSL https://raw.githubusercontent.com/zyb-os/zybos/main/cli/install.sh | bash
#
# Or from a local clone:
#   bash cli/install.sh
#
# Options:
#   --dir PATH        Installation directory (default: ~/.zybos)
#   --repo URL        GitHub repo to clone/download (default: zyb-os/zybos)
#   --branch NAME     Branch or tag to download (default: main)
#   --no-service      Skip systemd/launchd service registration
#   --agents LIST     Space-separated subset of agents to install (default: core set)
#   --all-agents      Install every available agent
#   --python PATH     Explicit python3 binary to use
#   --uninstall       Remove a previous installation
#
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { printf "${CYAN}▶${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
die()   { printf "${RED}✗${RESET}  %s\n" "$*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/.zybos"
GITHUB_REPO="${GITHUB_REPO:-zyb-os/zybos}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
INSTALL_SERVICE=1
UNINSTALL=0
PYTHON_BIN=""
AGENT_FILTER=""
ALL_AGENTS=0

# Core agents (mirrors active entries in run-all-agents.sh)
CORE_AGENTS=(
  agent-orchestrator
  task-planner-agent
  task-executor-agent
  task-scheduler-agent
  browser-agent
  slack-connector-agent
  gmail-agent
  summarize-agent
  filesystem-agent
  code-execution-agent
  self-heal-agent
  workflow-validator-agent
  skill-loader-agent
  skill-writer-agent
  telegram-agent
)

ALL_AGENT_LIST=(
  "${CORE_AGENTS[@]}"
  whatsapp-connector-agent
  serper-search-agent
  document-agent
  google-docs-agent
  research-agent
  avatar-agent
)

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        INSTALL_DIR="$2";    shift 2 ;;
    --repo)       GITHUB_REPO="$2";    shift 2 ;;
    --branch)     GITHUB_BRANCH="$2";  shift 2 ;;
    --no-service) INSTALL_SERVICE=0;   shift ;;
    --agents)     AGENT_FILTER="$2";   shift 2 ;;
    --all-agents) ALL_AGENTS=1;        shift ;;
    --python)     PYTHON_BIN="$2";     shift 2 ;;
    --uninstall)  UNINSTALL=1;         shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

BIN_DIR="${INSTALL_DIR}/bin"
VENV_DIR="${INSTALL_DIR}/venvs"
LOG_DIR="${INSTALL_DIR}/logs"
RUN_DIR="${INSTALL_DIR}/run"
SRC_DIR="${INSTALL_DIR}/src"
CLI_LINK="${HOME}/.local/bin/zybos"

# ── Detect platform ───────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
IS_MACOS=0; IS_LINUX=0
case "$OS" in
  Darwin) IS_MACOS=1 ;;
  Linux)  IS_LINUX=1 ;;
  *) die "Unsupported OS: $OS. Use install.ps1 on Windows." ;;
esac

# ── Uninstall path ────────────────────────────────────────────────────────────
if [[ "${UNINSTALL}" == "1" ]]; then
  UNINSTALL_SCRIPT="$(dirname "${BASH_SOURCE[0]:-$0}")/uninstall.sh"
  if [[ -f "${UNINSTALL_SCRIPT}" ]]; then
    bash "${UNINSTALL_SCRIPT}" "${INSTALL_DIR}"
  else
    # Inline minimal uninstall
    read -r -p "Remove ${INSTALL_DIR}? [y/N] " _c
    [[ "${_c}" == "y" || "${_c}" == "Y" ]] || exit 0
    [[ -x "${INSTALL_DIR}/bin/zybos" ]] && "${INSTALL_DIR}/bin/zybos" stop 2>/dev/null || true
    rm -rf "${INSTALL_DIR}" "${HOME}/.local/bin/zybos"
    echo "Removed."
  fi
  exit 0
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}ZybOS — CLI Installer${RESET}\n"
printf "Platform : %s/%s\n" "$OS" "$ARCH"
printf "Repo     : %s (%s)\n" "${GITHUB_REPO}" "${GITHUB_BRANCH}"
printf "Install  : %s\n\n" "$INSTALL_DIR"

# ── 1. Find Python ─────────────────────────────────────────────────────────────
info "Checking Python…"
if [[ -z "${PYTHON_BIN}" ]]; then
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
      PYTHON_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi
[[ -z "${PYTHON_BIN}" ]] && die "Python 3.10+ not found. Install Python and re-run (or pass --python /path/to/python3)."

PY_VER="$("${PYTHON_BIN}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJ="$(echo "${PY_VER}" | cut -d. -f1)"
PY_MIN="$(echo "${PY_VER}" | cut -d. -f2)"
if [[ "${PY_MAJ}" -lt 3 || ( "${PY_MAJ}" -eq 3 && "${PY_MIN}" -lt 10 ) ]]; then
  die "Python 3.10+ required. Found: ${PY_VER}"
fi
ok "Python ${PY_VER} at ${PYTHON_BIN}"

# ── 2. System dependencies ────────────────────────────────────────────────────
info "Checking system dependencies…"
if [[ "${IS_LINUX}" == "1" ]]; then
  # Only python3-venv and python3-dev are needed for the CLI agents.
  # libwebkit2gtk / libgtk are desktop-app (pywebview) deps — not required here.
  MISSING_PKGS=()
  for pkg in python3-venv python3-dev; do
    dpkg -s "${pkg}" &>/dev/null 2>&1 || MISSING_PKGS+=("${pkg}")
  done
  if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING_PKGS[@]}"
  fi
elif [[ "${IS_MACOS}" == "1" ]]; then
  if ! command -v brew &>/dev/null; then
    warn "Homebrew not found. Some optional features (poppler/tesseract for document-agent) may be unavailable."
  fi
fi
ok "System dependencies satisfied"

# ── 3. Obtain source ──────────────────────────────────────────────────────────
# Priority:
#   a) Running from inside the cloned repo   → use it in-place
#   b) git available                         → git clone into a temp dir
#   c) curl/wget available                   → download tarball and extract
#
info "Obtaining source code…"

REPO_ROOT=""

# (a) Check if we're already inside the repo
_try_local() {
  local script_path="${BASH_SOURCE[0]:-$0}"
  # BASH_SOURCE[0] is empty when piped through bash - skip
  [[ -z "${script_path}" || "${script_path}" == "bash" ]] && return 1
  local candidate
  candidate="$(cd "$(dirname "${script_path}")" 2>/dev/null && cd .. && pwd)"
  if [[ -f "${candidate}/agent-orchestrator/main.py" ]]; then
    REPO_ROOT="${candidate}"
    return 0
  fi
  return 1
}

_download_with_git() {
  local dest="${INSTALL_DIR}/.repo"
  rm -rf "${dest}"
  git clone --depth=1 --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_REPO}.git" "${dest}" 2>&1 | grep -v "^$" || return 1
  REPO_ROOT="${dest}"
}

_download_with_curl() {
  local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
  local tmp_tar="${INSTALL_DIR}/.source.tar.gz"
  local tmp_dir="${INSTALL_DIR}/.repo-extract"

  mkdir -p "${INSTALL_DIR}"
  rm -rf "${tmp_dir}"

  info "  Downloading source tarball from GitHub…"
  if command -v curl &>/dev/null; then
    curl -fsSL --progress-bar "${tarball_url}" -o "${tmp_tar}"
  elif command -v wget &>/dev/null; then
    wget -q --show-progress "${tarball_url}" -O "${tmp_tar}"
  else
    return 1
  fi

  mkdir -p "${tmp_dir}"
  tar -xzf "${tmp_tar}" -C "${tmp_dir}" --strip-components=1
  rm -f "${tmp_tar}"
  REPO_ROOT="${tmp_dir}"
}

if _try_local 2>/dev/null; then
  ok "Using local repository at ${REPO_ROOT}"
elif command -v git &>/dev/null; then
  info "Cloning ${GITHUB_REPO} (${GITHUB_BRANCH})…"
  mkdir -p "${INSTALL_DIR}"
  if _download_with_git; then
    ok "Repository cloned to ${INSTALL_DIR}/.repo"
  else
    warn "git clone failed, falling back to tarball download…"
    _download_with_curl || die "Could not download source. Install git or curl/wget and retry."
    ok "Source downloaded (tarball)"
  fi
else
  _download_with_curl || die "Could not download source. Install git or curl/wget and retry."
  ok "Source downloaded (tarball)"
fi

[[ -f "${REPO_ROOT}/agent-orchestrator/main.py" ]] || \
  die "Source download succeeded but agent-orchestrator/main.py not found. Check --repo / --branch."

# ── 4. Download CLI scripts if running via curl pipe ─────────────────────────
# When piped through bash, BASH_SOURCE[0] is empty, so we get the CLI tools
# from the downloaded repo itself.
CLI_SRC_DIR="${REPO_ROOT}/cli"
[[ -f "${CLI_SRC_DIR}/zybos" ]] || \
  die "cli/zybos not found in downloaded source."

# ── 5. Resolve agent list ─────────────────────────────────────────────────────
if [[ "${ALL_AGENTS}" == "1" ]]; then
  AGENTS=("${ALL_AGENT_LIST[@]}")
elif [[ -n "${AGENT_FILTER}" ]]; then
  read -ra AGENTS <<< "${AGENT_FILTER}"
else
  AGENTS=("${CORE_AGENTS[@]}")
fi

VALID_AGENTS=()
for a in "${AGENTS[@]}"; do
  if [[ -d "${REPO_ROOT}/${a}" ]]; then
    VALID_AGENTS+=("${a}")
  else
    warn "Agent not found in source, skipping: ${a}"
  fi
done
AGENTS=("${VALID_AGENTS[@]}")
[[ ${#AGENTS[@]} -gt 0 ]] || die "No agents found in source tree."

# ── 6. Create directory structure ─────────────────────────────────────────────
info "Creating installation directories…"
mkdir -p "${SRC_DIR}" "${VENV_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${BIN_DIR}"
mkdir -p "${HOME}/.local/bin"

# ── 7. Sync source files ──────────────────────────────────────────────────────
info "Installing source files…"

_sync_agent() {
  local agent="$1"
  local src="${REPO_ROOT}/${agent}"
  local dest="${SRC_DIR}/${agent}"
  if command -v rsync &>/dev/null; then
    rsync --archive --delete \
      --exclude='.venv/' --exclude='venv/' --exclude='env/' \
      --exclude='__pycache__/' --exclude='.git/' \
      --exclude='*.pyc' --exclude='*.egg-info/' \
      --exclude='dist/' --exclude='build/' \
      --exclude='node_modules/' --exclude='data/' \
      "${src}/" "${dest}/"
  else
    rm -rf "${dest}"
    cp -rp "${src}" "${dest}"
    for excl in .venv venv env __pycache__ .git dist build node_modules data; do
      rm -rf "${dest:?}/${excl}"
    done
  fi
}

for agent in "${AGENTS[@]}"; do
  printf "  %-40s" "${agent}…"
  _sync_agent "${agent}"
  printf " ${GREEN}ok${RESET}\n"
done
ok "Source installed to ${SRC_DIR}"

# ── 8. Create per-agent virtual environments ──────────────────────────────────
info "Creating virtual environments and installing dependencies…"
TOTAL="${#AGENTS[@]}"
IDX=0
for agent in "${AGENTS[@]}"; do
  IDX=$((IDX + 1))
  printf "  [%d/%d] %-40s" "${IDX}" "${TOTAL}" "${agent}…"
  AGENT_VENV="${VENV_DIR}/${agent}"
  AGENT_SRC="${SRC_DIR}/${agent}"
  REQ="${AGENT_SRC}/requirements.txt"

  if [[ ! -d "${AGENT_VENV}" ]]; then
    "${PYTHON_BIN}" -m venv "${AGENT_VENV}" --prompt "${agent}" 2>/dev/null
  fi

  if [[ -f "${REQ}" ]]; then
    "${AGENT_VENV}/bin/pip" install --quiet --upgrade pip 2>/dev/null
    "${AGENT_VENV}/bin/pip" install --quiet -r "${REQ}" 2>/dev/null
    printf " ${GREEN}ok${RESET}\n"
  else
    printf " ${YELLOW}(no requirements.txt)${RESET}\n"
  fi
done
ok "Virtual environments ready"

# ── 8b. Playwright browser install (browser-agent only) ───────────────────────
if printf '%s\n' "${AGENTS[@]}" | grep -q "^browser-agent$"; then
  PLAYWRIGHT_BIN="${VENV_DIR}/browser-agent/bin/playwright"
  if [[ -x "${PLAYWRIGHT_BIN}" ]]; then
    info "Installing Playwright browsers (chromium)…"
    "${PLAYWRIGHT_BIN}" install chromium --with-deps 2>&1 | tail -5 || \
      warn "Playwright browser install failed — run manually: ${PLAYWRIGHT_BIN} install chromium --with-deps"
  fi
fi

# ── 9. Write config file ──────────────────────────────────────────────────────
info "Writing configuration…"
CONFIG_FILE="${INSTALL_DIR}/config.env"
# Preserve any existing user-edited values (API keys, etc.)
if [[ -f "${CONFIG_FILE}" ]]; then
  cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
  warn "Existing config backed up to ${CONFIG_FILE}.bak"
fi
cat > "${CONFIG_FILE}" <<EOF
# ZybOS — Installation config
# Edit values here; they are sourced before each agent starts.
INSTALL_DIR=${INSTALL_DIR}
SRC_DIR=${SRC_DIR}
VENV_DIR=${VENV_DIR}
LOG_DIR=${LOG_DIR}
RUN_DIR=${RUN_DIR}
ORCHESTRATOR_URL=http://localhost:8000
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8000
LOG_LEVEL=INFO
# Source repo for updates (used by: zybos update)
GITHUB_REPO=${GITHUB_REPO}
GITHUB_BRANCH=${GITHUB_BRANCH}
# Agents to start (space-separated); leave blank to start all installed
ENABLED_AGENTS=""
EOF
ok "Config: ${CONFIG_FILE}"

# ── 10. Write agents manifest ──────────────────────────────────────────────────
MANIFEST_FILE="${INSTALL_DIR}/agents.txt"
printf '%s\n' "${AGENTS[@]}" > "${MANIFEST_FILE}"
ok "Agents manifest: ${MANIFEST_FILE}"

# ── 11. Install CLI ───────────────────────────────────────────────────────────
info "Installing CLI command…"
CLI_SCRIPT="${BIN_DIR}/zybos"
cp "${CLI_SRC_DIR}/zybos" "${CLI_SCRIPT}"
chmod +x "${CLI_SCRIPT}"

# Stamp the install dir into the script so it works without the config being sourced first
sed -i.bak "s|^INSTALL_DIR=.*|INSTALL_DIR=\"${INSTALL_DIR}\"|" "${CLI_SCRIPT}" 2>/dev/null || true
rm -f "${CLI_SCRIPT}.bak"

ln -sf "${CLI_SCRIPT}" "${CLI_LINK}"
ok "CLI: ${CLI_LINK}"

# ── 12. PATH check ────────────────────────────────────────────────────────────
SHELL_RC=""
case "${SHELL:-}" in
  */zsh)  SHELL_RC="${HOME}/.zshrc" ;;
  */bash) SHELL_RC="${HOME}/.bashrc" ;;
esac
if [[ -n "${SHELL_RC}" ]] && ! grep -q '\.local/bin' "${SHELL_RC}" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${SHELL_RC}"
  warn "Added ~/.local/bin to PATH in ${SHELL_RC}. Run: source ${SHELL_RC}"
fi
if ! echo ":${PATH}:" | grep -q ":${HOME}/.local/bin:"; then
  export PATH="${HOME}/.local/bin:${PATH}"
fi

# ── 13. Service registration ──────────────────────────────────────────────────
if [[ "${INSTALL_SERVICE}" == "1" ]]; then
  if [[ "${IS_MACOS}" == "1" ]]; then
    PLIST_DIR="${HOME}/Library/LaunchAgents"
    PLIST="${PLIST_DIR}/com.zybos.plist"
    mkdir -p "${PLIST_DIR}"
    cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>        <string>com.zybos</string>
  <key>ProgramArguments</key>
  <array>
    <string>${CLI_SCRIPT}</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>    <false/>
  <key>KeepAlive</key>    <false/>
  <key>StandardOutPath</key>  <string>${LOG_DIR}/launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/launchd.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST
    launchctl load "${PLIST}" 2>/dev/null || true
    ok "launchd service registered (run 'launchctl load -w ${PLIST}' to enable at login)"

  elif [[ "${IS_LINUX}" == "1" ]] && command -v systemctl &>/dev/null; then
    SERVICE_FILE="/etc/systemd/system/zybos.service"
    if [[ -w /etc/systemd/system ]] || sudo -n true 2>/dev/null; then
      sudo tee "${SERVICE_FILE}" > /dev/null <<SERVICE
[Unit]
Description=ZybOS
After=network.target

[Service]
Type=forking
User=${USER}
ExecStart=${CLI_SCRIPT} start
ExecStop=${CLI_SCRIPT} stop
Restart=on-failure
RestartSec=5
EnvironmentFile=-${CONFIG_FILE}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
      sudo systemctl daemon-reload
      ok "systemd service registered (run 'sudo systemctl enable zybos' to enable at boot)"
    else
      warn "No sudo access — skipping systemd registration. Run 'sudo zybos service install' later."
    fi
  fi
fi

# ── Clean up temp download if it was a tarball ────────────────────────────────
if [[ "${REPO_ROOT}" == "${INSTALL_DIR}/.repo-extract" ]]; then
  rm -rf "${REPO_ROOT}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}${GREEN}Installation complete!${RESET}\n\n"
printf "  Start agents   : ${BOLD}zybos start${RESET}\n"
printf "  Check status   : ${BOLD}zybos status${RESET}\n"
printf "  View logs      : ${BOLD}zybos logs${RESET}\n"
printf "  Dashboard      : ${BOLD}http://localhost:8000${RESET}\n\n"
printf "  Config file    : %s\n" "${CONFIG_FILE}"
printf "  Update later   : ${BOLD}zybos update${RESET}\n\n"
printf "  Installed agents (%d): %s\n\n" "${#AGENTS[@]}" "$(tr '\n' ' ' < "${MANIFEST_FILE}")"
