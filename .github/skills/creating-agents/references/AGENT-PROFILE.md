# Agent Profile Reference

Format and best practices for `.agent.md` custom agent profiles.

## File location

Agent profiles are discovered by Copilot CLI from:

- **Personal repo (default):** `~/.cronagents/.github/agents/<agent-name>.agent.md`
- **User-global:** `~/.copilot/agents/<agent-name>.agent.md`

## Tool format for CronAgents

CronAgents runs custom agents through **GitHub Copilot CLI**.

If you specify `tools:`, use concrete CLI tool names such as `view`, `rg`, `glob`, `edit`, `apply_patch`, `powershell`, `read_powershell`, `write_powershell`, `stop_powershell`, `list_powershell`, `task`, `read_agent`, and `list_agents`.

Do **not** use VS Code-style labels such as `read`, `search`, `shell`, `codebase`, `runCommands`, `usages`, or `vscodeAPI`.

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
| Read-only analysis | `[view, rg, glob]` | Safest — can't modify anything. |
| Code editing | `[view, edit, rg, glob]` | Can modify files but not run commands. |
| Shell access (limited) | `[view, powershell, read_powershell, write_powershell, stop_powershell, list_powershell]` | Pair with `denyTools` in registration to block dangerous commands. |
| Delegation | `[task, read_agent, list_agents]` | Lets the agent delegate work to sub-agents. |
| Full access | All tools | Only when genuinely needed. Prefer scoped tools. |

### Tool names

- `view` — read file contents
- `rg` / `glob` — search for text or files
- `edit` — modify files
- `apply_patch` — patch files
- `powershell`, `read_powershell`, `write_powershell`, `stop_powershell`, `list_powershell` — shell access
- `task`, `read_agent`, `list_agents` — delegate to sub-agents

## Example

```markdown
---
name: security-scan
description: "Scan for security vulnerabilities in code and dependencies"
tools:
  - view
  - rg
  - glob
---

You are a security scanner. Check for:

1. Hardcoded secrets (API keys, passwords, tokens)
2. Known vulnerable patterns (SQL injection, XSS, path traversal)
3. Dependency CVEs

Report each finding with severity, file, line, issue, and recommendation.
```

## Best practices

- **Least privilege** — start with `[view, rg, glob]` and expand only if needed.
- **Focused system prompts** — tell the agent exactly what to do and what format to use.
- **CLI-first tools** — if a generated draft uses VS Code-style tool names, rewrite the list to CLI tool names before saving.
- **No shell unless required** — if you need shell access, use `denyTools` in the registration to block destructive commands.
