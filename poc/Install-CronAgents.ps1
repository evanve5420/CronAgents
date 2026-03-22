<#
.SYNOPSIS
    POC — Validates that a Windows Task Scheduler at-logon entry can
    persist a PowerShell process across reboots.

.DESCRIPTION
    Registers one scheduled task that:
      - Triggers at logon for the current user
      - Launches a target .ps1 as a background process
      - Does NOT require admin/elevated privileges
      - Can be removed cleanly via Uninstall-CronAgents.ps1

    This POC proves the reboot-persistence mechanism only.
    It does not contain any agent, feedback, or dashboard logic.

.NOTES
    POC — cron persistence validation only.
#>

[CmdletBinding()]
param(
    [string]$SchedulerScript = (Join-Path $PSScriptRoot 'Start-CronAgents.ps1'),
    [string]$TaskName        = 'CronAgents',
    [string]$TaskPath        = '\CronAgents\',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Validate ---
if (-not (Test-Path $SchedulerScript)) {
    Write-Error "Scheduler script not found: $SchedulerScript"
    return
}

# --- Check for existing task ---
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Warning "Task '$TaskPath$TaskName' already exists. Use -Force to overwrite."
    return
}

# --- Build task components ---

# Action: launch pwsh (PowerShell 7+) running our scheduler script, hidden window
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshPath) {
    $pwshPath = (Get-Command powershell).Source   # fallback to Windows PowerShell
}

$action = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument "-NoProfile -WindowStyle Hidden -File `"$SchedulerScript`"" `
    -WorkingDirectory (Split-Path $SchedulerScript)

# Trigger: at logon for the current user
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Settings: allow running on battery, don't stop on idle, restart on failure
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)   # no time limit — long-running

# Principal: current user, no elevation required
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# --- Register ---
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
}

Register-ScheduledTask `
    -TaskName  $TaskName `
    -TaskPath  $TaskPath `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Description 'CronAgents POC — validates at-logon persistence for a long-running PowerShell process.'

Write-Host "Registered task '$TaskPath$TaskName'. Scheduler will start at next logon."
Write-Host "To start immediately: Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
