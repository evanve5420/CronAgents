<#
.SYNOPSIS
    Pester 3 tests for the CronAgents scheduling POC.
    Validates wake-time calculation and sleep-duration math only.
    No agent logic.
#>

# Dot-source the functions under test
. (Join-Path $PSScriptRoot 'ScheduleParser.ps1')

# ===== ConvertTo-Minutes =====

Describe 'ConvertTo-Minutes' {
    It 'Parses hours' {
        ConvertTo-Minutes '4h' | Should Be 240
    }
    It 'Parses minutes' {
        ConvertTo-Minutes '30m' | Should Be 30
    }
    It 'Rejects invalid formats' {
        $threw = $false
        try { ConvertTo-Minutes '5d' } catch { $threw = $true }
        $threw | Should Be $true
    }
}

# ===== Get-NextSlotTime — interval =====

Describe 'Get-NextSlotTime interval' {
    It 'Returns now when never run' {
        $s   = @{ type = 'interval'; every = '1h' }
        $now = [datetime]'2026-03-22T10:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $null -Now $now | Should Be $now
    }

    It 'Returns lastRun + interval when still in the future' {
        $s       = @{ type = 'interval'; every = '4h' }
        $last    = [datetime]'2026-03-22T08:00:00'
        $now     = [datetime]'2026-03-22T09:00:00'
        $expect  = [datetime]'2026-03-22T12:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $last -Now $now | Should Be $expect
    }

    It 'Returns now when interval already elapsed' {
        $s    = @{ type = 'interval'; every = '1h' }
        $last = [datetime]'2026-03-22T07:00:00'
        $now  = [datetime]'2026-03-22T09:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $last -Now $now | Should Be $now
    }
}

# ===== Get-NextSlotTime — daily =====

Describe 'Get-NextSlotTime daily' {
    It 'Returns today slot when not yet reached' {
        $s      = @{ type = 'daily'; time = '14:00' }
        $now    = [datetime]'2026-03-22T10:00:00'
        $expect = [datetime]'2026-03-22T14:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $null -Now $now | Should Be $expect
    }

    It 'Returns now when past slot and never run' {
        $s   = @{ type = 'daily'; time = '09:00' }
        $now = [datetime]'2026-03-22T10:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $null -Now $now | Should Be $now
    }

    It 'Returns tomorrow slot when already run today' {
        $s      = @{ type = 'daily'; time = '09:00' }
        $last   = [datetime]'2026-03-22T09:05:00'
        $now    = [datetime]'2026-03-22T10:00:00'
        $expect = [datetime]'2026-03-23T09:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $last -Now $now | Should Be $expect
    }
}

# ===== Get-NextSlotTime — weekly =====

Describe 'Get-NextSlotTime weekly' {
    # 2026-03-22 is Sunday
    It 'Returns now when on correct day, past time, never run' {
        $s   = @{ type = 'weekly'; day = 'Sunday'; time = '10:00' }
        $now = [datetime]'2026-03-22T10:30:00'
        Get-NextSlotTime -Schedule $s -LastRun $null -Now $now | Should Be $now
    }

    It 'Returns next week slot when already run this week' {
        $s      = @{ type = 'weekly'; day = 'Sunday'; time = '10:00' }
        $last   = [datetime]'2026-03-22T10:15:00'
        $now    = [datetime]'2026-03-22T14:00:00'
        $expect = [datetime]'2026-03-29T10:00:00'
        Get-NextSlotTime -Schedule $s -LastRun $last -Now $now | Should Be $expect
    }

    It 'Returns this week slot when not yet reached' {
        # Now is Saturday, target is Sunday
        $s      = @{ type = 'weekly'; day = 'Sunday'; time = '10:00' }
        $now    = [datetime]'2026-03-21T14:00:00'  # Saturday
        $expect = [datetime]'2026-03-22T10:00:00'  # Sunday
        Get-NextSlotTime -Schedule $s -LastRun $null -Now $now | Should Be $expect
    }
}

# ===== Get-NextWakeTime — picks earliest across multiple schedules =====

Describe 'Get-NextWakeTime' {
    It 'Picks the earliest slot from multiple schedules' {
        $schedules = @(
            @{ name = 'a'; type = 'daily';    time = '14:00' }
            @{ name = 'b'; type = 'interval'; every = '1h' }
        )
        $state = @{
            'a' = [datetime]'2026-03-21T14:05:00'   # ran yesterday
            'b' = [datetime]'2026-03-22T09:00:00'    # ran 1h ago
        }
        $now = [datetime]'2026-03-22T10:00:00'

        # b is due at 10:00 (now), a at 14:00 — earliest is now
        $result = Get-NextWakeTime -Schedules $schedules -State $state -Now $now
        $result | Should Be $now
    }

    It 'Returns now when any schedule has never run' {
        $schedules = @(
            @{ name = 'x'; type = 'daily'; time = '09:00' }
        )
        $state = @{}
        $now   = [datetime]'2026-03-22T10:00:00'
        Get-NextWakeTime -Schedules $schedules -State $state -Now $now | Should Be $now
    }
}

# ===== Get-SleepSeconds =====

Describe 'Get-SleepSeconds' {
    It 'Returns 0 when wake time is now or in the past' {
        $now = [datetime]'2026-03-22T10:00:00'
        Get-SleepSeconds -Now $now -WakeAt $now | Should Be 0
        Get-SleepSeconds -Now $now -WakeAt $now.AddMinutes(-5) | Should Be 0
    }

    It 'Returns correct seconds for a future wake time' {
        $now    = [datetime]'2026-03-22T10:00:00'
        $wakeAt = [datetime]'2026-03-22T10:30:00'
        Get-SleepSeconds -Now $now -WakeAt $wakeAt | Should Be 1800
    }

    It 'Clamps to MaxSeconds' {
        $now    = [datetime]'2026-03-22T10:00:00'
        $wakeAt = [datetime]'2026-03-22T14:00:00'   # 4 hours away
        Get-SleepSeconds -Now $now -WakeAt $wakeAt -MaxSeconds 3600 | Should Be 3600
    }
}

# ===== Unknown schedule type =====

Describe 'Unknown schedule type' {
    It 'Throws on unknown type' {
        $threw = $false
        try { Get-NextSlotTime -Schedule @{ type = 'cron' } -LastRun $null -Now (Get-Date) } catch { $threw = $true }
        $threw | Should Be $true
    }
}
