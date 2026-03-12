FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl wget git vim nano \
    openssh-server openssh-client \
    jq uuid-runtime \
    ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (client only — socket is mounted from host)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

# SSH server config (for VSCode Remote SSH)
RUN mkdir /run/sshd && \
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# SSH client config for reaching agents
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    printf "Host agent-*\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  User agent\n  IdentityFile /root/.ssh/orchestrator_key\n  LogLevel ERROR\n" \
    > /root/.ssh/config && \
    chmod 600 /root/.ssh/config

# Helper scripts
COPY spawn-agent.sh  /usr/local/bin/spawn-agent
COPY kill-agent.sh   /usr/local/bin/kill-agent
COPY list-agents.sh  /usr/local/bin/list-agents
RUN chmod +x /usr/local/bin/spawn-agent \
             /usr/local/bin/kill-agent \
             /usr/local/bin/list-agents

# Workspace + Claude context
WORKDIR /workspace
COPY CLAUDE.md /workspace/CLAUDE.md

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
