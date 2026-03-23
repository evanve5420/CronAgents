# Plan: CronAgents — Scheduled Copilot Agent Scaffolding

A reusable scaffolding that runs Copilot CLI agents on configurable schedules, reports results via a live dashboard markdown file, collects human feedback, and includes a self-improving feedback agent that edits agent/skill/memory files. PowerShell scheduler, JSON config, Copilot CLI invocation.

**Positioning:** This is not an empty market, but the nearby projects cluster into different shapes. Ralph-family projects focus on loop-until-complete autonomous coding. AgentUse and LangChain Runner support scheduled or triggered agents, but they are generic runtimes rather than Copilot-first repo scaffolds. OpenClaw, NanoClaw, Khoj, and Dorabot are assistant platforms where scheduling is one feature among many. CronAgents is positioned as a lightweight, repo-local, Copilot-customization-native scheduler with markdown dashboarding and a first-class human feedback loop.

**High-level differentiation:**
- Copilot-first, using repo customization primitives like `.agent.md`, `SKILL.md`, prompts, and workspace instructions
- Windows-first, PowerShell-first, and intentionally lightweight
- Repo-embedded rather than a global assistant platform or GUI workstation
- Centered on scheduled runs plus feedback-driven self-maintenance, not just task execution

**Customization location strategy:** Separate scaffold runtime from repo development from workload agents. `.github` holds only Copilot customizations for developing this repo (workspace instructions, prompts). Scaffold-internal agents (feedback evaluator, run summarizer) live in `scheduler/agents/` as committed product components. User-defined scheduled workload agents live in gitignored repo-local directories or user-global Copilot directories.

---

## Phase 1: Project Foundation

**Step 1** — Create the directory layout:

```
CronAgents/
├── .github/
│   ├── copilot-instructions.md               ← workspace instructions for repo development
│   ├── skills/
│   │   └── agent-creator/
│   │       └── SKILL.md                      ← interactive skill: create a new scheduled agent
│   └── prompts/
│       └── run-feedback.prompt.md
├── templates/
│   └── agents/
│       ├── daily-review.agent.md.example
│       └── weekly-deps.agent.md.example
├── scheduler/
│   ├── Start-CronAgents.ps1                  ← main entry point
│   ├── Invoke-ScheduledAgent.ps1             ← runs one agent via Copilot CLI
│   ├── Update-Dashboard.ps1                  ← regenerates dashboard.md (deterministic, no LLM)
│   ├── agents/                               ← scaffold-internal agents (committed)
│   │   ├── feedback-evaluator.agent.md
│   │   └── run-summarizer.agent.md           ← summarizes individual agent run output
│   ├── skills/
│   │   └── feedback-evaluator/
│   │       └── SKILL.md
│   └── lib/
│       ├── CronAgents.psd1                   ← module manifest
│       ├── ConfigLoader.ps1                  ← config loading, validation, agent discovery
│       ├── StateManager.ps1                  ← state.json read/write/recovery (file-locked)
│       ├── ScheduleParser.ps1                ← schedule matching logic
│       ├── RunManager.ps1                    ← run directory creation, metadata, output capture
│       ├── GitHelpers.ps1                    ← branch detection, sync, commit, divergence
│       ├── PowerHelpers.ps1                  ← battery state detection
│       ├── Logger.ps1                        ← structured logging (global + per-run)
│       └── RetentionCleanup.ps1              ← run directory expiration
├── cronagents.ps1                           ← CLI wrapper (run, status, pause, resume, feedback)
├── cronagents.json                          ← global scheduler settings (no agent definitions)
├── cronagents.schema.json                   ← JSON Schema for global config validation
├── cronagents-agent.schema.json             ← JSON Schema for per-agent schedule config files
├── dashboard.md                              ← live at-a-glance results (read-only)
├── .cronagents/
│   └── agents/                               ← repo-local workload agents + scheduling configs
│       ├── daily-review.agent.md             ← Copilot agent definition
│       ├── daily-review.json                 ← scheduling config (id = filename stem)
│       ├── weekly-deps.agent.md
│       └── weekly-deps.json
├── .cronstate/                              ← runtime data (always gitignored, entire directory)
│   ├── state.json                            ← last-run timestamps + agent enabled/disabled
│   ├── scheduler.log                         ← global scheduler log (rotated)
│   └── runs/                                 ← per-run detailed output
│       └── <timestamp>_<agent-id>_<nonce>/   ← nonce = short random suffix for uniqueness
│           ├── output.md                     ← captured agent output
│           ├── summary.md                    ← LLM-generated run summary (cached, written once)
│           ├── meta.json                     ← run metadata + feedbackProcessed flag
│           ├── session.md                    ← full session transcript (--share)
│           ├── scheduler.log                 ← per-run debug log (always debug level)
│           ├── feedback.md                   ← human feedback file (user edits this)
│           └── feedback-result.md            ← evaluator's changelog (written by evaluator)
├── tests/
│   ├── ScheduleParser.Tests.ps1
│   ├── ConfigValidation.Tests.ps1
│   ├── InvokeAgent.Tests.ps1
│   ├── Dashboard.Tests.ps1
│   ├── FeedbackFlow.Tests.ps1
│   ├── CliWrapper.Tests.ps1
│   ├── SchedulerLoop.Tests.ps1
│   ├── RetentionCleanup.Tests.ps1
│   ├── StateManagement.Tests.ps1
│   ├── AgentVersioning.Tests.ps1
│   ├── SyncWorkflow.Tests.ps1
│   ├── BackupRestore.Tests.ps1
│   ├── Smoke.Tests.ps1                       ← E2E (requires real Copilot CLI)
│   ├── TestHelpers.psm1                      ← shared setup/teardown
│   ├── fixtures/                             ← sample configs, run data, feedback files
│   └── mocks/
│       └── copilot.ps1                       ← mock Copilot CLI for testing
├── docs/                                     ← developer/design docs (not user-facing)
│   ├── PLAN.md                               ← this file — master build plan
│   ├── TESTING.md                            ← test specifications
│   ├── AGENT-VERSIONING.md                   ← git branch model design
│   ├── FUTURE.md                             ← roadmap beyond day 0
│   ├── SCRIPT-MODE.md                        ← future script mode design
│   ├── UX-REQUIREMENTS.md                    ← future HTML dashboard requirements
│   └── LANDSCAPE.md                          ← competitive intelligence (gitignored)
├── guide/                                    ← user-facing documentation
│   ├── getting-started.md                    ← prerequisites, install, first run
│   ├── configuration.md                      ← cronagents.json reference (all fields, defaults, examples)
│   ├── cli-reference.md                      ← cronagents.ps1 subcommands + TUI menu
│   ├── writing-agents.md                     ← how to create/register a scheduled agent
│   ├── feedback-system.md                    ← how the feedback loop works, editing feedback.md
│   ├── branching-and-sync.md                 ← user branch model, sync commands
│   └── troubleshooting.md                    ← common issues, health check, logs
├── .gitignore
├── README.md                                 ← landing page: overview, feature highlights, docs map
└── LICENSE
```

