<#
.SYNOPSIS
    Main CronAgents scheduler entry point — a single long-running process
    with one centralized heartbeat that evaluates and dispatches agents.

.PARAMETER ConfigPath
    Path to cronagents.json. Defaults to $RepoRoot\cronagents.json.

.PARAMETER RepoRoot
    Repository root directory. Defaults to parent of the script's parent directory.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------
# 1. Resolve paths
# -----------------------------------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $RepoRoot 'cronagents.json'
}

# -----------------------------------------------------------------------
# 2. Import module
# -----------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'lib\CronAgents.psd1') -Force

# -----------------------------------------------------------------------
# 3–4. Load and validate config
# -----------------------------------------------------------------------
$config = Import-CronAgentsConfig -ConfigPath $ConfigPath
$errors = Test-CronAgentsConfig -Config $config
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Error $e }
    exit 1
}

# -----------------------------------------------------------------------
# 4a. Resolve personal repo path
# -----------------------------------------------------------------------
$personalRepoPath = Get-PersonalRepoPath -ConfigPath $config.personalRepo.path

$cronStateDir = Join-Path $personalRepoPath '.cronstate'
$stateFile    = Join-Path $cronStateDir 'state.json'
$runsRoot     = Join-Path $cronStateDir 'runs'
$logFile      = Join-Path $cronStateDir 'scheduler.log'

# -----------------------------------------------------------------------
# 5. Initialize logging
# -----------------------------------------------------------------------
Set-CronAgentsLogLevel -Level $config.logLevel
Set-CronAgentsLogFile  -Path $logFile

# -----------------------------------------------------------------------
# 5a. Resolve bare copilotPath to an absolute path.
#     Process.Start with UseShellExecute=$false may not search the user
#     PATH in non-interactive contexts (e.g., Task Scheduler). Resolving
#     up front avoids "file not found" errors at agent-launch time.
# -----------------------------------------------------------------------
if ($config.copilotPath -notmatch '[\\/]') {
    $resolvedCmd = Get-Command $config.copilotPath -CommandType Application -ErrorAction SilentlyContinue |
                   Select-Object -First 1
    if ($resolvedCmd) {
        $config.copilotPath = $resolvedCmd.Source
        Write-CronAgentsLog -Level 'debug' -Message "Resolved copilotPath to: $($config.copilotPath)"
    }
    else {
        Write-CronAgentsLog -Level 'warn' -Message "Could not resolve copilotPath '$($config.copilotPath)' — agent runs may fail."
    }
}

# -----------------------------------------------------------------------
# 6. Ensure .cronstate/ exists
# -----------------------------------------------------------------------
if (-not (Test-Path $cronStateDir)) {
    New-Item -ItemType Directory -Path $cronStateDir -Force | Out-Null
}
if (-not (Test-Path $runsRoot)) {
    New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null
}

# -----------------------------------------------------------------------
# 6a. Isolated copilot home (prevents IDE auto-connect hangs)
# -----------------------------------------------------------------------
$script:schedulerCopilotHome = $null
$script:copilotAuthToken     = $null
try {
    $script:schedulerCopilotHome = Initialize-SchedulerCopilotHome -StateRoot $cronStateDir
    $script:copilotAuthToken     = Get-CopilotAuthToken
}
catch {
    Write-CronAgentsLog -Level 'warn' -Message "Failed to initialize scheduler copilot home: $_ — falling back to default."
}

# -----------------------------------------------------------------------
# 6b. Single-instance guard — exit if another scheduler is already running.
#     This prevents duplicate processes when the periodic trigger fires
#     while a scheduler is already active.
# -----------------------------------------------------------------------
$existingPidFile = Join-Path $cronStateDir 'scheduler.pid'
if (Test-SchedulerRunning -PidFilePath $existingPidFile -ExcludePid $PID) {
    Write-CronAgentsLog -Level 'info' -Message 'Another scheduler instance is already running. Exiting.'
    exit 0
}

# -----------------------------------------------------------------------
# 7. Log startup
# -----------------------------------------------------------------------
Write-CronAgentsLog -Level 'info' -Message 'CronAgents scheduler starting'

