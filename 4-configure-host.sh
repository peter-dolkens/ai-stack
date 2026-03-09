#!/usr/bin/env bash
# 4-configure-host.sh — Idempotent host setup for the AI stack
# Run as the regular user. Uses NOPASSWD sudo for privileged steps.
# Safe to re-run at any time.

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; WARNINGS=$((WARNINGS+1)); }
info()   { echo -e "  ${CYAN}→${RESET}  $*"; }
fail()   { echo -e "  ${RED}✗${RESET}  $*"; ERRORS=$((ERRORS+1)); }
header() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

WARNINGS=0
ERRORS=0
CHANGES=0
changed() { CHANGES=$((CHANGES+1)); info "$*"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root. Run as your regular user — the script uses sudo for privileged steps.${RESET}" >&2
    exit 1
fi

AI_USER=$(id -un)

# ── Distro detection ──────────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
    echo -e "${RED}/etc/os-release not found — cannot detect distro.${RESET}" >&2
    exit 1
fi
source /etc/os-release
DISTRO_ID="${ID:-unknown}"          # fedora, ubuntu, debian, arch, ...
DISTRO_LIKE="${ID_LIKE:-}"          # space-separated list of parent distros

is_fedora_like() { [[ "$DISTRO_ID" == "fedora" || "$DISTRO_LIKE" == *"fedora"* || "$DISTRO_LIKE" == *"rhel"* ]]; }
is_debian_like() { [[ "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "ubuntu" || "$DISTRO_LIKE" == *"debian"* ]]; }

STACK_SERVICE=/ai/ai-stack.service
STACK_SERVICE_LINK=/etc/systemd/system/ai-stack.service
CDI_SPEC=/etc/cdi/nvidia.yaml
DOCKER_DAEMON=/etc/docker/daemon.json
PROXY_NETWORK=proxy

echo -e "${BOLD}AI Stack Host Setup${RESET}"
echo    "────────────────────────────────────────"

# ── 1. Dependencies ───────────────────────────────────────────────────────────
header "Dependencies (distro: $DISTRO_ID)"

# ── Docker ────────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    ok "docker ($(docker --version | awk '{print $3}' | tr -d ','))"
else
    info "docker not found — installing..."
    if is_fedora_like; then
        sudo curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo \
            -o /etc/yum.repos.d/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    elif is_debian_like; then
        sudo apt-get update -qq
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DISTRO_ID} ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    else
        fail "Unsupported distro '$DISTRO_ID' — install docker manually"
    fi
    if command -v docker &>/dev/null; then
        sudo systemctl enable --now docker
        changed "Installed and started docker"
    else
        fail "docker installation failed"
    fi
fi

# ── NVIDIA container toolkit (nvidia-ctk) ────────────────────────────────────
if command -v nvidia-ctk &>/dev/null; then
    ok "nvidia-ctk ($(nvidia-ctk --version 2>/dev/null | awk '{print $NF}'))"
else
    info "nvidia-ctk not found — installing nvidia-container-toolkit..."
    if is_fedora_like; then
        # Available in Fedora repos as golang-github-nvidia-container-toolkit
        sudo dnf install -y golang-github-nvidia-container-toolkit
    elif is_debian_like; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
    else
        fail "Unsupported distro '$DISTRO_ID' — install nvidia-container-toolkit manually"
    fi
    command -v nvidia-ctk &>/dev/null \
        && changed "Installed nvidia-container-toolkit" \
        || fail "nvidia-ctk installation failed"
fi

# ── NVIDIA drivers (nvidia-smi) ───────────────────────────────────────────────
# Driver installation requires a reboot and is too risky to automate.
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    ok "nvidia-smi (driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1))"
else
    fail "nvidia-smi not found or GPU not accessible — install NVIDIA drivers manually then reboot"
    echo -e "       Fedora: sudo dnf install akmod-nvidia (RPM Fusion required)" >&2
    echo -e "       Ubuntu: sudo ubuntu-drivers autoinstall" >&2
fi

if [[ $ERRORS -gt 0 ]]; then
    echo -e "\n${RED}Dependency errors — fix the above before continuing.${RESET}"
    exit 1
fi

# ── 2. User group membership ──────────────────────────────────────────────────
header "User: $AI_USER → docker group"

if id -nG "$AI_USER" 2>/dev/null | grep -qw docker; then
    ok "$AI_USER is already in the docker group"
else
    sudo usermod -aG docker "$AI_USER"
    changed "Added $AI_USER to docker group (re-login or newgrp docker to activate)"
fi

# ── 3. Docker daemon config ───────────────────────────────────────────────────
header "Docker daemon (CDI + NVIDIA runtime)"

# Expected daemon.json content
EXPECTED_DAEMON='{
    "features": {
        "cdi": true
    },
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }
}'

# Read current content (may not exist)
CURRENT_DAEMON=$(sudo cat "$DOCKER_DAEMON" 2>/dev/null || echo '{}')

needs_cdi=$(echo "$CURRENT_DAEMON"    | grep -c '"cdi": true'                    || true)
needs_nvrt=$(echo "$CURRENT_DAEMON"   | grep -c '"nvidia-container-runtime"'     || true)

if [[ "$needs_cdi" -gt 0 && "$needs_nvrt" -gt 0 ]]; then
    ok "$DOCKER_DAEMON already has CDI and nvidia runtime"
else
    echo "$EXPECTED_DAEMON" | sudo tee "$DOCKER_DAEMON" > /dev/null
    changed "Updated $DOCKER_DAEMON (CDI + nvidia runtime)"
    info "Restarting Docker to apply daemon changes..."
    sudo systemctl restart docker
    ok "Docker restarted"
fi

# ── 4. NVIDIA CDI spec ────────────────────────────────────────────────────────
header "NVIDIA CDI device spec ($CDI_SPEC)"

sudo mkdir -p /etc/cdi

REGEN=false
if [[ ! -f "$CDI_SPEC" ]]; then
    REGEN=true
    info "CDI spec missing — will generate"
fi

if [[ -f "$CDI_SPEC" ]]; then
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    if [[ -n "$DRIVER_VER" ]] && ! grep -q "$DRIVER_VER" "$CDI_SPEC" 2>/dev/null; then
        REGEN=true
        info "Driver version mismatch in CDI spec — will regenerate"
    fi
fi

if $REGEN; then
    sudo nvidia-ctk cdi generate --output="$CDI_SPEC"
    changed "Generated $CDI_SPEC"
else
    ok "$CDI_SPEC is present and up to date"
fi

if sudo nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"; then
    ok "CDI device nvidia.com/gpu=all is available"
else
    warn "nvidia.com/gpu=all not listed in CDI — check: sudo nvidia-ctk cdi list"
fi

# ── 5. Docker proxy network ───────────────────────────────────────────────────
header "Docker network: $PROXY_NETWORK"

if sudo docker network inspect "$PROXY_NETWORK" &>/dev/null; then
    ok "Docker network '$PROXY_NETWORK' exists"
else
    sudo docker network create "$PROXY_NETWORK"
    changed "Created Docker network '$PROXY_NETWORK'"
fi

# ── 6. Mount point directories ────────────────────────────────────────────────
header "Mount point directories"

DIRS=(
    /ai/frigate/disk1
    /ai/frigate/disk2
    /ai/frigate/cache
    /ai/frigate/media
    /ai/models
    /ai/vector-db
    /ai/nginx/conf.d
    /ai/open-webui
)

for dir in "${DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        ok "$dir"
    else
        sudo mkdir -p "$dir"
        changed "Created $dir"
    fi
done

# ── 7. fstab mounts ───────────────────────────────────────────────────────────
header "fstab mounts"

MOUNTS=(
    /ai/frigate/disk1
    /ai/frigate/disk2
    /ai/models
    /ai/vector-db
    /ai/frigate/cache
)

for mnt in "${MOUNTS[@]}"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        ok "$mnt"
    else
        warn "$mnt is NOT mounted — check /etc/fstab and run: sudo mount $mnt"
    fi
done

# ── 8. SELinux: ai-stack.service ─────────────────────────────────────────────
header "SELinux context: $STACK_SERVICE"

if ! command -v semanage &>/dev/null; then
    ok "SELinux not present — skipping"
else
    SELINUX_TYPE=systemd_unit_file_t
    SELINUX_PATTERN="/ai/ai-stack\\.service"

    # -C lists only custom (locally-added) policies — small, fast, no SIGPIPE risk
    if sudo semanage fcontext -l -C 2>/dev/null | grep -q "ai-stack"; then
        ok "SELinux fcontext rule is present"
    else
        sudo semanage fcontext -a -t "$SELINUX_TYPE" "$SELINUX_PATTERN"
        changed "Added SELinux fcontext rule: $STACK_SERVICE → $SELINUX_TYPE"
    fi

    # Always check actual context on the file (resets on every edit)
    if ls -Z "$STACK_SERVICE" 2>/dev/null | grep -q "$SELINUX_TYPE"; then
        ok "File context is correct ($SELINUX_TYPE)"
    else
        sudo restorecon -v "$STACK_SERVICE"
        changed "Restored SELinux context on $STACK_SERVICE"
    fi
fi

# ── 9. Systemd service ────────────────────────────────────────────────────────
header "Systemd: ai-stack.service"

if [[ ! -f "$STACK_SERVICE" ]]; then
    fail "$STACK_SERVICE not found — cannot set up systemd service"
else
    ok "$STACK_SERVICE exists"

    if [[ -L "$STACK_SERVICE_LINK" ]] && \
       [[ "$(readlink -f "$STACK_SERVICE_LINK")" == "$(readlink -f "$STACK_SERVICE")" ]]; then
        ok "Symlink $STACK_SERVICE_LINK exists"
    else
        sudo ln -sf "$STACK_SERVICE" "$STACK_SERVICE_LINK"
        changed "Created symlink $STACK_SERVICE_LINK → $STACK_SERVICE"
    fi

    sudo systemctl daemon-reload

    if sudo systemctl is-enabled ai-stack.service &>/dev/null; then
        ok "ai-stack.service is enabled"
    else
        sudo systemctl enable ai-stack.service
        changed "Enabled ai-stack.service"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}${BOLD}  $ERRORS error(s) — manual action required.${RESET}"
fi
if [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}  $WARNINGS warning(s).${RESET}"
fi
if [[ $CHANGES -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}  $CHANGES change(s) applied.${RESET}"
fi
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 && $CHANGES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All checks passed — nothing to do.${RESET}"
fi

[[ $ERRORS -eq 0 ]]
