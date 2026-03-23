<#
.SYNOPSIS
    Removes the CronAgents scheduled task.

.DESCRIPTION
    Stops and unregisters the CronAgents at-logon Task Scheduler entry.
    Safe to run even when the task does not exist.

.PARAMETER TaskName
    Name of the scheduled task. Should not be changed.

.PARAMETER TaskPath
    Task Scheduler folder path. Should not be changed.
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'CronAgents',
    [string]$TaskPath = '\CronAgents\'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Check for existing task ──────────────────────────────────────────
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

if (-not $existing) {
    Write-Host "Task not found. Nothing to remove."
    return
}

# ── Stop if running ──────────────────────────────────────────────────
if ($existing.State -eq 'Running') {
    Write-Host "Stopping running task..."
    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
}

# ── Unregister ───────────────────────────────────────────────────────
Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false

Write-Host "Removed task '$TaskPath$TaskName'."
