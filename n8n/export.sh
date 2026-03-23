#!/usr/bin/env bash
# Export all n8n workflows to /ai/n8n/workflows/*.workflow.json
# Matches existing files by the id field in the JSON; new workflows get a
# filename derived from their name. Safe to run repeatedly — overwrites in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="$SCRIPT_DIR/workflows"
N8N_ENV="$SCRIPT_DIR/../mcp/n8n-mcp/.env"
N8N_BASE_URL="${N8N_BASE_URL:-https://n8n.dolkens.net}"

# Load N8N_API_KEY from env file if not already set
if [[ -z "${N8N_API_KEY:-}" && -f "$N8N_ENV" ]]; then
    N8N_API_KEY="$(grep '^N8N_API_KEY=' "$N8N_ENV" | cut -d= -f2-)"
fi

if [[ -z "${N8N_API_KEY:-}" ]]; then
    echo "ERROR: N8N_API_KEY not set and not found in $N8N_ENV" >&2
    exit 1
fi

API="$N8N_BASE_URL/api/v1"
AUTH_HEADER="X-N8N-API-KEY: $N8N_API_KEY"

mkdir -p "$WORKFLOWS_DIR"

# Build id → existing file path index
declare -A existing_files
shopt -s nullglob
for f in "$WORKFLOWS_DIR"/*.workflow.json; do
    fid="$(jq -r '.id // empty' "$f" 2>/dev/null)"
    [[ -n "$fid" ]] && existing_files["$fid"]="$f"
done

total=0
cursor=""

while true; do
    url="$API/workflows?limit=100"
    [[ -n "$cursor" ]] && url="$url&cursor=$cursor"

    response="$(curl -sf -H "$AUTH_HEADER" "$url")"

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        workflow="$(curl -sf -H "$AUTH_HEADER" "$API/workflows/$id")"
        name="$(echo "$workflow" | jq -r '.name')"

        if [[ -n "${existing_files[$id]:-}" ]]; then
            outfile="${existing_files[$id]}"
        else
            safe_name="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
            outfile="$WORKFLOWS_DIR/${safe_name}.workflow.json"
        fi

        echo "$workflow" | jq '.' > "$outfile"
        echo "Exported: $name ($id) → $(basename "$outfile")"
        ((total++))
    done < <(echo "$response" | jq -r '.data[].id')

    cursor="$(echo "$response" | jq -r '.nextCursor // empty')"
    [[ -z "$cursor" ]] && break
done

echo "Done. Exported $total workflow(s)."
