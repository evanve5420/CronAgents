# Troubleshooting

Common issues and how to fix them.

---

## "Task not registered"

**Symptom:** The scheduler doesn't start at logon. `cronagents.ps1 status` shows nothing running.

**Fix:** Register the Task Scheduler entry:

```powershell
.\cronagents.ps1 install
```

**Verify:**

```powershell
Get-ScheduledTask -TaskPath '\CronAgents\' -TaskName 'CronAgents'
```

You should see the task with a `Ready` or `Running` status and an "At logon" trigger.

---

## "Scheduler not running"

**Symptom:** Agents aren't running on schedule. The dashboard isn't updating.

**Possible causes:**

1. **Task isn't started.** The task triggers at logon — if you installed without logging out, start it manually:

   ```powershell
   Start-ScheduledTask -TaskName 'CronAgents' -TaskPath '\CronAgents\'
   ```

2. **Task is disabled.** Check in Task Scheduler (GUI) or:

   ```powershell
   Get-ScheduledTask -TaskPath '\CronAgents\' | Select-Object TaskName, State
   ```

3. **PowerShell not found.** The task runs `pwsh` (PowerShell 7). Verify it's installed:

   ```powershell
   pwsh --version
   ```

4. **Scheduler is paused.** Check if you paused it:

   ```powershell
   .\cronagents.ps1 status
   ```

   If paused, resume:

   ```powershell
   .\cronagents.ps1 resume
   ```

5. **Startup delay.** The scheduler waits before the first tick (default: 5 minutes). If you just started it, wait for the delay to pass. Check `cronagents.json`:

   ```json
   "startupDelay": "5m"
   ```

---

## "Agent not found"

**Symptom:** `cronagents.ps1 run <id>` says the agent doesn't exist.

**Fix:** Make sure the agent has a `.json` config file in `.cronagents/agents/`:

```powershell
Get-ChildItem .cronagents\agents\*.agent-registration.json
```

The filename stem must match the agent ID you're using. For example, `daily-review.agent-registration.json` → agent ID is `daily-review`.

**Common mistakes:**

- File is in the wrong directory (should be `.cronagents/agents/`, not `.cronagents/` or `agents/`)
- File has a typo in the name
- File is not valid JSON (syntax error)
- Agent mode config references an `.agent.md` file that doesn't exist (check the `agent` field)

---

## "Config validation error"

**Symptom:** Error messages about invalid configuration when running any command.

**For global config (`cronagents.json`):**

1. Check JSON syntax — missing commas, unclosed braces, trailing commas:

   ```powershell
   Get-Content cronagents.json | ConvertFrom-Json
   ```

2. Check for unknown fields. `cronagents.json` does not allow additional properties. Remove any fields not in the schema.

3. Check field values:
   - `logLevel`: must be `"debug"`, `"info"`, `"warn"`, or `"error"`
   - `syncPolicy`: must be `"auto"`, `"notify"`, or `"manual"`
   - `startupDelay`: must match `^[0-9]+(m|h|s)?$` or `"0"`
   - `retentionDays`, `maxRunHistory`: must be non-negative integers
   - `quietHours.start`, `quietHours.end`: must be `HH:MM` (24-hour)

**For agent registrations (`.cronagents/agents/<id>.agent-registration.json`):**

1. Check JSON syntax as above.

2. Verify required fields:
   - Both modes: `prompt` and `schedule` are required
   - Agent mode: `agent` field is also required
   - Prompt-only mode: `agent` field must be absent (not empty — absent)

3. Check schedule format:
   - Interval: `{ "type": "interval", "every": "2h" }` (minimum "30m")
   - Daily: `{ "type": "daily", "time": "09:00" }`
   - Weekly: `{ "type": "weekly", "day": "monday", "time": "09:00" }` (lowercase day)

4. Use the `$schema` field for editor validation:

   ```json
   { "$schema": "../../cronagents-agent.schema.json" }
   ```

---

## Reading logs

### Global scheduler log

```
.cronstate/scheduler.log
```

The main log for the scheduler process. Log level is controlled by `logLevel` in `cronagents.json`.

```powershell
# View recent log entries
Get-Content .cronstate\scheduler.log -Tail 50

# Watch in real time
Get-Content .cronstate\scheduler.log -Tail 10 -Wait

# Search for errors
Select-String -Path .cronstate\scheduler.log -Pattern '\[ERROR\]'
```

Log format: `[2024-01-15T14:30:22] [INFO] Agent daily-review is due, queuing`

### Per-run logs

Each run has its own `scheduler.log` at debug level:

```
.cronstate/runs/<timestamp>_<agent-id>_<nonce>/scheduler.log
```

```powershell
# Find the most recent run for an agent
Get-ChildItem .cronstate\runs\*daily-review* | Sort-Object Name -Descending | Select-Object -First 1

# Read that run's log
Get-Content ".cronstate\runs\20240115T143022_daily-review_a1b2\scheduler.log"
```

### Run metadata

Each run's `meta.json` contains structured information:

