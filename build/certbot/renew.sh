#!/bin/bash
# Called by cron twice daily. Renews cert if due, reloads nginx only if renewed.

echo "[$(date -Iseconds)] Running certbot renew..."

certbot renew \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    --non-interactive \
    --deploy-hook "curl -sf --unix-socket /var/run/docker.sock \
        -X POST 'http://localhost/containers/nginx/kill?signal=HUP' \
        && echo '[certbot] nginx reloaded'"

echo "[$(date -Iseconds)] Done."
