#!/usr/bin/env python3
"""Ollama running-models Prometheus exporter.

Queries /api/ps on a configurable interval and exposes:
  ollama_ps_up                         - 1 if Ollama responds, 0 otherwise
  ollama_ps_loaded_models_total        - number of models currently in memory
  ollama_ps_model_size_bytes           - total size of loaded model (RAM+VRAM)
  ollama_ps_model_size_vram_bytes      - VRAM portion of loaded model
  ollama_ps_model_context_length       - context length currently allocated
  ollama_ps_model_info                 - labels: model, family, parameter_size, quantization_level
"""

import os
import sys
import threading
import time
import urllib.request
import urllib.error
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from prometheus_client import (
    CollectorRegistry,
    Gauge,
    Info,
    CONTENT_TYPE_LATEST,
    generate_latest,
)

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "host.docker.internal:11434")
METRICS_PORT = int(os.environ.get("PORT", "9879"))
INTERVAL = int(os.environ.get("INTERVAL", "15"))

registry = CollectorRegistry()

ps_up = Gauge(
    "ollama_ps_up",
    "Ollama server responds to /api/ps",
    registry=registry,
)
ps_loaded_total = Gauge(
    "ollama_ps_loaded_models_total",
    "Number of models currently loaded in memory",
    registry=registry,
)
ps_size = Gauge(
    "ollama_ps_model_size_bytes",
    "Total size of loaded model in bytes (RAM + VRAM)",
    ["model"],
    registry=registry,
)
ps_size_vram = Gauge(
    "ollama_ps_model_size_vram_bytes",
    "VRAM used by loaded model in bytes",
    ["model"],
    registry=registry,
)
ps_context_length = Gauge(
    "ollama_ps_model_context_length",
    "Context length currently allocated for loaded model",
    ["model"],
    registry=registry,
)
ps_model_info = Gauge(
    "ollama_ps_model_info",
    "Loaded model metadata (always 1)",
    ["model", "family", "parameter_size", "quantization_level"],
    registry=registry,
)

# Track which label-sets we've seen so we can clear stale ones
_active_models: set[str] = set()
_lock = threading.Lock()


def fetch_ps() -> list | None:
    url = f"http://{OLLAMA_HOST}/api/ps"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
            return data.get("models", [])
    except Exception:
        return None


def poll_loop() -> None:
    global _active_models
    while True:
        models = fetch_ps()
        with _lock:
            if models is None:
                ps_up.set(0.0)
                # clear all loaded-model metrics
                for name in list(_active_models):
                    ps_size.remove(name)
                    ps_size_vram.remove(name)
                    ps_context_length.remove(name)
                _active_models = set()
                ps_loaded_total.set(0)
            else:
                ps_up.set(1.0)
                current = set()
                for m in models:
                    name = m.get("name", "unknown")
                    details = m.get("details", {})
                    current.add(name)

                    ps_size.labels(model=name).set(m.get("size", 0))
                    ps_size_vram.labels(model=name).set(m.get("size_vram", 0))
                    ps_context_length.labels(model=name).set(
                        m.get("context_length", 0)
                    )
                    ps_model_info.labels(
                        model=name,
                        family=details.get("family", "unknown"),
                        parameter_size=details.get("parameter_size", "unknown"),
                        quantization_level=details.get("quantization_level", "unknown"),
                    ).set(1)

                # remove metrics for models that unloaded since last poll
                stale = _active_models - current
                for name in stale:
                    try:
                        ps_size.remove(name)
                    except Exception:
                        pass
                    try:
                        ps_size_vram.remove(name)
                    except Exception:
                        pass
                    try:
                        ps_context_length.remove(name)
                    except Exception:
                        pass

                _active_models = current
                ps_loaded_total.set(len(current))

        time.sleep(INTERVAL)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/metrics":
            with _lock:
                output = generate_latest(registry)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()
            self.wfile.write(output)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args) -> None:  # noqa: A002
        pass


if __name__ == "__main__":
    threading.Thread(target=poll_loop, daemon=True).start()
    print(f"Ollama PS exporter listening on :{METRICS_PORT}", flush=True)
    try:
        HTTPServer(("", METRICS_PORT), MetricsHandler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
