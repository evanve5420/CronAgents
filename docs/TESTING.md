# Testing — CronAgents

How to run the test suite and what each test file covers. All tests use **Pester** (ships with PowerShell, zero external dependencies).

---

## Running tests

### Default — all tests except E2E

```powershell
./tests/Invoke-Tests.ps1
```

Each `*.Tests.ps1` file runs in its own `pwsh` subprocess for process isolation (up to 8 concurrent workers by default).

### Common options

```powershell
# Limit concurrent workers
./tests/Invoke-Tests.ps1 -MaxWorkers 4

# Run only test files matching a pattern
./tests/Invoke-Tests.ps1 -Filter 'Config*'

# Exclude additional tags
./tests/Invoke-Tests.ps1 -ExcludeTag 'E2E','Slow'

# Run E2E smoke tests only (requires real Copilot CLI + GitHub auth)
Invoke-Pester ./tests/ -Tag 'E2E'

# Run everything (unit + integration + E2E)
Invoke-Pester ./tests/
```

---

## Test infrastructure

| Component | Path | Purpose |
|-----------|------|---------|
| Test runner | `tests/Invoke-Tests.ps1` | Parallel subprocess runner with summary output |
| Test helpers | `tests/TestHelpers.psm1` | Shared setup/teardown utilities, temp environment creation |
| Mock Copilot CLI | `tests/mocks/copilot.ps1` | Deterministic stand-in for real `copilot` binary |
| Fixtures | `tests/fixtures/` | Sample configs, pre-built run directories, agent definitions |

---

## Test suites

### Unit tests

Fast, pure-function tests — no Copilot CLI (real or mock) needed.

| File | What it covers |
|------|---------------|
| `ScheduleParser.Tests.ps1` | Schedule evaluation (`Test-AgentDue`, `Get-NextRunTime`) for interval, daily, and weekly schedules including edge cases like DST transitions |
| `ConfigLoader.Tests.ps1` | Config loading, agent discovery, JSON validation, default values, and schema validation for both global and per-agent configuration |
| `StateManagement.Tests.ps1` | `.cronstate/state.json` read/write/recovery, concurrent access safety, atomic writes, and enabled/disabled toggling |
| `AgentVersioning.Tests.ps1` | Branch detection, username resolution, divergence calculation, and commit message formatting using temp git repos |
| `Update-Dashboard.Tests.ps1` | Dashboard markdown assembly from cached run data — table layout, status indicators, sorting, and retention filtering |

### Integration tests

Use the mock Copilot CLI. The mock's invocation log lets tests verify exact CLI flags passed.

| File | What it covers |
|------|---------------|
| `InvokeAgent.Tests.ps1` | Full agent invocation lifecycle — run directory creation, output capture, metadata, summarization, timeout enforcement, and retry logic |
| `FeedbackFlow.Tests.ps1` | Feedback evaluation lifecycle — detecting pending feedback, processing it, writing results, and auto-feedback triggering |
| `CliWrapper.Tests.ps1` | All `cronagents.ps1` subcommands (`run`, `install`, `uninstall`, `sync`, `status`, `list`, `pause`, `resume`, `feedback`, `evaluate`, `doctor`) and the interactive menu |
| `SchedulerLoop.Tests.ps1` | Single-heartbeat scheduler behavior — startup delay, global/per-agent pause, sequential queuing, deduplication, and skip-on-battery handling |
| `RetentionCleanup.Tests.ps1` | Run directory cleanup — age-based deletion, preservation of runs with unprocessed feedback, and stale state cleanup |
| `SyncWorkflow.Tests.ps1` | Branch bootstrap, clean/conflict merge workflows, feedback-commit hooks, and failure recovery against temp git repos |
| `BackupRestore.Tests.ps1` | Pre-edit snapshot creation, path mirroring, survival across git failures, and retention cleanup interaction |
| `HealthCheck.Tests.ps1` | `cronagents.ps1 doctor` — task registration checks, config validity, and state integrity reporting |

### E2E smoke test

| File | What it covers |
|------|---------------|
| `Smoke.Tests.ps1` | End-to-end with real Copilot CLI — one agent run + one feedback cycle. Tagged `E2E`, excluded from default runs. Uses retry with exponential backoff for LLM transience. |

---

## Test isolation

All tests are isolated from any real CronAgents installation:

- **Task Scheduler** tests use `\CronAgents-Test\` path, never production entries
- **Config and state** operate in temp directories, never the user's real files
- **Run directories** are created under temp paths, never under `~/.cronstate/runs/`
- **Git operations** (versioning tests) use temp repos with `git -C` scoping
- **Cleanup** happens in `AfterAll`/`AfterEach`/`finally` blocks so failures don't leave artifacts
