#!/usr/bin/env python3
"""Piper (Wyoming TTS) Prometheus exporter.

Metrics:
  wyoming_piper_up    - Wyoming describe probe (1=responding)
  wyoming_piper_info  - Service info from Wyoming describe (labels: name, version, voice)
"""

import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from prometheus_client import (
    CollectorRegistry,
    Gauge,
    Info,
    CONTENT_TYPE_LATEST,
    generate_latest,
)

PIPER_HOST = "host.docker.internal"
PIPER_PORT = 10200
METRICS_PORT = 9878
HEALTH_INTERVAL = 15  # seconds

registry = CollectorRegistry()

piper_up = Gauge(
    "wyoming_piper_up",
    "Piper TTS service responds to Wyoming describe probe",
    registry=registry,
)
piper_info = Info(
    "wyoming_piper",
    "Piper TTS service info from Wyoming describe",
    registry=registry,
)

_info_sent = False


def wyoming_describe(host: str, port: int, timeout: float = 3.0) -> dict | None:
    """Send a Wyoming describe event and return the data body as a dict."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.sendall(b'{"type": "describe", "data": {}}\n')
            sock.settimeout(timeout)
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            header_line, rest = buf.split(b"\n", 1)
            header = json.loads(header_line)
            data_len = header.get("data_length", 0)
            while len(rest) < data_len:
                rest += sock.recv(4096)
            return json.loads(rest[:data_len])
    except Exception:
        return None


def health_check_loop() -> None:
    global _info_sent
    while True:
        resp = wyoming_describe(PIPER_HOST, PIPER_PORT)
        if resp is not None:
            piper_up.set(1.0)
            if not _info_sent:
                try:
                    tts = resp.get("tts", [{}])[0]
                    voices = tts.get("voices", [])
                    installed_voices = [v["name"] for v in voices if v.get("installed")]
                    piper_info.info(
                        {
                            "name": tts.get("name", "piper"),
                            "version": tts.get("version", "unknown"),
                            "voices": ",".join(installed_voices),
                        }
                    )
                    _info_sent = True
                except Exception:
                    pass
        else:
            piper_up.set(0.0)
        time.sleep(HEALTH_INTERVAL)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/metrics":
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
    threading.Thread(target=health_check_loop, daemon=True).start()
    print(f"Piper exporter listening on :{METRICS_PORT}", flush=True)
    try:
        HTTPServer(("", METRICS_PORT), MetricsHandler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
