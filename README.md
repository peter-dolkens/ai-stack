# AI Stack

Self-hosted AI inference stack running on a dedicated Fedora machine (Ryzen 5800X, RTX 3090).

Provides LLM, speech-to-text, text-to-speech, and camera AI services to Home Assistant and the home network.

## Services

| Container | Purpose | Access |
|-----------|---------|--------|
| [ollama](compose/ollama.yaml) | LLM inference | `<hostname>.dolkens.net:11434` |
| [whisper](compose/whisper.yaml) | Speech-to-text (Wyoming) | `<hostname>.dolkens.net:10300` |
| [piper](compose/piper.yaml) | Text-to-speech (Wyoming) | `<hostname>.dolkens.net:10200` |
| [frigate](compose/frigate.yaml) | Camera NVR + object detection | `frigate.dolkens.net` |
| [postgres](compose/postgres.yaml) | Shared PostgreSQL instance | internal only |
| [litellm](compose/litellm.yaml) | LLM proxy (Ollama + cloud providers) | `llm.dolkens.net` |
| [openwebui](compose/openwebui.yaml) | LLM chat interface | `chat.dolkens.net` |
| [nginx](compose/nginx.yaml) | Reverse proxy + TLS | ports 80, 443 |
| [certbot](build/certbot/) | Let's Encrypt (Cloudflare DNS-01) | — |

All services are managed by `ai-stack.service` and start automatically on boot.

## Setup

On a fresh machine, run:

```bash
./setup.sh
```

This runs the following steps in order:

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `1-configure-drives.sh` | Interactive drive assignment → generates `2-mount-<hostname>.sh` |
| 2 | `2-mount-<hostname>.sh` | Applies fstab entries and mounts |
| 3 | `3-configure-secrets.sh` | Populates `.env` files from `.env.template` files |
| 4 | `4-configure-host.sh` | Docker, NVIDIA CDI, SELinux, systemd |
| — | `setup.sh` | Starts `ai-stack.service` |

All steps are idempotent — safe to re-run at any time.

For machine-specific drive configuration, `1-configure-drives.sh` will scan your drives and generate a `2-mount-<hostname>.sh` script. For cassowary (this machine), `2-mount-cassowary.sh` is already provided.

## Secrets

Each service that requires secrets has a `.env.template` file alongside it. Run `3-configure-secrets.sh` (or `setup.sh`) to be prompted for missing values:

| File | Keys |
|------|------|
| `nginx/.env` | `CLOUDFLARE_API_TOKEN`, `CERTBOT_EMAIL` |
| `frigate/.env` | `FRIGATE_MQTT_PASSWORD` |
| `open-webui/.env` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| `postgres/.env` | `POSTGRES_PASSWORD` |
| `litellm/.env` | `LITELLM_MASTER_KEY`, `DATABASE_URL`, optional cloud API keys |

`.env` files are gitignored and never committed.

## Documentation

See [PLAN.md](PLAN.md) for full architecture, hardware, storage layout, Frigate configuration, and DNS/routing details.
