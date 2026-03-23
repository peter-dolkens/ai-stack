#!/usr/bin/env bash
# Provision n8n workflows from /ai/n8n/workflows/*.json
# Creates new workflows or updates existing ones (matched by id field in JSON).
# Sub-workflows (executeWorkflowTrigger) are provisioned first to resolve cross-references.
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

shopt -s nullglob
all_files=("$WORKFLOWS_DIR"/*.json)

if [[ ${#all_files[@]} -eq 0 ]]; then
    echo "No workflow JSON files found in $WORKFLOWS_DIR"
    exit 0
fi

# Sort: sub-workflows (executeWorkflowTrigger) first, then the rest
sub_workflows=()
main_workflows=()
for file in "${all_files[@]}"; do
    if jq -e '.nodes[] | select(.type == "n8n-nodes-base.executeWorkflowTrigger")' "$file" > /dev/null 2>&1; then
        sub_workflows+=("$file")
    else
        main_workflows+=("$file")
    fi
done
files=("${sub_workflows[@]}" "${main_workflows[@]}")

# Track old→new ID mappings for freshly created workflows
declare -A id_map

provision_workflow() {
    local file="$1"
    local name id status body response new_id

    name="$(jq -r '.name' "$file")"
    id="$(jq -r '.id // empty' "$file")"

    # Build API-safe body: only fields accepted by PUT/POST, strip server-managed settings
    body="$(jq '{name, nodes, connections, settings: (.settings // {} | del(.binaryMode))}' "$file")"

    if [[ -n "$id" ]]; then
        # Check if workflow exists
        status="$(curl -s -o /dev/null -w '%{http_code}' \
            -H "$AUTH_HEADER" \
            "$API/workflows/$id")"

        if [[ "$status" == "200" ]]; then
            echo "Updating workflow: $name ($id)"
            curl -s -X PUT "$API/workflows/$id" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d "$body" | jq '{id: .id, name: .name, active: .active, updatedAt: .updatedAt}'
            return
        else
            echo "WARNING: Workflow id $id not found in n8n (HTTP $status), creating as new: $name"
        fi
    else
        echo "Creating workflow: $name"
    fi

    response="$(curl -s -X POST "$API/workflows" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$body")"
    new_id="$(echo "$response" | jq -r '.id')"
    echo "$response" | jq '{id: .id, name: .name, active: .active}'

    if [[ -n "$id" && "$new_id" != "$id" ]]; then
        echo "  → ID changed: $id → $new_id"
        id_map["$id"]="$new_id"
    fi

    echo "  → Updating $file with new id: $new_id"
    tmp="$(mktemp)"
    jq --arg id "$new_id" '. + {id: $id}' "$file" > "$tmp" && mv "$tmp" "$file"
}

for file in "${files[@]}"; do
    provision_workflow "$file"
done

# Rewrite cross-references across all workflow files for any IDs that changed
if [[ ${#id_map[@]} -gt 0 ]]; then
    echo ""
    echo "Rewriting cross-references for changed IDs..."
    for file in "${all_files[@]}"; do
        content="$(cat "$file")"
        updated=false
        for old_id in "${!id_map[@]}"; do
            new_id="${id_map[$old_id]}"
            if echo "$content" | grep -q "$old_id"; then
                content="$(echo "$content" | sed "s/$old_id/${new_id}/g")"
                updated=true
                echo "  → $file: $old_id → $new_id"
            fi
        done
        if $updated; then
            echo "$content" > "$file"
        fi
    done
fi

echo "Done."