`.github` is reserved for Copilot customizations that apply when *developing this repo* (workspace instructions, prompts). Scaffold-internal agents (feedback evaluator, run summarizer) and their skills live in `scheduler/agents/` and `scheduler/skills/` because they are product components of the CronAgents runtime, not repo development tools. The scheduler passes `--add-dir=scheduler/` when invoking them so Copilot CLI can resolve them. User-defined scheduled workload agents live in `.cronagents/agents/` (tracked on user branches), user-global directories like `C:\Users\<user>\.copilot`, or both.

**Config split — global settings vs. per-agent scheduling:** `cronagents.json` contains only global scheduler settings (log level, retention, quiet hours, versioning, etc.) — no agent definitions. Each user agent has a sibling `.json` scheduling config alongside its `.agent.md` file in `.cronagents/agents/`. The filename stem (e.g., `daily-review` from `daily-review.json`) serves as the **stable agent ID** used in state tracking, run directories, CLI commands, and future `dependsOn` references. The human-readable `name` field inside the file is display-only and can be changed freely without breaking history. This separation means master never touches agent definitions, user branches never touch global settings, and merge conflicts between the two are structurally impossible.

**Runtime data isolation:** All ephemeral runtime data lives in `.cronstate/` — a separate top-level directory that is always gitignored in its entirety. This includes `state.json`, `scheduler.log`, and all run directories under `runs/`. Clean separation from `.cronagents/` (which contains version-controlled code: agent definitions and scheduling configs on user branches) eliminates mixed git semantics within a single directory.

**Shared module architecture** — `scheduler/lib/` is a single PowerShell module (`CronAgents.psd1` manifest) that all scripts import. This prevents duplicated logic between the scheduler, CLI wrapper, health check, and tests. Each `.ps1` in `lib/` is a nested module exporting specific functions:

| Module file | Exported functions | Consumers |
|---|---|---|
| `ConfigLoader.ps1` | `Import-CronAgentsConfig`, `Test-CronAgentsConfig`, `Get-AgentConfigs` | Scheduler, CLI wrapper, health check, tests |
| `StateManager.ps1` | `Get-AgentState`, `Set-AgentState`, `Reset-AgentState` | Scheduler, CLI wrapper (pause/resume/status), tests |
| `ScheduleParser.ps1` | `Test-AgentDue`, `Get-NextRunTime` | Scheduler, CLI wrapper (status/list), tests |
| `RunManager.ps1` | `New-RunDirectory`, `Write-RunMetadata`, `Get-RunHistory` | `Invoke-ScheduledAgent.ps1`, `Update-Dashboard.ps1`, CLI wrapper, tests |
| `GitHelpers.ps1` | `Get-CronAgentsBranch`, `Get-BranchDivergence`, `Invoke-BranchSync`, `New-FeedbackCommit`, `Initialize-UserBranch` | Scheduler (feedback-commit hook, sync), CLI wrapper (sync/branch/install), tests |
| `PowerHelpers.ps1` | `Test-OnBatteryPower` | Scheduler (skipOnBattery check), tests |
| `Logger.ps1` | `Write-CronAgentsLog`, `Initialize-RunLog` | Everything — all scripts and modules log through this |
| `RetentionCleanup.ps1` | `Invoke-RetentionCleanup` | Scheduler (daily cleanup), tests |

