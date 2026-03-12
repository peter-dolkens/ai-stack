#!/bin/bash
set -e

SHARED=/workspace/shared
AGENT_AUTHORIZED_KEYS=/home/agent/.ssh/authorized_keys

# ── Authorize orchestrator SSH key ────────────────────────────────────────────
ORCH_PUB="$SHARED/.ssh/orchestrator.pub"
if [[ -f "$ORCH_PUB" ]]; then
    cat "$ORCH_PUB" > "$AGENT_AUTHORIZED_KEYS"
    chmod 600 "$AGENT_AUTHORIZED_KEYS"
    chown agent:agent "$AGENT_AUTHORIZED_KEYS"
    echo "[agent] Orchestrator SSH key installed."
else
    echo "[agent] WARNING: orchestrator.pub not found at $ORCH_PUB" >&2
    echo "[agent] SSH connections from orchestrator will fail." >&2
fi

# ── Apply network policy ───────────────────────────────────────────────────────
echo "[agent] Applying network policy: ${NETWORK_TIER:-airgapped}"
apply-network-policy

# ── Generate SSH host keys if needed ──────────────────────────────────────────
ssh-keygen -A

# ── Start SSH daemon ───────────────────────────────────────────────────────────
echo "[agent] Starting SSH server..."
/usr/sbin/sshd

echo "[agent] Ready. Tier=${NETWORK_TIER:-airgapped} Task=${TASK_ID:-none} Host=$(hostname)"

exec sleep infinity
