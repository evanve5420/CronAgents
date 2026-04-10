---
name: creating-agents
description: "Use when asked to create a new CronAgents agent or prompt-only invocation — scheduled or manual (ad-hoc). Helps create the required agent profile and registration in the personal repo."
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a CronAgents entry: a custom agent (`.agent.md` + `.agent-registration.json`) or a prompt-only invocation (`.agent-registration.json` only). Agents can be scheduled or manual (ad-hoc only).

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
2. **Schedule** — daily at 9am, every 4h, weekly Monday, etc. Or **manual** (no schedule) if the agent should only be triggered via the dashboard or `cronagents.ps1 run`.
3. **Agent or prompt-only?** — Prompt-only is simpler when no custom system instructions or tool scoping is needed. Agent mode when the task needs custom behavior, tool restrictions, or a system prompt.
4. **What tools does it need?** — Scope to the **minimum required**. Use CLI tool names, not VS Code-style labels. See [AGENT-PROFILE.md](references/AGENT-PROFILE.md).
5. **Parallel decomposition?** — If the task is broad (many files, modules, or independent subtasks), the agent can orchestrate parallel subagents via the `agent` tool. This requires `agent` in the tools list and an orchestrator-style system prompt. Only ask this when the described task sounds parallelizable. See [ORCHESTRATOR-PATTERN.md](../../../docs/ORCHESTRATOR-PATTERN.md) for the full pattern.
6. **Model preference?**
7. **Execution policies?** — timeout, skip on battery, retry on failure, `runIf` (see [RUNIF.md](references/RUNIF.md)), notify on failure (`notifyOnFailure`), notify on success (`notifyOnSuccess`)
8. **Agent profile placement (agent mode only)** — personal repo `.github/agents/` (default) or user-global `~/.copilot/agents/`
9. **Working directory?** — which project directory the agent should run in. If omitted, the scheduler runs from the personal repo root when available (otherwise the infra repo root), grants directory access with `--allow-all`, and auto-approves tools with `--allow-all-tools`.

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
  - <minimum CLI tools needed>
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

### Manual (ad-hoc) mode

For agents that should only run when manually triggered via `cronagents.ps1 run <id>` or the dashboard `POST /api/run/<id>`, omit `schedule`:

```jsonc
// Agent mode — manual
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "agent": "<agent-name>",
  "prompt": "<run prompt>"
}

// Prompt-only mode — manual
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "prompt": "<full prompt>"
}
```

Manual agents appear in the dashboard and CLI status with a "manual" schedule label. They are never auto-triggered by the scheduler.

### Companion SKILL.md (optional, agent mode only)

Create in `~/.cronagents/.github/skills/<agent-name>/SKILL.md` if the agent needs domain knowledge.

## Tool Format

CronAgents runs `.agent.md` profiles through **GitHub Copilot CLI**.

### Built-in tools

If you specify `tools:`, use the official tool aliases: `read`, `edit`, `search`, `execute`, `agent`, and `web`. Compatible aliases include `shell` / `Bash` / `powershell` for `execute`, and `Grep` / `Glob` for `search`.

Do **not** use VS Code-only tool names such as `editFiles`, `runCommands`, `runTasks`, `codebase`, `findTestFiles`, `usages`, `terminalLastCommand`, `terminalSelection`, or `vscodeAPI`.

### MCP tools

You can reference MCP server tools in the `.agent.md` `tools:` frontmatter using `server-name/tool-name` or `server-name/*` for all tools from a server. **Only the slash format works in frontmatter** — the hyphen format (`server-tool`) is silently ignored and the tool will not be available.

> **VS Code vs CLI tool naming.** VS Code and CLI present MCP tools under different runtime names. This matters because CronAgents agents run in CLI, not VS Code.
>
> | Context | Format | Example |
> |---------|--------|---------|
> | `.agent.md` `tools:` frontmatter | `server/tool` | `playwright/browser_click` |
> | VS Code runtime (model sees) | `server/tool` | `playwright/browser_click` |
> | CLI runtime (model sees) | `server-tool` | `playwright-browser_click` |
> | CLI `--deny-tool` / `denyTools` | `server(tool)` | `playwright(browser_click)` |
>
> The `tools:` frontmatter always uses the **slash** format — CLI translates internally. But `denyTools` values in the registration JSON are passed directly to `--deny-tool`, so MCP entries there must use the **parenthesized** CLI permission-pattern format: `server-name(tool-name)` to deny a specific tool, or `server-name()` to deny all tools from a server.

Keep the list minimal. If you are unsure, omit `tools:` rather than guessing.

## Validate

- Agent mode: `.agent.md` lives in `~/.cronagents/.github/agents/` or `~/.copilot/agents/`, has explicit `tools` list (least-privilege), and `agent` in the registration matches the `.agent.md` name
- Prompt-only: registration has `prompt`, no `agent` field, `denyTools` considered
- Scheduled: registration includes `schedule` with type `interval`/`daily`/`weekly`
- Manual: registration omits `schedule` — agent only runs via `cronagents.ps1 run <id>` or dashboard
- Both: registration file is named `~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json`
- Both: test with `cronagents.ps1 run <agent-id>`

## Agent Questions (Deferred Decisions)

Agents can ask the user operational questions that block the next run until answered. See [QUESTIONS.md](references/QUESTIONS.md) for the question format, lifecycle, and configuration.
