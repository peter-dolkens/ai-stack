#!/bin/bash
# Apply iptables egress policy based on $NETWORK_TIER.
# Must run as root (agent entrypoint runs as root before dropping to sshd).

TIER="${NETWORK_TIER:-airgapped}"

# Agent-net CIDR — matches the Docker network defined in orchestrator.yaml
AGENT_NET_CIDR="172.27.0.0/16"

# ── online: no restrictions ───────────────────────────────────────────────────
if [[ "$TIER" == "online" ]]; then
    echo "[network-policy] Tier: online — no egress restrictions."
    exit 0
fi

# ── Flush existing rules ───────────────────────────────────────────────────────
iptables -F OUTPUT

# ── Allow: loopback ───────────────────────────────────────────────────────────
iptables -A OUTPUT -o lo -j ACCEPT

# ── Allow: established connections (responses to inbound SSH, etc.) ────────────
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── Allow: agent-net (orchestrator + peer agents) ─────────────────────────────
iptables -A OUTPUT -d "$AGENT_NET_CIDR" -j ACCEPT

# ── Allow: Docker internal DNS (127.0.0.11) ───────────────────────────────────
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT

# ── Allow: DNS queries (needed to resolve API hostnames) ─────────────────────
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# ── local: add LAN access ─────────────────────────────────────────────────────
if [[ "$TIER" == "local" ]]; then
    echo "[network-policy] Tier: local — adding RFC-1918 egress."
    iptables -A OUTPUT -d 10.0.0.0/8     -j ACCEPT
    iptables -A OUTPUT -d 172.16.0.0/12  -j ACCEPT
    iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
fi

# ── Resolve and whitelist AI API endpoints ────────────────────────────────────
AI_HOSTS=(
    "api.anthropic.com"
    "api.openai.com"
    "sso.anthropic.com"
)

echo "[network-policy] Resolving AI API endpoints..."
for host in "${AI_HOSTS[@]}"; do
    IPS=$(dig +short "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [[ -z "$IPS" ]]; then
        echo "[network-policy] WARNING: could not resolve $host" >&2
        continue
    fi
    for ip in $IPS; do
        echo "[network-policy]   $host → $ip (ALLOW)"
        iptables -A OUTPUT -d "$ip" -j ACCEPT
    done
done

# ── Drop everything else ──────────────────────────────────────────────────────
echo "[network-policy] Tier: $TIER — blocking all other egress."
iptables -A OUTPUT -j DROP

echo "[network-policy] Policy applied."
