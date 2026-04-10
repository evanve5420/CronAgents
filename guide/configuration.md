# Configuration Reference

CronAgents uses two levels of configuration: a **global config** for scheduler behavior and **per-agent configs** for each agent's schedule and settings.

Both are validated against JSON Schemas. Your editor can use these schemas for autocomplete and inline validation.

---

## Global config: `cronagents.json`

Located at the repository root. Controls scheduler-wide behavior.

**Schema:** `cronagents.schema.json`

```json
{
  "$schema": "./cronagents.schema.json",
  "autoFeedback": false,
  "maxRunHistory": 50,
  "copilotPath": "copilot",
  "retentionDays": 14,
  "startupDelay": "5m",
  "logLevel": "info",
  "quietHours": null,
  "notifications": true,
  "questionExpirationDays": 7,
  "personalRepo": {
    "path": "~/.cronagents",
    "userName": null,
    "autoCommitFeedback": true,
    "defaultWorkingDirectory": null
  }
}
```

### Field reference

#### `autoFeedback`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `false` |
| **Description** | When `true`, the scheduler automatically invokes the feedback evaluator after each agent run if feedback is present. When `false`, you must run `cronagents.ps1 evaluate` manually. |

```json
"autoFeedback": true
```

#### `maxRunHistory`

| | |
|---|---|
| **Type** | `integer` |
| **Default** | `50` |
| **Min** | `0` |
| **Description** | Maximum number of run directories to keep under `.cronstate/runs/`. Oldest runs are deleted first. Set to `0` for unlimited. |

```json
"maxRunHistory": 100
```

#### `copilotPath`

| | |
|---|---|
| **Type** | `string` |
| **Default** | `"copilot"` |
| **Description** | Path to the Copilot CLI binary. Use the default if `copilot` is on your `PATH`. Set a full path if it's installed in a non-standard location. |

```json
"copilotPath": "C:\\Users\\me\\.local\\bin\\copilot.exe"
```

#### `retentionDays`

| | |
|---|---|
| **Type** | `integer` |
| **Default** | `14` |
| **Min** | `0` |
| **Description** | Delete run directories older than this many days. Runs with unprocessed feedback are never deleted. Set to `0` to disable time-based cleanup. |

```json
"retentionDays": 30
```

#### `startupDelay`

| | |
|---|---|
| **Type** | `string` |
| **Default** | `"5m"` |
| **Pattern** | `^[0-9]+(m\|h\|s)?$` or `"0"` |
| **Description** | How long the scheduler waits after starting before the first tick. Prevents thrashing at boot when many programs compete for resources. Supports `m` (minutes), `h` (hours), `s` (seconds). |

```json
"startupDelay": "2m"
```

```json
"startupDelay": "0"
```

#### `logLevel`

| | |
|---|---|
| **Type** | `string` |
| **Default** | `"info"` |
| **Enum** | `"debug"`, `"info"`, `"warn"`, `"error"` |
| **Description** | Minimum severity level for the global scheduler log (`.cronstate/scheduler.log`). `debug` is the most verbose. Per-run logs always use `debug` regardless of this setting. |

```json
"logLevel": "debug"
```

#### `quietHours`

| | |
|---|---|
| **Type** | `object` or `null` |
| **Default** | `null` |
| **Description** | Time window during which no agents run. Set to `null` to disable. Both `start` and `end` are required when the object is present. Uses 24-hour HH:MM format. |

```json
"quietHours": {
  "start": "22:00",
  "end": "07:00"
}
```

| Sub-field | Type | Pattern | Description |
|-----------|------|---------|-------------|
| `start` | `string` | `HH:MM` (24h) | Start of quiet window |
| `end` | `string` | `HH:MM` (24h) | End of quiet window |

#### `notifications`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `true` |
| **Description** | Global toggle for Windows toast notifications. When `false`, per-agent `notifyOnFailure` and `notifyOnSuccess` settings are ignored. |

```json
"notifications": false
```

#### `questionExpirationDays`

| | |
|---|---|
| **Type** | `integer` |
| **Default** | `7` |
| **Min** | `0` |
| **Description** | Number of days before unanswered agent questions auto-expire and unblock the next run. Set to `0` to disable expiration. |

```json
"questionExpirationDays": 14
```

#### `personalRepo`

Controls the separate personal repository for user agent definitions.

| Sub-field | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | `string` | `"~/.cronagents"` | Path to the personal repo. `~` expands to the current user's home directory. |
| `userName` | `string` or `null` | `null` | Override username for the personal repo. `null` = auto-detect from `git config github.user`, `gh auth status`, `git config user.name`, or `$env:USERNAME`. |
| `autoCommitFeedback` | `boolean` | `true` | Automatically `git commit` after the feedback evaluator edits agent files in the personal repo. |
| `defaultWorkingDirectory` | `string` or `null` | `null` | Optional default project directory stored in global config. Per-agent `workingDirectory` controls actual run scoping; when no per-agent value is set, the scheduler currently runs from the personal repo root if available, otherwise the infra repo root. |

