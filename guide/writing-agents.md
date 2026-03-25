# Writing Agents

This guide covers how to create scheduled agents, choose between agent mode and prompt-only mode, scope tools properly, and test your agents.

## Where agents live

CronAgents registrations go in `.cronagents/agents/`. Each scheduled entry needs a registration file named `<agent-id>.agent-registration.json`.

If you use agent mode, the Copilot custom agent profile is a separate `.agent.md` file in a Copilot-supported discovery location:

- Project-local: `.github/agents/<agent-name>.agent.md`
- User-global: `~/.copilot/agents/<agent-name>.agent.md`

```
.cronagents/
└── agents/
    ├── daily-review.agent-registration.json   # CronAgents registration
    ├── dep-check.agent-registration.json      # Prompt-only registration
    └── weekly-audit.agent-registration.json   # CronAgents registration

.github/
└── agents/
    ├── daily-review.agent.md                  # Copilot custom agent profile
    └── weekly-audit.agent.md                  # Copilot custom agent profile
```

The filename stem (e.g., `daily-review` from `daily-review.agent-registration.json`) is the **agent ID**. It must be unique and is used in:

- CLI commands: `cronagents.ps1 run daily-review`
- State tracking: `.cronstate/state.json`
- Run directories: `.cronstate/runs/20240115T143022_daily-review_a1b2/`
- Dashboard links

---

## Branch safety first

Tracked agent registrations belong on your personal CronAgents branch, not `master` / `main`.

Before creating or editing files in `.cronagents/agents/`:

1. Check `.\cronagents.ps1 branch`
2. If you are on `master` / `main`, switch to the expected `agents/<user>` branch first
3. `.\cronagents.ps1 install` bootstraps the user branch during initial setup

## Agent mode

Agent mode uses a custom Copilot `.agent.md` profile plus a CronAgents registration file. The `.agent.md` provides a system prompt and scopes which tools the agent can use.

### Step 1: Create the agent definition

**`.github/agents/security-scan.agent.md`**

```markdown
---
name: security-scan
description: "Scan for security vulnerabilities in code and dependencies"
tools:
  - read
  - search
---

You are a security scanner. You look for common vulnerabilities
in this repository.

## What to check

1. Search for hardcoded secrets (API keys, passwords, tokens)
2. Check for known vulnerable patterns (SQL injection, XSS, path traversal)
3. Review dependency files for known CVEs

## Output format

Report each finding with:
- **Severity**: Critical / High / Medium / Low
- **File**: path
- **Line**: number (if applicable)
- **Issue**: description
- **Recommendation**: how to fix
```

**Frontmatter fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Agent name, passed to Copilot CLI via `--agent` |
| `description` | No | One-line description for documentation |
| `tools` | Yes | Array of tool names the agent can use |

Everything after the frontmatter is the **system prompt** that defines the agent's behavior.

### Step 2: Create the registration file

**`.cronagents/agents/security-scan.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Security Scanner",
  "agent": "security-scan",
  "prompt": "Scan the repository for security vulnerabilities",
  "schedule": { "type": "daily", "time": "06:00" },
  "timeout": "15m",
  "retryCount": 1
}
```

The `agent` field must match the custom agent name that Copilot CLI discovers from `.github/agents/` or `~/.copilot/agents/`.

---

## Prompt-only mode

Prompt-only mode skips the `.agent.md` file. You only create a registration file. The prompt contains all the instructions. All tools are enabled by default (use `denyTools` to restrict).

**`.cronagents/agents/dep-check.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "prompt": "Check all package.json files for outdated dependencies. List each outdated package with current version, latest version, and whether it's a major/minor/patch update.",
  "schedule": { "type": "weekly", "day": "monday", "time": "08:00" },
  "timeout": "10m",
  "denyTools": ["edit", "shell(rm)", "shell(git push)"]
}
```

**When to use prompt-only mode:**

- Quick one-off tasks that don't need a persistent system prompt
- Simple read-only checks where writing a full `.agent.md` feels like overkill
- Tasks where you want all tools but need to deny a few specific ones

**When to use agent mode:**

- The agent has complex instructions that benefit from a structured system prompt
- You need precise tool scoping (least privilege)
- The agent will be refined over time via the feedback system
- Other people might reuse the agent definition

---

## Tool scoping best practices

Follow the principle of **least privilege** — give agents only the tools they need.

### Common tool sets

| Use case | Tools | Notes |
|----------|-------|-------|
| Read-only analysis | `[read]` or `[read, search]` | Safest. Can't modify anything. |
| Code editing | `[read, edit, search]` | Can modify files but not run commands. |
| Shell access (limited) | `[read, shell]` | Pair with `denyTools` to block dangerous commands. |
| Full access | All tools | Only when genuinely needed. Prefer agent mode with scoped tools. |

### Restricting shell commands

In prompt-only mode (all tools enabled), use `denyTools` to block specific shell commands:

```json
"denyTools": [
  "shell(rm)",
  "shell(git push)",
  "shell(git reset)"
]
```

In agent mode, simply omit `shell` from the tools list to prevent all shell access.

### Tool resolution

For agent mode, Copilot CLI loads the custom agent profile by name from its supported discovery locations (such as `.github/agents/` or `~/.copilot/agents/`). The profile's frontmatter controls which tools are available. Common tool names:

