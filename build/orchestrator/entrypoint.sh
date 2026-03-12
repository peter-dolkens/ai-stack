#!/bin/bash
set -e

SHARED=/workspace/shared
KEY_PRIV=/root/.ssh/orchestrator_key
KEY_PUB=/root/.ssh/orchestrator_key.pub

# Generate orchestrator SSH keypair once; publish public key to shared volume
if [[ ! -f "$KEY_PRIV" ]]; then
    echo "[orchestrator] Generating SSH keypair..."
    ssh-keygen -t ed25519 -N "" -C "orchestrator" -f "$KEY_PRIV"
fi

mkdir -p "$SHARED/.ssh" "$SHARED/tasks"
cp "$KEY_PUB" "$SHARED/.ssh/orchestrator.pub"
chmod 644 "$SHARED/.ssh/orchestrator.pub"

# Install host SSH public keys (populated by setup.sh → orchestrator.env)
if [[ -n "$AUTHORIZED_KEYS" ]]; then
    mkdir -p /root/.ssh
    # AUTHORIZED_KEYS may have literal \n between keys — expand them
    printf '%b\n' "$AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    KEY_COUNT=$(grep -c 'ssh-' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
    echo "[orchestrator] Installed $KEY_COUNT authorized key(s) from host."
else
    echo "[orchestrator] WARNING: No AUTHORIZED_KEYS set — SSH login disabled." >&2
    echo "[orchestrator]   Run: bash /ai/build/orchestrator/setup.sh" >&2
fi

echo "[orchestrator] Starting SSH server..."
/usr/sbin/sshd

echo "[orchestrator] Ready. Container: $(hostname)"
echo "[orchestrator] Claude Code: $(claude --version 2>/dev/null || echo 'not authenticated yet')"
echo ""
echo "  spawn-agent <airgapped|local|online> [task-id]"
echo "  list-agents"
echo "  kill-agent <container-name>"
echo ""

# Keep running — VSCode will exec into this container
exec sleep infinity