```powershell
Get-Content ".cronstate\runs\20240115T143022_daily-review_a1b2\meta.json" | ConvertFrom-Json
```

```json
{
  "agentId": "daily-review",
  "agentName": "Daily Code Review",
  "prompt": "Review yesterday's code changes",
  "startTime": "2024-01-15T14:30:22",
  "endTime": "2024-01-15T14:35:18",
  "exitCode": 0,
  "timedOut": false,
  "retryAttempt": 0,
  "feedbackProcessed": false
}
```

Key fields for troubleshooting:
- `exitCode`: `0` = success, non-zero = failure
- `timedOut`: `true` if the agent hit its timeout
- `retryAttempt`: which retry this was (0 = first attempt)

---

## Health check

Run the doctor command for a comprehensive check:

```powershell
.\cronagents.ps1 doctor
```

This verifies:

| Check | What it tests |
|-------|---------------|
| Task Scheduler | Is the `\CronAgents\CronAgents` task registered? |
| Config files | Are `cronagents.json` and agent configs valid? |
| Copilot CLI | Is `copilot` available and authenticated? |
| State integrity | Is `.cronstate/state.json` readable and well-formed? |
| Agent discovery | Can agents be found in `.cronagents/agents/`? |
| Branch health | Is the current branch a valid user branch? |
| Git status | Is the repository in a clean state? |

Each check reports pass or fail with a description of how to fix any issues.

---

## State corruption recovery

**Symptom:** Unexpected behavior, agents running at wrong times, status showing stale data.

### Reset agent state

Delete the state file to reset all agent timestamps and pause states:

```powershell
Remove-Item .cronstate\state.json
```

The scheduler recreates it on the next tick with defaults:
- All agents enabled
- No last-run timestamps (agents will run on next due check)
- Scheduler not paused

### Reset specific agent

If only one agent has stale state, you can edit `state.json` directly:

```powershell
$state = Get-Content .cronstate\state.json | ConvertFrom-Json
$state.agents.'daily-review'.lastRun = $null
$state.agents.'daily-review'.enabled = $true
$state | ConvertTo-Json -Depth 5 | Set-Content .cronstate\state.json
```

### Full state reset

To reset everything (state, logs, run history):

```powershell
Remove-Item .cronstate -Recurse -Force
```

> **Warning:** This deletes all run history, logs, and pending feedback. The scheduler recreates the directory structure on next start.

---

## Agent times out

**Symptom:** `meta.json` shows `timedOut: true`.

**Fix:** Increase the timeout in the agent's `.json` config:

```json
"timeout": "30m"
```

Or set to `"0"` for no timeout (use carefully).

Also consider whether the agent's task is too broad. A focused prompt completes faster than a vague one.

---

## Copilot CLI errors

**Symptom:** Agents fail with exit code 1, output shows Copilot CLI errors.

1. **Check authentication:**

   ```powershell
   copilot auth status
   ```

   If not authenticated: `copilot auth login`

2. **Check the Copilot path** in `cronagents.json`:

   ```json
   "copilotPath": "copilot"
   ```

   Make sure this is correct. Try running it directly:

   ```powershell
   copilot --version
   ```

3. **Check agent output** for error details:

   ```powershell
   Get-Content ".cronstate\runs\<latest-run>\output.md"
   ```

---

## Feedback not being processed

**Symptom:** You wrote feedback but it's still showing as "Pending".

1. **Check if auto-feedback is enabled:**

   ```json
   "autoFeedback": true
   ```

   If `false`, run manually:

   ```powershell
   .\cronagents.ps1 evaluate
   ```

2. **Check that feedback has content.** Comment-only lines (starting with `<!--`) don't count. The file needs actual text.

3. **Check the scheduler log** for evaluator errors:

   ```powershell
   Select-String -Path .cronstate\scheduler.log -Pattern 'feedback'
   ```

---

## Quiet hours confusion

**Symptom:** Agents skip runs during expected hours.

Check `quietHours` in `cronagents.json`:

```json
"quietHours": {
  "start": "22:00",
  "end": "07:00"
}
```

During quiet hours, no agents run. Set to `null` to disable:

```json
"quietHours": null
```

---

## Git/branch issues

### Wrong branch

```powershell
.\cronagents.ps1 branch
```

If you're not on your user branch:

```powershell
git checkout agents/<your-username>
```

### Merge conflicts after sync

If `cronagents.ps1 sync` fails with conflicts:

```powershell
git merge origin/master          # Start the merge
# Edit conflicted files
git add .
git commit                       # Complete the merge
```

### Dirty working tree prevents operations

```powershell
git stash                        # Stash changes
.\cronagents.ps1 sync           # Run the operation
git stash pop                    # Restore changes
```

---

## Getting help

If none of the above resolves your issue:

1. Run the health check: `.\cronagents.ps1 doctor`
2. Check the global log: `.cronstate/scheduler.log`
3. Check the per-run log for the failing agent
4. Set `logLevel` to `"debug"` in `cronagents.json` for maximum detail
5. Run the agent manually: `.\cronagents.ps1 run <id>` and observe output

