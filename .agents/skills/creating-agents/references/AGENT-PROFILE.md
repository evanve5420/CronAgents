# Agent Profile Reference

Format and best practices for `.agent.md` custom agent profiles.

## File location

Agent profiles are discovered by Copilot CLI from:

- **Personal repo (default):** `~/.cronagents/.github/agents/<agent-name>.agent.md`
- **User-global:** `~/.copilot/agents/<agent-name>.agent.md`

## Format

```markdown
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <tool-name>
  - <tool-name>
model: claude-sonnet-4     # optional — preferred AI model
agents: ['Researcher']     # optional — restrict available subagents
---

<System prompt — everything after the frontmatter>
```

### Frontmatter fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | Yes | string | Agent name, passed to Copilot CLI via `--agent`. Must match the registration's `agent` field. |
| `description` | No | string | One-line description for documentation and discovery. |
| `tools` | Yes | string[] | Array of tool names the agent can use. See [Tool format](#tool-format-for-cronagents) below. |
| `model` | No | string or string[] | Preferred AI model. Single name (e.g. `claude-sonnet-4`) or prioritized list — the first available model is used. If omitted, the runtime default applies. See [Model selection](#model-selection) below. |
| `agents` | No | string[] | Restrict which agents can be invoked as subagents. Use `['*']` to allow all, or `[]` to prevent any. Requires the `agent` tool in `tools`. Useful for orchestrator patterns — see [ORCHESTRATOR-PATTERN.md](../../../../docs/ORCHESTRATOR-PATTERN.md). |
| `argument-hint` | No | string | Hint text shown in the VS Code chat input field. No effect in CLI. |
| `user-invocable` | No | boolean | Whether the agent appears in the VS Code agents dropdown (default `true`). Set to `false` for agents that should only be used as subagents. No effect in CLI. |
| `disable-model-invocation` | No | boolean | Prevent other agents from invoking this agent as a subagent (default `false`). |
| `handoffs` | No | object[] | Suggested next-step transitions to other agents. Each entry has `label`, `agent`, `prompt`, optional `send` (boolean), and optional `model` (string). VS Code UI feature — no effect in CLI. |
| `hooks` | No | object | Hook commands scoped to this agent (Preview). No effect in CLI. Uses the same format as VS Code hook configuration. |
| `target` | No | string | Target environment: `vscode` or `github-copilot` ([cloud agents](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/create-custom-agents)). Omit for standard CLI/VS Code agents. |
| `mcp-servers` | No | object[] | MCP server configurations for agents targeting `github-copilot`. |

> **Deprecated:** The `infer` field has been replaced by `user-invocable` and `disable-model-invocation`. If you encounter it in existing profiles, replace `infer: true` with `user-invocable: true` (the default) and set `disable-model-invocation` as needed.

### Model selection

The `model` field in `.agent.md` sets the preferred model at the agent-definition level. This is distinct from the `model` field in the registration JSON:

| Where | What it does | Precedence |
|-------|-------------|------------|
| `.agent.md` `model:` | Declares the agent's preferred model. VS Code respects this directly. In CLI, it acts as a model hint. | Lower — overridden by registration or CLI flags |
| Registration `model:` | Passed to Copilot CLI as `--model`. Overrides the agent profile preference. | Higher — explicit CLI flag |

If both are set, the registration's `model` wins (it becomes an explicit `--model` CLI flag). Use the `.agent.md` `model` when you want a default preference that can be overridden per-invocation, and the registration `model` when you want a hard override.

**Prioritized model lists:** You can specify an array of model names. The runtime tries each in order until it finds one that's available:

```yaml
model: ['claude-opus-4', 'claude-sonnet-4', 'gpt-4.1']
```

### Common tool sets

| Use case | Tools | Notes |
|----------|-------|-------|
| Read-only analysis | `[read, search]` | Safest — can't modify anything. |
| Code editing | `[read, edit, search]` | Can modify files but not run commands. |
| Shell access (limited) | `[read, execute]` | Pair with `denyTools` in registration to block dangerous commands. |
| Delegation | `[agent]` | Lets the agent delegate work to sub-agents. |
| Orchestrator | `[read, search, agent]` | Decomposes work into parallel subagents. See [ORCHESTRATOR-PATTERN.md](../../../../docs/ORCHESTRATOR-PATTERN.md). |
| Full access | All tools | Only when genuinely needed. Prefer scoped tools. |

## Tool format for CronAgents

CronAgents runs custom agents through **GitHub Copilot CLI**, so `.agent.md` files must use CLI-compatible tool aliases.

If you specify `tools:`, use the official tool aliases: `read`, `edit`, `search`, `execute`, `agent`, and `web`. Compatible aliases include `shell` / `Bash` / `powershell` for `execute`, and `Grep` / `Glob` for `search`.

Do **not** use VS Code-only tool names such as `editFiles`, `runCommands`, `runTasks`, `codebase`, `findTestFiles`, `usages`, `terminalLastCommand`, `terminalSelection`, or `vscodeAPI`.

### Tool names

- `read` — read file contents (aliases: `Read`, `NotebookRead`)
- `edit` — modify files (aliases: `Edit`, `MultiEdit`, `Write`, `NotebookEdit`)
- `search` — search for text or files (aliases: `Grep`, `Glob`)
- `execute` — run shell commands (aliases: `shell`, `Bash`, `powershell`)
- `agent` — delegate to sub-agents (aliases: `custom-agent`, `Task`)

### MCP tool references

Reference MCP server tools in the `tools:` frontmatter using `server-name/tool-name` or `server-name/*` for all tools from a server. **Only the slash format works** — using the hyphen format (`server-tool`) is silently ignored by the CLI and the tools will not be available to the agent.

```yaml
tools:
  - read
  - search
  - playwright/browser_snapshot   # ✅ correct — slash format
  - github/*                      # ✅ correct — slash wildcard
  # - playwright-browser_snapshot # ❌ WRONG — silently ignored
```

> **VS Code vs CLI MCP tool naming.** VS Code and CLI expose MCP tools under different runtime names. The `.agent.md` `tools:` frontmatter uses the cross-platform **slash** format (`server/tool`) in both environments — CLI translates internally. However, the actual tool names the model sees at runtime differ:
>
> | Context | Format | Example |
> |---------|--------|---------|
> | `.agent.md` `tools:` frontmatter | `server/tool` | `playwright/browser_click` |
> | VS Code runtime (model sees) | `server/tool` | `playwright/browser_click` |
> | CLI runtime (model sees) | `server-tool` | `playwright-browser_click` |
> | CLI `--deny-tool` / `denyTools` | `server(tool)` | `playwright(browser_click)` |
>
> Since CronAgents agents run in CLI, `denyTools` entries in the registration JSON must use the **parenthesized** CLI permission-pattern: `server-name(tool-name)` for a specific tool or `server-name()` for all tools from a server. Do **not** use the slash format in `denyTools`.

## Example

```markdown
---
name: security-scan
description: "Scan for security vulnerabilities in code and dependencies"
tools:
  - read
  - search
---

You are a security scanner. Check for:

1. Hardcoded secrets (API keys, passwords, tokens)
2. Known vulnerable patterns (SQL injection, XSS, path traversal)
3. Dependency CVEs

Report each finding with severity, file, line, issue, and recommendation.
```

## Best practices

- **Least privilege** — start with `[read, search]` and expand only if needed.
- **Focused system prompts** — tell the agent exactly what to do and what format to use.
- **CLI-first tools** — if a generated draft uses VS Code-only tool names, rewrite the list to official CLI aliases before saving.
- **No shell unless required** — if you need shell access, use `denyTools` in the registration to block destructive commands.
