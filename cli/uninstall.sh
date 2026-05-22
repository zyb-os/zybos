#!/usr/bin/env bash
# uninstall.sh — Remove ZybOS CLI installation.
#
# Usage:
#   bash cli/uninstall.sh [install-dir]
#   zybos uninstall
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }

INSTALL_DIR="${1:-${HOME}/.zybos}"

if [[ ! -d "${INSTALL_DIR}" ]]; then
  warn "Installation directory not found: ${INSTALL_DIR}"
  exit 0
fi

echo ""
printf "${BOLD}ZybOS — Uninstaller${RESET}\n"
printf "Will remove: %s\n\n" "${INSTALL_DIR}"
read -r -p "Proceed? This cannot be undone. [y/N] " confirm
[[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Cancelled."; exit 0; }

# Stop running agents
CLI="${INSTALL_DIR}/bin/zybos"
if [[ -x "${CLI}" ]]; then
  warn "Stopping running agents…"
  "${CLI}" stop 2>/dev/null || true
fi

# Remove systemd service (Linux)
if command -v systemctl &>/dev/null && systemctl list-units --all zybos.service 2>/dev/null | grep -q zybos; then
  sudo systemctl disable zybos 2>/dev/null || true
  sudo systemctl stop zybos 2>/dev/null || true
  sudo rm -f /etc/systemd/system/zybos.service
  sudo systemctl daemon-reload
  ok "Removed systemd service"
fi

# Remove launchd service (macOS)
PLIST="${HOME}/Library/LaunchAgents/com.zybos.plist"
if [[ -f "${PLIST}" ]]; then
  launchctl unload -w "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
  ok "Removed launchd service"
fi

# Remove ~/.local/bin symlink
for link in "${HOME}/.local/bin/zybos" /usr/local/bin/zybos; do
  if [[ -L "${link}" ]]; then
    rm -f "${link}"
    ok "Removed symlink: ${link}"
  fi
done

# Remove installation directory
rm -rf "${INSTALL_DIR}"
ok "Removed ${INSTALL_DIR}"

echo ""
printf "${GREEN}ZybOS has been uninstalled.${RESET}\n\n"
