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

function Test-ScheduleMember {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        $Schedule,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Schedule -is [hashtable]) {
        return $Schedule.ContainsKey($Name)
    }
    return ($null -ne $Schedule.PSObject.Properties[$Name])
}

function Get-ScheduleMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Schedule,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Schedule -is [hashtable]) {
        return $Schedule[$Name]
    }
    return $Schedule.PSObject.Properties[$Name].Value
}

function ConvertTo-ScheduleHashtable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        $Schedule
    )

    if ($null -eq $Schedule) { return $null }

    $ht = @{ type = (Get-ScheduleMember -Schedule $Schedule -Name 'type') }
    foreach ($name in @('every', 'time', 'day', 'days')) {
        if (Test-ScheduleMember -Schedule $Schedule -Name $name) {
            $ht[$name] = Get-ScheduleMember -Schedule $Schedule -Name $name
        }
    }
    return $ht
}

function Format-Schedule {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Schedule
    )

    if ($null -eq $Schedule) { return 'manual' }
    $type = Get-ScheduleMember -Schedule $Schedule -Name 'type'
    switch ($type) {
        'interval' { return "every $(Get-ScheduleMember -Schedule $Schedule -Name 'every')" }
        'daily'    { return "daily at $(Get-ScheduleMember -Schedule $Schedule -Name 'time')" }
        'weekly'   {
            $time = Get-ScheduleMember -Schedule $Schedule -Name 'time'
            if (Test-ScheduleMember -Schedule $Schedule -Name 'days') {
                $days = @((Get-ScheduleMember -Schedule $Schedule -Name 'days') | ForEach-Object { [string]$_ })
                return "weekly $($days -join ', ') at $time"
            }
            return "$(Get-ScheduleMember -Schedule $Schedule -Name 'day') at $time"
        }
        default { return [string]$type }
    }
}

function Get-WeeklyScheduleDays {
    [CmdletBinding()]
    [OutputType([System.DayOfWeek[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Schedule
    )

    $dayValues = @(
        if (Test-ScheduleMember -Schedule $Schedule -Name 'days') {
            Get-ScheduleMember -Schedule $Schedule -Name 'days'
        }
        elseif (Test-ScheduleMember -Schedule $Schedule -Name 'day') {
            Get-ScheduleMember -Schedule $Schedule -Name 'day'
        }
        else {
            throw "Weekly schedule requires 'day' or 'days'."
        }
    )

    if ($dayValues.Count -eq 0) {
        throw "Weekly schedule 'days' must contain at least one day."
    }

    $days = [System.Collections.Generic.List[System.DayOfWeek]]::new()
    foreach ($day in $dayValues) {
        if ([string]::IsNullOrWhiteSpace([string]$day)) {
            throw "Weekly schedule contains an empty day."
        }
        try {
            $days.Add([System.DayOfWeek]([string]$day))
        }
        catch {
            throw "Invalid weekly schedule day '$day'."
        }
    }
    return $days.ToArray()
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
            $targetDays = @(Get-WeeklyScheduleDays -Schedule $Schedule)
            $tod        = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay

            if ($Now.DayOfWeek -notin $targetDays) { return $false }

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
            $targetDays = @(Get-WeeklyScheduleDays -Schedule $Schedule)
            $tod        = [datetime]::ParseExact($Schedule.time, 'HH:mm', $null).TimeOfDay
            $nextRun    = $null

            foreach ($targetDay in $targetDays) {
                $daysForward = (($targetDay.value__ - $Now.DayOfWeek.value__ + 7) % 7)
                $slot        = $Now.Date.AddDays($daysForward).Add($tod)

                $candidate = if ($Now -lt $slot) {
                    $slot
                }
                elseif ($null -eq $LastRun -or ([datetime]$LastRun) -lt $slot) {
                    $Now
                }
                else {
                    $slot.AddDays(7)
                }

                if ($null -eq $nextRun -or $candidate -lt $nextRun) {
                    $nextRun = $candidate
                }
            }

            return $nextRun
        }
        default { throw "Unknown schedule type '$($Schedule.type)'." }
    }
}
