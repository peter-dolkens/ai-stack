#!/bin/bash
set -e

exec python -m routellm.openai_server \
    --routers bert \
    --strong-model "$ROUTELLM_STRONG_MODEL" \
    --weak-model "$ROUTELLM_WEAK_MODEL" \
    --base-url "$OPENAI_BASE_URL" \
    --api-key "$OPENAI_API_KEY" \
    --port 6060