# -----------------------------------------------------------------------
# 7a. Write scheduler PID file for freshness detection
# -----------------------------------------------------------------------
$script:schedulerPidFile = Join-Path $cronStateDir 'scheduler.pid'
$pidPayload = @{ pid = $PID; startedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json
try {
    [System.IO.File]::WriteAllText($script:schedulerPidFile, $pidPayload, [System.Text.Encoding]::UTF8)
    Write-CronAgentsLog -Level 'debug' -Message "Wrote scheduler PID file: $($script:schedulerPidFile)"
}
catch {
    Write-CronAgentsLog -Level 'warn' -Message "Failed to write scheduler PID file '$($script:schedulerPidFile)': $_ — continuing without freshness PID file."
}

# -----------------------------------------------------------------------
# 7b. Recovery detection — check for missed runs after a crash/restart
# -----------------------------------------------------------------------
try {
    $missedAgents = Get-OverdueAgents -RepoRoot $RepoRoot `
        -PersonalRepoPath $personalRepoPath `
        -StateFile $stateFile -Now (Get-Date).ToUniversalTime()

    if ($missedAgents.Count -gt 0) {
        $list = $missedAgents -join ', '
        Write-CronAgentsLog -Level 'warn' -Message "Recovery: $($missedAgents.Count) agent(s) are overdue and will run this tick: $list"
        try {
            Send-SchedulerErrorNotification -Operation 'Scheduler recovery' `
                -ErrorMessage "Scheduler restarted. $($missedAgents.Count) overdue agent(s) will run shortly: $list" `
                -GlobalConfig $config
        } catch { <# best-effort #> }
    }
}
catch {
    Write-CronAgentsLog -Level 'warn' -Message "Recovery detection skipped: $_"
}

# -----------------------------------------------------------------------
# Ctrl+C handling
# -----------------------------------------------------------------------
$script:running = $true
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:running = $false
}

# -----------------------------------------------------------------------
# Quiet-hours helper
# -----------------------------------------------------------------------
function Test-InQuietHours {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$QuietHours,
        [datetime]$Now
    )

    if ($null -eq $QuietHours) { return $false }

    $start = [datetime]::ParseExact($QuietHours.start, 'HH:mm', $null).TimeOfDay
    $end   = [datetime]::ParseExact($QuietHours.end,   'HH:mm', $null).TimeOfDay
    $nowTod = $Now.TimeOfDay

    if ($start -lt $end) {
        # Same-day window (e.g., 09:00–17:00)
        return ($nowTod -ge $start -and $nowTod -lt $end)
    }
    else {
        # Overnight window (e.g., 22:00–06:00)
        return ($nowTod -ge $start -or $nowTod -lt $end)
    }
}

# -----------------------------------------------------------------------
# Sleep helper — breaks sleep into 10s chunks for Ctrl+C responsiveness
# -----------------------------------------------------------------------
function Start-InterruptibleSleep {
    [CmdletBinding()]
    param([int]$Seconds)

    $remaining = $Seconds
    while ($remaining -gt 0 -and $script:running) {
        $chunk = [Math]::Min($remaining, 10)
        Start-Sleep -Seconds $chunk
        $remaining -= $chunk
    }
}

# -----------------------------------------------------------------------
# Copilot env helper — temporarily applies scheduler-specific Copilot
# environment so background evaluator runs do not attach to the IDE daemon.
# -----------------------------------------------------------------------
function Invoke-WithSchedulerCopilotEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $prevHome  = $env:COPILOT_HOME
    $prevToken = $env:GH_TOKEN
    try {
        if ($script:schedulerCopilotHome) { $env:COPILOT_HOME = $script:schedulerCopilotHome }
        if ($script:copilotAuthToken)     { $env:GH_TOKEN     = $script:copilotAuthToken }
        & $ScriptBlock
    }
    finally {
        $env:COPILOT_HOME = $prevHome
        $env:GH_TOKEN     = $prevToken
    }
}

