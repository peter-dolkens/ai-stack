FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl wget git vim nano \
    openssh-server \
    iptables dnsutils \
    sudo \
    jq \
    ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Agent user with passwordless sudo
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent && \
    chmod 440 /etc/sudoers.d/agent

# SSH server setup
RUN mkdir -p /run/sshd && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AllowUsers agent" >> /etc/ssh/sshd_config && \
    # Pass common env vars through SSH sessions
    echo "AcceptEnv ANTHROPIC_API_KEY OPENAI_API_KEY TASK_ID NETWORK_TIER" >> /etc/ssh/sshd_config

# SSH client config (for agent-to-agent communication)
RUN mkdir -p /home/agent/.ssh && chmod 700 /home/agent/.ssh && \
    printf "Host agent-*\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n" \
    > /home/agent/.ssh/config && \
    chmod 600 /home/agent/.ssh/config && \
    chown -R agent:agent /home/agent/.ssh

# Network policy + entrypoint scripts
COPY network-policy.sh /usr/local/bin/apply-network-policy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/apply-network-policy /entrypoint.sh

WORKDIR /home/agent

EXPOSE 22

CMD ["/entrypoint.sh"]
