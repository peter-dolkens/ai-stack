# Local AI Node

Dedicated local AI inference host. Provides voice assistant backend, camera AI, and LLM services to Home Assistant and the wider home network.

---

## Hardware

| Component | Spec |
|-----------|------|
| CPU | Ryzen 5800X |
| RAM | 32 GB (target: 64 GB) |
| GPU | RTX 3090 (+ RTX 3080 available for dual-GPU future) |
| OS | Fedora KDE Spin |

**Dual-GPU future**: 3090 → LLM/STT/embeddings, 3080 → Frigate. Requires 1000W+ PSU.

---

## Storage

| Device | Mount | Size | Purpose |
|--------|-------|------|---------|
| `nvme0n1p3` | `/`, `/home` | 464GB | Boot/root (btrfs, dual subvolume) |
| `nvme1n1p1` | btrfs pool (466GB) | 466GB | Flexible btrfs volume — subvolumes share all space |
| `tmpfs` | `/ai/frigate/cache` | 4GB | Frigate `/tmp/cache` — RAM-backed |
| `sda` (860 EVO 1TB) | `/ai/frigate/disk1` | 932GB | Recordings — SMART: excellent, 31,976h |
| `sdc` (860 EVO 1TB) | `/ai/frigate/disk2` | 932GB | Clips — SMART: excellent, 31,978h |
| `sde` (860 EVO 1TB) | `/ai/models` | 932GB | All model storage (ollama, whisper, piper, frigate) |
| `sdb` (850 EVO 500GB) | `/ai/vector-db` | 466GB | Vector DB / experiments |
| `sdd` (850 EVO 500GB) | *(unmounted)* | 466GB | ⚠️ 166 CRC errors — swap SATA cable first |

---

## Active Services

| Container | Image | Port | Notes |
|-----------|-------|------|-------|
| frigate | `frigate-nvenc:local` | 5000 (via nginx) | Custom FFmpeg 8.0.1 + NVENC |
| ollama | `ollama/ollama:latest` | 11434 | Models at `/ai/models/ollama` |
| whisper | `rhasspy/wyoming-whisper` | 10300 | `distil-large-v3`, CUDA; models at `/ai/models/whisper` |
| piper | `rhasspy/wyoming-piper` | 10200 | `en_GB-alan-medium`; voices at `/ai/models/piper` |
| openwebui | `ghcr.io/open-webui/open-webui:main` | 8080 (via nginx) | Data at `/ai/open-webui`; Google OAuth enabled |
| nginx | `nginx:alpine` | 80, 443 | Reverse proxy; shared `proxy` Docker network |
| certbot | `certbot-cloudflare:local` | — | DNS-01 via Cloudflare; cron renewal at 03:17 & 15:17 |
| prometheus | `prom/prometheus:latest` | 9090 (internal) | Metrics scraper; 30d retention; `/ai/prometheus/prometheus.yml` |
| grafana | `grafana/grafana:latest` | 3000 (via nginx) | Dashboards at `grafana.dolkens.net`; data at `grafana_data` volume |
| node_exporter | `prom/node-exporter:latest` | 9100 (internal) | Host system metrics (CPU, RAM, disk, network) |
| cadvisor | `gcr.io/cadvisor/cadvisor:latest` | 8080 (internal) | Container resource metrics |
| nvidia_gpu_exporter | `utkuozdemir/nvidia_gpu_exporter:1.2.0` | 9835 (internal) | RTX 3090 GPU metrics via nvidia-smi |
| nginx_exporter | `nginx/nginx-prometheus-exporter:latest` | 9113 (internal) | nginx stub_status metrics |

All compose files in `/ai/compose/`, each with `name:` for independent projects.
Shared Docker network `proxy` connects nginx, frigate, and openwebui — backends addressed by container name.
Startup: `ai-stack.service` → `/ai/ai-stack.service` (symlinked, SELinux context set).

---

## Frigate Configuration

- **Model**: rfdetr-Nano ONNX (`/ai/models/frigate/rfdetr-Nano.onnx`, 108MB)
  - `model_type: rfdetr`, `width/height: 320`, `input_dtype: float` (required — models expect float32, not uint8)
- **FFmpeg**: custom image built from FFmpeg 8.0.1 + nv-codec-headers n13.0.19.0
  - Fixes `NV_ENC_ERR_INCOMPATIBLE_CLIENT_KEY` (code 21) on driver 580.x (NVENC SDK 13 required)
  - `global_args: -init_hw_device cuda=gpu:0`, `hwaccel_args: -hwaccel cuda`, encode: `h264_nvenc -preset p4 -cq 26`
  - Do NOT switch to `-hwaccel cuvid` — breaks RTSP decoding