# -----------------------------------------------------------------------
# Feedback sweep helper
# -----------------------------------------------------------------------
function Invoke-FeedbackSweep {
    [CmdletBinding()]
    param(
        [string]$RunsRoot,
        [string]$CopilotPath,
        [string]$RepoRoot,
        [bool]$AutoCommitFeedback
    )

    $history = Get-RunHistory -RunsRoot $RunsRoot
    $agentsDir = Join-Path $RepoRoot 'scheduler' 'agents'
    foreach ($run in $history) {
        if (-not $script:running) { break }
        if (-not $run.HasFeedback) { continue }
        if ($run.FeedbackProcessed) { continue }

        $runDir = $run.RunDirectory
        Write-CronAgentsLog -Level 'info' -Message "Processing feedback for run: $runDir"

        try {
            $evalSharePath = Join-Path $runDir 'evaluator-session.md'
            $copilotArgs = @(
                "--agent=feedback-evaluator"
                "-p"
                "Process feedback for run in: $runDir"
                "--silent"
                "--add-dir=$agentsDir"
                "--allow-all-tools"
                "--no-ask-user"
                "--share=$evalSharePath"
            )
            Invoke-WithSchedulerCopilotEnv -ScriptBlock {
                & $CopilotPath @copilotArgs 2>&1 | Out-Null
            }
            Write-CronAgentsLog -Level 'info' -Message "Feedback evaluator completed for: $runDir"
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Feedback evaluator failed for $runDir`: $_"
            try {
                Send-SchedulerErrorNotification -Operation 'Feedback evaluator' `
                    -ErrorMessage "$_" -GlobalConfig $config
            } catch { <# best-effort #> }
        }

        # Mark feedbackProcessed in meta.json
        try {
            $metaPath = Join-Path $runDir 'meta.json'
            if (Test-Path $metaPath) {
                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $meta.feedbackProcessed = $true
                $json = $meta | ConvertTo-Json -Depth 10
                Set-Content -LiteralPath $metaPath -Value $json -Encoding UTF8
            }
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Failed to update feedbackProcessed in $runDir`: $_"
            try {
                Send-SchedulerErrorNotification -Operation 'Feedback metadata update' `
                    -ErrorMessage "$_" -GlobalConfig $config
            } catch { <# best-effort #> }
        }

        if ($AutoCommitFeedback) {
            try {
                New-FeedbackCommit -RepoRoot $RepoRoot `
                    -AgentId $run.AgentId `
                    -Summary "Processed feedback" `
                    -ChangedFiles @($runDir)
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Feedback commit failed for $($run.AgentId): $_"
                try {
                    Send-SchedulerErrorNotification -Operation 'Feedback commit' `
                        -ErrorMessage "$_" -GlobalConfig $config
                } catch { <# best-effort #> }
            }
        }
    }
}

# -----------------------------------------------------------------------
# 8. Apply startup delay
# -----------------------------------------------------------------------
$startupDelaySec = ConvertTo-Seconds -Duration ($config.startupDelay)
if ($startupDelaySec -gt 0) {
    Write-CronAgentsLog -Level 'info' -Message "Startup delay: $($config.startupDelay). Waiting before first tick..."
    Start-InterruptibleSleep -Seconds $startupDelaySec
    if (-not $script:running) {
        Write-CronAgentsLog -Level 'info' -Message 'Scheduler shutting down gracefully'
        exit 0
    }
    Write-CronAgentsLog -Level 'info' -Message 'Startup delay complete. Beginning scheduler loop.'
}

# -----------------------------------------------------------------------
# Retention tracking — run cleanup once per day
# -----------------------------------------------------------------------
$script:lastCleanupDate = $null

