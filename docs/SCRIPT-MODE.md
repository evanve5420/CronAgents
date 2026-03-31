# Script Mode — Custom Script Execution for CronAgents

## Summary

Extend CronAgents so an "agent" entry in `cronagents.json` can be either a **prompt-mode** invocation (current design: scheduler calls Copilot CLI with a prompt) or a **script-mode** invocation (scheduler runs a user-provided script that handles its own logic). Both modes inherit the same scheduling, timeout, retry, pause, health-check, and logging benefits.

---

## Motivation

### 1. Token-efficient agent pre-work

Some agent tasks require deterministic data gathering before the LLM does anything useful. In prompt mode, the agent spends tokens on tool calls to locate, read, and parse files — work a script can do in milliseconds for free.

**Example — MCP config parity:** A user wants Copilot's MCP server configuration kept in sync across VS Code, VS Code Insiders, and Copilot CLI. The three config files live at known paths but use slightly different formats, and plugin/marketplace references resolve internally to each tool (not portable). A script can:

1. Read `settings.json` from VS Code and VS Code Insiders, extract MCP blocks
2. Read `~/.copilot/config.json` (CLI format)
3. Normalize the three into a comparable structure
4. Pass the diff to `copilot -p "reconcile these MCP configs…" --share=…`

The agent receives a clean, focused prompt with all context pre-assembled. No tool calls wasted on `Get-Content`.

An alternative is giving the agent a custom tool that deterministically fetches all three configs at once. That's viable, but script mode is more general — it covers cases where the pre-work isn't just "fetch files" but involves arbitrary logic, API calls, or multi-step pipelines.

### 2. Scripts that happen to use an agent

Some workflows are scripts first and agents second. The user may already have a PowerShell script they run twice a week that does procedural work and invokes Copilot CLI for one step. CronAgents should be able to schedule that script directly, rather than forcing the user to restructure it as a prompt.

### 3. Scripts with no agent at all

A general-purpose scheduler that already handles wake-up, logging, retry, and health checks is useful even for tasks that never touch Copilot CLI. Script mode makes CronAgents a lightweight cron replacement for Windows users — though Copilot-agent scheduling remains the primary use case.

---

## Proposed Config

Script mode uses the same per-agent `.agent-registration.json` scheduling config files as prompt mode. The discriminator is the presence of `script` instead of `agent`+`prompt`.

```jsonc
// File: .cronagents/agents/daily-review.agent-registration.json (agent mode — existing)
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Daily Code Review",
  "agent": "daily-review",
  "prompt": "Review today's changes and summarize",
  "schedule": { "type": "daily", "time": "09:00" },
  "timeout": "10m"
}
```

```jsonc
// File: .cronagents/agents/mcp-sync.agent-registration.json (script mode)
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "MCP Config Sync",
  "script": "./scripts/sync-mcp-configs.ps1",
  "schedule": { "type": "weekly", "day": "monday", "time": "08:00" },
  "timeout": "15m",
  "retryCount": 1
}
```

```jsonc
// File: .cronagents/agents/weekly-report.agent-registration.json (script mode — no Copilot CLI inside)
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Weekly Report",
  "script": "./scripts/generate-report.ps1",
  "schedule": { "type": "weekly", "day": "friday", "time": "17:00" },
  "timeout": "5m"
}
```

**Discrimination:** A per-agent config specifies exactly one of: `agent`+`prompt` (agent mode), `prompt`-only (prompt-only mode), or `script` (script mode). The `cronagents-agent.schema.json` already enforces the first two modes via `oneOf`; script mode will add a third branch.

---

## Execution Semantics