The top-level scripts (`Start-CronAgents.ps1`, `Invoke-ScheduledAgent.ps1`, `Update-Dashboard.ps1`, `cronagents.ps1`, `Test-CronAgentsHealth.ps1`) are thin orchestrators that import the module and call its functions. `tests/TestHelpers.psm1` also imports `CronAgents.psd1`, ensuring tests exercise the same code paths as production.

**Step 2** — `.gitignore` should ignore the entire `.cronstate/` directory on all branches (runtime data). The `.cronagents/` directory is **tracked on user branches** (`agents/<username>`) — this is where user agent definitions and scheduling configs live. On `master`, `.cronagents/` can be empty or absent. Scaffold-internal agents under `scheduler/agents/` are committed on `master`. Examples and templates remain committed on `master`. The per-user branch model, sync policies, auto-bootstrap, and pre-edit snapshot design are detailed in [AGENT-VERSIONING.md](AGENT-VERSIONING.md).

---

## Phase 2: Configuration System

Configuration is split into two layers: **global scheduler settings** (`cronagents.json`) and **per-agent scheduling configs** (individual `.json` files alongside each agent's `.agent.md`).

### Step 3a — Global config: `cronagents.json`

Contains only scheduler-wide settings — no agent definitions. Day 0 should support coarse-grained recurring schedules only, with **1 hour as the recommended default** and **30 minutes as the finest supported interval**.
  - `{ "type": "interval", "every": "1h" }`
  - `{ "type": "interval", "every": "4h" }`
  - `{ "type": "daily", "time": "09:00" }`
  - `{ "type": "weekly", "day": "monday", "time": "10:00" }`

If cron syntax is added, it should be treated as a normalized internal representation, not as a promise of arbitrary minute-level scheduling. Day 0 policy is deliberately coarse because the scheduler runs agents sequentially and most real agent runs will take longer than a minute.

Settings include `autoFeedback` toggle, `maxRunHistory`, `copilotPath` (defaults to `copilot`), `retentionDays` (default 14 — run directories older than this are deleted; set to 0 to disable), `startupDelay` (default `5m` — how long the scheduler waits after process start before the first evaluation tick; set to `0` to disable), `logLevel` (default `"info"`, also `"debug"`, `"warn"`, `"error"` — controls verbosity of scheduler log output), `quietHours` (optional — time window during which no agents are started; due agents queue until the window ends), and optional overrides for Copilot CLI environment.

Agent versioning settings (in a `versioning` block):
- `syncPolicy` — `"notify"` (default), `"auto"`, or `"manual"`. Controls how scaffold updates from master are handled. See [AGENT-VERSIONING.md](AGENT-VERSIONING.md).
- `userName` — explicit override for branch name (`agents/<userName>`). When omitted, auto-detected from `git config user.name` (slugified) or `$env:USERNAME`.
- `autoCommitFeedback` — when `true` (default), the scheduler commits evaluator edits to the user branch automatically.
- `branchPrefix` — branch naming prefix. Default `"agents"` → branches named `agents/<userName>`.

#### Global config example

```jsonc
{
  "$schema": "./cronagents.schema.json",
  "autoFeedback": false,
  "maxRunHistory": 50,
  "copilotPath": "copilot",
  "retentionDays": 14,
  "startupDelay": "5m",
  "logLevel": "info",
  "quietHours": { "start": "22:00", "end": "06:00" },

  "versioning": {
    "syncPolicy": "notify",
    "userName": null,
    "autoCommitFeedback": true,
    "branchPrefix": "agents"
  }
}
```

All fields are optional — sensible defaults apply.

### Step 3b — Per-agent scheduling configs

Each user agent has a `.json` file alongside its `.agent.md` in `.cronagents/agents/` (or in user-global Copilot directories). The **filename stem is the stable agent ID** — used in `state.json` keys, run directory names, CLI arguments, and future `dependsOn` references. The `name` field inside the file is a human-readable display label that can be changed freely without breaking history.

Agent discovery: the scheduler scans `.cronagents/agents/*.json` (and any additional directories from config) on startup. Each `.json` file found is a scheduling config. No central registration step — drop files in the right place and they're discovered.

Per-agent scheduling config fields:
- `name` — human-readable display name (mutable, display-only). Default: the agent ID (filename stem).
- `agent` — agent file reference for Copilot CLI `--agent=` flag. Usually matches the `.agent.md` name. **Optional** — omit for prompt-only mode.
- `prompt` — the prompt passed to Copilot CLI for each run. **Required.**
- `schedule` — when to run. Supports `interval`, `daily`, `weekly` types. **Required.**
- `timeout` — maximum runtime before the scheduler terminates the agent process. Default: `10m`.
- `skipOnBattery` — when `true`, skip starting that agent while the device is on battery power. Default: `false`.
- `retryCount` — number of retry attempts after a failed run before giving up for that schedule window. Default: `0`.
- `model` — override the model used for this agent's Copilot CLI invocation (e.g., `"gpt-4o"`, `"claude-sonnet-4"`). When set, the scheduler passes `--model=<value>` to the CLI. When omitted, the agent uses whatever model its `.agent.md` frontmatter specifies (or Copilot's default).
- `denyTools` — array of tool names to block via `--deny-tool` (e.g., `["shell(rm)", "shell(git push)"]`). In agent mode, this is an **additional restriction layer** on top of the agent's `.agent.md` `tools` frontmatter. In prompt-only mode, this is the **only** tool restriction mechanism (since there is no `.agent.md` to scope tools). Default: `[]`.
- `extraCliFlags` — array of additional Copilot CLI flags passed verbatim (e.g., `["--no-ask-user", "--output-format=json"]`). Escape hatch for new CLI features without schema changes. Default: `[]`.
- `envVars` — object of additional environment variables set for the agent's Copilot CLI process (e.g., `{ "COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "./extra" }`). For secrets, reference system environment variables rather than embedding values in config. Default: `{}`.

