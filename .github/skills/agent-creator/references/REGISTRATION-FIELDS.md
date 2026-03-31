# Registration Fields Reference

All fields for `.agent-registration.json` files. Schema: `cronagents-agent.schema.json`.

## Required fields

### `prompt` (string, min 1 char)

The prompt sent to Copilot CLI. In agent mode, supplements the system prompt. In prompt-only mode, this is the entire instruction.

### `schedule` (object)

When the agent runs. One of three types:

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

Tools to deny. Most useful in prompt-only mode (which gets `--allow-all-tools`).

```json
"denyTools": ["edit", "shell(rm)", "shell(git push)"]
```

### `extraCliFlags` (array of string, default `[]`)

Additional flags passed to the Copilot CLI invocation.

### `workingDirectory` (string or null)

Override working directory for this agent. `null` = use global default (personal repo root with `--allow-all`).

### `envVars` (object, default `{}`)

Environment variables set for the agent process. String keys and values.

```json
"envVars": { "NODE_ENV": "production" }
```

### `notifyOnFailure` (boolean, default `false`)

Show a Windows toast notification when the agent fails or times out. Requires the global `notifications` setting to be `true` in `cronagents.json`.

## Mode summary

| | Agent mode | Prompt-only mode |
|---|---|---|
| **Required** | `agent` + `prompt` + `schedule` | `prompt` + `schedule` |
| **Tool scoping** | Via `.agent.md` `tools` list | All tools (`--allow-all-tools`) |
| **Tool restriction** | Omit tools from `.agent.md` | `denyTools` in registration |
