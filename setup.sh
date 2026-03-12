#!/usr/bin/env bash
# setup.sh — One-click AI stack setup orchestrator
#
# Run order:
#   1-configure-drives.sh   — interactive drive assignment → generates 2-mount-<hostname>.sh
#   2-mount-<hostname>.sh   — applies fstab entries and mounts
#   3-configure-secrets.sh  — populate .env files from .env.template files
#   4-configure-host.sh     — Docker, NVIDIA, SELinux, systemd prerequisites
#   build-images.sh         — build all custom local Docker images under build/
#   → starts ai-stack.service
#
# Safe to re-run at any time. All steps are idempotent.
# Run as your regular user — individual scripts use sudo for privileged steps.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
info()   { echo -e "  ${CYAN}→${RESET}  $*"; }

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root. Run as your regular user.${RESET}" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME=$(hostname -s)
MOUNT_SCRIPT="${DIR}/2-mount-${HOSTNAME}.sh"

echo -e "${BOLD}AI Stack Setup${RESET}"
echo    "────────────────────────────────────────"

# ── Step 1: Drive configuration ───────────────────────────────────────────────
header "Step 1: Drive configuration"

if [[ -f "$MOUNT_SCRIPT" ]]; then
    info "Found existing ${MOUNT_SCRIPT##*/} — skipping drive configuration"
    info "To reconfigure drives, delete it and re-run setup.sh"
else
    info "No mount script found — running 1-configure-drives.sh..."
    bash "${DIR}/1-configure-drives.sh"
fi

# ── Step 2: Mount drives ───────────────────────────────────────────────────────
header "Step 2: Mount drives"

if [[ ! -f "$MOUNT_SCRIPT" ]]; then
    echo -e "${RED}  ${MOUNT_SCRIPT##*/} not found — drive configuration may have been skipped.${RESET}" >&2
    exit 1
fi

bash "$MOUNT_SCRIPT"

# ── Step 3: Secrets ───────────────────────────────────────────────────────────
header "Step 3: Secrets"

bash "${DIR}/3-configure-secrets.sh"

# ── Step 4: Host configuration ────────────────────────────────────────────────
header "Step 4: Host configuration"

bash "${DIR}/4-configure-host.sh"

# ── Step 5: Build local images ────────────────────────────────────────────────
header "Step 5: Build local images"

bash "${DIR}/build-images.sh"

# ── Start the stack ───────────────────────────────────────────────────────────
header "Starting ai-stack.service"

sudo systemctl start ai-stack.service
sudo systemctl status ai-stack.service --no-pager --lines=5

echo
echo "────────────────────────────────────────"
echo -e "${GREEN}${BOLD}  Setup complete.${RESET}"
