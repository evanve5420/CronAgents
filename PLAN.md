# Plan: CronAgents — Scheduled Copilot Agent Scaffolding

A reusable scaffolding that runs Copilot CLI agents on configurable schedules, reports results via a live dashboard markdown file, collects human feedback, and includes a self-improving feedback agent that edits agent/skill/memory files. PowerShell scheduler, JSON config, Copilot CLI invocation.

**Positioning:** This is not an empty market, but the nearby projects cluster into different shapes. Ralph-family projects focus on loop-until-complete autonomous coding. AgentUse and LangChain Runner support scheduled or triggered agents, but they are generic runtimes rather than Copilot-first repo scaffolds. OpenClaw, NanoClaw, Khoj, and Dorabot are assistant platforms where scheduling is one feature among many. CronAgents is positioned as a lightweight, repo-local, Copilot-customization-native scheduler with markdown dashboarding and a first-class human feedback loop.

**High-level differentiation:**
- Copilot-first, using repo customization primitives like `.agent.md`, `SKILL.md`, prompts, and workspace instructions
- Windows-first, PowerShell-first, and intentionally lightweight
- Repo-embedded rather than a global assistant platform or GUI workstation
- Centered on scheduled runs plus feedback-driven self-maintenance, not just task execution

**Customization location strategy:** Separate scaffold runtime from repo development from workload agents. `.github` holds only Copilot customizations for developing this repo (workspace instructions, prompts). Scaffold-internal agents (feedback evaluator, dashboard summarizer) live in `scheduler/agents/` as committed product components. User-defined scheduled workload agents live in gitignored repo-local directories or user-global Copilot directories.

---

## Phase 1: Project Foundation

**Step 1** — Create the directory layout:

```
CronAgents/
├── .github/
│   ├── copilot-instructions.md               ← workspace instructions for repo development
│   └── prompts/
│       └── run-feedback.prompt.md
├── templates/
│   └── agents/
│       ├── daily-review.agent.md.example
│       └── weekly-deps.agent.md.example
├── scheduler/
│   ├── Start-CronAgents.ps1                  ← main entry point
│   ├── Invoke-ScheduledAgent.ps1             ← runs one agent via Copilot CLI
│   ├── Update-Dashboard.ps1                  ← regenerates dashboard.md
│   ├── agents/                               ← scaffold-internal agents (committed)
│   │   ├── feedback-evaluator.agent.md
│   │   └── dashboard-summarizer.agent.md
│   ├── skills/
│   │   └── feedback-evaluator/
│   │       └── SKILL.md
│   └── lib/
│       └── ScheduleParser.ps1                ← schedule matching logic
├── chronagents.ps1                           ← CLI wrapper (run, status, pause, resume, feedback)
├── chronagents.json                          ← user config
├── chronagents.schema.json                   ← JSON Schema for validation + autocomplete
├── dashboard.md                              ← live at-a-glance results (read-only)
├── .chronagents/
│   ├── agents/                               ← optional repo-local ignored workload agents
│   ├── state.json                            ← last-run timestamps + agent enabled/disabled
│   └── runs/                                 ← per-run detailed output
│       └── <timestamp>_<agent>/
│           ├── output.md                     ← captured agent output
│           ├── meta.json                     ← run metadata + feedbackProcessed flag
│           ├── session.md                    ← full session transcript (--share)
│           ├── feedback.md                   ← human feedback file (user edits this)
│           └── feedback-result.md            ← evaluator's changelog (written by evaluator)
├── tests/
│   ├── ScheduleParser.Tests.ps1
│   ├── ConfigValidation.Tests.ps1
│   ├── InvokeAgent.Tests.ps1
│   ├── Dashboard.Tests.ps1
│   ├── FeedbackFlow.Tests.ps1
│   ├── CliWrapper.Tests.ps1
│   ├── RetentionCleanup.Tests.ps1
│   ├── Smoke.Tests.ps1                       ← E2E (requires real Copilot CLI)
│   ├── TestHelpers.psm1                      ← shared setup/teardown
│   ├── fixtures/                             ← sample configs, run data, feedback files
│   └── mocks/
│       └── copilot.ps1                       ← mock Copilot CLI for testing
├── .gitignore
├── README.md
└── LICENSE
```

