#!/bin/bash
# Usage: spawn-agent <tier> [task-id]
# Prints CONTAINER, TASK_ID, SSH connection string to stdout.
# On error, exits non-zero with a message on stderr.

TIER="${1:-}"
TASK_ID="${2:-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)}"

SHARED=/workspace/shared
AGENT_IMAGE="agent-${TIER}:local"
CONTAINER="agent-${TIER}-${TASK_ID}"

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "$TIER" ]]; then
    echo "Usage: spawn-agent <airgapped|local|online> [task-id]" >&2
    exit 1
fi

if [[ ! "$TIER" =~ ^(airgapped|local|online)$ ]]; then
    echo "Error: tier must be airgapped, local, or online" >&2
    exit 1
fi

if [[ ! -f "$SHARED/.ssh/orchestrator.pub" ]]; then
    echo "Error: orchestrator public key not found at $SHARED/.ssh/orchestrator.pub" >&2
    echo "Is the orchestrator container healthy?" >&2
    exit 1
fi

# ── Task directory ────────────────────────────────────────────────────────────
TASK_DIR="$SHARED/tasks/$TASK_ID"
mkdir -p "$TASK_DIR"

cat > "$TASK_DIR/meta.json" <<EOF
{
  "task_id": "$TASK_ID",
  "tier": "$TIER",
  "container": "$CONTAINER",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ── Launch container ───────────────────────────────────────────────────────────
echo "[spawn-agent] Launching $CONTAINER ($TIER)..." >&2

docker run -d \
    --name "$CONTAINER" \
    --hostname "$CONTAINER" \
    --network agent-net \
    --cap-add NET_ADMIN \
    --env NETWORK_TIER="$TIER" \
    --env TASK_ID="$TASK_ID" \
    --volume ai-shared:/workspace/shared \
    --label ai.agent=true \
    --label ai.agent.tier="$TIER" \
    --label ai.agent.task="$TASK_ID" \
    "$AGENT_IMAGE" >/dev/null

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo "[spawn-agent] Waiting for SSH on $CONTAINER..." >&2
for i in $(seq 1 30); do
    if docker exec "$CONTAINER" test -f /run/sshd.pid 2>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Error: SSH did not start within 30s on $CONTAINER" >&2
        docker logs "$CONTAINER" >&2
        exit 1
    fi
    sleep 1
done

# ── Output ────────────────────────────────────────────────────────────────────
echo "CONTAINER=$CONTAINER"
echo "TASK_ID=$TASK_ID"
echo "TIER=$TIER"
echo "SSH=ssh agent@$CONTAINER"
echo ""
echo "[spawn-agent] Agent ready. Run tasks with:" >&2
echo "  ssh agent@$CONTAINER 'claude --dangerously-skip-permissions \"your task\"'" >&2
echo "  Results → /workspace/shared/tasks/$TASK_ID/" >&2
