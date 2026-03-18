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
# Auto-generated keys: add entries to AUTO_GENERATE below. When a key is empty
# in the template, the user is prompted but can press Enter to accept the
# auto-generated value.
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

# ── Auto-generated keys ────────────────────────────────────────────────────────
# Keys listed here are prompted but the user can press Enter to accept the
# auto-generated value.
declare -A AUTO_GENERATE
AUTO_GENERATE["LITELLM_MASTER_KEY"]='printf "sk-%s" "$(openssl rand -hex 16)"'
AUTO_GENERATE["POSTGRES_PASSWORD"]='openssl rand -hex 16'
AUTO_GENERATE["SEARXNG_SECRET_KEY"]='openssl rand -hex 32'
AUTO_GENERATE["N8N_ENCRYPTION_KEY"]='openssl rand -hex 32'

# ── Derived keys ───────────────────────────────────────────────────────────────
# Keys listed here are computed automatically from other already-set values.
# No prompting — the expression is eval'd and the result written to the .env file.
declare -A DERIVE
DERIVE["DATA_SOURCE_NAME"]='pw=$(grep "^POSTGRES_PASSWORD=" "$env_file" | cut -d= -f2-); printf "postgresql://postgres:%s@postgres:5432/postgres?sslmode=disable" "$pw"'
DERIVE["DATABASE_URL"]='pw=$(grep "^POSTGRES_PASSWORD=" "$AI_DIR/postgres/.env" | cut -d= -f2-); printf "postgresql://postgres:%s@postgres:5432/litellm" "$pw"'
DERIVE["GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH"]='em=$(grep "^GF_ADMIN_EMAIL=" "$env_file" | cut -d= -f2-); [[ -n "$em" ]] && printf "email == '"'"'%s'"'"' && '"'"'Admin'"'"' || '"'"'Viewer'"'"'" "$em"'
DERIVE["DB_POSTGRESDB_PASSWORD"]='grep "^POSTGRES_PASSWORD=" "$AI_DIR/postgres/.env" | cut -d= -f2-'

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

            # Has a DERIVE expression — compute the value automatically
            if [[ -n "${DERIVE[$key]+x}" ]]; then
                derived_val="$(eval "${DERIVE[$key]}")"
                if [[ -n "$derived_val" ]]; then
                    echo "${key}=${derived_val}" >> "$env_file"
                    info "Set ${key} (derived)"
                    CHANGES=$((CHANGES+1))
                    pending_comment=""
                    continue
                fi
                # Derivation failed (dependency not yet set) — fall through to prompt
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

            # Pre-generate a default value if this key has an auto-generator
            generated=""
            [[ -n "${AUTO_GENERATE[$key]+x}" ]] && generated="$(eval "${AUTO_GENERATE[$key]}")"

            value=""
            if [[ -n "$generated" ]]; then
                # Sensitive: don't display generated value; non-sensitive: show it
                if $is_secret; then
                    read -r -s -p "  ${key} (press Enter to auto-generate, or type override, hidden): " value; echo
                else
                    read -r -p "  ${key} [${generated}]: " value
                fi
                [[ -z "$value" ]] && value="$generated"
            else
                if $is_secret; then
                    read -r -s -p "  ${key} (hidden, Enter to skip): " value; echo
                else
                    read -r -p "  ${key} (Enter to skip): " value
                fi
            fi

            echo "${key}=${value}" >> "$env_file"
            info "Set ${key}"
            CHANGES=$((CHANGES+1))
            pending_comment=""
        fi
    done 3< "$template"

done 4< <({
    # postgres must come first so DATABASE_URL in litellm/.env can be derived from it
    [[ -f "$AI_DIR/postgres/.env.template" ]] && printf '%s\0' "$AI_DIR/postgres/.env.template"
    find "$AI_DIR" -name ".env.template" ! -path "*/postgres/.env.template" -print0 2>/dev/null | sort -z
})

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if [[ $CHANGES -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}  $CHANGES secret(s) configured.${RESET}"
else
    echo -e "${GREEN}${BOLD}  All secrets already set — nothing to do.${RESET}"
fi
