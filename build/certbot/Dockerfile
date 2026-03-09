FROM certbot/dns-cloudflare

# Add cron and curl (for reloading nginx via Docker socket)
RUN apk add --no-cache cronie curl bash

COPY renew.sh /usr/local/bin/renew.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/renew.sh /usr/local/bin/healthcheck.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
