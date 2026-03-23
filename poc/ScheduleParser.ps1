<#
.SYNOPSIS
    POC — Validates the coarse sleep-loop wake mechanism for CronAgents.

.DESCRIPTION
    Proves that a single PowerShell loop can:
      1. Compute the next wake time from a set of coarse schedules
      2. Sleep precisely until that boundary (not polling every minute)
      3. Wake, identify which slots matched, then go back to sleep

    This file contains only the scheduling math. No agent invocation,
    no feedback, no dashboard — just the clock.

.NOTES
    The companion Install-CronAgents.ps1 handles reboot persistence via
    Windows Task Scheduler. This file handles what happens once the
    process is alive.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Get-NextWakeTime
#   Given a list of schedule slots, returns the earliest future boundary
#   the scheduler should sleep until.
# ---------------------------------------------------------------------------
function Get-NextWakeTime {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Schedules,       # array of @{ type; every/time/day }
        [Parameter(Mandatory=$true)]
        [hashtable]$State,             # @{ agentName = [datetime]lastRun }
        [Parameter(Mandatory=$true)]
        [datetime]$Now
    )

    $earliest = $null

    foreach ($s in $Schedules) {
        $name    = $s.name
        $lastRun = if ($State.ContainsKey($name)) { $State[$name] } else { $null }
        $next    = Get-NextSlotTime -Schedule $s -LastRun $lastRun -Now $Now

        if ($null -eq $earliest -or $next -lt $earliest) {
            $earliest = $next
        }
    }

    return $earliest
}

# ---------------------------------------------------------------------------
# Get-NextSlotTime
#   Pure function: given one schedule + its last run, returns the next
#   datetime that schedule becomes due.
# ---------------------------------------------------------------------------
function Get-NextSlotTime {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Schedule,
        $LastRun,            # [datetime] or $null
        [Parameter(Mandatory=$true)]
        [datetime]$Now
    )

    switch ($Schedule.type) {
        'interval' {
            $minutes = ConvertTo-Minutes $Schedule.every
            if ($null -eq $LastRun) { return $Now }
            $next = ([datetime]$LastRun).AddMinutes($minutes)
            if ($next -le $Now) { return $Now }
            return $next
        }
        'daily' {
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay
            $todaySlot = $Now.Date.Add($tod)
            if ($null -eq $LastRun -and $Now -ge $todaySlot) { return $Now }
            if ($null -ne $LastRun -and ([datetime]$LastRun) -ge $todaySlot) {
                return $todaySlot.AddDays(1)
            }
            if ($Now -lt $todaySlot) { return $todaySlot }
            return $Now
        }
        'weekly' {
            $targetDay = [System.DayOfWeek]$Schedule.day
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay

            # Days forward to the next occurrence of target day (0 = today)
            $daysForward = (($targetDay.value__ - $Now.DayOfWeek.value__ + 7) % 7)
            $nextSlot    = $Now.Date.AddDays($daysForward).Add($tod)

            # Slot is still in the future — return it
            if ($Now -lt $nextSlot) { return $nextSlot }

            # Slot is now or in the past (today is target day, time has passed)
            if ($null -eq $LastRun -or ([datetime]$LastRun) -lt $nextSlot) { return $Now }

            # Already ran this week's slot — next week
            return $nextSlot.AddDays(7)
        }
        default { throw "Unknown schedule type '$($Schedule.type)'." }
    }
}

# ---------------------------------------------------------------------------
# ConvertTo-Minutes  — parses "1h", "4h", "30m" into integer minutes
# ---------------------------------------------------------------------------
function ConvertTo-Minutes {
    param([Parameter(Mandatory=$true)][string]$Interval)

    if ($Interval -match '^\s*(\d+)\s*h\s*$') { return [int]$Matches[1] * 60 }
    if ($Interval -match '^\s*(\d+)\s*m\s*$') { return [int]$Matches[1] }
    throw "Invalid interval '$Interval'. Use '<N>h' or '<N>m'."
}

# ---------------------------------------------------------------------------
# Get-SleepSeconds  — how long to sleep from $Now until $WakeAt, clamped
# ---------------------------------------------------------------------------
function Get-SleepSeconds {
    param(
        [Parameter(Mandatory=$true)][datetime]$Now,
        [Parameter(Mandatory=$true)][datetime]$WakeAt,
        [int]$MaxSeconds = 3600   # cap at 1 hour to re-check periodically
    )

    $delta = ($WakeAt - $Now).TotalSeconds
    if ($delta -le 0) { return 0 }
    return [Math]::Min([int][Math]::Ceiling($delta), $MaxSeconds)
}
