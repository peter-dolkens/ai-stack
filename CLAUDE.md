# Claude Session Notes

## Vendored Submodules

- `vendor/frigate` — git submodule pointing to `git@github.com:peter-dolkens/frigate.git`
- Inside the submodule, `upstream` remote = `blakeblackshear/frigate`
- After cloning `/ai`, run `git submodule update --init` to populate `vendor/frigate`

## SELinux Notes

- `/ai/ai-stack.service` requires `systemd_unit_file_t` context
- Persistent policy already set: `semanage fcontext -a -t systemd_unit_file_t '/ai/ai-stack\.service'`
- **Context resets on every file edit** — always run after editing the service file:
  ```
  sudo restorecon -v /ai/ai-stack.service && sudo systemctl daemon-reload
  ```

---

## Adding a New Service — Checklist & Patterns

### 1. Compose file (`compose/<name>.yaml`)

- `name:` must match the service name (top-level key, independent project)
- `container_name:` must match the service name (used for DNS resolution)
- `restart: unless-stopped`
- Networks:
  - Always include `proxy` (external) if nginx will front it
  - Include `postgres` (external) if the service uses the shared postgres instance
  - Do NOT add to `monitoring` — prometheus reaches services via the `proxy` network
- Volumes: bind-mount data to `/ai/<name>/data` (or `/ai/<name>` for config-style services)
- Secrets go in `env_file: /ai/<name>/.env`; non-secret config goes inline in `environment:`
- Only use tmpfs for genuinely ephemeral data (e.g. video buffer cache). Application data, installed plugins/extensions, and binary execution data must use bind mounts.

### 2. Secrets template (`<name>/.env.template`)

- One template file per service; `3-configure-secrets.sh` picks it up automatically
- Keys containing `PASSWORD`, `SECRET`, `TOKEN`, or `KEY` get hidden input
- To auto-generate a secret: add it to `AUTO_GENERATE` in `3-configure-secrets.sh`
- To derive from another secret (e.g. postgres password): add it to `DERIVE`
- Current AUTO_GENERATE keys: `LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD`, `SEARXNG_SECRET_KEY`, `N8N_ENCRYPTION_KEY`, `OAUTH2_PROXY_COOKIE_SECRET`
- Current DERIVE keys: `DATA_SOURCE_NAME`, `DATABASE_URL`, `GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH`, `DB_POSTGRESDB_PASSWORD`

### 3. Gitignore (`/.gitignore`)

Add two lines:
```
<name>/.env
<name>/data/
```

### 4. Nginx vhost (`nginx/conf.d/<name>.conf`)

Standard pattern:
```nginx
server {
    listen 80;
    server_name <name>.dolkens.net <name>.dolkens.au;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name <name>.dolkens.net <name>.dolkens.au;

    ssl_certificate     /etc/letsencrypt/live/<name>.dolkens.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<name>.dolkens.net/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Include WebSocket headers if the service uses them
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    resolver 127.0.0.11 valid=10s;
    set $upstream http://<name>:<port>;

    location / {
        proxy_pass $upstream;
    }
}
```

- Always include both `.dolkens.net` and `.dolkens.au` in `server_name`
- Cert path always references the `.net` domain
- Certbot auto-issues a SAN cert covering both `.net` and `.au` on restart — no separate cert needed
- Use `set $upstream` + `resolver 127.0.0.11` to avoid nginx failing at startup if the upstream container isn't up yet
- `client_max_body_size 0` for services that accept file uploads

### 5. Systemd service (`ai-stack.service`)

- Add `ExecStart` after its dependencies (postgres before anything that uses it, before nginx)
- Add matching `ExecStop` in reverse order (before its dependencies stop)
- After editing: `sudo restorecon -v /ai/ai-stack.service && sudo systemctl daemon-reload`

### 6. Makefile

- Add `compose/<name>.yaml` to `COMPOSE_FILES` in the same position as the service order in `ai-stack.service`

### 7. Postgres database (if needed)

Create the database before first start:
```
sudo docker exec postgres psql -U postgres -c "CREATE DATABASE <name>;"
```

### 8. First start

```bash
sudo docker compose -f /ai/compose/<name>.yaml up -d
sudo docker logs <name>   # verify startup
```

Certbot will issue the TLS cert automatically on its next run (triggered by nginx restart). If nginx was already running and fails due to missing cert, restart nginx after certbot completes.

### 9. Prometheus scraping (if the service exposes metrics)

- Enable metrics via env vars in the compose file
- Add a scrape job to `prometheus/prometheus.yml`
- Prometheus reaches services on the `proxy` network — use `<name>.proxy:<port>` as the target (not just `<name>:<port>`, which only resolves on the `monitoring` network)
- Reload: `sudo docker compose -f /ai/compose/monitoring.yaml restart prometheus`

### 10. Grafana dashboard