```json
"personalRepo": {
  "path": "~/.cronagents",
  "userName": "alice",
  "autoCommitFeedback": true,
  "defaultWorkingDirectory": "C:\\Projects\\my-app"
}
```

> **Note:** Additional properties are not allowed. Adding an unrecognized field to `cronagents.json` will cause a validation error.

---

## Per-agent registration: `.cronagents/agents/<id>.agent-registration.json`

Each agent has a JSON config file. The filename stem (for example, `daily-review` from `daily-review.agent-registration.json`) is the **agent ID** used in CLI commands, state tracking, and run directories.

**Schema:** `cronagents-agent.schema.json`

### Agent mode example

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Daily Code Review",
  "agent": "daily-review",
  "prompt": "Review yesterday's code changes and report findings",
  "schedule": { "type": "daily", "time": "09:00" },
  "runIf": "git-dirty",
  "timeout": "10m",
  "skipOnBattery": false,
  "retryCount": 1,
  "model": null,
  "denyTools": [],
  "extraCliFlags": [],
  "envVars": {},
  "notifyOnFailure": true,
  "notifyOnSuccess": false
}
```

### Prompt-only mode example

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "prompt": "List outdated npm packages and check for security advisories",
  "schedule": { "type": "daily", "time": "10:00" },
  "denyTools": ["edit"]
}
```

### Manual (ad-hoc) agent example

Omit `schedule` to create an agent that is only triggered manually via `cronagents.ps1 run <id>` or the dashboard:

```json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "Release Notes Generator",
  "agent": "release-notes",
  "prompt": "Generate release notes for the latest tag"
}
```

Manual agents appear in the dashboard and CLI status with a "manual" schedule label and no next-run time.

### Field reference

#### `name`

| | |
|---|---|
| **Type** | `string` |
| **Required** | No |
| **Description** | Human-readable display name. Shown in the dashboard and status output. If omitted, the agent ID (filename) is used. |

#### `agent`

| | |
|---|---|
| **Type** | `string` |
| **Required** | Yes (agent mode) / Must be absent (prompt-only mode) |
| **Description** | References the custom agent profile name (without the `.agent.md` extension). Copilot CLI discovers these profiles from supported locations such as `.github/agents/` or `~/.copilot/agents/`. |

#### `prompt`

| | |
|---|---|
| **Type** | `string` |
| **Required** | Yes |
| **Min length** | 1 |
| **Description** | The prompt sent to Copilot CLI on each run. In agent mode, this supplements the agent's system prompt. In prompt-only mode, this is the entire instruction. |

#### `schedule`

| | |
|---|---|
| **Type** | `object` or omitted |
| **Required** | No |
| **Description** | When the agent should run. Omit entirely for manual (ad-hoc) agents that are only triggered via `cronagents.ps1 run` or the dashboard. One of three types: |

**Interval schedule** — run every N hours/minutes (minimum 30 minutes):

```json
"schedule": { "type": "interval", "every": "2h" }
```

```json
"schedule": { "type": "interval", "every": "30m" }
```

**Daily schedule** — run once a day at a fixed time:

```json
"schedule": { "type": "daily", "time": "09:00" }
```

**Weekly schedule** — run once a week on a specific day and time:

```json
"schedule": { "type": "weekly", "day": "monday", "time": "08:00" }
```

| Schedule type | Required fields | Pattern |
|---------------|----------------|---------|
| `interval` | `type`, `every` | `every`: `^[0-9]+(h\|m)$`, min 30m |
| `daily` | `type`, `time` | `time`: `HH:MM` (24h) |
| `weekly` | `type`, `day`, `time` | `day`: lowercase day name, `time`: `HH:MM` |

#### `runIf`

| | |
|---|---|
| **Type** | `string` or `object` |
| **Required** | No |
| **Description** | Optional execution condition evaluated after the schedule says the agent is due. The base directory is the agent execution root: `workingDirectory` when set, otherwise the personal repo root, otherwise the infra repo root. |

Built-in predicates:

```json
"runIf": "git-dirty"
```

Runs only when the current git `HEAD` differs from the last observed `HEAD` for that agent.

```json
"runIf": "file-changed:package.json"
```

Runs only when the tracked file's last-write time differs from the last observed value for that agent. Paths must be relative to the execution root and cannot escape it.

Custom PowerShell script:

```json
"runIf": { "script": ".cronagents/scripts/should-run.ps1" }
```

CronAgents invokes the script with named parameters `-RepoRoot`, `-AgentId`, and `-StateFile`. The script must exit with code `0` and write `true` or `false` to stdout.

#### `timeout`

