---
name: creating-agents
description: "Use when asked to create a new CronAgents agent or prompt-only scheduled invocation. Helps create the required agent profile and registration in the personal repo."
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a CronAgents scheduled entry: either a custom agent (`.agent.md` + `.agent-registration.json`) or a prompt-only invocation (`.agent-registration.json` only).

## Important — CronAgents agent profiles must be CLI-compatible

CronAgents ultimately runs these agents via **GitHub Copilot CLI**, not VS Code chat.

When you create or edit a `.agent.md` profile for CronAgents:

- Use the official custom-agent `tools` format that Copilot CLI supports.
- Prefer the CLI-safe aliases: `read`, `edit`, `search`, `execute`, `agent`.
- You may also use namespaced MCP tools such as `github/*`, `playwright/*`, or `server-name/tool-name` when intentionally needed.
- Compatible aliases include `shell`/`Bash`/`powershell` for `execute`, and `Grep`/`Glob` for `search`.
- **Do not** emit VS Code-only tool names or chat-mode tool sets such as `editFiles`, `runCommands`, `runTasks`, `codebase`, `findTestFiles`, `usages`, `terminalLastCommand`, `terminalSelection`, `changes`, `problems`, `githubRepo`, or `vscodeAPI`.

If Copilot generates a draft agent profile using VS Code-style tool names, rewrite the `tools:` list before saving it so the profile stays correct for CLI execution.

## Personal Repo Setup — Do This Before Creating Anything

Agent definitions and registrations live in the user's **personal repo** (`~/.cronagents/`), not in the infra repo.

1. Load the shared module and check the personal repo:
   ```powershell
   Import-Module scheduler/lib/CronAgents.psd1 -Force
   Import-CronAgentsConfig
   $repoPath = Get-PersonalRepoPath
   $valid = Test-PersonalRepoValid
   ```
2. If the personal repo doesn't exist or isn't valid, initialize it:
   ```powershell
   Initialize-PersonalRepo
   ```
3. Agent files go in:
   - **Agent profiles:** `~/.cronagents/.github/agents/<agent-name>.agent.md`
   - **Registrations:** `~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json`
4. No branch switching is needed — the personal repo is a standalone git repository.

## Interview the User

Skip anything already clear from context:

1. **What should it do?**
2. **Schedule** — daily at 9am, every 4h, weekly Monday, etc.
3. **Agent or prompt-only?** — Prompt-only is simpler when no custom system instructions or tool scoping is needed. Agent mode when the task needs custom behavior, tool restrictions, or a system prompt.
4. **What tools does it need?** — Scope to the **minimum required** and express them in **CLI-compatible tool aliases**. Start restrictive; the user can expand later. See [AGENT-PROFILE.md](references/AGENT-PROFILE.md) for the approved tool format and common tool sets.
5. **Model preference?**
6. **Execution policies?** — timeout, skip on battery, retry on failure, `runIf` (see [RUNIF.md](references/RUNIF.md)), notify on failure (`notifyOnFailure`), notify on success (`notifyOnSuccess`)
7. **Agent profile placement (agent mode only)** — personal repo `.github/agents/` (default) or user-global `~/.copilot/agents/`
8. **Working directory?** — which project directory the agent should run in. If omitted, the scheduler runs from the personal repo root when available (otherwise the infra repo root) with `--allow-all`.

## Create

For field details, see [REGISTRATION-FIELDS.md](references/REGISTRATION-FIELDS.md).

### Agent mode

Custom agent profile — see [AGENT-PROFILE.md](references/AGENT-PROFILE.md) for format and tool scoping:

```markdown
# ~/.cronagents/.github/agents/<agent-name>.agent.md
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <CLI-compatible tool alias>
  - <CLI-compatible tool alias>
---

<System prompt>
```

CronAgents registration file — **filename stem = stable agent ID**:

```jsonc
// ~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "agent": "<agent-name>",
  "prompt": "<run prompt>",
  "schedule": { "type": "daily", "time": "09:00" }
}
```

### Prompt-only mode

No `.agent.md`. Omit `agent` field — scheduler invokes `copilot -p` with `--allow-all-tools`. Use `denyTools` to restrict.

```jsonc
// ~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "prompt": "<full prompt>",
  "schedule": { "type": "daily", "time": "09:00" },
  "denyTools": ["shell(rm)", "shell(git push)"]
}
```

### Companion SKILL.md (optional, agent mode only)

Create in `~/.cronagents/.github/skills/<agent-name>/SKILL.md` if the agent needs domain knowledge.

## Validate

- Agent mode: `.agent.md` lives in `~/.cronagents/.github/agents/` or `~/.copilot/agents/`, has an explicit least-privilege `tools` list using **CLI-compatible aliases**, and `agent` in the registration matches the `.agent.md` file stem
- Prompt-only: registration has `prompt` + `schedule`, no `agent` field, `denyTools` considered
- Both: registration file is named `~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json`
- Both: schedule type is `interval`/`daily`/`weekly`, test with `cronagents.ps1 run <agent-id>`
- Both: if a generated `.agent.md` contains VS Code-only tool names, normalize them before finishing

## Agent Questions (Deferred Decisions)

Agents can ask the user operational questions that block the next run until answered. See [QUESTIONS.md](references/QUESTIONS.md) for the question format, lifecycle, and configuration.
