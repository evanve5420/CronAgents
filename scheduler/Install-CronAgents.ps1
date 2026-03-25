<#
.SYNOPSIS
    Registers the CronAgents at-logon Task Scheduler entry and bootstraps the user branch.

.DESCRIPTION
    Creates (or updates) a Windows Task Scheduler task that launches the CronAgents
    scheduler at user logon. The task runs as the current user with no elevation.
    Also initialises the per-user git branch used for agent feedback.

    Safe to run multiple times — idempotent by design.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER TaskName
    Name of the scheduled task. Should not be changed.

.PARAMETER TaskPath
    Task Scheduler folder path. Should not be changed.

.PARAMETER Force
    Re-register the task even if an up-to-date definition already exists.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TaskName = 'CronAgents',
    [string]$TaskPath = '\CronAgents\',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Module & config ──────────────────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot 'lib/CronAgents.psd1') -Force

$config = Import-CronAgentsConfig
$versioningEnabled = Test-CronAgentsVersioningEnabled -Config $config

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# ── Resolve scheduler script ────────────────────────────────────────
$schedulerScript = Join-Path $PSScriptRoot 'Start-CronAgents.ps1'
if (-not (Test-Path $schedulerScript)) {
    Write-Error "Scheduler script not found: $schedulerScript"
    return
}

# ── Resolve PowerShell executable ────────────────────────────────────
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshPath) {
    $pwshPath = (Get-Command powershell -ErrorAction Stop).Source
}

# ── Build expected task definition pieces ────────────────────────────
$expectedArgs = "-NoProfile -WindowStyle Hidden -File `"$schedulerScript`""

$action = New-ScheduledTaskAction `
    -Execute  $pwshPath `
    -Argument $expectedArgs `
    -WorkingDirectory $RepoRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

$principal = New-ScheduledTaskPrincipal `
    -UserId   $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$taskDescription = 'CronAgents — runs scheduled Copilot agents at logon.'

# ── Helper: compare existing task against expected definition ────────
function Test-TaskCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Task)

    $act = $Task.Actions | Select-Object -First 1
    if (-not $act) { return $false }

    if ($act.Execute    -ne $pwshPath)      { return $false }
    if ($act.Arguments  -ne $expectedArgs)  { return $false }

    $wd = $act.WorkingDirectory.TrimEnd('\')
    if ($wd -ne $RepoRoot.TrimEnd('\'))     { return $false }

    return $true
}

# ── Check for existing task ──────────────────────────────────────────
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

if ($existing) {
    if ((Test-TaskCurrent $existing) -and -not $Force) {
        Write-Host "Task already registered. No changes needed."
        Write-CronAgentsLog -Level 'info' -Message "Install: task '$TaskPath$TaskName' already up-to-date."
    }
    else {
        $reason = if ($Force) { 'Force flag set' } else { 'stale definition detected' }
        Write-Host "Updating task ($reason)..."
        Write-CronAgentsLog -Level 'info' -Message "Install: updating task '$TaskPath$TaskName' — $reason."

        if ($existing.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
        }
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false

        Register-ScheduledTask `
            -TaskName    $TaskName `
            -TaskPath    $TaskPath `
            -Action      $action `
            -Trigger     $trigger `
            -Settings    $settings `
            -Principal   $principal `
            -Description $taskDescription | Out-Null

        Write-Host "Task '$TaskPath$TaskName' updated."
    }
}
else {
    Write-CronAgentsLog -Level 'info' -Message "Install: registering new task '$TaskPath$TaskName'."

    Register-ScheduledTask `
        -TaskName    $TaskName `
        -TaskPath    $TaskPath `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -Principal   $principal `
        -Description $taskDescription | Out-Null

    Write-Host "Registered task '$TaskPath$TaskName'."
}

# ── Warn about unexpected tasks under the same folder ────────────────
$allTasks = Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue
$unexpected = $allTasks | Where-Object { $_.TaskName -ne $TaskName }
if ($unexpected) {
    foreach ($t in $unexpected) {
        Write-Warning "Unexpected task found under ${TaskPath}: '$($t.TaskName)'. This may conflict with CronAgents."
    }
}

# ── Bootstrap user branch ────────────────────────────────────────────
if ($versioningEnabled) {
    $branchPrefix = $config.versioning.branchPrefix
    $userName = Resolve-CronAgentsUserName -ConfigUserName $config.versioning.userName -RepoRoot $RepoRoot
    $branchResult = Initialize-UserBranch -RepoRoot $RepoRoot -BranchPrefix $branchPrefix -UserName $userName

    Write-CronAgentsLog -Level 'info' -Message "Install: user branch '$($branchResult.BranchName)' — created=$($branchResult.Created)."
}
else {
    $branchResult = [PSCustomObject]@{
        BranchName = '(unchanged; versioning disabled)'
        Created    = $false
        Message    = 'Git versioning is disabled in cronagents.json.'
    }
    Write-CronAgentsLog -Level 'info' -Message 'Install: skipped user branch bootstrap because git versioning is disabled.'
}

# ── Summary ──────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Task path  : ' -NoNewline; Write-Host "$TaskPath$TaskName"
Write-Host '  Trigger    : ' -NoNewline; Write-Host "At logon ($env:USERNAME)"
Write-Host '  Scheduler  : ' -NoNewline; Write-Host $schedulerScript
Write-Host '  Branch     : ' -NoNewline; Write-Host $branchResult.BranchName
Write-Host ''
Write-Host "To start now:  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
