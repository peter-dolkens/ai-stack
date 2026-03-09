#!/bin/bash
set -e

# Write Cloudflare credentials from environment
printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > /etc/cloudflare.ini
chmod 600 /etc/cloudflare.ini

# Extract all unique server_names from nginx conf.d (excludes _, localhost, and bare IPs)
get_domains() {
    grep -rh 'server_name' /etc/nginx/conf.d/*.conf 2>/dev/null \
        | sed 's/server_name//g; s/;//g' \
        | tr ' ' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -Ev '^$|^_$|^localhost$|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u
}

# Issue or expand a cert. First arg is primary domain, remaining args are SANs.
issue_cert() {
    local primary="$1"
    shift
    local sans=("$@")

    local d_flags="-d ${primary}"
    for san in "${sans[@]}"; do
        d_flags="${d_flags} -d ${san}"
    done

    if [ ! -f "/etc/letsencrypt/live/${primary}/fullchain.pem" ]; then
        echo "[certbot] Issuing certificate for ${primary}${sans:+ (+ ${sans[*]})}..."
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials /etc/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 30 \
            $d_flags \
            --agree-tos --non-interactive \
            -m "$CERTBOT_EMAIL"
    else
        # Check if existing cert already covers all SANs
        local cert_file="/etc/letsencrypt/live/${primary}/cert.pem"
        local needs_expand=false
        for san in "${sans[@]}"; do
            if ! openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -q "DNS:${san}"; then
                needs_expand=true
                break
            fi
        done

        if [ "$needs_expand" = true ]; then
            echo "[certbot] Expanding certificate for ${primary} to add: ${sans[*]}..."
            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials /etc/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 30 \
                $d_flags \
                --expand \
                --agree-tos --non-interactive \
                -m "$CERTBOT_EMAIL"
        else
            echo "[certbot] Certificate already exists and covers all domains for ${primary}, skipping."
        fi
    fi
}

domains=$(get_domains)

if [ -z "$domains" ]; then
    echo "[certbot] WARNING: No domains found in /etc/nginx/conf.d — check your nginx configs."
    exit 1
fi

# Separate .dolkens.net domains from .dolkens.au and everything else.
# For each .dolkens.net domain, automatically pair with the .dolkens.au variant as a SAN.
net_domains=$(echo "$domains" | grep '\.dolkens\.net$' || true)
au_domains=$(echo "$domains" | grep '\.dolkens\.au$' || true)
other_domains=$(echo "$domains" | grep -v '\.dolkens\.' || true)

for domain in $net_domains; do
    au="${domain%.dolkens.net}.dolkens.au"
    issue_cert "$domain" "$au"
done

# Handle any .dolkens.au that has no matching .net (unlikely, but safe)
for domain in $au_domains; do
    net="${domain%.dolkens.au}.dolkens.net"
    if ! echo "$net_domains" | grep -qx "$net"; then
        issue_cert "$domain"
    fi
done

for domain in $other_domains; do
    issue_cert "$domain"
done

echo "[certbot] Reloading nginx..."
curl -sf --unix-socket /var/run/docker.sock \
    -X POST 'http://localhost/containers/nginx/kill?signal=HUP' || true

# Install crontab: renew twice daily at 03:17 and 15:17
echo "17 3,15 * * * /usr/local/bin/renew.sh >> /var/log/certbot-renew.log 2>&1" | crontab -

echo "[certbot] Starting cron for renewal..."
exec crond -f