# -----------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------
try {
    while ($script:running) {
        $tickStart = Get-Date

        # Begin collecting scheduler-error notifications for this tick.
        # Errors are queued and fired as a single summary toast at tick end.
        Start-SchedulerErrorBatch

        # -----------------------------------------------------------
        # Step 1: Check global pause
        # -----------------------------------------------------------
        $state = Get-AgentState -StateFile $stateFile
        if ($state.schedulerPaused) {
            Write-CronAgentsLog -Level 'info' -Message 'Scheduler paused — skipping tick'
            Start-InterruptibleSleep -Seconds 60
            continue
        }

        # -----------------------------------------------------------
        # Step 2: Feedback sweep
        # -----------------------------------------------------------
        if ($config.autoFeedback) {
            try {
                Invoke-FeedbackSweep -RunsRoot $runsRoot `
                    -CopilotPath $config.copilotPath `
                    -RepoRoot $personalRepoPath `
                    -AutoCommitFeedback $config.personalRepo.autoCommitFeedback
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Feedback sweep error: $_"
                try {
                    Send-SchedulerErrorNotification -Operation 'Feedback sweep' `
                        -ErrorMessage "$_" -GlobalConfig $config
                } catch { <# best-effort #> }
            }
        }

        # -----------------------------------------------------------
        # Step 3: Quiet hours check
        # -----------------------------------------------------------
        $skipAgents = $false
        if ($null -ne $config.quietHours) {
            if (Test-InQuietHours -QuietHours $config.quietHours -Now $tickStart) {
                Write-CronAgentsLog -Level 'info' -Message "Quiet hours active ($($config.quietHours.start)–$($config.quietHours.end)). Skipping agent evaluation."
                $skipAgents = $true
            }
        }

        if (-not $skipAgents) {
            # -----------------------------------------------------------
            # Step 4: Scheduled agents
            # -----------------------------------------------------------
            $agents = Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath
            $state  = Get-AgentState -StateFile $stateFile
            $now    = (Get-Date).ToUniversalTime()
            $queue  = [System.Collections.Generic.List[PSCustomObject]]::new()
            $seenAgentIds = [System.Collections.Generic.HashSet[string]]::new()

            foreach ($agent in $agents) {
                if (-not $script:running) { break }

                $agentId = $agent.Id

                # Deduplicate within the same tick
                if ($seenAgentIds.Contains($agentId)) { continue }
                [void]$seenAgentIds.Add($agentId)

                # Check if disabled in state
                $agentState = if ($state.agents.ContainsKey($agentId)) { $state.agents[$agentId] } else { $null }
                if ($agentState -and $agentState.enabled -eq $false) {
                    Write-CronAgentsLog -Level 'debug' -Message "Agent '$agentId' is disabled — skipping"
                    continue
                }

                # Expire stale questions for this agent before checking
                try { Remove-ExpiredQuestions -StateRoot $cronStateDir -AgentId $agentId } catch { }

                # Check for unanswered questions blocking this agent
                if (Test-AgentHasPendingQuestions -StateRoot $cronStateDir -AgentId $agentId) {
                    Write-CronAgentsLog -Level 'info' -Message "Agent '$agentId' has unanswered questions — blocked until answered"
                    continue
                }

                # Parse lastRun
                $lastRun = $null
                if ($agentState -and $agentState.lastRun) {
                    try {
                        $lastRun = [datetime]::Parse($agentState.lastRun)
                    }
                    catch {
                        Write-CronAgentsLog -Level 'warn' -Message "Invalid lastRun for '$agentId': $($agentState.lastRun)"
                    }
                }

                # Build schedule hashtable from config (null for manual-only agents)
                if ($null -eq $agent.Config.schedule) {
                    Write-CronAgentsLog -Level 'debug' -Message "Agent '$agentId' has no schedule (manual-only) — skipping"
                    continue
                }
                $schedule = @{ type = $agent.Config.schedule.type }
                if ($agent.Config.schedule.PSObject.Properties['every']) {
                    $schedule['every'] = $agent.Config.schedule.every
                }
                if ($agent.Config.schedule.PSObject.Properties['time']) {
                    $schedule['time'] = $agent.Config.schedule.time
                }
                if ($agent.Config.schedule.PSObject.Properties['day']) {
                    $schedule['day'] = $agent.Config.schedule.day
                }

                # Check if due
                if (Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now) {
                    $executionRoot = Get-AgentRunIfExecutionRoot -AgentConfig $agent.Config -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath
                    $runIfState = if ($agentState -and $agentState.runIfState) { $agentState.runIfState } else { @{} }
                    if (-not (Test-AgentRunIf -RunIf $agent.Config.runIf -ExecutionRoot $executionRoot -AgentId $agentId -StateFile $stateFile -RunIfState $runIfState)) {
                        Write-CronAgentsLog -Level 'info' -Message "Agent '$agentId' is due but runIf evaluated to false — skipping."
                        continue
                    }

                    $snapshotResult = Get-AgentRunIfSnapshot -RunIf $agent.Config.runIf -ExecutionRoot $executionRoot
                    $runIfSnapshot = if ($snapshotResult.Success) {
                        $snapshotResult.Snapshot
                    } else {
                        Write-CronAgentsLog -Level 'warn' -Message "Snapshot capture failed for '$agentId': $($snapshotResult.Reason) — preserving previous runIfState."
                        $runIfState
                    }
                    if ($agent.PSObject.Properties['RunIfSnapshot']) {
                        $agent.RunIfSnapshot = $runIfSnapshot
                    }
                    else {
                        $agent | Add-Member -NotePropertyName 'RunIfSnapshot' -NotePropertyValue $runIfSnapshot
                    }

                    Write-CronAgentsLog -Level 'info' -Message "Agent '$agentId' is due"
                    $queue.Add($agent)
                }
            }

            # Run queued agents sequentially in discovery order
            $invokeScript = Join-Path $PSScriptRoot 'Invoke-ScheduledAgent.ps1'
            foreach ($agent in $queue) {
                if (-not $script:running) { break }

                $agentId = $agent.Id
                Write-CronAgentsLog -Level 'info' -Message "Starting agent: $agentId"

                try {
                    if (Test-Path $invokeScript) {
                        & $invokeScript -AgentId $agent.Id `
                            -AgentConfig $agent.Config `
                            -GlobalConfig $config `
                            -RepoRoot $RepoRoot `
                            -PersonalRepoPath $personalRepoPath `
                            -RunIfSnapshot $agent.RunIfSnapshot `
                            -RunsRoot $runsRoot
                    }
                    else {
                        Write-CronAgentsLog -Level 'warn' -Message "Invoke-ScheduledAgent.ps1 not found at: $invokeScript — skipping agent '$agentId'"
                    }
                }
                catch {
                    Write-CronAgentsLog -Level 'error' -Message "Agent '$agentId' failed: $_"
                    try {
                        Send-SchedulerErrorNotification -Operation "Agent execution ($agentId)" `
                            -ErrorMessage "$_" -GlobalConfig $config
                    } catch { <# best-effort #> }
                }

                # Post-run feedback for this specific agent
                if ($config.autoFeedback) {
                    try {
                        $latestRun = Get-RunHistory -RunsRoot $runsRoot -AgentId $agentId -MaxResults 1
                        if ($latestRun -and $latestRun.Count -gt 0 -and $latestRun[0].HasFeedback -and -not $latestRun[0].FeedbackProcessed) {
                            $runDir = $latestRun[0].RunDirectory
                            Write-CronAgentsLog -Level 'info' -Message "Running feedback evaluator for agent '$agentId' run: $runDir"
                            $evalAgentsDir  = Join-Path $RepoRoot 'scheduler' 'agents'
                            $evalSharePath  = Join-Path $runDir 'evaluator-session.md'
                            $copilotArgs = @(
                                "--agent=feedback-evaluator"
                                "-p"
                                "Process feedback for run in: $runDir"
                                "--silent"
                                "--add-dir=$evalAgentsDir"
                                "--allow-all-tools"
                                "--no-ask-user"
                                "--share=$evalSharePath"
                            )
                            Invoke-WithSchedulerCopilotEnv -ScriptBlock {
                                & $config.copilotPath @copilotArgs 2>&1 | Out-Null
                            }

                            # Mark processed
                            $metaPath = Join-Path $runDir 'meta.json'
                            if (Test-Path $metaPath) {
                                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                $meta.feedbackProcessed = $true
                                $json = $meta | ConvertTo-Json -Depth 10
                                Set-Content -LiteralPath $metaPath -Value $json -Encoding UTF8
                            }
                        }
                    }
                    catch {
                        Write-CronAgentsLog -Level 'warn' -Message "Post-run feedback for '$agentId' failed: $_"
                        try {
                            Send-SchedulerErrorNotification -Operation "Post-run feedback ($agentId)" `
                                -ErrorMessage "$_" -GlobalConfig $config
                        } catch { <# best-effort #> }
                    }
                }
            }
        }

        # -----------------------------------------------------------
        # Step 6: Dashboard update
        # -----------------------------------------------------------
        try {
            $dashboardScript = Join-Path $PSScriptRoot 'Update-Dashboard.ps1'
            if (Test-Path $dashboardScript) {
                & $dashboardScript -RepoRoot $RepoRoot `
                    -RunsRoot $runsRoot `
                    -PersonalRepoPath $personalRepoPath `
                    -MaxRunHistory $config.maxRunHistory `
                    -RetentionDays $config.retentionDays
            }
            else {
                Write-CronAgentsLog -Level 'debug' -Message 'Update-Dashboard.ps1 not found — skipping dashboard update'
            }
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Dashboard update failed: $_"
            try {
                Send-SchedulerErrorNotification -Operation 'Dashboard update' `
                    -ErrorMessage "$_" -GlobalConfig $config
            } catch { <# best-effort #> }
        }

        # -----------------------------------------------------------
        # Step 7: Retention cleanup (once per day)
        # -----------------------------------------------------------
        $today = (Get-Date).Date
        if ($script:lastCleanupDate -ne $today) {
            try {
                $agentIds = @((Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath) | ForEach-Object { $_.Id })
                Invoke-RetentionCleanup -RunsRoot $runsRoot `
                    -RetentionDays $config.retentionDays `
                    -StateFile $stateFile `
                    -DiscoveredAgentIds $agentIds
                $script:lastCleanupDate = $today
                Write-CronAgentsLog -Level 'info' -Message 'Retention cleanup completed'
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Retention cleanup failed: $_"
                try {
                    Send-SchedulerErrorNotification -Operation 'Retention cleanup' `
                        -ErrorMessage "$_" -GlobalConfig $config
                } catch { <# best-effort #> }
            }

            # Note: per-agent question expiration runs each tick (before blocking check above).
            # A full sweep here catches agents not evaluated this tick.
            try { Remove-ExpiredQuestions -StateRoot $cronStateDir }
            catch { Write-CronAgentsLog -Level 'warn' -Message "Question expiration sweep failed: $_" }
        }

        # -----------------------------------------------------------
        # Step 8: Flush batched scheduler-error notifications
        # -----------------------------------------------------------
        try {
            Complete-SchedulerErrorBatch -GlobalConfig $config
        } catch { <# best-effort #> }

        # -----------------------------------------------------------
        # Step 9: Sleep until next tick
        # -----------------------------------------------------------
        $agents = Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath
        $state  = Get-AgentState -StateFile $stateFile
        $now    = (Get-Date).ToUniversalTime()
        $maxSleepSec = 3600  # Clamp to 1 hour max

        $nextDue = $null
        foreach ($agent in $agents) {
            $agentState = if ($state.agents.ContainsKey($agent.Id)) { $state.agents[$agent.Id] } else { $null }
            if ($agentState -and $agentState.enabled -eq $false) { continue }
            # Skip manual-only agents (no schedule) in next-due calculation
            if ($null -eq $agent.Config.schedule) { continue }

            $lastRun = $null
            if ($agentState -and $agentState.lastRun) {
                try { $lastRun = [datetime]::Parse($agentState.lastRun) } catch { }
            }

            $schedule = @{ type = $agent.Config.schedule.type }
            if ($agent.Config.schedule.PSObject.Properties['every']) { $schedule['every'] = $agent.Config.schedule.every }
            if ($agent.Config.schedule.PSObject.Properties['time'])  { $schedule['time']  = $agent.Config.schedule.time }
            if ($agent.Config.schedule.PSObject.Properties['day'])   { $schedule['day']   = $agent.Config.schedule.day }

            $agentNext = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
            if ($null -eq $nextDue -or $agentNext -lt $nextDue) {
                $nextDue = $agentNext
            }
        }

        $sleepSec = $maxSleepSec
        if ($null -ne $nextDue) {
            $delta = ($nextDue - $now).TotalSeconds
            if ($delta -gt 0) {
                $sleepSec = [Math]::Min([int][Math]::Ceiling($delta), $maxSleepSec)
            }
            else {
                $sleepSec = 60  # Already due — short sleep to re-check
            }
        }

        Write-CronAgentsLog -Level 'debug' -Message "Sleeping $sleepSec seconds until next tick"
        Start-InterruptibleSleep -Seconds $sleepSec
    }
}
finally {
    Write-CronAgentsLog -Level 'info' -Message 'Scheduler shutting down gracefully'
    if ($script:schedulerPidFile -and (Test-Path $script:schedulerPidFile)) {
        Remove-Item $script:schedulerPidFile -Force -ErrorAction SilentlyContinue
    }
}