- `read` — read file contents
- `search` — search/grep across files
- `edit` — modify files
- `shell` — run shell commands

---

## Schedule types

### Interval (minimum 30 minutes)

```json
"schedule": { "type": "interval", "every": "2h" }
```

```json
"schedule": { "type": "interval", "every": "30m" }
```

The agent runs every N hours/minutes, measured from when it last completed. If the scheduler was down, the agent runs on the next tick after its interval has elapsed.

### Daily

```json
"schedule": { "type": "daily", "time": "09:00" }
```

Runs once a day at the specified time (24-hour format). If the scheduler starts after the scheduled time, the agent runs on the next tick if it hasn't run today.

### Weekly

```json
"schedule": { "type": "weekly", "day": "friday", "time": "17:00" }
```

Runs once a week on the specified day and time. Day names must be lowercase.

---

## Testing agents

Always test your agent before relying on the scheduler:

```powershell
.\cronagents.ps1 run security-scan
```

This runs the agent immediately and captures output. Check the results:

1. Look at the run directory created under `.cronstate/runs/`
2. Read `output.md` for the agent's raw output
3. Read `summary.md` for the LLM-generated summary
4. Check `meta.json` for exit code, timing, and timeout status

If the agent fails or produces bad output, edit the `.agent.md` or prompt and run again.

---

## Using the agent-creator skill

The fastest way to create a new agent is the built-in `/agent-creator` skill. In a Copilot CLI session:

```
/agent-creator
```

The skill runs an interactive interview:

1. **What should this agent do?** — Describe the task
2. **Agent mode or prompt-only?** — Guided recommendation
3. **What tools does it need?** — Least-privilege suggestions
4. **Schedule** — Interval, daily, or weekly
5. **Additional options** — Timeout, retry, battery, model

It then generates the `.agent.md` profile and `.agent-registration.json` registration file for you, validates them against the schemas, and places them in the correct locations.

---

## Examples

### Code review agent (daily)

Reviews yesterday's changes and reports issues.

**`.github/agents/daily-review.agent.md`**

```markdown
---
name: daily-review
description: "Review recent code changes and summarize findings"
tools:
  - read
  - search
---

You are a code reviewer. Each day you review the most recent changes
in this repository and produce a summary.

1. Run `git log --oneline --since="24 hours ago"` to find recent commits.
2. For each commit with code changes, review the diff for:
   - Potential bugs or logic errors
   - Missing error handling
   - Style inconsistencies
   - Security concerns
3. Summarize findings in a clear, actionable format.

Start with a one-line status: either "✓ No issues found" or "⚠ N issues found".
```

**`.cronagents/agents/daily-review.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Daily Code Review",
  "agent": "daily-review",
  "prompt": "Review code changes from the last 24 hours",
  "schedule": { "type": "daily", "time": "09:00" },
  "timeout": "10m",
  "retryCount": 1
}
```

### Dependency audit (weekly, prompt-only)

Checks for outdated and vulnerable packages. No `.agent.md` needed.

**`.cronagents/agents/dep-audit.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Dependency Audit",
  "prompt": "Audit all dependency files (package.json, requirements.txt, go.mod) for outdated packages and known security vulnerabilities. Produce a table of findings sorted by severity.",
  "schedule": { "type": "weekly", "day": "wednesday", "time": "10:00" },
  "timeout": "15m",
  "denyTools": ["edit"]
}
```

### Stale branch cleanup (weekly)

Finds and reports branches that haven't been updated recently.

**`.github/agents/branch-cleanup.agent.md`**

```markdown
---
name: branch-cleanup
description: "Report stale git branches"
tools:
  - read
  - search
---

List all remote branches that have had no commits in the last 30 days.
For each stale branch, show:
- Branch name
- Last commit date
- Last commit author
- Whether it has been merged to master

Do NOT delete any branches. Only report.
```

**`.cronagents/agents/branch-cleanup.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Stale Branch Report",
  "agent": "branch-cleanup",
  "prompt": "Find and report all stale remote branches",
  "schedule": { "type": "weekly", "day": "friday", "time": "16:00" },
  "timeout": "5m"
}
```

### Resource monitor (interval)

Checks disk space and memory usage every 4 hours.

**`.cronagents/agents/resource-monitor.agent-registration.json`**

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "prompt": "Check current disk space usage and memory utilization. Alert if any drive is above 90% capacity or available memory is below 500MB. Format as a brief status report.",
  "schedule": { "type": "interval", "every": "4h" },
  "timeout": "5m",
  "skipOnBattery": true,
  "denyTools": ["edit"]
}
```

---

## Tips

- **Start small.** Give agents narrow scope and simple prompts, then refine using the [feedback system](feedback-system.md).
- **Use `read` and `search` as your default tool set.** Only add `edit` or `shell` when the agent needs to modify things.
- **Set realistic timeouts.** A 10-minute timeout works for most agents. Increase for agents that process large codebases.
- **Test before deploying.** Always run `cronagents.ps1 run <id>` at least once before leaving an agent to the scheduler.
- **Use meaningful agent IDs.** The filename becomes the ID — `daily-review` is better than `agent1`.
