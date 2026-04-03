# Agent Profile Reference

Format and best practices for `.agent.md` custom agent profiles.

## File location

Agent profiles are discovered by Copilot CLI from:

- **Personal repo (default):** `~/.cronagents/.github/agents/<agent-name>.agent.md`
- **User-global:** `~/.copilot/agents/<agent-name>.agent.md`

## Important for CronAgents

CronAgents runs custom agents through **GitHub Copilot CLI**, so `.agent.md` files must use the CLI-compatible custom-agent format.

- Prefer the official tool aliases `read`, `edit`, `search`, `execute`, and `agent`.
- Namespaced MCP tools such as `github/*`, `playwright/*`, or `server-name/tool-name` are also valid when explicitly needed.
- Compatible aliases include `shell`, `Bash`, and `powershell` for `execute`, plus `Grep` and `Glob` for `search`.
- Do **not** use VS Code-only tool names such as `editFiles`, `runCommands`, `runTasks`, `codebase`, `findTestFiles`, `usages`, `terminalLastCommand`, `terminalSelection`, `changes`, `problems`, `githubRepo`, or `vscodeAPI` in CronAgents agent profiles. Copilot CLI/cloud-agent configuration ignores unrecognized tool names.

## Format

```markdown
---
name: <display-name>
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
| `name` | No (recommended) | Display name for the custom agent. Keep it aligned with the file purpose for clarity. |
| `description` | Yes | One-line description for documentation, discovery, and agent selection. |
| `tools` | No | Array of CLI-compatible tool names the agent can use. Omit to allow all tools. |

For CronAgents, the registration file's `agent` field should match the `.agent.md` **file stem** (for example, `security-scan` from `security-scan.agent.md`), not necessarily the frontmatter `name`.

### Common tool sets

| Use case | Tools | Notes |
|----------|-------|-------|
| Read-only analysis | `[read]` or `[read, search]` | Safest — can't modify anything. |
| Code editing | `[read, edit, search]` | Can modify files but not run commands. |
| Shell access (limited) | `[read, execute]` | `shell` is also accepted, but `execute` is the primary alias from the official custom-agent docs. Pair with `denyTools` in registration to block dangerous commands. |
| Multi-agent coordination | `[read, search, agent]` | Lets the agent delegate to other custom agents without granting edit or shell access. |
| Full access | All tools | Only when genuinely needed. Prefer scoped tools. |

### Tool names

- `read` — read file contents
- `search` — search/grep across files
- `edit` — modify files
- `execute` — run shell commands (`shell`, `Bash`, and `powershell` are compatible aliases)
- `agent` — delegate to another custom agent
- `github/*`, `playwright/*`, or `server-name/tool-name` — namespaced MCP tools when configured

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
- **CLI-first tools** — if a generated draft uses VS Code-style tool names, rewrite the list to CLI-compatible aliases before saving.
- **No shell unless required** — if you need shell access, prefer `execute`/`shell` only when necessary and use `denyTools` in the registration to block destructive commands.
