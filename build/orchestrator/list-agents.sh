#!/bin/bash
# List running agent containers with their tier, task, and status

{ \
    docker ps --filter "label=ai.agent=true" --format "table {{.Names}}\t{{.Label \"ai.agent.tier\"}}\t{{.Label \"ai.agent.task\"}}\t{{.Status}}" \
    | head -1; \
    docker ps --filter "label=ai.agent=true" --format "table {{.Names}}\t{{.Label \"ai.agent.tier\"}}\t{{.Label \"ai.agent.task\"}}\t{{.Status}}" \
    | tail -n +2 | sort; \
}
