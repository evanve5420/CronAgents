Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# ConvertTo-Minutes — parses "1h", "4h", "30m" into integer minutes
# ---------------------------------------------------------------------------
function ConvertTo-Minutes {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Duration
    )

    if ($Duration -match '^\s*(\d+)\s*h\s*$') { return [int]$Matches[1] * 60 }
    if ($Duration -match '^\s*(\d+)\s*m\s*$') { return [int]$Matches[1] }
    throw "Invalid duration '$Duration'. Use '<N>h' or '<N>m'."
}

# ---------------------------------------------------------------------------
# ConvertTo-Seconds — parses "1h", "10m", "30s", bare number, or "0"
#   Bare numbers are treated as minutes for backward compatibility.
# ---------------------------------------------------------------------------
function ConvertTo-Seconds {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Duration
    )

    if ($Duration -match '^\s*(\d+)\s*h\s*$') { return [int]$Matches[1] * 3600 }
    if ($Duration -match '^\s*(\d+)\s*m\s*$') { return [int]$Matches[1] * 60 }
    if ($Duration -match '^\s*(\d+)\s*s\s*$') { return [int]$Matches[1] }
    if ($Duration -match '^\s*(\d+)\s*$') {
        $value = [int]$Matches[1]
        if ($value -eq 0) { return 0 }
        # Bare number = minutes for backward compat
        return $value * 60
    }
    throw "Invalid duration '$Duration'. Use '<N>h', '<N>m', '<N>s', or a bare number (minutes)."
}

# ---------------------------------------------------------------------------
# Test-AgentDue — returns $true if an agent should run now
# ---------------------------------------------------------------------------
function Test-AgentDue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [hashtable]$Schedule,

        [AllowNull()]
        [Nullable[datetime]]$LastRun,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    # Manual-only agents (no schedule) are never auto-due
    if ($null -eq $Schedule) { return $false }

    switch ($Schedule.type) {
        'interval' {
            $minutes = ConvertTo-Minutes $Schedule.every
            if ($null -eq $LastRun) { return $true }
            $elapsed = ($Now - [datetime]$LastRun).TotalMinutes
            return ($elapsed -ge $minutes)
        }
        'daily' {
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay
            $todaySlot = $Now.Date.Add($tod)

            if ($null -eq $LastRun) {
                return ($Now -ge $todaySlot)
            }
            # Due if last run was before today's slot and we've reached it
            return (([datetime]$LastRun) -lt $todaySlot -and $Now -ge $todaySlot)
        }
        'weekly' {
            $targetDay = [System.DayOfWeek]$Schedule.day
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay

            # Is today the target day?
            if ($Now.DayOfWeek -ne $targetDay) { return $false }

            $todaySlot = $Now.Date.Add($tod)
            if ($Now -lt $todaySlot) { return $false }

            if ($null -eq $LastRun) { return $true }
            # Due if last run was before this week's slot
            return (([datetime]$LastRun) -lt $todaySlot)
        }
        default { throw "Unknown schedule type '$($Schedule.type)'." }
    }
}

# ---------------------------------------------------------------------------
# Get-NextRunTime — returns the next datetime the agent will be due
# ---------------------------------------------------------------------------
function Get-NextRunTime {
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param(
        [AllowNull()]
        [hashtable]$Schedule,

        [AllowNull()]
        [Nullable[datetime]]$LastRun,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    # Manual-only agents have no next scheduled run
    if ($null -eq $Schedule) { return $null }

    switch ($Schedule.type) {
        'interval' {
            $minutes = ConvertTo-Minutes $Schedule.every
            if ($null -eq $LastRun) { return $Now }
            $next = ([datetime]$LastRun).AddMinutes($minutes)
            if ($next -gt $Now) { return $next }
            return $Now
        }
        'daily' {
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay
            $todaySlot = $Now.Date.Add($tod)

            if ($null -eq $LastRun) {
                if ($Now -ge $todaySlot) { return $Now }
                return $todaySlot
            }
            if (([datetime]$LastRun) -ge $todaySlot) {
                return $todaySlot.AddDays(1)
            }
            if ($Now -lt $todaySlot) { return $todaySlot }
            return $Now
        }
        'weekly' {
            $targetDay = [System.DayOfWeek]$Schedule.day
            $tod       = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay

            $daysForward = (($targetDay.value__ - $Now.DayOfWeek.value__ + 7) % 7)
            $nextSlot    = $Now.Date.AddDays($daysForward).Add($tod)

            # Slot is still in the future
            if ($Now -lt $nextSlot) { return $nextSlot }

            # Slot is now or past — never run or not run this week
            if ($null -eq $LastRun -or ([datetime]$LastRun) -lt $nextSlot) { return $Now }

            # Already ran this week's slot — next week
            return $nextSlot.AddDays(7)
        }
        default { throw "Unknown schedule type '$($Schedule.type)'." }
    }
}
