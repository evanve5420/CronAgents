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
| Read-only analysis | `[read]` or `[read, search]` | Safest — can't modify anything. |
| Code editing | `[read, edit, search]` | Can modify files but not run commands. |
| Shell access (limited) | `[read, shell]` | Pair with `denyTools` in registration to block dangerous commands. |
| Full access | All tools | Only when genuinely needed. Prefer scoped tools. |

### Tool names

- `read` — read file contents
- `search` — search/grep across files
- `edit` — modify files
- `shell` — run shell commands

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

- **Least privilege** — start with `[read]` or `[read, search]` and expand only if needed.
- **Focused system prompts** — tell the agent exactly what to do and what format to use.
- **No shell unless required** — if you need shell, use `denyTools` in the registration to block destructive commands.