- Place JSON in `grafana/provisioning/dashboards/<name>.json`
- Reference the datasource by name string (`"Prometheus"`, `"openwebui-sqlite"`) — not by uid object
- Grafana hot-reloads provisioned dashboards every 60 seconds; no restart needed
- Use `uid: "<name>-dashboard"` to make the dashboard URL predictable

### DNS

- Add Unifi DNS override for `<name>.dolkens.net` → `10.24.1.130` for local LAN access
- `<name>.dolkens.au` external access is handled by the Cloudflare Tunnel on the HA machine — add a DNS record there pointing to the tunnel

---

## Adding a New MCP Server

All MCP servers live in a single compose file (`compose/mcp.yaml`) and are routed via path prefix under `mcp.dolkens.net/<name>`.

### 1. Add service to `compose/mcp.yaml`

```yaml
  <name>-mcp:
    image: <image>
    container_name: <name>-mcp
    restart: unless-stopped
    networks:
      - proxy
    volumes:
      - /ai/mcp/<name>-mcp/data:/app/data
    env_file:
      - /ai/mcp/<name>-mcp/.env
    environment:
      - MCP_MODE=http
      - PORT=3000
```

### 2. Add nginx location block to `nginx/conf.d/n8n-mcp.conf`

```nginx
location /<name>/ {
    set $upstream http://<name>-mcp:3000;
    rewrite ^/<name>/(.*) /$1 break;
    proxy_pass $upstream;
}
```

### 3. Create secrets template (`mcp/<name>-mcp/.env.template`)

```
# Bearer token for MCP clients to authenticate with this server
AUTH_TOKEN=

# Any service-specific credentials
MY_API_KEY=
```

`AUTH_TOKEN` is in `AUTO_GENERATE` — press Enter to auto-generate during `3-configure-secrets.sh`.

### 4. Add to `.gitignore`

Already covered by the glob patterns `mcp/*/.env` and `mcp/*/data/` — no changes needed.

### 5. Deploy

```bash
cd /ai && bash 3-configure-secrets.sh   # set AUTH_TOKEN + service credentials
sudo docker compose -f /ai/compose/mcp.yaml up -d
sudo docker compose -f /ai/compose/nginx.yaml restart
```

### MCP Architecture Notes

- All MCP containers on `proxy` network — internal clients (n8n, OpenWebUI) reach them at `http://<name>-mcp:3000`
- External clients (Claude Code, etc.) use `https://mcp.dolkens.net/<name>/` with `AUTH_TOKEN` as Bearer token
- No separate DNS entry needed — single `mcp.dolkens.net` / `mcp.dolkens.au` covers all servers
- `mcp.dolkens.net` Unifi DNS override → `10.24.1.130` (one-time, already covers all MCP paths)
- Cloudflare Tunnel route for `mcp.dolkens.au` on HA machine (one-time)
- Data at `/ai/mcp/<name>-mcp/data/` (bind mount, survives restarts)

---

## Services Added

| Service | Compose | Port | URL |
|---------|---------|------|-----|
| n8n | `compose/n8n.yaml` | 5678 | `n8n.dolkens.net` / `n8n.dolkens.au` |
| n8n-mcp | `compose/mcp.yaml` | 3000 (internal) | `mcp.dolkens.net/n8n/` / `mcp.dolkens.au/n8n/` |

### n8n Workflow Provisioning

- Workflow snapshots (for provisioning/version control) live at `/ai/n8n/workflows/<name>.workflow.json`
- Export via n8n MCP: `n8n_get_workflow` with `mode=full`, save the `data` object to the file
- To provision all workflows: `make n8n-provision` (pushes all `n8n/workflows/*.json` via `n8n/provision.sh`)

### n8n Notes

- Uses shared postgres instance (`n8n` database — create manually before first start)
- Data at `/ai/n8n/data` — bind mount on root NVMe. **Do not use tmpfs**: the data dir holds installed community nodes, binary execution data (referenced by PostgreSQL), and config — all need to survive restarts
- Metrics enabled via `N8N_METRICS=true`; scraped by prometheus at `n8n.proxy:5678/metrics`
- Grafana dashboard at `grafana/provisioning/dashboards/n8n.json` (uid: `n8n-dashboard`)
- **Google OAuth** via `n8n-oauth2-proxy` (oauth2-proxy container, port 4180) — nginx proxies to oauth2-proxy which gates access to n8n. Webhook paths (`/webhook/`, `/webhook-test/`, `/webhook-waiting/`) bypass auth. oauth2-proxy uses the incoming request's host to build the callback URL dynamically — register both `https://n8n.dolkens.net/oauth2/callback` and `https://n8n.dolkens.au/oauth2/callback` in Google Cloud Console.
- Consider enabling execution pruning for high-frequency workflows:
  ```
  N8N_METRICS_PRUNE=true
  EXECUTIONS_DATA_PRUNE=true
  EXECUTIONS_DATA_MAX_AGE=168
  ```