| Concern | Agent Mode | Prompt-Only Mode | Script Mode |
|---------|-----------|-----------------|-------------|
| What runs | `copilot --agent=NAME -p "PROMPT" …` | `copilot -p "PROMPT" --allow-all-tools …` | User-provided `.ps1` / `.sh` / executable |
| Working directory | Repo root (or personal repo) | Repo root (or personal repo) | Repo root |
| Stdout capture | `output.md` in run directory | `output.md` in run directory | `output.md` in run directory |
| Exit code | Copilot CLI exit code | Copilot CLI exit code | Script exit code |
| `--share` transcript | Auto-saved to `session.md` | Auto-saved to `session.md` | N/A (script manages its own Copilot calls) |
| Timeout | Enforced by scheduler | Enforced by scheduler | Enforced by scheduler |
| Retry | Per `retryCount` | Per `retryCount` | Per `retryCount` |
| `skipOnBattery` | Supported | Supported | Supported |
| Pause/resume | Supported | Supported | Supported |
| `envVars` | Set as process env vars | Set as process env vars | Set as process env vars |
| `notifyOnFailure` | Toast on failure/timeout | Toast on failure/timeout | Toast on failure/timeout |
| Dashboard | Full integration | Full integration | Full integration |
| Feedback | `feedback.md` stub created | `feedback.md` stub created | `feedback.md` stub created |

### Environment variables provided to script-mode invocations

The scheduler sets these for the script's process:

| Variable | Value |
|----------|-------|
| `CRONAGENTS_RUN_DIR` | Absolute path to the run directory (e.g. `.cronstate/runs/20260322T0800_mcp-sync_a7f3/`) |
| `CRONAGENTS_AGENT_NAME` | The `name` from config |
| `CRONAGENTS_CONFIG` | Absolute path to `cronagents.json` |

Scripts can use `CRONAGENTS_RUN_DIR` to write additional artifacts (logs, diffs, reports) that the dashboard and feedback system will pick up.

---

## Security Considerations

- **Script paths must be relative to the repo root or absolute.** The scheduler resolves them and verifies the file exists before execution. No shell expansion or glob evaluation on the path.
- **No implicit shell wrapping.** `.ps1` scripts are invoked via `pwsh -File <path>`, not piped through `Invoke-Expression`. Other executables are invoked directly.
- **Execution policy:** The scheduler does not bypass PowerShell execution policy. If the user's policy blocks unsigned scripts, they must sign them or adjust policy themselves.
- **Same trust boundary as prompt mode.** Script mode doesn't elevate privileges — it runs in the same user context as the scheduler. Users who register a script are responsible for what it does, just as they're responsible for the prompts they write.

---

## Dashboard & Feedback Integration

Script-mode runs produce the same run directory structure as prompt-mode runs:

```
.cronstate/runs/20260322T0800_mcp-sync_a7f3/
├── output.md               ← captured stdout
├── session.md              ← Copilot CLI transcript (agent/prompt modes only)
├── summary.md              ← LLM-generated summary (from run-summarizer agent)
├── summarizer-session.md   ← run-summarizer's own Copilot session transcript
├── meta.json               ← run metadata (includes "mode": "script")
├── feedback.md             ← stub for human feedback
└── feedback-result.md      ← written by evaluator if feedback provided
```

The `meta.json` includes a `mode` field (`"agent"`, `"prompt"`, or `"script"`) so the run-summarizer agent and dashboard assembly can adjust presentation. `session.md` is omitted for script-mode runs since there's no single Copilot session to capture (the script may invoke zero or many Copilot sessions internally). `summarizer-session.md` is present in all modes — the run-summarizer always runs after the primary execution.

---

## Relationship to Prompt Mode

Script mode is **not** a replacement for prompt mode. It's a complementary execution path for cases where:

- Deterministic pre-work saves significant tokens
- An existing script needs scheduling and already handles its own Copilot invocations
- A task doesn't involve Copilot CLI at all but benefits from the scheduling/logging/retry infrastructure

For straightforward "run this prompt on a schedule" use cases, prompt mode remains simpler and preferred.

---

## Open Questions

1. **Should script-mode entries participate in auto-feedback?** The feedback evaluator is designed around Copilot CLI output. For scripts that internally call Copilot, the evaluator could still read `output.md`, but the feedback loop may be less meaningful for pure-script runs.
2. **Script argument passing.** Should config support an `args` array for scripts? Or should scripts read `CRONAGENTS_*` env vars and `cronagents.json` for all configuration?
3. **Cross-platform path handling.** Scripts with `.ps1` extension invoke via `pwsh -File`. What about `.sh` on WSL, `.py`, or bare executables? Day 0 could restrict to `.ps1` only and expand later.
4. **Copilot CLI passthrough for hybrid scripts.** Should the scheduler pass `copilotPath` as an env var so scripts don't need to resolve the Copilot CLI binary themselves?
