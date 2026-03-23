# CLI Reference

All CronAgents operations go through the `cronagents.ps1` script at the repository root.

```powershell
.\cronagents.ps1 <command> [arguments]
```

Running without arguments launches the [interactive menu](#interactive-menu).

---

## Commands

### `run <agent-id>`

Trigger an ad-hoc run of a specific agent immediately, bypassing the schedule.

```powershell
.\cronagents.ps1 run daily-review
```

The agent runs through Copilot CLI and output is captured in a new run directory under `.cronstate/runs/`. This is the primary way to test agents before relying on the scheduler.

The run goes through the same pipeline as a scheduled run: output capture, metadata recording, summary generation, and feedback stub creation.

---

### `status`

Show the current state of the scheduler and all agents.

```powershell
.\cronagents.ps1 status
```

Output:

```
Agent           Status    Schedule       Last Run              Next Run              Feedback
-----           ------    --------       --------              --------              --------
daily-review    enabled   daily 09:00    2024-01-15 09:02      2024-01-16 09:00      📝 Pending
weekly-deps     disabled  weekly mon…    2024-01-08 10:00      —                     —
security-scan   enabled   interval 2h    2024-01-15 14:30      2024-01-15 16:30      ✅ Processed
```

**Columns:**

| Column | Description |
|--------|-------------|
| Agent | Agent ID (filename stem) |
| Status | `enabled` or `disabled` (per-agent pause state) |
| Schedule | Human-readable schedule description |
| Last Run | When the agent last completed |
| Next Run | When the agent will next run (`—` if disabled) |
| Feedback | `📝 Pending`, `✅ Processed`, or `—` (no feedback) |

If the scheduler is globally paused, a warning is shown at the top.

---

### `list`

List all discovered agents and their schedules.

```powershell
.\cronagents.ps1 list
```

Output:

```
ID              Name                 Schedule            Next Run
--              ----                 --------            --------
daily-review    Daily Code Review    daily 09:00         2024-01-16 09:00
weekly-deps     Dependency Check     weekly monday 08:00 2024-01-22 08:00
security-scan   Security Scanner     interval 2h         2024-01-15 16:30
```

Agents are discovered from `.cronagents/agents/` by scanning for `.json` files that match the agent schema.

---

### `pause [agent-id]`

Pause the scheduler or a specific agent.

```powershell
# Pause the entire scheduler (no agents will run)
.\cronagents.ps1 pause

# Pause a specific agent
.\cronagents.ps1 pause daily-review
```

**Global pause** sets `schedulerPaused: true` in `.cronstate/state.json`. The scheduler loop continues ticking but skips all agent evaluation.

**Per-agent pause** sets `enabled: false` for that agent in state. Other agents continue running.

---

### `resume [agent-id]`

Resume the scheduler or a specific agent.

```powershell
# Resume the entire scheduler
.\cronagents.ps1 resume

# Resume a specific agent
.\cronagents.ps1 resume daily-review
```

---

### `feedback [agent-id]`

Open the most recent pending feedback file in your default editor.

```powershell
# Open the most recent pending feedback across all agents
.\cronagents.ps1 feedback

# Open the most recent pending feedback for a specific agent
.\cronagents.ps1 feedback daily-review
```

This finds the most recent run directory that has an unprocessed `feedback.md` and opens it. Write your feedback as plain text, then save and close the editor.

The feedback will be processed the next time you run `cronagents.ps1 evaluate` (or automatically if `autoFeedback` is enabled).

---

### `evaluate`

Process all pending feedback using the feedback evaluator agent.

```powershell
.\cronagents.ps1 evaluate
```

This finds all run directories with unprocessed feedback and invokes the feedback-evaluator agent for each one. The evaluator reads your feedback, makes targeted edits to the agent's definition files, and writes a changelog to `feedback-result.md`.

If `versioning.autoCommitFeedback` is `true`, changes are automatically committed to git.

See [Feedback System](feedback-system.md) for the full workflow.

---

### `doctor`

Run health checks to verify the CronAgents installation.

```powershell
.\cronagents.ps1 doctor
```

Checks include:

- Task Scheduler entry is registered
- Config files are valid JSON and pass schema validation
- Copilot CLI is available and authenticated
- State file integrity
- Git repository and branch health
- Agent config discovery

Each check reports pass/fail with details on how to fix failures.

---

### `install`

Register the Windows Task Scheduler entry and bootstrap the user branch.

```powershell
.\cronagents.ps1 install
```

**What it does:**

1. Registers a scheduled task (`\CronAgents\CronAgents`) that triggers at logon
2. Creates or checks out your user branch (`agents/<username>`)

The command is idempotent — running it again won't create duplicate tasks. Use this after cloning the repo for the first time or if the task was accidentally removed.

---

### `uninstall`

Remove the Windows Task Scheduler entry.

```powershell
.\cronagents.ps1 uninstall
```

Stops the running scheduler (if active) and removes the `\CronAgents\CronAgents` scheduled task. Does not delete any files, configs, or run history.

---

### `sync`

Merge the latest changes from `master` into your user branch.

```powershell
.\cronagents.ps1 sync
```

Fetches `origin/master` and merges into your current branch. If conflicts are detected, CronAgents attempts agent-assisted resolution via Copilot CLI. If that fails, the merge is aborted and you can resolve manually.

See [Branching & Sync](branching-and-sync.md) for details.

---

### `branch`

Show information about the current branch and its relationship to `master`.

```powershell
.\cronagents.ps1 branch
```

Output includes:

- Current branch name
- Whether it's a valid user branch
- Expected branch name based on username
- Commits ahead/behind `master`
- Last sync time (merge-base)

---

### `help` / `--help`

Show the usage summary.

```powershell
.\cronagents.ps1 help
.\cronagents.ps1 --help
```

---

## Interactive menu

Running `cronagents.ps1` with no arguments launches a numbered interactive menu:

```
CronAgents — Interactive Menu

  1) Status & upcoming runs
  2) Trigger ad-hoc run
  3) Pause / Resume
  4) View run history
  5) Submit feedback
  6) Health check (doctor)
  7) Sync from master
  8) Branch info
  9) Exit

Select [1-9]:
```

### Menu options

| # | Action | Description |
|---|--------|-------------|
| 1 | Status & upcoming runs | Same as `cronagents.ps1 status` |
| 2 | Trigger ad-hoc run | Shows a list of discovered agents, lets you pick one to run |
| 3 | Pause / Resume | Choose global or per-agent, then pause or resume |
| 4 | View run history | Shows the 20 most recent runs with agent, time, exit code, and feedback status |
| 5 | Submit feedback | Opens the most recent pending `feedback.md` in your editor |
| 6 | Health check | Same as `cronagents.ps1 doctor` |
| 7 | Sync from master | Same as `cronagents.ps1 sync` |
| 8 | Branch info | Same as `cronagents.ps1 branch` |
| 9 | Exit | Close the menu |

Type the number and press Enter. After each action completes, the menu reappears so you can perform additional operations.

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (invalid arguments, agent not found, config error) |
| Agent exit code | Propagated from Copilot CLI when using `run` |

---

## Quick reference

```powershell
.\cronagents.ps1                        # Interactive menu
.\cronagents.ps1 run daily-review       # Run agent now
.\cronagents.ps1 status                 # Show all agent statuses
.\cronagents.ps1 list                   # List discovered agents
.\cronagents.ps1 pause                  # Pause scheduler globally
.\cronagents.ps1 pause daily-review     # Pause specific agent
.\cronagents.ps1 resume                 # Resume scheduler
.\cronagents.ps1 resume daily-review    # Resume specific agent
.\cronagents.ps1 feedback               # Open pending feedback
.\cronagents.ps1 feedback daily-review  # Open feedback for agent
.\cronagents.ps1 evaluate               # Process all pending feedback
.\cronagents.ps1 doctor                 # Run health checks
.\cronagents.ps1 install                # Register Task Scheduler + branch
.\cronagents.ps1 uninstall              # Remove Task Scheduler entry
.\cronagents.ps1 sync                   # Merge from master
.\cronagents.ps1 branch                 # Show branch info
```
