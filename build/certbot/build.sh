#!/usr/bin/env bash
# Build certbot-cloudflare:local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker buildx build \
    -t certbot-cloudflare:local \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"