`.github` is reserved for Copilot customizations that apply when *developing this repo* (workspace instructions, prompts). Scaffold-internal agents (feedback evaluator, dashboard summarizer) and their skills live in `scheduler/agents/` and `scheduler/skills/` because they are product components of the CronAgents runtime, not repo development tools. The scheduler passes `--add-dir=scheduler/` when invoking them so Copilot CLI can resolve them. User-defined scheduled workload agents live in `.chronagents/agents/` (gitignored), user-global directories like `C:\Users\<user>\.copilot`, or both.

**Step 2** — `.gitignore` should ignore runtime data (`.chronagents/runs/`, `state.json`) on all branches. User workload agent definitions under `.chronagents/agents/` are **tracked on user branches** (`agents/<username>`) but not on `master`. Scaffold-internal agents under `scheduler/agents/` are committed on `master`. Examples and templates remain committed on `master`. The per-user branch model, sync policies, auto-bootstrap, and pre-edit snapshot design are detailed in [AGENT-VERSIONING.md](AGENT-VERSIONING.md).

---

## Phase 2: Configuration System

**Step 3** — `chronagents.json` config — defines agents, their schedules, prompts, and settings. Day 0 should support coarse-grained recurring schedules only, with **1 hour as the recommended default** and **30 minutes as the finest supported interval**.
  - `{ "type": "interval", "every": "1h" }`
  - `{ "type": "interval", "every": "4h" }`
  - `{ "type": "daily", "time": "09:00" }`
  - `{ "type": "weekly", "day": "monday", "time": "10:00" }`

If cron syntax is added, it should be treated as a normalized internal representation, not as a promise of arbitrary minute-level scheduling. Day 0 policy is deliberately coarse because the scheduler runs agents sequentially and most real agent runs will take longer than a minute.

Settings include `autoFeedback` toggle, `maxRunHistory`, `copilotPath` (defaults to `copilot`), `retentionDays` (default 14 — run directories older than this are deleted; set to 0 to disable), and optional overrides for Copilot CLI environment.

Each agent should also support scheduler-execution policies:
- `timeout` — maximum runtime before the scheduler terminates the agent process. Default: `10m`.
- `skipOnBattery` — when `true`, skip starting that agent while the device is on battery power. Default: `false`.
- `retryCount` — number of retry attempts after a failed run before giving up for that schedule window. Default: `0`.

These are **per-agent scheduler policies**, not Task Scheduler settings. The one OS-level task only bootstraps the CronAgents process at logon.

Resolution model (simplified, leverages native Copilot CLI resolution):
- Copilot CLI already resolves agents from `.github/agents/` (project) → `~/.copilot/agents/` (user)
- The scheduler sets `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` per-invocation if the user configures extra instruction directories
- `copilotHome` config key (optional): overrides `COPILOT_HOME` env var to point Copilot CLI at a non-default config/agents root
- scaffold agents (feedback-evaluator, dashboard-summarizer) live in `scheduler/agents/` — the scheduler passes `--add-dir=scheduler/` when invoking them
- user workload agents resolve from `.chronagents/agents/` (via `--add-dir`), `~/.copilot/agents/`, or explicit paths in config
- examples remain committed as templates only

**Step 4** — `chronagents.schema.json` — JSON Schema for editor autocompletion and config validation.

---

## Phase 3: PowerShell Scheduler

**Step 5** — `lib/ScheduleParser.ps1` — Functions: `Test-AgentDue` and `Get-NextRunTime`, with helpers for interval, daily, and weekly schedules. Reads/writes `.chronagents/state.json`.

**Scheduling mechanism:**
- `Start-CronAgents.ps1` is a single long-running scheduler process with one centralized heartbeat. There is **not** a separate Windows Task Scheduler entry, cron daemon job, or timer per agent.
- Day 0 uses a coarse scheduler cadence: wake on a fixed boundary no more than every 30 minutes, or sleep dynamically until the next known due time. Do not wake every minute unless later evidence justifies it.
- On each wake, the scheduler checks all configured agents against the current time slot and collects the agents that are due.
- Due agents are enqueued once and run sequentially in config order.
- If an agent is still running when its next scheduled slot arrives, the scheduler must **not** stack duplicate runs for the same agent. It either coalesces them into one pending run or skips the missed slot, depending on configured policy.
- The scheduler records per-agent state in `.chronagents/state.json` so the same due window is not re-enqueued repeatedly after restarts or repeated checks.
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

