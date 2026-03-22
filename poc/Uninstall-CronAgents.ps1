<#
.SYNOPSIS
    POC — Removes the CronAgents test task registered by Install-CronAgents.ps1.
    Cron persistence validation only.
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'CronAgents',
    [string]$TaskPath = '\CronAgents\'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "Task '$TaskPath$TaskName' does not exist. Nothing to remove."
    return
}

# Stop if running
if ($existing.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
}

Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
Write-Host "Removed task '$TaskPath$TaskName'."
