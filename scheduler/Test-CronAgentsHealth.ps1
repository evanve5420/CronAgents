<#
.SYNOPSIS
    Health check module for CronAgents — used by `cronagents.ps1 doctor`.

.DESCRIPTION
    Runs a suite of diagnostic checks against the CronAgents installation
    and returns a structured result with per-check status (Pass/Warn/Fail).
    Designed for both interactive (console) and programmatic (CLI wrapper) use.

.OUTPUTS
    PSCustomObject with Overall, Checks, PassCount, WarnCount, FailCount.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TaskName = 'CronAgents',
    [string]$TaskPath = '\CronAgents\',
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve repo root ---
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# --- Import shared module ---
Import-Module (Join-Path $PSScriptRoot 'lib\CronAgents.psd1') -Force

# --- Helper: create a check result ---
function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    [PSCustomObject]@{
        Name    = $Name
        Status  = $Status
        Message = $Message
    }
}

# ===================================================================
# Check 1: Task Scheduler
# ===================================================================
function Test-TaskScheduler {
    param([string]$TaskName, [string]$TaskPath)

    try {
        $tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)

        if ($tasks.Count -eq 0) {
            return New-CheckResult -Name 'Task Scheduler' -Status 'Warn' `
                -Message 'No tasks registered (not installed)'
        }

        $matching = @($tasks | Where-Object { $_.TaskName -eq $TaskName })

        if ($matching.Count -gt 1) {
            return New-CheckResult -Name 'Task Scheduler' -Status 'Fail' `
                -Message "$($matching.Count) duplicate tasks found (accumulation bug)"
        }

        if ($matching.Count -eq 0) {
            $found = ($tasks | ForEach-Object { $_.TaskName }) -join ', '
            return New-CheckResult -Name 'Task Scheduler' -Status 'Fail' `
                -Message "No task named '$TaskName' under $TaskPath (found: $found)"
        }

        $task = $matching[0]

        # Validate the task action points at a PowerShell script
        $actions = @($task.Actions)
        $valid = $false
        foreach ($action in $actions) {
            if ($action.Arguments -and $action.Arguments -match 'Start-CronAgents\.ps1') {
                $valid = $true
                break
            }
        }

        if (-not $valid) {
            return New-CheckResult -Name 'Task Scheduler' -Status 'Fail' `
                -Message "Task definition does not reference Start-CronAgents.ps1"
        }

        # Validate trigger exists
        $triggers = @($task.Triggers)
        if ($triggers.Count -eq 0) {
            return New-CheckResult -Name 'Task Scheduler' -Status 'Fail' `
                -Message 'Task has no triggers defined'
        }

        # Validate both logon and periodic triggers are present
        $hasLogon = $triggers | Where-Object {
            $_ -is [CimInstance] -and $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
        }
        # Require a time trigger so a repeating logon trigger does not satisfy the watchdog check.
        # PT15M must match the interval in Install-CronAgents.ps1 ($periodicTrigger).
        $hasPeriodic = $triggers | Where-Object {
            $_ -is [CimInstance] -and
            $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' -and
            $_.Repetition -and
            $_.Repetition.Interval -eq 'PT15M'
        }

        if (-not $hasLogon -or -not $hasPeriodic) {
            $missing = @()
            if (-not $hasLogon)    { $missing += 'logon' }
            if (-not $hasPeriodic) { $missing += 'periodic (15-min watchdog)' }
            return New-CheckResult -Name 'Task Scheduler' -Status 'Fail' `
                -Message "Missing trigger(s): $($missing -join ', '). Re-run Install-CronAgents.ps1 to fix."
        }

        return New-CheckResult -Name 'Task Scheduler' -Status 'Pass' `
            -Message '1 task registered, definition and triggers match'
    }
    catch {
        return New-CheckResult -Name 'Task Scheduler' -Status 'Warn' `
            -Message "Could not query Task Scheduler: $_"
    }
}

# ===================================================================
# Check 2: Global Config
# ===================================================================
function Test-GlobalConfig {
    param([string]$RepoRoot)

    try {
        $configPath = Join-Path $RepoRoot 'cronagents.json'
        $null = Import-CronAgentsConfig -ConfigPath $configPath
        return New-CheckResult -Name 'Global Config' -Status 'Pass' `
            -Message 'Valid (cronagents.json)'
    }
    catch {
        return New-CheckResult -Name 'Global Config' -Status 'Fail' `
            -Message "$_"
    }
}