**Step 6** — `Invoke-ScheduledAgent.ps1` — Invokes `copilot --agent=<name> -p "<prompt>" --allow-all-tools --silent --share=<run-dir>/session.md`, captures output, creates run directory `.chronagents/runs/<timestamp>_<agent-name>/` with:
  - `output.md` — captured agent stdout
  - `meta.json` — run metadata (agent name, start/end time, exit code, prompt, `feedbackProcessed: false`)
  - `session.md` — full session transcript (auto-saved by `--share`)
  - `feedback.md` — pre-populated stub template for human feedback (separate from dashboard)
  - `feedback-result.md` — created later by the feedback evaluator after processing

  Uses `--deny-tool` when the agent config specifies tool restrictions. The `copilotPath` config key allows tests to point at a mock.

  Execution policy handling:
  - Enforce per-agent `timeout` by terminating the Copilot CLI process if runtime exceeds the configured budget. Default is `10m`.
  - Respect `skipOnBattery: true` before launch by checking device power state and recording the run as skipped rather than started.
  - Respect `retryCount` on failure by retrying the same scheduled run up to `N` additional times with simple backoff, without creating duplicate scheduled entries for the same window.

**Step 7** — `Update-Dashboard.ps1` — Regenerates `dashboard.md` after each tick. The script collects run metadata (`meta.json`, exit codes, output size, feedback state) and invokes a **dashboard-summarizer agent** via Copilot CLI to produce the markdown. The agent decides how much space each run deserves:
  - **Failures** get expanded detail: error context, which tools failed, suggested next steps
  - **Runs where work happened** (non-trivial output, file edits) get a meaningful summary of what changed
  - **No-op runs** collapse to a single line: "✓ no changes"

  The agent writes structured markdown with a summary table (agent | last run | status | feedback | detail) plus per-run narrative sections scaled by importance. Links directly to `feedback.md` for runs awaiting feedback, and to `feedback-result.md` for processed runs. Dashboard is **read-only** — the user never edits it directly.

  The dashboard-summarizer agent lives in `scheduler/agents/dashboard-summarizer.agent.md` and ships with the scaffold alongside the feedback evaluator. It has `tools: [read]` only — no edit access.

**Step 8** — `Start-CronAgents.ps1` — Main loop. Reads config, validates, and maintains one centralized scheduler heartbeat with coarse wake intervals. Each tick follows this order:

  1. **Feedback sweep** — run the feedback evaluator for all pending feedback (non-empty `feedback.md` + `feedbackProcessed: false`). This ensures agent/skill edits from human feedback take effect *before* the next workload runs.
  2. **Scheduled agents** — check `Test-AgentDue` per agent for the current scheduler window, collect all due agents, enqueue each at most once, then invoke them sequentially from the same loop. If `autoFeedback` is true, also trigger the feedback evaluator immediately after each individual run (for self-review of the run that just happened).
      Before launch, the scheduler applies each agent's execution policies: skip when on battery if configured, enforce timeout, and perform bounded retries on failure.
  3. **Dashboard update** — regenerate `dashboard.md` reflecting all changes from this tick.
  4. **Retention cleanup** — once per day, delete run directories older than `retentionDays` (preserving runs with unprocessed feedback regardless of age).

  This is intentionally one persistent scheduler loop, not one OS-level job per agent. Handles Ctrl+C gracefully.

