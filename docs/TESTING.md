# Testing Plan — CronAgents

Detailed test strategy for the CronAgents scheduler, CLI wrapper, feedback system, and dashboard. All tests use **Pester** (ships with PowerShell, zero install).

Referenced from [PLAN.md](PLAN.md) Phase 6.

---

## Test enforcement

The `copilot-instructions.md` for this repository instructs agents to run all non-E2E tests before committing changes: `Invoke-Pester ./tests/ -ExcludeTag 'E2E'`. The test suite is structured so it can also be wired into PR gates or CI if that's ever desired.

---

## Test infrastructure

### Mock Copilot CLI

A PowerShell script at `tests/mocks/copilot.ps1` that accepts the same flags as the real `copilot` binary. The `copilotPath` config key in `chronagents.json` lets the test harness point at this mock without modifying production code.

The mock should:
- Accept all flags the scheduler passes (agent, prompt, silent, share, allow/deny tool, output format, etc.)
- Write an invocation log (JSONL) so tests can verify exactly which flags were passed and in what order
- Produce predictable, deterministic output for a given agent name
- Write a session file to the `--share` path if that flag was provided
- Support different output formats (text by default, JSON if `--output-format=json`)
- Exit with configurable exit codes so tests can simulate failures

### Fixtures

`tests/fixtures/` should contain:
- Several `chronagents.json` variants: valid minimal, valid full-featured, missing required fields, unknown schedule type, malformed JSON
- Pre-built run directories representing different states: successful run, failed run, run with pending feedback, run with processed feedback, run older than retention threshold
- A trivial `.agent.md` file for testing agent invocation

### Test helper module

`tests/TestHelpers.psm1` — shared utilities for setup and teardown:
- Create a temp test environment with proper directory structure and config pointing at the mock
- Clean up the temp environment after each test
- Parse the mock's invocation log into structured objects for assertion
- Generate a `chronagents.json` pre-configured to use the mock `copilotPath`

---

## Unit tests

These are fast, pure-function tests. No Copilot CLI (real or mock) needed.

### ScheduleParser.Tests.ps1

Test `Test-AgentDue` and `Get-NextRunTime`:

- **Interval schedules**: returns due when enough time has elapsed, not due when interval hasn't passed, and rejects intervals smaller than 30 minutes for day 0
- **Daily schedules**: returns due when past scheduled time with no run today, not due when already run today, due on first run ever, handles midnight rollover
- **Weekly schedules**: due on the correct day and time, not due on wrong day, not due when already run this week
- **Next-run calculation**: `Get-NextRunTime` returns correct next occurrence for interval, daily, and weekly schedules
- **Edge cases**: DST spring-forward, DST fall-back, timezone conversion, and long-running agents whose previous execution extends beyond the next nominal slot

### ConfigValidation.Tests.ps1

Test config loading and validation:

- Valid config loads without errors
- Missing `agents` array produces a specific error naming the field
- Agent with no schedule produces a specific error
- Unknown schedule type rejected with clear message
- Malformed JSON produces a parse error
- Optional fields default correctly (`copilotPath`, `maxRunHistory`, `retentionDays`)
- Per-agent execution policy defaults apply correctly (`timeout: 10m`, `skipOnBattery: false`, `retryCount: 0`, `model: null`)
- Reject invalid per-agent execution policy values (negative `retryCount`, malformed `timeout`, non-boolean `skipOnBattery`)
- `model` field accepts valid model strings and rejects empty strings
- `retentionDays` and `maxRunHistory` validated as positive integers (or 0 for unlimited/disabled)
- `startupDelay` validated: accepts duration strings (`"5m"`, `"0"`, `"10m"`), rejects negative or malformed values
- `versioning` block defaults: missing block defaults to `syncPolicy: "notify"`, `userName: null`, `autoCommitFeedback: true`, `branchPrefix: "agents"`
- `versioning.syncPolicy` rejects unknown values (only `"auto"`, `"notify"`, `"manual"` accepted)
- JSON Schema file validates against the JSON Schema meta-schema

