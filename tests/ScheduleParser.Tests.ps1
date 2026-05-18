<#
.SYNOPSIS
    Pester 5 tests for ScheduleParser.ps1 — schedule evaluation,
    next-run computation, and duration parsing for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== ConvertTo-Minutes =====

Describe 'ConvertTo-Minutes' {
    It 'Parses hours: "4h" → 240' {
        ConvertTo-Minutes -Duration '4h' | Should -Be 240
    }

    It 'Parses minutes: "30m" → 30' {
        ConvertTo-Minutes -Duration '30m' | Should -Be 30
    }

    It 'Parses single hour: "1h" → 60' {
        ConvertTo-Minutes -Duration '1h' | Should -Be 60
    }

    It 'Parses single minute: "1m" → 1' {
        ConvertTo-Minutes -Duration '1m' | Should -Be 1
    }

    It 'Handles whitespace around value: " 2h " → 120' {
        ConvertTo-Minutes -Duration ' 2h ' | Should -Be 120
    }

    It 'Rejects invalid duration string' {
        { ConvertTo-Minutes -Duration 'abc' } | Should -Throw '*Invalid duration*'
    }

    It 'Rejects bare number' {
        { ConvertTo-Minutes -Duration '10' } | Should -Throw '*Invalid duration*'
    }

    It 'Rejects seconds unit' {
        { ConvertTo-Minutes -Duration '30s' } | Should -Throw '*Invalid duration*'
    }
}

# ===== ConvertTo-Seconds =====

Describe 'ConvertTo-Seconds' {
    It 'Parses hours: "1h" → 3600' {
        ConvertTo-Seconds -Duration '1h' | Should -Be 3600
    }

    It 'Parses minutes: "10m" → 600' {
        ConvertTo-Seconds -Duration '10m' | Should -Be 600
    }

    It 'Parses seconds: "30s" → 30' {
        ConvertTo-Seconds -Duration '30s' | Should -Be 30
    }

    It 'Parses "0" → 0' {
        ConvertTo-Seconds -Duration '0' | Should -Be 0
    }

    It 'Treats bare number as minutes: "5" → 300' {
        ConvertTo-Seconds -Duration '5' | Should -Be 300
    }

    It 'Handles whitespace: " 2h " → 7200' {
        ConvertTo-Seconds -Duration ' 2h ' | Should -Be 7200
    }

    It 'Rejects non-numeric input' {
        { ConvertTo-Seconds -Duration 'abc' } | Should -Throw '*Invalid duration*'
    }

    It 'Rejects mixed units' {
        { ConvertTo-Seconds -Duration '1h30m' } | Should -Throw '*Invalid duration*'
    }
}

# ===== Schedule formatting =====

Describe 'Format-Schedule' {
    It 'Formats weekly schedules with multiple days clearly' {
        $schedule = @{ type = 'weekly'; days = @('tuesday', 'friday'); time = '12:00' }
        Format-Schedule -Schedule $schedule | Should -Be 'weekly tuesday, friday at 12:00'
    }
}

# ===== Test-AgentDue — Interval Schedules =====