**Step 8a** — `chronagents.ps1` — CLI wrapper for management actions. Subcommands:
  - `run <agent>` — trigger a one-off run outside the schedule
  - `status` — show scheduler state, next run times, pending feedback count
  - `pause` — (no argument) set `schedulerPaused: true` in `state.json` — the scheduler loop continues running but skips all agent evaluation until resumed
  - `pause <agent>` — set `enabled: false` for that agent in `state.json` (skipped by scheduler)
  - `resume` — (no argument) clear the global pause
  - `resume <agent>` — set `enabled: true` for that agent in `state.json`
  - `list` — list configured agents with schedule and last run
  - `feedback [agent]` — open the most recent unprocessed `feedback.md` in `$EDITOR` / VS Code
  - `evaluate` — manually trigger feedback evaluator for all pending feedback
  - `doctor` — health check: verify exactly one Task Scheduler entry under `\CronAgents\`, config is valid, `state.json` is not corrupted, scheduler process is running, and no orphaned run directories exist

  These are convenience wrappers around the same scripts the scheduler calls. No new logic, just ergonomics.

  When invoked with **no subcommand** (`chronagents.ps1`), launch an interactive text menu. The menu is a numbered-option loop that calls the same subcommands above:

  ```
  CronAgents
  ──────────────────────────
   1) Status & upcoming runs
   2) Trigger ad-hoc run
   3) Pause / Resume
   4) View run history
   5) Submit feedback
   6) Health check (doctor)
   7) Exit
  ──────────────────────────
  Select [1-7]:
  ```

  Layered navigation where needed — e.g. option 2 lists agents and lets you pick one, option 3 shows current pause state and offers global vs. per-agent toggle. Each action returns to the main menu after completion. This is day 0 — the menu is the primary management surface until the HTML dashboard is built.

**Step 8b** — `Test-CronAgentsHealth.ps1` — Health-check module invoked by `chronagents.ps1 doctor`. Checks:
  - Exactly one task under `\CronAgents\` in Task Scheduler (warns on zero, errors on >1)
  - Task definition matches expected action/trigger (detects stale installs)
  - `chronagents.json` parses and validates against schema
  - `state.json` is readable and not corrupted
  - Scheduler process is currently running (optional — informational)
  - No orphaned run directories that reference agents no longer in config
  - Reports a pass/warn/fail summary the user can act on

---

## Phase 4: Feedback System

**Step 9** — `feedback-evaluator.agent.md` — Copilot agent with `tools: [read, edit, search]`. Reads feedback from run directories, evaluates it, edits agent/skill/memory files accordingly. Outputs a changelog. Cannot edit scheduler scripts, config schema, or its own definition. This is the one shared agent that ships with the scaffold so every CronAgents setup has the same baseline maintainer behavior.

**Feedback flow (explicit):**
1. Agent runs → scheduler creates run directory with `feedback.md` stub
2. Dashboard regenerates with a link to the run's `feedback.md`
3. User opens `feedback.md` (from dashboard link or `chronagents.ps1 feedback <agent>`), writes plain-language feedback, saves
4. Feedback evaluator scans for run directories where `feedback.md` is non-empty and `meta.json` has `feedbackProcessed: false`
5. Evaluator reads the feedback, makes edits to agent/skill/memory files, writes `feedback-result.md` with a changelog
6. Evaluator sets `feedbackProcessed: true` in `meta.json`
7. Dashboard re-renders to show feedback was processed with a link to the changelog

Feedback is always a **separate file per run**, never part of the dashboard.

**Step 9a** — Feedback-commit hook — after the evaluator edits files and writes `feedback-result.md`, the scheduler commits the changes to the user's `agents/<username>` branch with a structured message (`feedback: <agent-name> — <summary>`). Pre-edit snapshots are written to the run directory's `backup/` folder **before** edits are applied, providing immediate rollback regardless of git state. Full design in [AGENT-VERSIONING.md](AGENT-VERSIONING.md).

**Step 10** — `run-feedback.prompt.md` — Invokable as `/run-feedback` to trigger feedback processing for recent runs.

**Step 11** — Auto-feedback mode — when `autoFeedback: true`, the scheduler automatically invokes a secondary Copilot CLI session after each agent run using the feedback-evaluator persona. Results logged to `feedback-result.md` per run.

**Step 12** — Feedback evaluator skill (`SKILL.md`) — bundles evaluation procedures and reference docs for what edits are appropriate.

---

## Phase 5: Documentation & Polish

**Step 13** — `README.md` — Quickstart, how to create agents, config reference, feedback system explanation.

**Step 14** — `copilot-instructions.md` — Workspace instructions for extending the project.

**Step 15** — Example agent files (`.example` suffix) — kept as templates under `templates/agents/`. Users copy them into `.chronagents/agents/` or a user-global Copilot directory to activate.

**Step 16** — `LANDSCAPE.md` — market map, competitor assessment, and positioning notes so the project README and roadmap stay grounded in what already exists.

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
- `CliWrapper.Tests.ps1` — all `chronagents.ps1` subcommands
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
3. `chronagents.ps1 run <agent>` → verify run directory created with all artifacts
4. Open `dashboard.md` after runs → verify table renders with links to runs and feedback
5. Edit a run's `feedback.md`, run `chronagents.ps1 evaluate` → verify `feedback-result.md` written
6. Set `autoFeedback: true`, run an agent → verify auto-feedback applied
7. `chronagents.ps1 pause <agent>` → verify scheduler skips it on next tick
8. `git branch` → on `agents/<username>`, user agents tracked. `git log --oneline -5` → feedback commits visible
9. `chronagents.ps1 sync` → merges master cleanly, scaffold files updated, user agents preserved
9. Run `Invoke-Pester ./tests/` → all tests pass

---

## Decisions

- **Single PowerShell scheduler heartbeat** with coarse wake intervals, not separate Windows Task Scheduler jobs per agent — simpler, self-contained
- **Reboot persistence** via one at-logon Task Scheduler entry (`Install-CronAgents.ps1`). No admin required. Idempotent — safe to run repeatedly, never stacks tasks. Clean uninstall via `Uninstall-CronAgents.ps1`
- **Health check** via `chronagents.ps1 doctor` — verifies single bootstrap task, valid config, clean state, running process
- **Copilot CLI only** (`copilot --agent=NAME -p "PROMPT" --allow-all-tools -s`). Multi-runner is future work
- **Coarse schedule granularity** for day 0: 1 hour recommended, 30 minutes minimum. One centralized matcher loop, not per-agent cron jobs
- **Per-agent execution policies**: `timeout` default `10m`, `skipOnBattery` default `false`, `retryCount` default `0`
- **Agent versioning**: per-user long-running branches (`agents/<username>`) track user agent customizations with full git history. Scaffold code stays on `master`; user branches are supersets. Feedback evaluator edits are auto-committed. Scaffold updates merge from master via configurable sync policy (`notify` default, `auto`, `manual`). Pre-edit snapshots in run directories provide immediate rollback. Full design in [AGENT-VERSIONING.md](AGENT-VERSIONING.md)
- **Agent ownership**: the feedback evaluator is the one shared scaffold agent. User-defined scheduled agents live on their `agents/<username>` branch (repo-local) or in user-global directories
- **Dashboard**: single tracked markdown file the user keeps open in VS Code — read-only, never edited by user
- **Feedback**: separate `feedback.md` per run directory — the user's edit surface, not the dashboard
- **Management UI**: PowerShell CLI wrapper (`chronagents.ps1`) for management actions. Interactive HTML dashboard is a future phase — requirements captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md)
- **Testing**: Pester tests with mock Copilot CLI, E2E with retry mechanism. Detailed plan in [TESTING.md](TESTING.md)
- **Test enforcement**: `copilot-instructions.md` instructs agents to run `Invoke-Pester ./tests/ -ExcludeTag 'E2E'` before committing. PR gates are a future option — the test suite is already structured for CI.
- **Positioning**: compete as a Copilot-native repo scaffold, not as a general agent runtime, assistant platform, or workstation product
- **Customization locations**: `.github` is for repo development customizations only (workspace instructions, prompts). Scaffold-internal agents live in `scheduler/agents/`. User workload agents live in `.chronagents/agents/` or user-global directories

---

## Copilot CLI Reference (verified March 2026)

The old `gh copilot` extension was retired October 2025. The replacement is the standalone **GitHub Copilot CLI** (`github/copilot-cli`), installed via `winget install GitHub.Copilot` on Windows.

### Programmatic invocation (how the scheduler calls agents)

```
copilot --agent=<name> -p "<prompt>" --allow-all-tools --silent --share=<path>
```

Key flags used by CronAgents:

| Flag | Purpose |
|------|---------|
| `-p` / `--prompt` | Run one prompt then exit |
| `--agent=NAME` | Use a specific custom agent (`.agent.md` file) |
| `--allow-all-tools` | Auto-approve all tool use for unattended runs |
| `--deny-tool=TOOL` | Block specific tools (e.g. `shell(rm)`) |
| `-s` / `--silent` | Output only agent response, no stats |
| `--share=PATH` | Save full session transcript to file |
| `--output-format=json` | JSONL output for machine parsing |
| `--add-dir=PATH` | Add trusted directory for file access |
| `--no-ask-user` | Prevent agent from prompting for input |

### Custom agent file format

Agent profiles are `.agent.md` files with YAML frontmatter. Key fields: `name`, `description`, `tools` (list), `model`, `infer` (bool). Markdown body contains the agent prompt.

### File locations (Copilot CLI native resolution)

| What | Project-level | User-level |
|------|--------------|------------|
| Agents | `.github/agents/` | `~/.copilot/agents/` |
| Skills | `.github/skills/` | `~/.copilot/skills/` |
| Instructions | `.github/copilot-instructions.md` | `~/.copilot/copilot-instructions.md` |
| Config | `.github/copilot/settings.json` | `~/.copilot/config.json` |

Project-level overrides user-level on name collisions. `COPILOT_HOME` env var overrides the user config directory. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` adds extra instruction search paths.

