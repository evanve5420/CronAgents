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
Agent           Status    Schedule                         Last Run              Next Run              Questions       Feedback
-----           ------    --------                         --------              --------              ---------       --------
daily-review    Enabled   daily at 09:00                   2024-01-15 09:02      2024-01-16 09:00      -               1 pending
weekly-deps     Disabled  weekly tuesday, friday at 12:00  2024-01-12 12:00      2024-01-16 12:00      -               -
security-scan   Enabled   every 2h                         2024-01-15 14:30      2024-01-15 16:30      -               2 pending
```

**Columns:**

| Column | Description |
|--------|-------------|
| Agent | Agent ID (filename stem) |
| Status | `Enabled`, `Disabled`, or `Blocked` (per-agent pause/question state) |
| Schedule | Human-readable schedule description |
| Last Run | When the agent last completed |
| Next Run | When the agent will next run (`—` if disabled) |
| Questions | Number of pending questions, or `-` |
| Feedback | Number of pending feedback items, or `-` |

If the scheduler is globally paused, a warning is shown at the top.

---

### `list`

List all discovered agents and their schedules.

```powershell
.\cronagents.ps1 list
```

Output:

```
ID              Name                 Schedule                         Next Run
--              ----                 --------                         --------
daily-review    Daily Code Review    daily at 09:00                   2024-01-16 09:00
weekly-deps     Dependency Check     weekly tuesday, friday at 12:00  2024-01-16 12:00
security-scan   Security Scanner     every 2h                         2024-01-15 16:30
```

Agents are discovered from `.cronagents/agents/` by scanning for `*.agent-registration.json` files that match the agent schema.

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

If `personalRepo.autoCommitFeedback` is `true`, changes are automatically committed to the personal repo.

See [Feedback System](feedback-system.md) for the full workflow.

---

### `questions`

List and interactively answer pending agent questions (human-in-the-loop decisions).

```powershell
# Answer pending questions across all agents
.\cronagents.ps1 questions

# Answer pending questions for a specific agent
.\cronagents.ps1 questions daily-review
```

Agents can pause and ask a question instead of guessing. This command lists each
pending question, lets you pick a provided choice or type a custom response, and
records the answer so the agent receives it on its next run.

---

### `clear [agent-id]`

Delete run history from `.cronstate/runs/`.

```powershell
# Clear run history for all agents
.\cronagents.ps1 clear

# Clear run history for a specific agent
.\cronagents.ps1 clear daily-review
```

Prompts for confirmation before deleting. This removes captured run directories
(output, summaries, metadata); it does not affect agent definitions, registrations,
or config.

---

### `doctor`

Run health checks to verify the CronAgents installation.

```powershell
.\cronagents.ps1 doctor
```

Checks include:

- Task Scheduler entry is registered (definition and triggers match)
- Global config is valid JSON and passes schema validation
- Agent configs are discoverable and reference existing `.agent.md` files
- State file is readable and well-formed
- The background scheduler process is running
- No orphaned run directories
- A notification backend (BurntToast or native) is available

Each check reports pass/fail with details on how to fix failures.

---

### `install`

Register the Windows Task Scheduler entry and initialize the personal repo.

```powershell
.\cronagents.ps1 install
```

**What it does:**

1. Registers a scheduled task (`\CronAgents\CronAgents`) that triggers at logon and re-launches every 15 minutes for crash recovery
2. Initializes the personal repo at `~/.cronagents/` (or the configured `personalRepo.path`)

The command is idempotent — running it again won't create duplicate tasks or reinitialize an existing personal repo. Use this after cloning the infra repo for the first time or if the task was accidentally removed.

---

### `uninstall`

Remove the Windows Task Scheduler entry.

```powershell
.\cronagents.ps1 uninstall
```

Stops the running scheduler (if active) and removes the `\CronAgents\CronAgents` scheduled task. Does not delete any files, configs, or run history.

---

### `migrate`

Migrate agent definitions from the old branch model (`personal-agents/<username>`) to the personal repo.

```powershell
.\cronagents.ps1 migrate
```

Copies agent profiles and registrations from the current infra repo into the personal repo at `~/.cronagents/`. Existing files in the personal repo are not overwritten unless `--force` is specified.

---

### `help` / `--help`

Show the usage summary.

```powershell
.\cronagents.ps1 help
.\cronagents.ps1 --help
```

---

### `dashboard`

Start the HTML dashboard server and open it in your browser.

```powershell
.\cronagents.ps1 dashboard
```

Launches a lightweight HTTP server on `127.0.0.1:9077` serving an interactive HTML dashboard. The dashboard provides live status, agent controls (pause/resume/trigger), configuration inspection, run history with details, feedback submission, and question answering — all through a browser UI. Auto-refreshes every 5 seconds.

The server runs until you press Ctrl+C. Both the HTML dashboard and the static `dashboard.md` can coexist — they read from the same `.cronstate/` data.

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
  6) Pending questions
  7) Health check (doctor)
  8) Open HTML dashboard
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
| 6 | Pending questions | View and answer pending agent questions interactively |
| 7 | Health check | Same as `cronagents.ps1 doctor` |
| 8 | Open HTML dashboard | Same as `cronagents.ps1 dashboard` — starts the browser-based management UI |
| 9 | Exit | Close the menu |

Type the number and press Enter. After each action completes, the menu reappears so you can perform additional operations.

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (invalid arguments, agent not found, config error) |
| ggent exit code | Propagated from Copilot CLI when using `run` |

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
.\cronagents.ps1 questions              # View and answer pending questions
.\cronagents.ps1 clear                  # Clear run history (all agents)
.\cronagents.ps1 clear daily-review     # Clear run history for an agent
.\cronagents.ps1 dashboard              # Open HTML dashboard in browser
.\cronagents.ps1 doctor                 # Run health checks
.\cronagents.ps1 install                # Register Task Scheduler + personal repo
.\cronagents.ps1 uninstall              # Remove Task Scheduler entry
.\cronagents.ps1 migrate                # Migrate from branch model to personal repo
```

