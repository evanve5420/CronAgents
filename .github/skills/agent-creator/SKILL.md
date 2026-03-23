---
name: agent-creator
description: "Create a new CronAgents scheduled agent. Use when: creating an agent, adding a scheduled task, writing an .agent.md, configuring a new agent in chronagents.json"
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a fully configured CronAgents scheduled agent — the `.agent.md` file, the `chronagents.json` config entry, and optionally a companion SKILL.md.

## When to Use

- User wants to add a new scheduled agent
- User wants to convert an idea into a working agent + config
- User wants help editing an `.agent.md` or per-agent config options

## Gather Context

Before creating anything, read the project's documentation to stay current on structure and options:

1. Read [guide/writing-agents.md](../../../guide/writing-agents.md) for `.agent.md` structure, frontmatter fields, prompt patterns, and placement rules
2. Read [guide/configuration.md](../../../guide/configuration.md) for all per-agent config fields, types, defaults, and examples

If those files don't exist yet, fall back to [docs/PLAN.md](../../../docs/PLAN.md) — search for "Complete config example" and "Step 3" for the config schema, and "templates/agents/" for agent file structure.

## Interview the User

Ask about the following (skip anything already clear from context):

1. **What should the agent do?** — summarize in one sentence
2. **Schedule** — how often? (daily at 9am, every 4 hours, weekly Monday, etc.)
3. **Model preference** — specific model, or use the default?
4. **Tool restrictions** — any tools to deny? (e.g., `shell(rm)`, `shell(git push)`)
5. **Execution policies** — timeout, skip on battery, retry on failure?
6. **Placement** — project-local (`.chronagents/agents/`) or user-global (`~/.copilot/agents/`)?

## Create the Agent

### 1. Write the `.agent.md` file

Place it in the chosen location. Use this structure:

```markdown
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <tool references as needed>
---

<System prompt for the agent — what it does, how it behaves, what output format to use>
```

Naming: lowercase, hyphenated, descriptive (e.g., `daily-review`, `weekly-deps`, `stale-branch-cleanup`).

### 2. Add the config entry to `chronagents.json`

Add an object to the `agents` array:

```jsonc
{
  "name": "<agent-name>",          // must match .agent.md name
  "agent": "<agent-name>",         // agent file reference
  "prompt": "<what to tell the agent each run>",
  "schedule": { "type": "daily", "time": "09:00" },
  // Optional per-agent overrides (all have sensible defaults):
  // "timeout": "10m",
  // "skipOnBattery": false,
  // "retryCount": 0,
  // "model": "claude-sonnet-4",
  // "denyTools": [],
  // "extraCliFlags": [],
  // "envVars": {}
}
```

### 3. Optionally create a companion SKILL.md

If the agent needs domain knowledge to do its job well, create a skill in `scheduler/skills/<agent-name>/SKILL.md` and reference it from the agent's prompt or instructions.

## Validate

After creating:

- [ ] `.agent.md` has valid YAML frontmatter with `name` and `description`
- [ ] `name` in `.agent.md` matches `agent` field in config
- [ ] Config entry has required fields: `name`, `agent`, `prompt`, `schedule`
- [ ] Schedule uses a supported type: `interval`, `daily`, or `weekly`
- [ ] If `denyTools` specified, entries are valid tool patterns
- [ ] Test manually: `chronagents.ps1 run <agent-name>`

## Example

> "Create an agent that checks for outdated npm dependencies every Monday"

Result:
- `.chronagents/agents/weekly-deps.agent.md` — agent with instructions to run `npm outdated`, summarize findings, flag security issues
- `chronagents.json` entry — `weekly`, Monday 10:00, 15m timeout, `skipOnBattery: true`
