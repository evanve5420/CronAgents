---
name: agent-creator
description: "Create a new CronAgents scheduled agent or prompt-only invocation"
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a CronAgents scheduled entry: either a custom agent (`.agent.md` + `.agent-registration.json`) or a prompt-only invocation (`.agent-registration.json` only).

## Gather Context

Read these for current structure and options (fall back to [docs/PLAN.md](../../../docs/PLAN.md) if they don't exist yet):

1. [guide/writing-agents.md](../../../guide/writing-agents.md)
2. [guide/configuration.md](../../../guide/configuration.md)

## Branch Safety — Do This Before Creating Anything

Scheduled agent registrations are tracked customizations and should live on the user's personal branch, not `master` / `main`.

1. Read the current branch state before creating files.
2. Load `cronagents.json` and determine the expected user branch from `versioning.branchPrefix` and `versioning.userName`.
3. If the repo is on `master` or `main`, switch to the expected user branch **before** creating any tracked agent files.
4. Use the shared module helpers rather than ad-hoc git logic:
   - `Import-Module scheduler/lib/CronAgents.psd1 -Force`
   - `Import-CronAgentsConfig`
   - `Get-CronAgentsBranch`
   - `Resolve-CronAgentsUserName`
   - `Initialize-UserBranch`
5. If the working tree is dirty and branch initialization cannot proceed safely, stop and tell the user exactly what must be cleaned up first.
6. Never scaffold tracked agent files on `master` / `main` unless the user explicitly overrides that rule.

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
7. **Agent profile placement (agent mode only)** — project-local `.github/agents/` or user-global `~/.copilot/agents/`

## Create

### Agent mode

Custom agent profile in a Copilot-supported discovery location — scope `tools` to what the task actually needs:

```markdown
# .github/agents/<agent-name>.agent.md
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <minimum tools needed>
---

<System prompt>
```

CronAgents registration file — **filename stem = stable agent ID**:

```jsonc
// .cronagents/agents/<agent-id>.agent-registration.json
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
// .cronagents/agents/<agent-id>.agent-registration.json
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

- Agent mode: `.agent.md` lives in `.github/agents/` or `~/.copilot/agents/`, has explicit `tools` list (least-privilege), and `agent` in the registration matches the `.agent.md` name
- Prompt-only: registration has `prompt` + `schedule`, no `agent` field, `denyTools` considered
- Both: registration file is named `.cronagents/agents/<agent-id>.agent-registration.json`
- Both: schedule type is `interval`/`daily`/`weekly`, test with `cronagents.ps1 run <agent-id>`
