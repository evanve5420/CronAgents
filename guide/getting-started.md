# Getting Started

This guide walks you through installing CronAgents, creating your first scheduled agent, and verifying everything works.

> **Note:** CronAgents is Windows-first. The scheduler uses Windows Task Scheduler to run at logon.

## Quickstart via Copilot CLI

If you already have GitHub Copilot CLI installed and authenticated, that's all you need. Open a terminal, start a Copilot session, and point it at this repo:

```
Read https://github.com/evanve5420/CronAgents and set up CronAgents for me.
```

Copilot will read the docs and drive the full setup — cloning, checking for Git and PowerShell, running the installer — asking you questions as needed.

---

## Prerequisites

If you prefer to set things up manually, you'll need the following. Run each check command in a terminal (PowerShell or Windows Terminal) to verify it's installed.

| Requirement | Minimum | Check command |
|-------------|---------|---------------|
| Windows | 10 / Server 2016+ | — |
| PowerShell | 7.0+ | `$PSVersionTable.PSVersion` |
| GitHub Copilot CLI | Latest, authenticated | `copilot --version` |
| Git | 2.x+ | `git --version` |

### Installing prerequisites

Open a terminal and run the following `winget` commands for anything you're missing:

```powershell
# PowerShell 7+
winget install Microsoft.PowerShell

# Git
winget install Git.Git

# GitHub Copilot CLI
winget install GitHub.Copilot
```

After installing, close and reopen your terminal so the new tools are on your PATH.

Then authenticate Copilot CLI:

```powershell
copilot login
copilot --version   # verify it's working
```

## Installation

### 1. Clone the repository

In a terminal, run:

```powershell
git clone https://github.com/evanve5420/CronAgents CronAgents
cd CronAgents
```

### 2. Run the installer

Still in the same terminal window:

```powershell
.\cronagents.ps1 install
```

This does two things:

1. **Registers a Windows Task Scheduler entry** that starts the scheduler automatically at logon, and re-launches it every 15 minutes so it recovers from crashes without waiting for the next logon. The task runs `Start-CronAgents.ps1` in a hidden PowerShell window — no terminal pops up.
2. **Initializes your personal repo** at `~/.cronagents/` — a standalone git repository where your agent definitions, registrations, and runtime data live. No branches to manage.

You should see output like:

```
  Task path    : \CronAgents\CronAgents
  Trigger      : At logon (your-username) + every 15 min
  Scheduler    : ...\scheduler\Start-CronAgents.ps1
  Personal repo: ~/.cronagents

To start now:  Start-ScheduledTask -TaskName 'CronAgents' -TaskPath '\CronAgents\'
```

### 3. Start the scheduler now (optional)

The scheduler will start automatically at your next logon. To start it immediately:

```powershell
Start-ScheduledTask -TaskName 'CronAgents' -TaskPath '\CronAgents\'
```

## Create your first agent

The fastest way to get started is to copy a template and customize it.

### Using the creating-agents skill

If you're in a Copilot CLI session, use the built-in skill:

```
/creating-agents
```

It will walk you through an interview to set up your agent's name, schedule, prompt, and tool permissions.

### Manual setup

Create one agent profile in the personal repo's `.github/agents/` and one registration in `.cronagents/agents/`:

**`~/.cronagents/.github/agents/daily-review.agent.md`** — the agent definition:

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

**`~/.cronagents/.cronagents/agents/daily-review.agent-registration.json`** — the agent registration:

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
  Agent                Status     Schedule               Last Run               Next Run               Feedback
  ---------------------------------------------------------------------------------------------------------
  daily-review         Enabled    daily 09:00            2024-01-15 09:02       2024-01-16 09:00       -
```

### Check the dashboard

The primary way to manage and monitor agents is the HTML dashboard. Launch it and open it in your browser:

```powershell
.\cronagents.ps1 dashboard
```

It serves a browser UI at `127.0.0.1:9077` with live status, agent controls (pause/resume/trigger), configuration details, run history, feedback, and questions. See the [CLI reference](cli-reference.md#dashboard) for details.

The scheduler also writes a lightweight `dashboard.md` snapshot in the personal repo for an at-a-glance summary when a browser isn't handy.

### Run the health check

```powershell
.\cronagents.ps1 doctor
```

This verifies that the Task Scheduler entry is registered, configs are valid JSON, state files are well-formed, the scheduler process and a notification backend are healthy, and your agent configs and personal repo are in good shape.

## What happens at next logon

When you log in to Windows, Task Scheduler automatically starts the CronAgents scheduler in the background. The scheduler:

1. Waits for the configured startup delay (default: 5 minutes) to avoid thrashing at boot.
2. Discovers all agents in the personal repo (`~/.cronagents/.cronagents/agents/`).
3. Checks each agent's schedule against its last run time.
4. Runs any agents that are due, with CWD set to the personal repo (or the agent's configured `workingDirectory`).
5. Updates the dashboard.
6. Repeats on a ~60-second tick cycle.

You don't need to open a terminal or do anything — it just works in the background.

## Next steps

- [Configuration reference](configuration.md) — tune global settings and per-agent options
- [Writing agents](writing-agents.md) — create more agents, learn about prompt-only mode
- [CLI reference](cli-reference.md) — all available commands
- [Feedback system](feedback-system.md) — how to improve agents over time