These are **per-agent scheduler policies**, not Task Scheduler settings. The one OS-level task only bootstraps the CronAgents process at logon.

**Execution modes:**
- **Agent mode:** Config has `agent` + `prompt`. Scheduler invokes `copilot --agent=<name> -p "<prompt>" --silent ...`. The `.agent.md` defines the system prompt, tool scoping, and behavior.
- **Prompt-only mode:** Config has `prompt` but no `agent`. Scheduler invokes `copilot -p "<prompt>" --allow-all-tools --silent ...`. No `.agent.md` needed — useful for simple tasks expressible in a single prompt. `--allow-all-tools` is the default since there's no agent file to scope tools; use `denyTools` to restrict.
- **Script mode** (future): Config has `script` instead of `agent`/`prompt`. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).

The `cronagents-agent.schema.json` enforces these as `oneOf` — a config specifies exactly one of: `agent`+`prompt`, `prompt`-only, or `script`.

**Security: least-privilege tool scoping.** Agents should be configured with the minimum set of tools required for their task. The `.agent.md` `tools` frontmatter is the primary security boundary — it defines what Copilot CLI can access. `denyTools` in the scheduling config adds a second restriction layer at the scheduler level. For prompt-only mode (where no `.agent.md` exists), `denyTools` is the **only** restriction mechanism — users should be advised to specify deny rules for any destructive operations.

#### Per-agent config example

```jsonc
// File: .cronagents/agents/daily-review.json
// Agent ID: "daily-review" (from filename)
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Daily Code Review",
  "agent": "daily-review",
  "prompt": "Review today's changes and summarize",
  "schedule": { "type": "daily", "time": "09:00" },
  "timeout": "10m",
  "skipOnBattery": false,
  "retryCount": 0,
  "model": "claude-sonnet-4",
  "denyTools": ["shell(rm)"],
  "extraCliFlags": ["--no-ask-user"],
  "envVars": {}
}
```

```jsonc
// File: .cronagents/agents/weekly-deps.json
// Agent ID: "weekly-deps" (from filename)
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Weekly Dependency Check",
  "agent": "weekly-deps",
  "prompt": "Check for outdated dependencies and security advisories",
  "schedule": { "type": "weekly", "day": "monday", "time": "10:00" },
  "timeout": "15m",
  "skipOnBattery": true,
  "retryCount": 1
}
```

```jsonc
// File: .cronagents/agents/morning-summary.json
// Agent ID: "morning-summary" (from filename)
// Prompt-only mode — no .agent.md needed
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Morning Summary",
  "prompt": "Summarize all git commits from the last 24 hours. Group by author and highlight breaking changes.",
  "schedule": { "type": "daily", "time": "08:00" },
  "denyTools": ["shell(rm)", "shell(git push)", "shell(git reset)"]
}
```

Per-agent fields `timeout`, `skipOnBattery`, `retryCount`, `model`, `denyTools`, `extraCliFlags`, and `envVars` are all optional with the defaults shown above. Only `prompt` and `schedule` are required. `agent` is required for agent mode, omitted for prompt-only mode.

### Why split config?

