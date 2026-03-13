#!/bin/bash
set -e

python3 /usr/local/bin/generate-config.py

exec litellm --config /tmp/generated-config.yaml --port 4000 --telemetry False
