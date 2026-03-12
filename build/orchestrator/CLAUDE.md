# Agent Orchestrator — Claude Instructions

You are running inside the **orchestrator** container. Your role is to coordinate
a fleet of isolated agent containers to complete tasks on behalf of the user.

## Available Tools

| Command | Purpose |
|---------|---------|
| `spawn-agent <tier> [task-id]` | Launch a new agent container |
| `list-agents` | Show running agents |
| `kill-agent <container>` | Stop and remove an agent |
| `ssh agent@<container> '<cmd>'` | Run a command on an agent |

## Security Tiers — Always Ask the User

Before spawning any agent, confirm the required network access tier:

| Tier | Network Access |
|------|---------------|
| `airgapped` | Claude API + OpenAI API + agent-net only |
| `local` | airgapped + 10.0.0.0/8 (LAN access) |
| `online` | Full internet + all of the above |

Default to **airgapped** unless the task clearly requires broader access.

## Spawning an Agent

```bash
# Returns CONTAINER, TASK_ID, SSH line
eval $(spawn-agent airgapped)

# Run Claude on the agent
ssh agent@$CONTAINER 'claude --dangerously-skip-permissions "your task here"'
```

## Shared Volume Layout

All containers mount `ai-shared` at `/workspace/shared/`:

```
/workspace/shared/
  .ssh/orchestrator.pub    ← orchestrator SSH pubkey (read by agents)
  tasks/
    <task-id>/
      meta.json            ← spawned by orchestrator
      result.md            ← written by agent when done
      <other files>        ← any artefacts the agent produces
```

Agents should write their final output to `/workspace/shared/tasks/$TASK_ID/result.md`.

## Agent Communication

Agents can reach each other by container name over `agent-net`:
```bash
ssh agent@agent-airgapped-abc123   # from orchestrator
ssh agent@agent-online-def456      # from orchestrator or another agent
```

## Running Multiple Agents in Parallel

Spawn multiple agents, give each a distinct task, wait for their result files:

```bash
eval $(spawn-agent airgapped task-a)
eval $(spawn-agent airgapped task-b)

ssh agent@agent-airgapped-task-a 'claude --dangerously-skip-permissions "..." &'
ssh agent@agent-airgapped-task-b 'claude --dangerously-skip-permissions "..." &'

# Poll for results
while [[ ! -f /workspace/shared/tasks/task-a/result.md ]]; do sleep 2; done
while [[ ! -f /workspace/shared/tasks/task-b/result.md ]]; do sleep 2; done
```

## Cleanup

Always kill agents when their task is complete:
```bash
kill-agent agent-airgapped-abc123
```
