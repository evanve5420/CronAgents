<#
.SYNOPSIS
    Registers the CronAgents at-logon Task Scheduler entry and bootstraps the user branch.

.DESCRIPTION
    Creates (or updates) a Windows Task Scheduler task that launches the CronAgents
    scheduler at user logon. The task runs as the current user with no elevation.
    Also initialises the personal repo (~/.cronagents) used for agent state and feedback.

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

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Periodic trigger — restarts the scheduler every 15 minutes so it
# auto-recovers from crashes without waiting for the next logon.
# The scheduler itself guards against duplicate instances.
$periodicTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15)

$trigger = @($logonTrigger, $periodicTrigger)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

$principal = New-ScheduledTaskPrincipal `
    -UserId   $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$taskDescription = 'CronAgents — runs scheduled Copilot agents at logon and every 15 minutes for crash recovery.'

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

# ── Initialize personal repo ─────────────────────────────────────────
$personalRepoPath = Get-PersonalRepoPath -ConfigPath $config.personalRepo.path
$userName = Resolve-CronAgentsUserName -ConfigUserName $config.personalRepo.userName -RepoRoot $RepoRoot
$repoResult = Initialize-PersonalRepo -Path $personalRepoPath -UserName $userName -InfraRepoRoot $RepoRoot
Write-CronAgentsLog -Level 'info' -Message "Install: personal repo '$personalRepoPath' — created=$($repoResult.Created)."

# ── Summary ──────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Task path    : ' -NoNewline; Write-Host "$TaskPath$TaskName"
Write-Host '  Trigger      : ' -NoNewline; Write-Host "At logon ($env:USERNAME) + every 15 min"
Write-Host '  Scheduler    : ' -NoNewline; Write-Host $schedulerScript
Write-Host '  Personal repo: ' -NoNewline; Write-Host $personalRepoPath
Write-Host ''
Write-Host "To start now:  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"

# ── Offer BurntToast installation ────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name 'BurntToast' -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host 'BurntToast module is not installed.' -ForegroundColor Yellow
    Write-Host 'BurntToast enables rich Windows toast notifications for agent failures'
    Write-Host 'and scheduler errors. Without it, CronAgents will try the native Windows'
    Write-Host 'notification API and silently degrade if neither is available.'
    Write-Host ''

    $response = Read-Host 'Install BurntToast from the PowerShell Gallery? (Y/n)'
    if ($response -match '^(y(es)?)?$') {
        try {
            Write-Host 'Installing BurntToast...' -ForegroundColor Cyan
            Install-Module BurntToast -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host 'BurntToast installed successfully.' -ForegroundColor Green
            Write-CronAgentsLog -Level 'info' -Message 'Install: BurntToast module installed.'
        }
        catch {
            Write-Host "BurntToast installation failed: $_" -ForegroundColor Yellow
            Write-Host 'You can install it later with: Install-Module BurntToast -Scope CurrentUser'
            Write-CronAgentsLog -Level 'warn' -Message "Install: BurntToast installation failed: $_"
        }
    }
    else {
        Write-Host 'Skipped. You can install later with: Install-Module BurntToast -Scope CurrentUser'
    }
}
else {
    Write-Host ''
    Write-Host '  Notifications: BurntToast module available' -ForegroundColor Green
}