- **GPU stats**: Dockerfile patches `stats/util.py` to recognise `cuda` keyword; `cap_add: [PERFMON]` in compose
- **Storage**: recordings → disk1 (sda), clips → disk2 (sdc), segment cache → tmpfs (4GB RAM-backed at `/ai/frigate/cache`)
- **Cameras**: 10 active, dual-stream (record full-res + detect sub-stream via UniFi Protect)
- **MQTT**: host via `FRIGATE_MQTT_HOSTNAME`, user via `FRIGATE_MQTT_USERNAME`, password via `FRIGATE_MQTT_PASSWORD` env var (see `frigate/.env`)
- **DB**: `/media/frigate/frigate.db` (persisted in `/ai/frigate/media/`)
- **go2rtc**: H.264 passthrough for live view — no transcoding needed for UniFi cameras

### Stream Quality Strategy

Each camera uses **two UniFi Protect RTSP streams**:
- `HIGH` stream → `record` role (full native resolution from UniFi)
- `MEDIUM` stream → `detect` role (lower-res sub-stream; saves GPU/CPU on inference)

**Recording**: `output_args.record` uses `-c copy` — stream is copied directly with no re-encoding. This preserves the original UniFi Protect H.264 quality and avoids any encode overhead. NVENC is available but not used for recordings.

**Detection**: MEDIUM sub-stream resolution per camera (set explicitly under `detect: width/height`) — sized to match actual sub-stream output from UniFi Protect, not upscaled.

**Preview**: `quality: very_high` — Frigate-generated preview clips use the highest quality setting.

**Live view**: go2rtc serves the HIGH stream directly via H.264 passthrough — no server-side transcoding. UniFi cameras must be set to **Standard** encoding (H.264) — not Enhanced (H.265) or Advanced (AV1) — so browsers can decode the stream natively without Frigate needing to transcode.

### Camera FPS

| FPS | Cameras |
|-----|---------|
| 1 | shed-cam, bench-cam |
| 3 | drive-cam, bird-cam, creek-cam, fruit-patrol, willie-patrol, office-cam |
| 5 | door-cam, house-cam |

---

## nginx / HTTPS

Reverse proxy with automatic TLS via Let's Encrypt (Cloudflare DNS-01 challenge).

| vhost | Backend | URL |
|-------|---------|-----|
| `frigate.dolkens.net` / `frigate.dolkens.au` | `frigate:5000` | Frigate NVR |
| `chat.dolkens.net` / `chat.dolkens.au` | `openwebui:8080` | Open WebUI |

- nginx, frigate, and openwebui all share the external Docker network `proxy`; nginx routes by container name
- Config: `/ai/nginx/conf.d/*.conf` — add a new `.conf` to add a vhost; restart certbot to auto-issue cert
- Certbot image: `/ai/build/certbot/` — scans conf.d for domains, issues missing certs on startup, renews via cron
- Secrets: `/ai/nginx/.env` (gitignored) — `CLOUDFLARE_API_TOKEN`, `CERTBOT_EMAIL`
- Certs stored in Docker named volume `letsencrypt`
- SELinux: `ai-stack.service` context resets on edit — run `restorecon -v /ai/ai-stack.service` after any edit

---

## Secrets

- `frigate/.env` — gitignored, contains `FRIGATE_MQTT_PASSWORD`
- `nginx/.env` — gitignored, contains `CLOUDFLARE_API_TOKEN` and `CERTBOT_EMAIL`
- All other configs safe to commit

---

## Pending

- [ ] Connect Whisper + Piper to Home Assistant (Wyoming integration)
  - STT: port 10300, TTS: port 10200
  - HA → Settings → Devices & Services → Add Wyoming
- [ ] Swap SATA cable on `sdd`, recheck CRC errors with `smartctl`

---

## Future

- Second GPU (RTX 3080) for dedicated Frigate inference
- Kubernetes lab (kubectl, helm, k3d, k9s)
- ~~Prometheus + Grafana monitoring~~ ✓ done
- Embedding models, vector DB
- **Dockerized AI agents** — remotely controllable task agents running in sandboxed containers
  - Each agent gets its own container with scoped filesystem, network, and tool access
  - Controlled via API (task submission, status, cancellation)
  - Similar to Claude Code / Agent SDK model but self-hosted: receive a task, execute autonomously, return results
  - Sandbox constraints: no host mounts, limited egress, resource caps (CPU/GPU/RAM)
  - Potential stack: Anthropic Agent SDK, or open-source equiv (LangGraph, smolagents) + local Ollama backend
  - Orchestrator service manages agent lifecycle and queues tasks

