#!/usr/bin/env bash
# Build frigate-nvenc:local
# Uses a named BuildKit context to pull patched files from vendor/frigate
# without widening the main build context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

docker buildx build \
    -t frigate-nvenc:local \
    -f "${SCRIPT_DIR}/Dockerfile" \
    --build-context vendor-frigate="${REPO_ROOT}/vendor/frigate" \
    "${SCRIPT_DIR}"
