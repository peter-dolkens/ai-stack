#!/bin/bash
# Usage: kill-agent <container-name-or-task-id>

INPUT="${1:-}"

if [[ -z "$INPUT" ]]; then
    echo "Usage: kill-agent <container-name-or-task-id>" >&2
    exit 1
fi

# Resolve full container name — accept exact name or partial task-id match
CONTAINER=$(docker ps --filter "label=ai.agent=true" --format "{{.Names}}" | grep -F "$INPUT" | head -1)

if [[ -z "$CONTAINER" ]]; then
    echo "[kill-agent] No running agent matching '$INPUT'" >&2
    exit 1
fi

echo "[kill-agent] Stopping $CONTAINER..."
docker stop "$CONTAINER" && docker rm "$CONTAINER"
echo "[kill-agent] Done."
