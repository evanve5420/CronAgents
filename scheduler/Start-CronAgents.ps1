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

$cronStateDir = Join-Path $RepoRoot '.cronstate'
$stateFile    = Join-Path $cronStateDir 'state.json'
$runsRoot     = Join-Path $cronStateDir 'runs'
$logFile      = Join-Path $cronStateDir 'scheduler.log'

# -----------------------------------------------------------------------
# 2. Import module
# -----------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'lib\CronAgents.psd1') -Force

# -----------------------------------------------------------------------
# 3–4. Load and validate config
# -----------------------------------------------------------------------
$config = Import-CronAgentsConfig -ConfigPath $ConfigPath
$errors = @(Test-CronAgentsConfig -Config $config)
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Error $e }
    exit 1
}

$versioningEnabled = Test-CronAgentsVersioningEnabled -Config $config

# -----------------------------------------------------------------------
# 5. Initialize logging
# -----------------------------------------------------------------------
Set-CronAgentsLogLevel -Level $config.logLevel
Set-CronAgentsLogFile  -Path $logFile

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
# 7. Log startup
# -----------------------------------------------------------------------
Write-CronAgentsLog -Level 'info' -Message 'CronAgents scheduler starting'
if (-not $versioningEnabled) {
    Write-CronAgentsLog -Level 'info' -Message 'Git versioning is disabled; sync checks and feedback commits will be skipped.'
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
    foreach ($run in $history) {
        if (-not $script:running) { break }
        if (-not $run.HasFeedback) { continue }
        if ($run.FeedbackProcessed) { continue }

        $runDir = $run.RunDirectory
        Write-CronAgentsLog -Level 'info' -Message "Processing feedback for run: $runDir"

        try {
            $copilotArgs = @(
                "--agent=feedback-evaluator"
                "-p"
                "Process feedback for run in: $runDir"
                "--silent"
                "--add-dir=$RepoRoot\scheduler"
                "--allow-all-tools"
                "--no-ask-user"
                "--share=$runDir\evaluator-session.md"
            )
            & $CopilotPath @copilotArgs 2>&1 | Out-Null
            Write-CronAgentsLog -Level 'info' -Message "Feedback evaluator completed for: $runDir"
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Feedback evaluator failed for $runDir`: $_"
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
                    -RepoRoot $RepoRoot `
                    -AutoCommitFeedback ($versioningEnabled -and $config.versioning.autoCommitFeedback)
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Feedback sweep error: $_"
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
            # Step 4: Sync check (notify / auto)
            # -----------------------------------------------------------
            if ($versioningEnabled) {
                try {
                    if ($config.versioning.syncPolicy -eq 'notify') {
                        $divergence = Get-BranchDivergence -RepoRoot $RepoRoot
                        if ($divergence.Behind -gt 0) {
                            Write-CronAgentsLog -Level 'info' -Message "Branch is $($divergence.Behind) commits behind master"
                        }
                    }
                    elseif ($config.versioning.syncPolicy -eq 'auto') {
                        Invoke-BranchSync -RepoRoot $RepoRoot
                    }
                }
                catch {
                    Write-CronAgentsLog -Level 'warn' -Message "Sync check error: $_"
                }
            }

            # -----------------------------------------------------------
            # Step 5: Scheduled agents
            # -----------------------------------------------------------
            $agents = Get-AgentConfigs -RepoRoot $RepoRoot
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

                # Build schedule hashtable from config
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
                        & $invokeScript -AgentConfig $agent `
                            -Config $config `
                            -RepoRoot $RepoRoot `
                            -StateFile $stateFile `
                            -RunsRoot $runsRoot
                    }
                    else {
                        Write-CronAgentsLog -Level 'warn' -Message "Invoke-ScheduledAgent.ps1 not found at: $invokeScript — skipping agent '$agentId'"
                    }
                }
                catch {
                    Write-CronAgentsLog -Level 'error' -Message "Agent '$agentId' failed: $_"
                }

                # Post-run feedback for this specific agent
                if ($config.autoFeedback) {
                    try {
                        $latestRun = Get-RunHistory -RunsRoot $runsRoot -AgentId $agentId -MaxResults 1
                        if ($latestRun -and $latestRun.Count -gt 0 -and $latestRun[0].HasFeedback -and -not $latestRun[0].FeedbackProcessed) {
                            $runDir = $latestRun[0].RunDirectory
                            Write-CronAgentsLog -Level 'info' -Message "Running feedback evaluator for agent '$agentId' run: $runDir"
                            $copilotArgs = @(
                                "--agent=feedback-evaluator"
                                "-p"
                                "Process feedback for run in: $runDir"
                                "--silent"
                                "--add-dir=$RepoRoot\scheduler"
                                "--allow-all-tools"
                                "--no-ask-user"
                                "--share=$runDir\evaluator-session.md"
                            )
                            & $config.copilotPath @copilotArgs 2>&1 | Out-Null

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
                & $dashboardScript -RepoRoot $RepoRoot -StateFile $stateFile -RunsRoot $runsRoot -Config $config
            }
            else {
                Write-CronAgentsLog -Level 'debug' -Message 'Update-Dashboard.ps1 not found — skipping dashboard update'
            }
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Dashboard update failed: $_"
        }

        # -----------------------------------------------------------
        # Step 7: Retention cleanup (once per day)
        # -----------------------------------------------------------
        $today = (Get-Date).Date
        if ($script:lastCleanupDate -ne $today) {
            try {
                $agentIds = @((Get-AgentConfigs -RepoRoot $RepoRoot) | ForEach-Object { $_.Id })
                Invoke-RetentionCleanup -RunsRoot $runsRoot `
                    -RetentionDays $config.retentionDays `
                    -StateFile $stateFile `
                    -DiscoveredAgentIds $agentIds
                $script:lastCleanupDate = $today
                Write-CronAgentsLog -Level 'info' -Message 'Retention cleanup completed'
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Retention cleanup failed: $_"
            }
        }

        # -----------------------------------------------------------
        # Step 8: Sleep until next tick
        # -----------------------------------------------------------
        $agents = Get-AgentConfigs -RepoRoot $RepoRoot
        $state  = Get-AgentState -StateFile $stateFile
        $now    = (Get-Date).ToUniversalTime()
        $maxSleepSec = 3600  # Clamp to 1 hour max

        $nextDue = $null
        foreach ($agent in $agents) {
            $agentState = if ($state.agents.ContainsKey($agent.Id)) { $state.agents[$agent.Id] } else { $null }
            if ($agentState -and $agentState.enabled -eq $false) { continue }

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
}
