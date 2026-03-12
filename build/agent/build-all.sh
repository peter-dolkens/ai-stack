#!/bin/bash
# Build all three agent tier images from the shared agent Dockerfile.
# Run from /ai/build/agent/ or via: bash /ai/build/agent/build-all.sh

set -e
cd "$(dirname "$0")"

echo "==> Building agent:local (base)..."
docker build -t agent:local .

echo "==> Tagging tier images..."
docker tag agent:local agent-airgapped:local
docker tag agent:local agent-local:local
docker tag agent:local agent-online:local

echo "==> Building orchestrator..."
docker build -t orchestrator:local ../orchestrator

echo ""
echo "Done. Images available:"
docker images | grep -E "^(agent|orchestrator)"
