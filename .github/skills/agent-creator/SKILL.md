---
name: agent-creator
description: "Create a new CronAgents scheduled agent or prompt-only invocation"
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a CronAgents scheduled entry: either a custom agent (`.agent.md` + `.json` config) or a prompt-only invocation (`.json` config only).

## Gather Context

Read these for current structure and options (fall back to [docs/PLAN.md](../../../docs/PLAN.md) if they don't exist yet):

1. [guide/writing-agents.md](../../../guide/writing-agents.md)
2. [guide/configuration.md](../../../guide/configuration.md)

## Interview the User

Skip anything already clear from context:

1. **What should it do?**
2. **Schedule** — daily at 9am, every 4h, weekly Monday, etc.
3. **Agent or prompt-only?** — Prompt-only is simpler when no custom system instructions or tool scoping is needed. Agent mode when the task needs custom behavior, tool restrictions, or a system prompt.
4. **What tools does it need?** — Scope to the **minimum required**. Start restrictive; the user can expand later.
   - Read-only: `tools: [read]` or `[read, search]`
   - Edits files: `tools: [read, edit, search]`
   - Shell access: `tools: [read, shell]` — use `denyTools` to block destructive ops (`shell(rm)`, `shell(git push)`)
   - `--allow-all-tools` only when genuinely needed — confirm with the user
5. **Model preference?**
6. **Execution policies?** — timeout, skip on battery, retry on failure
7. **Placement** — `.cronagents/agents/` (project-local) or `~/.copilot/agents/` (user-global)

## Create

### Agent mode

`.agent.md` — scope `tools` to what the task actually needs:

```markdown
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <minimum tools needed>
---

<System prompt>
```

Sibling `.json` — **filename stem = stable agent ID**:

```jsonc
// .cronagents/agents/<agent-id>.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "agent": "<agent-name>",
  "prompt": "<run prompt>",
  "schedule": { "type": "daily", "time": "09:00" }
  // Optional: timeout, skipOnBattery, retryCount, model, denyTools, extraCliFlags, envVars
}
```

### Prompt-only mode

No `.agent.md`. Omit `agent` field — scheduler invokes `copilot -p` with `--allow-all-tools`. Use `denyTools` to restrict.

```jsonc
// .cronagents/agents/<agent-id>.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "prompt": "<full prompt>",
  "schedule": { "type": "daily", "time": "09:00" },
  "denyTools": ["shell(rm)", "shell(git push)"]
}
```

### Companion SKILL.md (optional, agent mode only)

Create in `scheduler/skills/<agent-name>/SKILL.md` if the agent needs domain knowledge.

## Validate

- Agent mode: `.agent.md` has explicit `tools` list (least-privilege), `agent` in `.json` matches `.agent.md` name
- Prompt-only: `.json` has `prompt` + `schedule`, no `agent` field, `denyTools` considered
- Both: schedule type is `interval`/`daily`/`weekly`, test with `cronagents.ps1 run <agent-id>`
