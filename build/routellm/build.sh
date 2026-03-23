#!/usr/bin/env bash
# Build routellm:local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker buildx build \
    -t routellm:local \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"
