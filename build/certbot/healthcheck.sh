#!/bin/sh
# Passes when every domain in nginx conf.d has a valid cert.
# For *.dolkens.au domains, checks the matching *.dolkens.net SAN cert.

set -e

domains=$(
    grep -rh 'server_name' /etc/nginx/conf.d/*.conf 2>/dev/null \
        | sed 's/server_name//g; s/;//g' \
        | tr ' ' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -Ev '^$|^_$|^localhost$|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u
)

if [ -z "$domains" ]; then
    echo "No domains found in conf.d" >&2
    exit 1
fi

for domain in $domains; do
    # .dolkens.au domains are SANs on the matching .net cert
    if echo "$domain" | grep -q '\.dolkens\.au$'; then
        net="${domain%.dolkens.au}.dolkens.net"
        cert="/etc/letsencrypt/live/${net}/cert.pem"
        if [ ! -f "$cert" ]; then
            echo "Missing cert for ${net} (needed for SAN ${domain})" >&2
            exit 1
        fi
        if ! openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -q "DNS:${domain}"; then
            echo "Cert for ${net} does not cover SAN ${domain}" >&2
            exit 1
        fi
    else
        if [ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
            echo "Missing cert for ${domain}" >&2
            exit 1
        fi
    fi
done

echo "All certs present: $(echo "$domains" | tr '\n' ' ')"
