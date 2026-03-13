#!/usr/bin/env bash
# Build litellm:local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker buildx build \
    -t litellm:local \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"
