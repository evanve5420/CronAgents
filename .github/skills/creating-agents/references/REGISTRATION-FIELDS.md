# Registration Fields Reference

All fields for `.agent-registration.json` files. Schema: `cronagents-agent.schema.json`.

## Required fields

### `prompt` (string, min 1 char)

The prompt sent to Copilot CLI. In agent mode, supplements the system prompt. In prompt-only mode, this is the entire instruction.

### `schedule` (object) — optional

When the agent runs. Omit entirely for manual (ad-hoc) agents that are only triggered via `cronagents.ps1 run` or the dashboard. One of three types:

```json
{ "type": "interval", "every": "2h" }       // min 30m, pattern: ^[0-9]+(h|m)$
{ "type": "daily", "time": "09:00" }        // HH:MM 24h
{ "type": "weekly", "day": "monday", "time": "08:00" }  // lowercase day name
```

### `agent` (string) — agent mode only

References the `.agent.md` profile name (without extension). Must match a profile in `.github/agents/` or `~/.copilot/agents/`. Omit entirely for prompt-only mode.

## Optional fields

### `name` (string)

Display name for the dashboard. Falls back to agent ID (filename stem) if omitted.

### `runIf` (string or object)

Execution condition checked after the schedule says the agent is due. See [RUNIF.md](RUNIF.md).

### `timeout` (string, default `"10m"`)

Max run duration. Pattern: `^[0-9]+(m|h|s)?$` or `"0"` (no timeout).

### `skipOnBattery` (boolean, default `false`)

Skip when the machine is on battery power.

### `retryCount` (integer, default `0`, min `0`)

Number of retries on failure. Each retry is a full re-invocation.

### `model` (string or null)

Override Copilot CLI model. `null` uses the CLI default.

```json
"model": "claude-sonnet-4"
```

### `denyTools` (array of string, default `[]`)

Tools to deny. Most useful in prompt-only mode (which gets `--allow-all-tools`). Use bare names to deny an entire tool (`"edit"`), or parenthesized patterns to deny specific commands (`"shell(rm)"`, `"shell(git push)"`).

```json
"denyTools": ["edit", "shell(rm)", "shell(git push)"]
```

### `extraCliFlags` (array of string, default `[]`)

Additional flags passed to the Copilot CLI invocation.

### `workingDirectory` (string or null)

Override the working directory and scope for this agent. When set, the scheduler grants access to that directory plus the personal repo and infra repo with `--add-dir`. When `null`, the scheduler runs from the personal repo root if available, otherwise the infra repo root, with `--allow-all`. In all unattended runs, CronAgents also passes `--allow-all-tools`.

### `envVars` (object, default `{}`)

Environment variables set for the agent process. String keys and values.

```json
"envVars": { "NODE_ENV": "production" }
```

### `notifyOnFailure` (boolean, default `false`)

Show a Windows toast notification when the agent fails or times out. Requires the global `notifications` setting to be `true` in `cronagents.json`.

### `notifyOnSuccess` (boolean, default `false`)

Show a Windows toast notification when the agent completes successfully. Requires the global `notifications` setting to be `true` in `cronagents.json`.

### `raiseAttention` (string, default `"all"`)

Controls when the run-summarizer flags a run as needing attention in the dashboard banner. One of:

- `"all"` — Flag on failures, actionable results, significant changes, and timeouts. (Default — backwards-compatible behavior.)
- `"significant-changes"` — Flag on failures, codebase/PR changes, and timeouts, but **not** routine monitoring results.
- `"failures-only"` — Only flag on non-zero exit codes and timeouts.
- `"never"` — Never flag attention. Results are visible in the dashboard but won't trigger the banner.

Use `"failures-only"` or `"significant-changes"` for monitoring agents that routinely find actionable items (e.g., a PR watcher that always has open PRs). This prevents a permanent attention banner while still surfacing failures.

```json
"raiseAttention": "failures-only"
```

### `notificationSound` (string, optional)

Override the Windows toast notification sound for this agent. Applies to both success and failure toasts. Only takes effect when `notifyOnFailure` or `notifyOnSuccess` is enabled and global `notifications` is `true`.

Use a **preset name** or a **file path** to a custom `.wav` file.

**Presets:** `Default`, `IM`, `Mail`, `Reminder`, `SMS`, `Alarm`, `Call`, `None`. Alarm/Call variants (`Alarm2`–`Alarm10`, `Call2`–`Call10`) are also accepted. `None` silences the toast. Preset names are case-insensitive.

> **Note:** `Alarm` and `Call` presets (including numbered variants) produce looping audio and keep the toast visible until dismissed. Use `Reminder` or `SMS` for a non-looping alert sound.

```json
"notificationSound": "Alarm3"
```

```json
"notificationSound": "C:\\Sounds\\my-alert.wav"
```

## Mode summary

| | Agent mode | Prompt-only mode |
|---|---|---|
| **Required (scheduled)** | `agent` + `prompt` + `schedule` | `prompt` + `schedule` |
| **Required (manual)** | `agent` + `prompt` | `prompt` |
| **Tool scoping** | Via `.agent.md` `tools` list | All tools (`--allow-all-tools`) |
| **Tool restriction** | Omit tools from `.agent.md` | `denyTools` in registration |
