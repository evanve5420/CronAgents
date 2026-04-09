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

        # Validate the process command line actually matches the scheduler
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue).CommandLine
        }
        catch { return $false }

        return ($cmdLine -and $cmdLine -match 'Start-CronAgents\.ps1')
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

        $schedule = @{ type = $agent.Config.schedule.type }
        if ($agent.Config.schedule.PSObject.Properties['every']) { $schedule['every'] = $agent.Config.schedule.every }
        if ($agent.Config.schedule.PSObject.Properties['time'])  { $schedule['time']  = $agent.Config.schedule.time }
        if ($agent.Config.schedule.PSObject.Properties['day'])   { $schedule['day']   = $agent.Config.schedule.day }

        if (Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $Now) {
            $overdue.Add($agent.Id)
        }
    }

    return @($overdue)
}