### Impact on CronAgents design

1. `--agent` flag confirmed — agent instructions load from `.agent.md` files natively, no prompt inlining needed
2. `--silent` + `--output-format=json` ideal for parsing run results in PowerShell
3. `--share=PATH` auto-saves session transcripts to the run directory
4. Agent resolution (`.github/agents/` → `~/.copilot/agents/`) already matches our scaffold vs. workload agent split
5. `COPILOT_HOME` / `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` env vars solve the customization root problem natively
6. `--deny-tool` enables constraining the feedback evaluator

Full CLI command reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference

---

## Future Considerations

1. **HTML dashboard** — Requirements captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md). Only worth doing after the CLI wrapper proves the command set.
2. **Parallel execution & agent dependencies** — Currently agents run sequentially in config array order (the user controls execution order by arranging the `agents` array). A future version could add parallel execution for independent agents plus a `dependsOn: ["other-agent"]` config to express ordering constraints, with the scheduler building a dependency graph and running independent branches concurrently. Parallelism would make 30-minute schedules more attractive, but it adds complexity: Copilot CLI rate limits, concurrent `state.json` access, output interleaving, and topological sort. Not worth it until someone has enough agents to feel the sequential bottleneck.
4. **Cloud reporting** — local markdown now, but `Update-Dashboard.ps1` is designed to be extensible to webhooks/Slack/Teams.
5. **Cross-platform** — PowerShell Core runs on macOS/Linux, but initial target is Windows only.
6. **PR gate enforcement** — The test suite is already structured for CI (`Invoke-Pester ./tests/ -ExcludeTag 'E2E'`). A future GitHub Actions workflow can run this as a required status check on PRs. Currently enforced via `copilot-instructions.md` only.
7. **Script mode execution** — Allow agent entries to specify a `script` path instead of `agent`+`prompt`, so the scheduler runs a user-provided script (which may invoke Copilot CLI internally, or not at all). Covers token-efficient pre-work patterns, existing workflow automation, and general-purpose scheduling. Same timeout/retry/pause/logging benefits as prompt mode. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).
8. **Security review agent** — A scaffold-internal agent that reviews recent diffs to agent definitions, skills, config, and feedback for harmful patterns. Runs after the feedback-commit hook but before the next scheduled agents execute, so poisoned edits are caught before they take effect. Would watch for: prompt injection in agent definitions, unexpected tool additions/`--deny-tool` removals, feedback content attempting to manipulate the evaluator, and anomalous output patterns suggesting data exfiltration. Flagged issues auto-pause the affected agent and notify via dashboard/TUI. The infrastructure for this already exists: git branch diffs from agent versioning, pre-edit snapshots, and feedback-result.md changelogs provide structured input. Attack pattern knowledge would accumulate in a dedicated skill file (`scheduler/skills/security-reviewer/SKILL.md`) that can be community-contributed.
