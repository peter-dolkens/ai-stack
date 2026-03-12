#!/usr/bin/env python3
"""Whisper (Wyoming STT) Prometheus exporter.

Metrics:
  wyoming_whisper_up                  - Wyoming describe probe (1=responding)
  wyoming_whisper_requests_total      - Transcription requests completed
  wyoming_whisper_audio_seconds_total - Total audio duration transcribed (seconds)
  wyoming_whisper_info                - Service info from Wyoming describe (labels: name, version)
"""

import json
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import docker
from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Info,
    CONTENT_TYPE_LATEST,
    generate_latest,
)

WHISPER_HOST = "host.docker.internal"
WHISPER_PORT = 10300
METRICS_PORT = 9877
HEALTH_INTERVAL = 15  # seconds

registry = CollectorRegistry()

whisper_up = Gauge(
    "wyoming_whisper_up",
    "Whisper STT service responds to Wyoming describe probe",
    registry=registry,
)
whisper_info = Info(
    "wyoming_whisper",
    "Whisper STT service info from Wyoming describe",
    registry=registry,
)
whisper_requests_total = Counter(
    "wyoming_whisper_requests_total",
    "Total transcription requests completed by Whisper",
    registry=registry,
)
whisper_audio_seconds_total = Counter(
    "wyoming_whisper_audio_seconds_total",
    "Total seconds of audio transcribed by Whisper",
    registry=registry,
)

# Matches: Processing audio with duration MM:SS.sss
DURATION_RE = re.compile(r"Processing audio with duration (\d+):(\d+\.\d+)")

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
        resp = wyoming_describe(WHISPER_HOST, WHISPER_PORT)
        if resp is not None:
            whisper_up.set(1.0)
            if not _info_sent:
                try:
                    asr = resp.get("asr", [{}])[0]
                    models = asr.get("models", [{}])
                    installed = [m["name"] for m in models if m.get("installed")]
                    whisper_info.info(
                        {
                            "name": asr.get("name", "whisper"),
                            "version": asr.get("version", "unknown"),
                            "model": installed[0] if installed else "unknown",
                        }
                    )
                    _info_sent = True
                except Exception:
                    pass
        else:
            whisper_up.set(0.0)
        time.sleep(HEALTH_INTERVAL)


def tail_whisper_logs() -> None:
    """Follow whisper container logs and parse transcription metrics."""
    while True:
        try:
            client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
            container = client.containers.get("whisper")
            print("Tailing whisper logs", flush=True)
            for raw in container.logs(stream=True, follow=True, tail=0, stderr=True):
                line = raw.decode("utf-8", errors="replace").rstrip()
                m = DURATION_RE.search(line)
                if m:
                    minutes = int(m.group(1))
                    seconds = float(m.group(2))
                    duration = minutes * 60.0 + seconds
                    whisper_requests_total.inc()
                    whisper_audio_seconds_total.inc(duration)
            print("whisper log stream ended, retrying in 5s", flush=True)
        except Exception as exc:
            print(f"Error tailing whisper logs: {exc}", flush=True)
        time.sleep(5)


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
    threading.Thread(target=tail_whisper_logs, daemon=True).start()
    print(f"Whisper exporter listening on :{METRICS_PORT}", flush=True)
    try:
        HTTPServer(("", METRICS_PORT), MetricsHandler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
