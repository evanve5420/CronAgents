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
---

<System prompt — everything after the frontmatter>
```

### Frontmatter fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Agent name, passed to Copilot CLI via `--agent`. Must match the registration's `agent` field. |
| `description` | No | One-line description for documentation and discovery. |
| `tools` | Yes | Array of tool names the agent can use. |

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

If you specify `tools:`, use the official CLI tool aliases: `read`, `edit`, `search`, `execute`, and `agent`. Compatible aliases include `shell` / `Bash` / `powershell` for `execute`, and `Grep` / `Glob` for `search`. You can also reference MCP tools with `server-name/tool-name` or `server-name/*` for all tools from a server.

Do **not** use VS Code-only tool names such as `editFiles`, `runCommands`, `runTasks`, `codebase`, `findTestFiles`, `usages`, `terminalLastCommand`, `terminalSelection`, or `vscodeAPI`.

### Tool names

- `read` — read file contents (aliases: `Read`, `NotebookRead`)
- `edit` — modify files (aliases: `Edit`, `MultiEdit`, `Write`, `NotebookEdit`)
- `search` — search for text or files (aliases: `Grep`, `Glob`)
- `execute` — run shell commands (aliases: `shell`, `Bash`, `powershell`)
- `agent` — delegate to sub-agents (aliases: `custom-agent`, `Task`)

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
