# Getting Started

This guide walks you through installing CronAgents, creating your first scheduled agent, and verifying everything works.

## Prerequisites

| Requirement | Minimum | Check command |
|-------------|---------|---------------|
| Windows | 10 / Server 2016+ | — |
| PowerShell | 7.0+ | `$PSVersionTable.PSVersion` |
| GitHub Copilot CLI | Latest, authenticated | `copilot --version` |
| Git | 2.x+ | `git --version` |

> **Note:** CronAgents is Windows-first. The scheduler uses Windows Task Scheduler to run at logon.

Make sure you are signed into Copilot CLI before proceeding:

```powershell
copilot auth status
```

If not authenticated, run `copilot auth login` first.

## Installation

### 1. Clone the repository

```powershell
git clone <repo-url> CronAgents
cd CronAgents
```

### 2. Run the installer

```powershell
.\cronagents.ps1 install
```

This does two things:

1. **Registers a Windows Task Scheduler entry** that starts the scheduler automatically at logon. The task runs `Start-CronAgents.ps1` in a hidden PowerShell window — no terminal pops up.
2. **Bootstraps your user branch** (`agents/<your-username>`) so your agent customizations are tracked separately from the scaffold code on `master`.

You should see output like:

```
✔ Scheduled task registered: \CronAgents\CronAgents
  Trigger:   At logon
  Scheduler: scheduler\Start-CronAgents.ps1
  Branch:    agents/your-name

To start now:  Start-ScheduledTask -TaskName 'CronAgents' -TaskPath '\CronAgents\'
```

### 3. Start the scheduler now (optional)

The scheduler will start automatically at your next logon. To start it immediately:

```powershell
Start-ScheduledTask -TaskName 'CronAgents' -TaskPath '\CronAgents\'
```

## Create your first agent

The fastest way to get started is to copy a template and customize it.

### Using the agent-creator skill

If you're in a Copilot CLI session, use the built-in skill:

```
/agent-creator
```

It will walk you through an interview to set up your agent's name, schedule, prompt, and tool permissions.

### Manual setup

Create one registration file in `.cronagents/agents/` and one custom agent profile in `.github/agents/`:

**`.github/agents/daily-review.agent.md`** — the agent definition:

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
2. For each commit, review the diff for bugs, missing error handling,
   and security issues.
3. Summarize findings in a clear, actionable format.
```

**`.cronagents/agents/daily-review.agent-registration.json`** — the agent registration:

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Daily Code Review",
  "agent": "daily-review",
  "prompt": "Review yesterday's code changes and report findings",
  "schedule": { "type": "daily", "time": "09:00" },
  "timeout": "10m"
}
```

The filename stem (`daily-review`) is your **agent ID** — use it everywhere in CLI commands and state tracking.

## Test the agent

Run it manually to make sure it works:

```powershell
.\cronagents.ps1 run daily-review
```

This invokes the agent immediately through Copilot CLI and captures output in a run directory under `.cronstate/runs/`.

## Verify everything is working

### Check status

```powershell
.\cronagents.ps1 status
```

You'll see a table like:

```
Agent           Status    Schedule       Last Run              Next Run              Feedback
-----           ------    --------       --------              --------              --------
daily-review    enabled   daily 09:00    2024-01-15 09:02      2024-01-16 09:00      —
```

### Check the dashboard

After the scheduler runs, it generates `dashboard.md` in the repo root with a live summary of all agents, recent runs, and pending feedback.

### Run the health check

```powershell
.\cronagents.ps1 doctor
```

This verifies that the Task Scheduler entry is registered, configs are valid, Copilot CLI is reachable, and the git branch state is healthy.

## What happens at next logon

When you log in to Windows, Task Scheduler automatically starts the CronAgents scheduler in the background. The scheduler:

1. Waits for the configured startup delay (default: 5 minutes) to avoid thrashing at boot.
2. Discovers all agents in `.cronagents/agents/`.
3. Checks each agent's schedule against its last run time.
4. Runs any agents that are due.
5. Updates the dashboard.
6. Repeats on a ~60-second tick cycle.

You don't need to open a terminal or do anything — it just works in the background.

## Next steps

- [Configuration reference](configuration.md) — tune global settings and per-agent options
- [Writing agents](writing-agents.md) — create more agents, learn about prompt-only mode
- [CLI reference](cli-reference.md) — all available commands
- [Feedback system](feedback-system.md) — how to improve agents over time