# ===================================================================
# Check 3: Agent Configs
# ===================================================================
function Test-AgentConfigs {
    param([string]$RepoRoot, [string]$PersonalRepoPath)

    try {
        $agents = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)

        if ($agents.Count -eq 0) {
            $locations = @("$RepoRoot\.cronagents\agents\")
            if ($PersonalRepoPath) { $locations += "$PersonalRepoPath\.cronagents\agents\" }
            $scanned = $locations -join ', '
            return New-CheckResult -Name 'Agent Configs' -Status 'Warn' `
                -Message "No agents discovered in: $scanned"
        }

        # Check for agents that reference .agent.md files that don't exist
        $warnings = @()
        foreach ($agent in $agents) {
            if ($agent.Config.PSObject.Properties['agent'] -and
                $agent.Config.agent -and
                -not $agent.AgentFilePath) {
                $warnings += "Agent '$($agent.Id)' references missing .agent.md"
            }
        }

        if ($warnings.Count -gt 0) {
            $detail = "$($agents.Count) agents discovered; $($warnings -join '; ')"
            return New-CheckResult -Name 'Agent Configs' -Status 'Warn' `
                -Message $detail
        }

        return New-CheckResult -Name 'Agent Configs' -Status 'Pass' `
            -Message "$($agents.Count) agents discovered, all valid"
    }
    catch {
        return New-CheckResult -Name 'Agent Configs' -Status 'Fail' `
            -Message "$_"
    }
}

# ===================================================================
# Check 4: State File
# ===================================================================
function Test-StateFile {
    param([string]$StateRoot)

    try {
        $stateFile = Join-Path $StateRoot 'state.json'

        if (-not (Test-Path $stateFile)) {
            return New-CheckResult -Name 'State File' -Status 'Warn' `
                -Message 'File does not exist (will be created on first run)'
        }

        $raw = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json

        # Validate expected schema fields
        $hasVersion = $null -ne $parsed.PSObject.Properties['schemaVersion']
        $hasPaused  = $null -ne $parsed.PSObject.Properties['schedulerPaused']
        $hasAgents  = $null -ne $parsed.PSObject.Properties['agents']

        if (-not $hasVersion -or -not $hasPaused -or -not $hasAgents) {
            $missing = @()
            if (-not $hasVersion) { $missing += 'schemaVersion' }
            if (-not $hasPaused)  { $missing += 'schedulerPaused' }
            if (-not $hasAgents)  { $missing += 'agents' }
            return New-CheckResult -Name 'State File' -Status 'Fail' `
                -Message "Missing required fields: $($missing -join ', ')"
        }

        return New-CheckResult -Name 'State File' -Status 'Pass' `
            -Message 'Valid (.cronstate/state.json)'
    }
    catch {
        return New-CheckResult -Name 'State File' -Status 'Fail' `
            -Message "Corrupted or unreadable: $_"
    }
}

# ===================================================================
# Check 5: Scheduler Process
# ===================================================================
function Test-SchedulerProcess {
    try {
        $running = Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                    $cmdLine -and $cmdLine -match 'Start-CronAgents\.ps1'
                }
                catch { $false }
            }

        if ($running) {
            $count = @($running).Count
            return New-CheckResult -Name 'Scheduler Process' -Status 'Pass' `
                -Message "Running ($count process$(if ($count -ne 1) { 'es' }))"
        }

        return New-CheckResult -Name 'Scheduler Process' -Status 'Warn' `
            -Message 'Not running'
    }
    catch {
        return New-CheckResult -Name 'Scheduler Process' -Status 'Warn' `
            -Message "Could not query processes: $_"
    }
}

# ===================================================================
# Check 6: Orphaned Runs
# ===================================================================
function Test-OrphanedRuns {
    param(
        [string]$RepoRoot,
        [string]$PersonalRepoPath,
        [string]$RunsRoot
    )

    try {
        if (-not (Test-Path $runsRoot)) {
            return New-CheckResult -Name 'Run Directories' -Status 'Pass' `
                -Message 'No run directory yet'
        }

        # Get known agent IDs
        $knownIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        try {
            $agents = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
            foreach ($a in $agents) { [void]$knownIds.Add($a.Id) }
        }
        catch { }

        # Scan run directories for agent IDs
        $runDirs = Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(\d{8}T\d{6})_(.+)_([0-9a-f]{4})$' }

        $orphanedIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($dir in $runDirs) {
            if ($dir.Name -match '^(\d{8}T\d{6})_(.+)_([0-9a-f]{4})$') {
                $agentId = $Matches[2]
                if ($knownIds.Count -gt 0 -and -not $knownIds.Contains($agentId)) {
                    [void]$orphanedIds.Add($agentId)
                }
            }
        }

        if ($orphanedIds.Count -gt 0) {
            $list = ($orphanedIds | Sort-Object) -join ', '
            return New-CheckResult -Name 'Run Directories' -Status 'Warn' `
                -Message "Found orphaned runs for: $list"
        }

        return New-CheckResult -Name 'Run Directories' -Status 'Pass' `
            -Message 'No orphaned runs'
    }
    catch {
        return New-CheckResult -Name 'Run Directories' -Status 'Warn' `
            -Message "Could not check run directories: $_"
    }
}

# ===================================================================
# Check 7: Notification Backend
# ===================================================================
function Test-NotificationBackend {
    param([string]$RepoRoot)

    try {
        $configPath = Join-Path $RepoRoot 'cronagents.json'
        $cfg = Import-CronAgentsConfig -ConfigPath $configPath
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Notification health check: config parse failed: $_"
        $cfg = [PSCustomObject]@{ notifications = $true }
    }

    if ($cfg.PSObject.Properties['notifications'] -and $cfg.notifications -eq $false) {
        return New-CheckResult -Name 'Notifications' -Status 'Pass' `
            -Message 'Disabled globally (notifications: false)'
    }

    $backend = Resolve-NotificationBackend

    switch ($backend) {
        'BurntToast' {
            return New-CheckResult -Name 'Notifications' -Status 'Pass' `
                -Message 'BurntToast module available'
        }
        'Native' {
            return New-CheckResult -Name 'Notifications' -Status 'Pass' `
                -Message 'Native Windows.UI.Notifications available (BurntToast recommended for richer toasts)'
        }
        default {
            return New-CheckResult -Name 'Notifications' -Status 'Warn' `
                -Message 'No notification backend available. Install BurntToast: Install-Module BurntToast -Scope CurrentUser'
        }
    }
}

# ===================================================================
# Run all checks
# ===================================================================
[System.Collections.Generic.List[PSCustomObject]]$checks = @()

$checks.Add((Test-TaskScheduler -TaskName $TaskName -TaskPath $TaskPath))
$checks.Add((Test-GlobalConfig -RepoRoot $RepoRoot))

$personalRepoPath = $null
try {
    $healthConfig = Import-CronAgentsConfig -ConfigPath (Join-Path $RepoRoot 'cronagents.json')
    if ($healthConfig.PSObject.Properties['personalRepo'] -and
        $null -ne $healthConfig.personalRepo -and
        $healthConfig.personalRepo.PSObject.Properties['path'] -and
        -not [string]::IsNullOrWhiteSpace($healthConfig.personalRepo.path)) {
        $personalRepoPath = Get-PersonalRepoPath -ConfigPath $healthConfig.personalRepo.path
    }
}
catch {
    $personalRepoPath = $null
}

$stateRoot = if ($personalRepoPath) {
    Join-Path $personalRepoPath '.cronstate'
} else {
    Join-Path $RepoRoot '.cronstate'
}
$runsRoot = Join-Path $stateRoot 'runs'

$checks.Add((Test-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath))
$checks.Add((Test-StateFile -StateRoot $stateRoot))
$checks.Add((Test-SchedulerProcess))
$checks.Add((Test-OrphanedRuns -RepoRoot $RepoRoot -PersonalRepoPath $personalRepoPath -RunsRoot $runsRoot))
$checks.Add((Test-NotificationBackend -RepoRoot $RepoRoot))

# ===================================================================
# Compute summary
# ===================================================================
$passCount = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
$warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
$failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count

$overall = if ($failCount -gt 0) { 'Unhealthy' }
           elseif ($warnCount -gt 0) { 'Warning' }
           else { 'Healthy' }

# ===================================================================
# Console output
# ===================================================================
$statusIcon = @{
    Pass = @{ Icon = [char]0x2705; Color = 'Green'  }
    Warn = @{ Icon = [char]0x26A0; Color = 'Yellow' }
    Fail = @{ Icon = [char]0x274C; Color = 'Red'    }
}

Write-Host ''
Write-Host 'CronAgents Health Check' -ForegroundColor Cyan
Write-Host ([string]::new([char]0x2550, 23)) -ForegroundColor Cyan
Write-Host ''

foreach ($check in $checks) {
    $icon  = $statusIcon[$check.Status]
    $label = $check.Name.PadRight(20)
    Write-Host "  $($icon.Icon) " -NoNewline -ForegroundColor $icon.Color
    Write-Host "$label" -NoNewline -ForegroundColor $icon.Color
    Write-Host " $([char]0x2014) $($check.Message)"
}

Write-Host ''
$summaryColor = switch ($overall) {
    'Healthy'   { 'Green'  }
    'Warning'   { 'Yellow' }
    'Unhealthy' { 'Red'    }
}
Write-Host "Overall: " -NoNewline
Write-Host "$passCount pass, $warnCount warn, $failCount fail" -ForegroundColor $summaryColor
Write-Host ''

# ===================================================================
# Structured return value
# ===================================================================
return [PSCustomObject]@{
    Overall   = $overall
    Checks    = @($checks)
    PassCount = $passCount
    WarnCount = $warnCount
    FailCount = $failCount
}
