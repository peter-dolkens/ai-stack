#!/usr/bin/env bash
# 3-configure-secrets.sh — Populate .env files from .env.template files
#
# Scans for *.env.template files under /ai, then for each KEY= entry checks
# whether the matching .env already has a value. Prompts only for missing keys.
# Never overwrites an existing value.
# Safe to re-run at any time.
#
# To add a new secret: add KEY= (with optional comment) to the relevant
# .env.template file — this script will pick it up automatically.
#
# Secret detection: keys whose names contain PASSWORD, SECRET, TOKEN, or KEY
# are treated as sensitive — input is hidden during entry.
#
# Run as your regular user.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
ok()     { echo -e "  ${GREEN}✓${RESET}  $*"; }
info()   { echo -e "  ${CYAN}→${RESET}  $*"; }

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root.${RESET}" >&2; exit 1
fi

AI_DIR="$(cd "$(dirname "$0")" && pwd)"
CHANGES=0

echo -e "${BOLD}AI Stack Secret Configuration${RESET}"
echo    "────────────────────────────────────────"

# ── Process each template ─────────────────────────────────────────────────────
while IFS= read -r -d '' template <&4; do
    env_file="${template%.template}"
    rel="${template#"$AI_DIR/"}"
    header "${rel}"

    # Ensure the .env file and its directory exist
    mkdir -p "$(dirname "$env_file")"
    [[ -f "$env_file" ]] || touch "$env_file"

    pending_comment=""

    while IFS= read -r line <&3; do
        # Accumulate comment lines to show as context when prompting
        if [[ "$line" =~ ^# ]]; then
            pending_comment+="${line#\# }"$'\n'
            continue
        fi

        # Blank lines reset the comment buffer
        if [[ -z "$line" ]]; then
            pending_comment=""
            continue
        fi

        # KEY=value or KEY= lines
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            default="${BASH_REMATCH[2]}"

            # Already present in .env (with or without a value)?
            if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
                if grep -qE "^${key}=.+" "$env_file" 2>/dev/null; then
                    ok "${key} already set"
                else
                    ok "${key} present but empty — skipping (set manually if needed)"
                fi
                pending_comment=""
                continue
            fi

            # Has a default value in the template — write it without prompting
            if [[ -n "$default" ]]; then
                echo "${key}=${default}" >> "$env_file"
                info "Set ${key} to template default"
                CHANGES=$((CHANGES+1))
                pending_comment=""
                continue
            fi

            # Needs user input — show accumulated comment as context
            echo
            [[ -n "$pending_comment" ]] && echo -e "  ${CYAN}${pending_comment%$'\n'}${RESET}"

            # Detect sensitive keys
            is_secret=false
            [[ "$key" =~ (PASSWORD|SECRET|TOKEN|KEY) ]] && is_secret=true

            value=""
            while [[ -z "$value" ]]; do
                if $is_secret; then
                    read -r -s -p "  ${key} (hidden): " value; echo
                else
                    read -r -p "  ${key}: " value
                fi
                [[ -z "$value" ]] && echo "  Value cannot be empty."
            done

            echo "${key}=${value}" >> "$env_file"
            info "Set ${key}"
            CHANGES=$((CHANGES+1))
            pending_comment=""
        fi
    done 3< "$template"

done 4< <(find "$AI_DIR" -name ".env.template" -print0 | sort -z)

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if [[ $CHANGES -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}  $CHANGES secret(s) configured.${RESET}"
else
    echo -e "${GREEN}${BOLD}  All secrets already set — nothing to do.${RESET}"
fi