### Dashboard.Tests.ps1

Test `Update-Dashboard.ps1` markdown generation from sample run data:

- Generated table has correct columns: agent, last run, status, feedback, detail
- Links directly to `feedback.md` for runs awaiting feedback
- Links to `feedback-result.md` for processed runs
- Shows "✓ no changes" for no-op runs
- Shows error indicator for failed runs
- Shows "no runs yet" when history is empty
- Sorts by most recent first
- Respects `maxRunHistory` for row count
- Excludes runs older than `retentionDays`

### StateManagement.Tests.ps1

Test `state.json` read/write/recovery:

- Creates `state.json` if it doesn't exist
- Reads existing state correctly
- Updates one agent's timestamp without disturbing others
- Persists enough per-agent scheduler state to avoid duplicate queueing across restarts
- Handles enabled/disabled toggle per agent
- Recovers from corrupted `state.json` (resets to empty state)

### AgentVersioning.Tests.ps1

Test the versioning helper functions in isolation using temp git repos. No Copilot CLI needed.

- **Branch detection**: Given a temp repo with various branch states, verify `Get-CronAgentsBranch` correctly identifies current branch and whether it matches the expected `agents/<user>` pattern
- **Username resolution**: Test priority chain — explicit config → `git config user.name` (with slugification edge cases: spaces, special chars, unicode) → `$env:USERNAME` fallback
- **Divergence calculation**: Given a temp repo where master is N commits ahead, verify `Get-BranchDivergence` returns correct ahead/behind counts
- **Commit message formatting**: Verify feedback commits produce structured messages from changelog input
- **Config defaults**: Verify missing `versioning` block defaults to `notify` / auto-detect / `true` / `agents`

---

## Integration tests

These use the mock Copilot CLI. The mock's invocation log lets tests verify exact flags without parsing process output.

### InvokeAgent.Tests.ps1

Test `Invoke-ScheduledAgent.ps1` end-to-end with the mock:

- Creates run directory with correct naming (`<timestamp>_<agent>`)
- Creates `output.md` with captured agent output
- Creates `meta.json` with agent name, start/end time, exit code, prompt, `feedbackProcessed: false`
- Creates `session.md` via `--share`
- Creates `feedback.md` stub with template content
- Mock invocation log shows correct flags: `--agent`, `--silent`, `--allow-all-tools`
- Passes `--model=<value>` when agent config specifies a model override; omits flag when model is null/unset
- Passes `--deny-tool` when agent config specifies tool restrictions
- Passes `--add-dir` when agent has extra trusted directories
- Enforces per-agent `timeout` and marks timed-out runs clearly in `meta.json`
- Retries failed runs up to `retryCount` additional times and records retry attempts in metadata/logs
- Does not start agents with `skipOnBattery: true` while the system is on battery power
- Handles non-zero exit code gracefully (marks run as failed in `meta.json`)
- Updates `state.json` with new last-run timestamp and any scheduler bookkeeping needed to prevent duplicate queueing

### FeedbackFlow.Tests.ps1

Test the feedback lifecycle with the mock:

- Evaluator finds runs with non-empty `feedback.md` and `feedbackProcessed: false`
- Evaluator skips runs with empty `feedback.md`
- Evaluator skips runs where `feedbackProcessed` is already true
- After processing: `feedback-result.md` exists, `meta.json` shows `feedbackProcessed: true`
- Mock invocation log shows evaluator called with `--agent=feedback-evaluator`
- Auto-feedback: scheduler triggers evaluator after each run when `autoFeedback: true`, does not when false

### CliWrapper.Tests.ps1

Test all `chronagents.ps1` subcommands:

