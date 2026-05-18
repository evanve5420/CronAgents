Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-OnBatteryPower {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if (-not $battery) { return $false }
        # BatteryStatus 1 = Discharging (on battery)
        return ($battery.BatteryStatus -eq 1)
    }
    catch {
        return $false
    }
}

function Test-SchedulerRunning {
    <#
    .SYNOPSIS
        Checks whether the CronAgents scheduler process is alive by
        validating the PID file against running processes.
    .PARAMETER PidFilePath
        Path to the scheduler.pid JSON file.
    .PARAMETER ExcludePid
        Optional PID to exclude (the caller's own PID, to avoid
        self-detection during single-instance guard).
    .OUTPUTS
        $true if a live scheduler process was found; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PidFilePath,
        [int]$ExcludePid = 0
    )

    if (-not (Test-Path -LiteralPath $PidFilePath)) { return $false }

    try {
        $pidData = Get-Content -LiteralPath $PidFilePath -Raw | ConvertFrom-Json
        if (-not $pidData.pid) { return $false }

        $targetPid = [int]$pidData.pid
        if ($ExcludePid -gt 0 -and $targetPid -eq $ExcludePid) { return $false }

        $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if (-not $proc) { return $false }

        # Cross-platform validation: confirm the PID file's startedAt
        # matches the running process start time within a small tolerance.
        # This ensures the PID hasn't been recycled to a different process.
        if ($pidData.PSObject.Properties.Name -contains 'startedAt' -and $pidData.startedAt) {
            try {
                # ConvertFrom-Json may auto-parse the ISO datetime string to
                # a [datetime] with Kind=Local, so normalise both to UTC.
                $startedAt = if ($pidData.startedAt -is [datetime]) {
                    $pidData.startedAt.ToUniversalTime()
                } else {
                    [datetime]::Parse($pidData.startedAt).ToUniversalTime()
                }
                $procStartUtc = $proc.StartTime.ToUniversalTime()
                $driftSeconds = [math]::Abs(($procStartUtc - $startedAt).TotalSeconds)
                if ($driftSeconds -gt 5) { return $false }
            }
            catch {
                Write-CronAgentsLog -Level 'debug' -Message "Could not compare scheduler start time for PID $targetPid from '$PidFilePath': $_"
            }
        }

        # Windows-only enhancement: verify command line matches the scheduler.
        # Not required on non-Windows or when command line cannot be read.
        $isWindowsPlatform = if (Test-Path variable:IsWindows) { $IsWindows } else { $true }
        if ($isWindowsPlatform) {
            $cmdLine = $null
            try {
                $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue).CommandLine
            }
            catch { <# best-effort only #> }

            if ($cmdLine) {
                return ($cmdLine -match 'Start-CronAgents\.ps1')
            }
        }

        return $true
    }
    catch {
        Write-CronAgentsLog -Level 'debug' -Message "Could not validate PID file '$PidFilePath': $_"
        return $false
    }
}

function Get-OverdueAgents {
    <#
    .SYNOPSIS
        Returns agent IDs that are overdue based on their schedule and
        last-run state. Used for recovery detection on startup.
    .PARAMETER RepoRoot
        Repository root path for discovering agents.
    .PARAMETER PersonalRepoPath
        Personal repo path for discovering agents.
    .PARAMETER StateFile
        Path to the state.json file.
    .PARAMETER Now
        Current UTC time to evaluate schedules against.
    .OUTPUTS
        Array of agent ID strings that are currently overdue.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$PersonalRepoPath,
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][datetime]$Now
    )

    $agents = Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath
    $state  = Get-AgentState -StateFile $StateFile

    [System.Collections.Generic.List[string]]$overdue = @()
    foreach ($agent in $agents) {
        if ($null -eq $agent.Config.schedule) { continue }

        $agentState = if ($state.agents.ContainsKey($agent.Id)) { $state.agents[$agent.Id] } else { $null }
        if ($agentState -and $agentState.enabled -eq $false) { continue }

        $lastRun = $null
        if ($agentState -and $agentState.lastRun) {
            try { $lastRun = [datetime]::Parse($agentState.lastRun) } catch { }
        }

        $schedule = ConvertTo-ScheduleHashtable -Schedule $agent.Config.schedule

        if (Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $Now) {
            $overdue.Add($agent.Id)
        }
    }

    return @($overdue)
}
