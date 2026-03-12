#!/usr/bin/env bash
# build-images.sh — Build all custom local Docker images under build/
#
# For each subdirectory of build/:
#   - If a build.sh exists alongside the Dockerfile, run it.
#   - Otherwise, run a plain: docker buildx build -t <dirname>:local <dir>
#
# Safe to re-run — Docker layer cache makes rebuilds fast when nothing changed.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()      { echo -e "  ${GREEN}✓${RESET}  $*"; }
info()    { echo -e "  ${CYAN}→${RESET}  $*"; }
fail()    { echo -e "  ${RED}✗${RESET}  $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

if [[ ! -d "$BUILD_DIR" ]]; then
    fail "build/ directory not found at ${BUILD_DIR}"
fi

header "Building local Docker images"

for dir in "${BUILD_DIR}"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}Dockerfile" ]] || continue

    name="$(basename "$dir")"

    if [[ -f "${dir}build.sh" ]]; then
        info "${name}: running build.sh"
        bash "${dir}build.sh" || fail "${name}: build.sh failed"
    else
        info "${name}: plain build → ${name}:local"
        docker buildx build -t "${name}:local" -f "${dir}Dockerfile" "$dir" \
            || fail "${name}: docker build failed"
    fi

    ok "${name} done"
done

echo
echo -e "${GREEN}${BOLD}  All images built.${RESET}"