The git branch model has master owning global settings and user branches owning agent definitions. A single `cronagents.json` containing both would cause merge conflicts every time master changes a default while the user has agents defined. With the split, master's `cronagents.json` and users' `.cronagents/agents/*.json` files are in completely separate paths — structurally impossible to conflict. The split also enables future features naturally: config profiles (#15) only overlay global settings, remote config (#17) can push agent definitions independently, and agent sharing is just copying a `.json` + `.agent.md` pair.

### Agent resolution model

Simplified, leveraging native Copilot CLI resolution:
- Copilot CLI already resolves agents from `.github/agents/` (project) → `~/.copilot/agents/` (user)
- The scheduler sets `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` per-invocation if the user configures extra instruction directories
- `copilotHome` config key (optional): overrides `COPILOT_HOME` env var to point Copilot CLI at a non-default config/agents root
- scaffold agents (feedback-evaluator, run-summarizer) live in `scheduler/agents/` — the scheduler passes `--add-dir=scheduler/` when invoking them
- user workload agents resolve from `.cronagents/agents/` (via `--add-dir`), `~/.copilot/agents/`, or explicit paths in config
- examples remain committed as templates only

**Step 4** — `cronagents.schema.json` and `cronagents-agent.schema.json` — JSON Schemas for editor autocompletion and config validation. Two schemas: one for global config, one for per-agent scheduling configs.

---

## Phase 3: PowerShell Scheduler

**Step 5** — `lib/ScheduleParser.ps1` — Functions: `Test-AgentDue` and `Get-NextRunTime`, with helpers for interval, daily, and weekly schedules. Reads state via `StateManager.ps1`.

**State management (`lib/StateManager.ps1`):**
- All scheduler state lives in `.cronstate/state.json` — separate from agent definitions.
- The file stores: per-agent last-run timestamps (keyed by **agent ID**, i.e. the filename stem), per-agent enabled/disabled state, global scheduler pause flag, and a `schemaVersion` field for future migrations.
- **Concurrency contract:** All reads and writes go through `Get-AgentState` / `Set-AgentState` which use file-level locking (`[System.IO.FileStream]` with `FileShare.None`) and atomic write-to-temp-then-rename. This prevents races between the scheduler loop, CLI wrapper, and future HTTP API.
- **Recovery:** If `state.json` is unreadable or fails schema validation, `StateManager` resets to empty state and logs a warning. The `schemaVersion` field enables forward-compatible migrations when the state schema evolves.

**Scheduling mechanism:**
- `Start-CronAgents.ps1` is a single long-running scheduler process with one centralized heartbeat. There is **not** a separate Windows Task Scheduler entry, cron daemon job, or timer per agent.
- Day 0 uses a coarse scheduler cadence: wake on a fixed boundary no more than every 30 minutes, or sleep dynamically until the next known due time. Do not wake every minute unless later evidence justifies it.
- On each wake, the scheduler checks all discovered agents against the current time slot and collects the agents that are due.
- Due agents are enqueued once and run sequentially in discovery order.
- If an agent is still running when its next scheduled slot arrives, the scheduler must **not** stack duplicate runs for the same agent. It either coalesces them into one pending run or skips the missed slot, depending on configured policy.
- The scheduler records per-agent state in `.cronstate/state.json` so the same due window is not re-enqueued repeatedly after restarts or repeated checks.
- This makes schedule times advisory due markers: the system guarantees "run when due and capacity allows," not exact launch at the top of the slot.

**Reboot persistence (POC-validated):**
- `Install-CronAgents.ps1` registers a single Windows Task Scheduler entry (`\CronAgents\CronAgents`) that launches `Start-CronAgents.ps1` at user logon via `MSFT_TaskLogonTrigger`.
- No admin/elevation required — runs as the current user at `Limited` run level.
- Settings: `AllowStartIfOnBatteries`, `DontStopIfGoingOnBatteries`, `StartWhenAvailable`, `RestartCount 3` with 5-minute backoff, no execution time limit.
- `Uninstall-CronAgents.ps1` removes the task cleanly.
- This is the **only** OS-level scheduled task. All agent scheduling is handled internally by the scheduler loop.
- POC round-trip verified: `Register-ScheduledTask` → `Get-ScheduledTask` (state: Ready, trigger: `MSFT_TaskLogonTrigger`) → `Unregister-ScheduledTask` → confirmed removed.

**Idempotent install:**
- `Install-CronAgents.ps1` must be safe to run repeatedly. If the expected task already exists with the correct definition, it should succeed silently (no-op). If it exists with a stale definition, it should update in place. It must never create a second task.
- Before registering, the script should check for unexpected tasks under `\CronAgents\` and warn (or refuse) if it finds entries it did not create.
- The task name (`CronAgents`) and task path (`\CronAgents\`) are fixed constants, not user-configurable, to prevent accidental accumulation.

**Step 6** — `Invoke-ScheduledAgent.ps1` — Determines execution mode from the agent's scheduling config:
  - **Agent mode** (`agent` field present): Invokes `copilot --agent=<name> -p "<prompt>" --silent --share=<run-dir>/session.md`
  - **Prompt-only mode** (`agent` field absent): Invokes `copilot -p "<prompt>" --allow-all-tools --silent --share=<run-dir>/session.md`

  Creates run directory `.cronstate/runs/<timestamp>_<agent-id>_<nonce>/` with:
  - `output.md` — captured agent stdout
  - `meta.json` — run metadata (agent ID, display name, start/end time, exit code, prompt, `feedbackProcessed: false`)
  - `summary.md` — LLM-generated summary of this run's output (written by run-summarizer agent after completion)
  - `session.md` — full session transcript (auto-saved by `--share`)
  - `feedback.md` — pre-populated stub template for human feedback (separate from dashboard)
  - `feedback-result.md` — created later by the feedback evaluator after processing

  Run directory naming uses `<ISO-timestamp>_<agent-id>_<nonce>` where the nonce is a short random hex suffix (e.g., `20260322T090000_daily-review_a7f3`). The agent ID portion ensures human readability; the nonce prevents collisions if future parallel execution produces simultaneous completions.

  Uses `--deny-tool` for each entry in the agent's `denyTools` config array. Passes `--model=<value>` when the agent config specifies a model override. Appends any `extraCliFlags` verbatim. Sets any `envVars` as environment variables on the child process. The `copilotPath` config key allows tests to point at a mock.

  Enforces per-agent execution policies defined in Step 3b (`timeout`, `skipOnBattery`, `retryCount`).

**Step 7** — Dashboard generation is split into two stages: **LLM summarization** (per-run, cached) and **deterministic assembly** (per-tick, no LLM).

  **Stage 1 — Run summarization (LLM, once per agent run):** After each agent run completes, the scheduler invokes the **run-summarizer agent** (`scheduler/agents/run-summarizer.agent.md`) to produce a concise summary of that specific run's output. The summarizer reads `output.md` and `meta.json` from the run directory and decides how much detail the run deserves:
  - **Failures** get expanded detail: error context, which tools failed, suggested next steps
  - **Runs where work happened** (non-trivial output, file edits) get a meaningful summary of what changed
  - **No-op runs** collapse to a single line: "✓ no changes"

  The summary is written to `summary.md` in the run directory and is **never regenerated** — it's a cached artifact. This means the LLM cost is exactly one invocation per agent run, not per dashboard refresh. The run-summarizer has `tools: [read]` only — no edit access.

  **Stage 2 — Dashboard assembly (deterministic, no LLM):** `Update-Dashboard.ps1` is a pure script that reads `meta.json` + `summary.md` from recent run directories and assembles `dashboard.md` mechanically. It produces a summary table (agent | last run | status | feedback | detail) plus per-run sections using the cached `summary.md` content. Links directly to `feedback.md` for runs awaiting feedback, and to `feedback-result.md` for processed runs. Dashboard is **read-only** — the user never edits it directly.

  Because the assembly is deterministic, it's fast, free (no tokens), fully testable with snapshot assertions, and produces structured data that the future HTTP API (`GET /api/status`) can reuse directly.

**Step 8** — `Start-CronAgents.ps1` — Main loop. Reads config, validates, applies `startupDelay` (default `5m`) before the first evaluation tick to avoid competing with the post-boot resource storm, then maintains one centralized scheduler heartbeat with coarse wake intervals. The delay logs its countdown so the user knows the scheduler is alive but waiting. Set `startupDelay: "0"` to skip. Each tick follows this order:

  1. **Feedback sweep** — run the feedback evaluator for all pending feedback (non-empty `feedback.md` + `feedbackProcessed: false`). This ensures agent/skill edits from human feedback take effect *before* the next workload runs.
  2. **Quiet hours check** — if `quietHours` is configured and the current time falls within the window, skip all agent evaluation for this tick. Log the skip. Due agents remain due and will be picked up when the window ends.
  3. **Scheduled agents** — check `Test-AgentDue` per agent for the current scheduler window, collect all due agents, enqueue each at most once, then invoke them sequentially from the same loop. After each agent run completes, invoke the **run-summarizer agent** to produce `summary.md` for that run (one LLM call per agent run, cached). If `autoFeedback` is true, also trigger the feedback evaluator immediately after each individual run (for self-review of the run that just happened).
      Before launch, the scheduler applies each agent's execution policies: skip when on battery if configured, enforce timeout, and perform bounded retries on failure.
  4. **Dashboard update** — regenerate `dashboard.md` deterministically (no LLM) from cached `summary.md` + `meta.json` across recent runs.
  5. **Retention cleanup** — once per day, delete run directories older than `retentionDays` (preserving runs with unprocessed feedback regardless of age).

  **Logging:** The scheduler writes structured log entries via a shared `Write-CronAgentsLog` function (in `lib/`), gated on the configured `logLevel`. Each run also captures a per-run log at `.cronstate/runs/<timestamp>_<agent-id>_<nonce>/scheduler.log` with debug-level detail regardless of the global log level — this ensures per-run troubleshooting is always possible. The global scheduler log writes to `.cronstate/scheduler.log` (gitignored, rotated by size).

  This is intentionally one persistent scheduler loop, not one OS-level job per agent. Handles Ctrl+C gracefully.

**Step 8a** — `cronagents.ps1` — CLI wrapper for management actions. Subcommands:
  - `run <agent-id>` — trigger a one-off run outside the schedule
  - `status` — show scheduler state, next run times, pending feedback count
  - `pause` — (no argument) set `schedulerPaused: true` in `.cronstate/state.json` — the scheduler loop continues running but skips all agent evaluation until resumed
  - `pause <agent-id>` — set `enabled: false` for that agent in `state.json` (skipped by scheduler)
  - `resume` — (no argument) clear the global pause
  - `resume <agent-id>` — set `enabled: true` for that agent in `state.json`
  - `list` — list discovered agents with schedule and last run
  - `feedback [agent-id]` — open the most recent unprocessed `feedback.md` in `$EDITOR` / VS Code
  - `evaluate` — manually trigger feedback evaluator for all pending feedback
  - `doctor` — health check: verify exactly one Task Scheduler entry under `\CronAgents\`, config is valid, `.cronstate/state.json` is not corrupted, scheduler process is running, and no orphaned run directories exist
  - `install` — register (or update) the at-logon Task Scheduler entry. Auto-bootstrap the `agents/<username>` branch if it doesn't exist. Idempotent.
  - `uninstall` — remove the Task Scheduler entry cleanly
  - `sync` — manually trigger merge from `master` into user branch. Reports clean merge or conflict status.
  - `branch` — show current branch, commits ahead/behind master, last sync date

  These are convenience wrappers around the same scripts the scheduler calls. No new logic, just ergonomics.

  When invoked with **no subcommand** (`cronagents.ps1`), launch an interactive text menu. The menu is a numbered-option loop that calls the same subcommands above:

  ```
  CronAgents (branch: agents/<user>, N behind master)
  ──────────────────────────
   1) Status & upcoming runs
   2) Trigger ad-hoc run
   3) Pause / Resume
   4) View run history
   5) Submit feedback
   6) Health check (doctor)
   7) Sync from master
   8) Branch info
   9) Exit
  ──────────────────────────
  Select [1-9]:
  ```

  Layered navigation where needed — e.g. option 2 lists agents and lets you pick one, option 3 shows current pause state and offers global vs. per-agent toggle. Each action returns to the main menu after completion. This is day 0 — the menu is the primary management surface until the HTML dashboard is built.

**Step 8b** — `Test-CronAgentsHealth.ps1` — Health-check module invoked by `cronagents.ps1 doctor`. Checks:
  - Exactly one task under `\CronAgents\` in Task Scheduler (warns on zero, errors on >1)
  - Task definition matches expected action/trigger (detects stale installs)
  - `cronagents.json` parses and validates against schema
  - Agent config files in `.cronagents/agents/` parse and validate against agent schema
  - `.cronstate/state.json` is readable and not corrupted
  - Scheduler process is currently running (optional — informational)
  - No orphaned run directories (in `.cronstate/runs/`) that reference agents no longer discovered
  - Reports a pass/warn/fail summary the user can act on

---

## Phase 4: Feedback System

**Step 9** — `feedback-evaluator.agent.md` — Copilot agent with `tools: [read, edit, search]`. Reads feedback from run directories, evaluates it, edits agent/skill/memory files accordingly. Outputs a changelog. Cannot edit scheduler scripts, config schema, or its own definition. This is the one shared agent that ships with the scaffold so every CronAgents setup has the same baseline maintainer behavior.

**Feedback flow (explicit):**
1. Agent runs → scheduler creates run directory with `feedback.md` stub
2. Dashboard regenerates with a link to the run's `feedback.md`
3. User opens `feedback.md` (from dashboard link or `cronagents.ps1 feedback <agent>`), writes plain-language feedback, saves
4. Feedback evaluator scans for run directories where `feedback.md` is non-empty and `meta.json` has `feedbackProcessed: false`
5. Evaluator reads the feedback, makes edits to agent/skill/memory files, writes `feedback-result.md` with a changelog
6. Evaluator sets `feedbackProcessed: true` in `meta.json`
7. Dashboard re-renders to show feedback was processed with a link to the changelog

Feedback is always a **separate file per run**, never part of the dashboard.

**Step 9a** — Feedback-commit hook — after the evaluator edits files and writes `feedback-result.md`, the scheduler commits the changes to the user's `agents/<username>` branch with a structured message (`feedback: <agent-id> — <summary>`). Pre-edit snapshots are written to the run directory's `backup/` folder (in `.cronstate/runs/`) **before** edits are applied, providing immediate rollback regardless of git state. Full design in [AGENT-VERSIONING.md](AGENT-VERSIONING.md).

**Step 10** — `run-feedback.prompt.md` — Invokable as `/run-feedback` to trigger feedback processing for recent runs.

**Step 11** — Auto-feedback mode — when `autoFeedback: true`, the scheduler automatically invokes a secondary Copilot CLI session after each agent run using the feedback-evaluator persona. Results logged to `feedback-result.md` per run.

**Step 12** — Feedback evaluator skill (`SKILL.md`) — bundles evaluation procedures and reference docs for what edits are appropriate.

---

## Phase 5: Documentation & Polish

Documentation is a day-0 deliverable, not an afterthought. Every feature must be documented as it's built — a user who clones this repo should be able to set up, configure, and use CronAgents without reading the source code.

Three tiers, three audiences:
- **`README.md`** (landing page) — concise project overview, feature highlights, and a docs map linking into `guide/`. First impression for anyone who opens the repo.
- **`guide/`** (user-facing) — the docs you read to use the tool. Written for someone who cloned the repo and wants to get up and running without reading source code.
- **`docs/`** (developer/design) — build plan, test specs, architecture decisions, roadmap. Written for contributors and agents building the project.

**Step 13** — `guide/` pages:
- `getting-started.md` — prerequisites, install, configure, first agent, first run
- `configuration.md` — full `cronagents.json` reference (global settings) and per-agent `.json` schedule config reference (every field, type, default, example)
- `cli-reference.md` — all `cronagents.ps1` subcommands, TUI menu, `--help` examples
- `writing-agents.md` — how to create an `.agent.md` + sibling `.json` schedule config, test it manually
- `feedback-system.md` — how the feedback loop works, editing `feedback.md`, auto-feedback
- `branching-and-sync.md` — user branch model, sync commands, conflict resolution
- `troubleshooting.md` — common issues, `cronagents.ps1 doctor`, reading logs

**Step 13a** — `README.md` — project overview, feature bullets, quick-start teaser (link to `guide/getting-started.md`), docs map table linking every `guide/` page, badges, license.

**Step 14** — `.github/copilot-instructions.md` — Workspace instructions for extending the project (core principles, no-duplication rule, project structure, test enforcement).

**Step 14a** — `.github/skills/agent-creator/SKILL.md` — Interactive skill that walks users through creating a new scheduled agent. Interviews the user, reads `guide/writing-agents.md` and `guide/configuration.md` for current structure/options, then scaffolds the `.agent.md` file and sibling `.json` schedule config. This is a development-time Copilot skill, not a runtime component.

**Step 15** — Example agent files (`.example` suffix) — kept as templates under `templates/agents/`. Users copy them into `.cronagents/agents/` or a user-global Copilot directory to activate. Each example includes inline comments explaining every frontmatter field and prompt pattern.

**Step 16** — `docs/LANDSCAPE.md` — market map, competitor assessment, and positioning notes so the project README and roadmap stay grounded in what already exists. Gitignored — development context only, not for distribution.

**Step 17** — Inline help — Every `cronagents.ps1` subcommand supports `--help` with usage, description, and examples. The TUI menu shows context-sensitive hints.

---

## Phase 6: Testing

All tests use **Pester** (ships with PowerShell, zero install). Detailed test plan, fixture descriptions, mock implementation, and coverage goals are in [TESTING.md](TESTING.md).

**Unit tests** (fast, no Copilot CLI needed):
- `ScheduleParser.Tests.ps1` — schedule matching and next-run calculations, including DST edge cases
- `ConfigValidation.Tests.ps1` — valid/invalid config handling, schema self-validation
- `Dashboard.Tests.ps1` — markdown generation from sample run data, snapshot comparison
- `StateManagement.Tests.ps1` — state.json read/write/recovery
- `AgentVersioning.Tests.ps1` — branch detection, username resolution/slugification, divergence calculation, commit message formatting

**Integration tests** (mock Copilot CLI via `copilotPath` config key):
- `InvokeAgent.Tests.ps1` — full invocation flow, verifies exact CLI flags passed
- `FeedbackFlow.Tests.ps1` — feedback lifecycle from stub to evaluator processing
- `CliWrapper.Tests.ps1` — all `cronagents.ps1` subcommands (including `sync`, `branch`, `install`)
- `SchedulerLoop.Tests.ps1` — single-heartbeat behavior, pause/resume, duplicate prevention, startupDelay
- `RetentionCleanup.Tests.ps1` — run directory cleanup respecting `retentionDays` and unprocessed feedback
- `SyncWorkflow.Tests.ps1` — auto-bootstrap, clean merge, conflict merge (agent-assisted + failure), feedback-commit hook, dirty-tree abort
- `BackupRestore.Tests.ps1` — pre-edit snapshot creation, path mirroring, snapshot survival on git failure, retention interaction

**E2E smoke test** (requires real Copilot CLI + auth, excluded from default runs via Pester tag `E2E`):
- `Smoke.Tests.ps1` — one full run + one feedback cycle against real Copilot CLI
- Uses retry mechanism (3 retries with exponential backoff) to handle non-deterministic LLM behavior

Run all tests except E2E: `Invoke-Pester ./tests/ -ExcludeTag 'E2E'`

---

## Verification (manual checklist)

1. Run `Start-CronAgents.ps1` with invalid config → clear validation error
2. `Test-AgentDue` with various schedule types and timestamps (also covered by Pester)
3. `cronagents.ps1 run <agent>` → verify run directory created with all artifacts
4. Open `dashboard.md` after runs → verify table renders with links to runs and feedback
5. Edit a run's `feedback.md`, run `cronagents.ps1 evaluate` → verify `feedback-result.md` written
6. Set `autoFeedback: true`, run an agent → verify auto-feedback applied
7. `cronagents.ps1 pause <agent>` → verify scheduler skips it on next tick
8. `git branch` → on `agents/<username>`, user agents tracked. `git log --oneline -5` → feedback commits visible
9. `cronagents.ps1 sync` → merges master cleanly, scaffold files updated, user agents preserved
10. Run `Invoke-Pester ./tests/` → all tests pass

---

## Copilot CLI Reference

Full details in [COPILOT-CLI.md](COPILOT-CLI.md). Key design implications:

1. `--agent` flag confirmed — agent instructions load from `.agent.md` files natively, no prompt inlining needed
2. `--silent` + `--output-format=json` ideal for parsing run results in PowerShell
3. `--share=PATH` auto-saves session transcripts to the run directory
4. Agent resolution (`.github/agents/` → `~/.copilot/agents/`) already matches our scaffold vs. workload agent split
5. `COPILOT_HOME` / `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` env vars solve the customization root problem natively
6. `--deny-tool` enables constraining the feedback evaluator

---

## Future Considerations

Items beyond day-0 scope are tracked in [FUTURE.md](FUTURE.md) — HTML dashboard, parallel execution, cloud reporting, cross-platform, PR gates, script mode, security review agent, conditional execution, agent tags, edit scope enforcement, notifications, token budgets, pipelines, config profiles, webhook triggers, rate limiting, remote config.