Describe 'Test-AgentDue - Interval' {
    It 'Is due when never run (LastRun is null)' {
        $schedule = @{ type = 'interval'; every = '1h' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $true
    }

    It 'Is due when enough time has elapsed' {
        $schedule = @{ type = 'interval'; every = '1h' }
        $now     = [datetime]::new(2025, 6, 15, 11, 30, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $true
    }

    It 'Is not due when interval has not passed' {
        $schedule = @{ type = 'interval'; every = '2h' }
        $now     = [datetime]::new(2025, 6, 15, 10, 30, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $false
    }

    It 'Is due at exact interval boundary' {
        $schedule = @{ type = 'interval'; every = '30m' }
        $now     = [datetime]::new(2025, 6, 15, 10, 30, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $true
    }
}

# ===== Test-AgentDue — Daily Schedules =====

Describe 'Test-AgentDue - Daily' {
    It 'Is due when past time with no run today' {
        $schedule = @{ type = 'daily'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 14, 9, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $true
    }

    It 'Is not due when already run today after scheduled time' {
        $schedule = @{ type = 'daily'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 15, 12, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 9, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $false
    }

    It 'Is due on first run ever when past scheduled time' {
        $schedule = @{ type = 'daily'; time = '09:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $true
    }

    It 'Is not due on first run if before scheduled time' {
        $schedule = @{ type = 'daily'; time = '14:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $false
    }

    It 'Is not due before scheduled time even with old last run' {
        $schedule = @{ type = 'daily'; time = '14:00' }
        $now     = [datetime]::new(2025, 6, 15, 8, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 14, 14, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $false
    }
}

# ===== Test-AgentDue — Weekly Schedules =====

Describe 'Test-AgentDue - Weekly' {
    It 'Is due on correct day and past scheduled time' {
        # 2025-06-16 is a Monday
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '09:00' }
        $now = [datetime]::new(2025, 6, 16, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $true
    }

    It 'Is not due on wrong day' {
        # 2025-06-15 is a Sunday
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '09:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $false
    }

    It 'Is not due on correct day before scheduled time' {
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '14:00' }
        $now = [datetime]::new(2025, 6, 16, 10, 0, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $false
    }

    It 'Is not due when already run this week' {
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 16, 12, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 16, 9, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $false
    }

    It 'Is due when last run was from previous week' {
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 16, 10, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 9, 9, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $true
    }

    It 'Is due on any listed weekly day' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now = [datetime]::new(2025, 6, 20, 12, 30, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $true
    }

    It 'Is not due on a day outside the weekly days list' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now = [datetime]::new(2025, 6, 18, 12, 30, 0)
        Test-AgentDue -Schedule $schedule -LastRun $null -Now $now | Should -Be $false
    }

    It 'Allows the next listed weekly day after an earlier listed day ran' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now     = [datetime]::new(2025, 6, 20, 12, 30, 0)
        $lastRun = [datetime]::new(2025, 6, 17, 12, 5, 0)
        Test-AgentDue -Schedule $schedule -LastRun $lastRun -Now $now | Should -Be $true
    }
}

# ===== Test-AgentDue — Edge cases =====

Describe 'Test-AgentDue - Edge Cases' {
    It 'Throws on unknown schedule type' {
        $schedule = @{ type = 'cron'; expr = '* * * * *' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        { Test-AgentDue -Schedule $schedule -LastRun $null -Now $now } | Should -Throw '*Unknown schedule type*'
    }
}

# ===== Get-NextRunTime — Interval =====

Describe 'Get-NextRunTime - Interval' {
    It 'Returns Now when never run' {
        $schedule = @{ type = 'interval'; every = '1h' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be $now
    }

    It 'Returns lastRun + interval when in the future' {
        $schedule = @{ type = 'interval'; every = '2h' }
        $now     = [datetime]::new(2025, 6, 15, 10, 30, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 15, 12, 0, 0))
    }

    It 'Returns Now when lastRun + interval is in the past' {
        $schedule = @{ type = 'interval'; every = '1h' }
        $now     = [datetime]::new(2025, 6, 15, 14, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be $now
    }
}

# ===== Get-NextRunTime — Daily =====

Describe 'Get-NextRunTime - Daily' {
    It 'Returns today slot when never run and before slot' {
        $schedule = @{ type = 'daily'; time = '14:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 15, 14, 0, 0))
    }

    It 'Returns Now when never run and past slot' {
        $schedule = @{ type = 'daily'; time = '09:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be $now
    }

    It 'Returns tomorrow slot when already run today' {
        $schedule = @{ type = 'daily'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 15, 12, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 15, 9, 5, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 16, 9, 0, 0))
    }

    It 'Returns today slot when last run was yesterday and now is before slot' {
        $schedule = @{ type = 'daily'; time = '14:00' }
        $now     = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 14, 14, 5, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 15, 14, 0, 0))
    }
}

# ===== Get-NextRunTime — Weekly =====

Describe 'Get-NextRunTime - Weekly' {
    It 'Returns this week slot when today is the target day and before time' {
        # 2025-06-16 is Monday
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '14:00' }
        $now = [datetime]::new(2025, 6, 16, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 16, 14, 0, 0))
    }

    It 'Returns next week slot when already run this week' {
        $schedule = @{ type = 'weekly'; day = 'Monday'; time = '09:00' }
        $now     = [datetime]::new(2025, 6, 16, 12, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 16, 9, 5, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 23, 9, 0, 0))
    }

    It 'Returns upcoming day slot when target day is later this week' {
        # 2025-06-15 is Sunday; next Friday = 2025-06-20
        $schedule = @{ type = 'weekly'; day = 'Friday'; time = '09:00' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 20, 9, 0, 0))
    }

    It 'Returns the earliest upcoming slot across multiple weekly days' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now = [datetime]::new(2025, 6, 18, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 20, 12, 0, 0))
    }

    It 'Returns the next listed day when the current listed day already ran' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now     = [datetime]::new(2025, 6, 17, 13, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 17, 12, 5, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be ([datetime]::new(2025, 6, 20, 12, 0, 0))
    }

    It 'Returns Now when a later listed weekly slot is currently due' {
        $schedule = @{ type = 'weekly'; days = @('Tuesday', 'Friday'); time = '12:00' }
        $now     = [datetime]::new(2025, 6, 20, 13, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 17, 12, 5, 0)
        $result = Get-NextRunTime -Schedule $schedule -LastRun $lastRun -Now $now
        $result | Should -Be $now
    }

    It 'Throws on unknown schedule type' {
        $schedule = @{ type = 'unknown' }
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        { Get-NextRunTime -Schedule $schedule -LastRun $null -Now $now } | Should -Throw '*Unknown schedule type*'
    }
}

# ===== Manual (no schedule) agents =====

Describe 'Test-AgentDue - Manual (null schedule)' {
    It 'Returns false when schedule is null' {
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Test-AgentDue -Schedule $null -LastRun $null -Now $now | Should -Be $false
    }

    It 'Returns false with a previous lastRun' {
        $now     = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 14, 9, 0, 0)
        Test-AgentDue -Schedule $null -LastRun $lastRun -Now $now | Should -Be $false
    }
}

Describe 'Get-NextRunTime - Manual (null schedule)' {
    It 'Returns null when schedule is null' {
        $now = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $result = Get-NextRunTime -Schedule $null -LastRun $null -Now $now
        $result | Should -BeNullOrEmpty
    }

    It 'Returns null even with a previous lastRun' {
        $now     = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $lastRun = [datetime]::new(2025, 6, 14, 9, 0, 0)
        $result = Get-NextRunTime -Schedule $null -LastRun $lastRun -Now $now
        $result | Should -BeNullOrEmpty
    }
}