- `run <agent>` invokes `Invoke-ScheduledAgent.ps1` with correct args; rejects unknown agent names
- `install` registers Task Scheduler entry idempotently; bootstraps user branch if absent
- `uninstall` removes Task Scheduler entry cleanly
- `sync` triggers merge from master; reports clean merge or conflict
- `branch` shows current branch name, ahead/behind counts, last sync date
- `pause` (no argument) sets `schedulerPaused: true` in `state.json`
- `pause <agent>` sets `enabled: false` in `state.json`; rejects unknown agents
- `resume` (no argument) clears global pause
- `resume <agent>` sets `enabled: true` in `state.json`
- `status` shows global pause state prominently when active
- `status` lists agents with enabled/disabled state, next scheduled run time, pending feedback count
- `list` shows all configured agents with schedule type, parameters, and next scheduled run
- `status` or run detail surfaces skipped-on-battery, timed-out, and retried outcomes clearly
- `feedback <agent>` identifies the most recent unprocessed `feedback.md`; reports "no pending feedback" when none
- `evaluate` triggers feedback evaluator for all pending feedback; reports "nothing to evaluate" when none
- `doctor` reports pass/warn/fail for task count, config validity, state integrity

**Interactive menu** (no-argument mode):
- Launching `chronagents.ps1` with no subcommand enters the interactive menu
- Each numbered option dispatches to the correct subcommand logic
- Layered menus (e.g. agent selection for ad-hoc run, global vs. per-agent pause) navigate correctly
- Invalid input re-prompts without crashing
- Option 7 / Ctrl+C exits cleanly

### SchedulerLoop.Tests.ps1

Test the single-heartbeat scheduler behavior:

- `startupDelay` is respected: scheduler sleeps for configured duration before first tick; `startupDelay: "0"` skips the wait
- One scheduler tick evaluates all configured agents from the same scheduler wake cycle
- When `schedulerPaused: true`, no agents are evaluated or enqueued regardless of due state
- Per-agent `enabled: false` skips that agent while others still run normally
- Global pause + per-agent pause interact correctly: resuming global pause does not un-pause individually paused agents
- Multiple due agents in the same slot are queued from one tick, not from separate timers
- Agents run sequentially in config order when more than one matches the same slot
- A second check in the same due window does not enqueue the same agent twice
- If an agent is still running when its next slot arrives, the scheduler coalesces or skips the duplicate according to policy rather than stacking another run
- Restarting the scheduler does not duplicate a run when prior due-state bookkeeping is already recorded
- Agents with `skipOnBattery: true` remain due-but-unstarted until AC power returns, or are marked skipped according to policy
- Retries stay inside the same queued work item rather than creating new scheduled entries

### RetentionCleanup.Tests.ps1

Test the run directory cleanup mechanism:

- Deletes run directories older than `retentionDays`
- Preserves run directories within `retentionDays`
- Does NOT delete runs with unprocessed feedback regardless of age
- Removes stale entries from `state.json` for deleted agents
- Defaults to 14 days when `retentionDays` is not configured
- `retentionDays: 0` means never delete

### SyncWorkflow.Tests.ps1

Test full sync and bootstrap workflows against temp git repos with mock Copilot CLI.

- **Auto-bootstrap (no branch exists)**: Init temp repo with only master. Run bootstrap. Verify `agents/<user>` branch created from master HEAD, working tree on new branch.
- **Auto-bootstrap (branch exists)**: Init temp repo with existing `agents/<user>` branch. Run bootstrap. Verify checkout to existing branch, no duplicate branch created.
- **Auto-bootstrap (dirty working tree)**: Init temp repo with uncommitted changes. Run bootstrap. Verify it warns and aborts, no data loss.
- **Clean merge**: Create temp repo. Add commits to master after user branch diverges. Run sync. Verify merge succeeds, user customization files preserved, scaffold files updated.
- **Conflict merge (agent-assisted)**: Create temp repo where master and user branch both edit the same file. Run sync with mock copilot that "resolves" conflicts. Verify merge completes with agent's resolution.
- **Conflict merge (agent fails)**: Same as above but mock copilot leaves conflicts. Verify `git merge --abort` is called, user notified, no corrupted state.
- **Feedback-commit hook**: Edit files as the feedback evaluator would, run the commit hook. Verify correct files staged, commit message formatted from changelog, commit exists in branch history.
- **Feedback-commit failure**: Simulate `git commit` failure (e.g., lock file). Verify files remain edited on disk, failure logged, dashboard notified, pre-edit snapshots still exist.