| | |
|---|---|
| **Type** | `string` |
| **Default** | `"10m"` |
| **Pattern** | `^[0-9]+(m\|h\|s)?$` or `"0"` |
| **Description** | Maximum time the agent is allowed to run before the scheduler kills it. Supports `m` (minutes), `h` (hours), `s` (seconds). `"0"` means no timeout. |

```json
"timeout": "30m"
```

#### `skipOnBattery`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `false` |
| **Description** | When `true`, the agent is skipped if the machine is running on battery power. Useful for expensive or long-running agents on laptops. |

#### `retryCount`

| | |
|---|---|
| **Type** | `integer` |
| **Default** | `0` |
| **Min** | `0` |
| **Description** | Number of times to retry the agent if it fails (non-zero exit code). Each retry is a full re-invocation. |

#### `model`

| | |
|---|---|
| **Type** | `string` or `null` |
| **Default** | `null` |
| **Description** | Override the Copilot CLI model for this agent. `null` uses the CLI default. |

```json
"model": "claude-sonnet-4"
```

#### `denyTools`

| | |
|---|---|
| **Type** | `array` of `string` |
| **Default** | `[]` |
| **Description** | Tools to deny. Unattended runs use `--allow-all-tools`, so use this to restrict specific tools when needed. This is especially useful in prompt-only mode; in agent mode, you can also limit tools by omitting them from `.agent.md`. Values are passed directly to `--deny-tool` and use CLI permission-pattern syntax. |

Supports built-in names (`edit`, `execute`), shell commands (`shell(rm)`), MCP tools (`server-name(tool-name)`), and `write` (all file-modifying tools except shell). For full details, see the [Registration Fields reference](../.github/skills/creating-agents/references/REGISTRATION-FIELDS.md#denytools-array-of-string-default-).

```json
"denyTools": ["edit", "shell(rm)", "shell(git push)"]
```

#### `extraCliFlags`

| | |
|---|---|
| **Type** | `array` of `string` |
| **Default** | `[]` |
| **Description** | Additional flags passed directly to the Copilot CLI invocation. |

```json
"extraCliFlags": ["--no-pager", "--quiet"]
```

#### `envVars`

| | |
|---|---|
| **Type** | `object` (string keys and values) |
| **Default** | `{}` |
| **Description** | Environment variables set for the agent's process. |

```json
"envVars": {
  "NODE_ENV": "production",
  "REVIEW_DEPTH": "shallow"
}
```

#### `notifyOnFailure`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `false` |
| **Description** | Show a Windows toast notification when the agent fails or times out. Requires global `notifications` to be `true`. |

#### `notifyOnSuccess`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `false` |
| **Description** | Show a Windows toast notification when the agent completes successfully. Requires global `notifications` to be `true`. |

#### `workingDirectory`

| | |
|---|---|
| **Type** | `string` or `null` |
| **Default** | `null` |
| **Description** | Override the working directory and scope for this agent's Copilot CLI invocation. When set, the scheduler grants access to that directory plus the personal repo and infra repo with `--add-dir`. When `null`, the scheduler runs from the personal repo root if available, otherwise the infra repo root, with `--allow-all`. In all unattended runs, CronAgents also passes `--allow-all-tools`. |

```json
"workingDirectory": "C:\\Projects\\my-app"
```

---

## Agent mode vs prompt-only mode

CronAgents supports two modes, determined by whether the `agent` field is present. Both modes can be scheduled or manual.

| | Agent mode | Prompt-only mode |
|---|---|---|
| **Config fields (scheduled)** | `agent` + `prompt` + `schedule` | `prompt` + `schedule` |
| **Config fields (manual)** | `agent` + `prompt` | `prompt` |
| **`.agent.md` file** | Required (`.github/agents/` or `~/.copilot/agents/`) | Not used |
| **Tool scoping** | Defined in `.agent.md` frontmatter `tools` list | All tools enabled (`--allow-all-tools`) |
| **Tool restriction** | Via `.agent.md` frontmatter | Via `denyTools` in config |
| **System prompt** | From `.agent.md` body | None (prompt is the only instruction) |
| **Best for** | Reusable, well-defined agents | Quick one-off tasks, simple automation |

**Use agent mode** when you want a stable agent definition with scoped tools and a persistent system prompt. **Use prompt-only mode** for quick tasks where writing a full `.agent.md` file is overkill.

**Use manual mode** (omit `schedule`) when the agent should only run on-demand — for example, a release-notes generator or a one-time migration helper. Manual agents are visible in the dashboard and CLI but the scheduler never auto-triggers them.

---

## JSON Schema references

Both schemas support the `$schema` field for editor integration:

```json
{
  "$schema": "./cronagents.schema.json"
}
```

```json
{
  "$schema": "../../cronagents-agent.schema.json"
}
```

In VS Code, this gives you autocomplete, inline validation, and hover documentation for every field.

