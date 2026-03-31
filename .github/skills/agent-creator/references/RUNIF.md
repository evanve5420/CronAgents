# runIf Reference

Conditional execution: the agent only runs when a predicate is true, even if the schedule says it's due.

## Built-in predicates

### `git-dirty`

```json
"runIf": "git-dirty"
```

Runs when the current `HEAD` differs from the last observed `HEAD` for that agent. Comparison is scoped to the agent's execution root.

### `file-changed:<path>`

```json
"runIf": "file-changed:package.json"
```

Runs when the tracked file's last-write time differs from the last observed value. The path is relative to the execution root and cannot escape it.

## Custom script predicate

```json
"runIf": { "script": ".cronagents/scripts/should-run.ps1" }
```

CronAgents invokes the script with named parameters:

| Parameter | Description |
|-----------|-------------|
| `-RepoRoot` | Execution root directory |
| `-AgentId` | The agent's ID (registration filename stem) |
| `-StateFile` | Path to the agent's state file for reading/writing custom state |

**Requirements:**
- Must exit with code `0`
- Must write exactly `true` or `false` to stdout
- Any other output or non-zero exit = predicate treated as failed (agent skipped, warning logged)

## Execution root resolution

The base directory for all predicates is determined in order:

1. `workingDirectory` (if set on the registration)
2. Personal repo root (`~/.cronagents/`)
3. Infra repo root (the CronAgents project itself)