### BackupRestore.Tests.ps1

Test pre-edit snapshot creation and recovery.

- **Snapshot creation**: Run feedback evaluator mock that edits two files. Verify `backup/` directory in run dir contains exact copies of both files pre-edit.
- **Snapshot path mirroring**: Edit files at nested paths (`.chronagents/agents/nested/deep/agent.md`). Verify backup preserves the relative path structure.
- **Snapshot survives git failure**: Simulate git commit failure after backup. Verify snapshots exist and are readable.
- **Retention cleanup preserves recent backups**: Run retention cleanup. Verify backups in recent run dirs survive, backups in expired (and feedback-processed) run dirs are cleaned up.

### Test isolation for versioning tests

All versioning tests (`AgentVersioning`, `SyncWorkflow`, `BackupRestore`) create **temp git repos** (`New-TemporaryFile` → `git init`) and clean up in `AfterAll`/`finally`. They never touch the real CronAgents repo, the user's global git config, or any real branches. The tests use `GIT_DIR` / `GIT_WORK_TREE` env vars or `git -C <path>` to scope all git operations to the temp directory.

---

## E2E smoke test

### Smoke.Tests.ps1

Requires real Copilot CLI + GitHub auth. Tagged with Pester tag `E2E` so it's excluded from default runs.

**Retry mechanism**: Copilot CLI is backed by LLM inference — responses vary, tool calls can fail transiently, rate limits can cause timeouts. E2E tests should:
- Retry up to 3 times for agent runs, 2 times for feedback processing
- Use increasing delay between retries (exponential backoff)
- Only fail after all retries exhausted
- Log each attempt's failure reason

This does NOT apply to unit or integration tests — those use the deterministic mock.

**Test cases**:
- Set up a temp directory with minimal config and a trivial test agent
- Run `Invoke-ScheduledAgent.ps1` once against real Copilot CLI, verify output artifacts exist and are non-empty
- Write feedback to the run's `feedback.md`, trigger evaluator, verify `feedback-result.md` written and `feedbackProcessed` set to true
- Clean up temp directory

---

## Test isolation policy

Tests must never interfere with a real CronAgents installation running on the same machine.

- **Task Scheduler**: Tests that touch Task Scheduler must use a distinct task path (`\CronAgents-Test\`) and a distinct task name (`CronAgents-Test`), never the production `\CronAgents\CronAgents` entry. Teardown must always unregister test tasks, even on failure (use `try/finally`).
- **Config and state**: All tests operate in a temp directory with their own `chronagents.json` and `state.json`. They must never read or write the user's real config or state files.
- **Run directories**: Tests create run output under the temp directory, never under the user's real `.chronagents/runs/`.
- **Cleanup**: Every test that creates OS-level side effects (tasks, temp dirs, processes) must clean up in a `finally` block or Pester `AfterAll`/`AfterEach` so failures don't leave artifacts behind.

### HealthCheck.Tests.ps1

Test `Test-CronAgentsHealth.ps1` / `chronagents.ps1 doctor`:

- Reports pass when exactly one task exists under `\CronAgents-Test\` with correct definition
- Reports warning when zero tasks exist (not installed)
- Reports error when more than one task exists (accumulation bug)
- Reports error when task definition doesn't match expected action/trigger
- Reports pass for valid config+state, error for corrupted `state.json`, error for invalid config
- All tests use the `\CronAgents-Test\` task path and clean up after themselves

---

## Running tests

- **Default (all except E2E)**: `Invoke-Pester ./tests/ -ExcludeTag 'E2E'`
- **E2E only**: `Invoke-Pester ./tests/ -Tag 'E2E'`
- **All**: `Invoke-Pester ./tests/`

---

## Coverage goals

- Every public function has at least one positive and one negative test case
- Every `chronagents.ps1` subcommand is exercised
- Every run directory artifact is verified in at least one integration test
- Mock invocation log is checked in every integration test to verify exact CLI flags
- E2E is a smoke test only — one run + one feedback cycle is sufficient
