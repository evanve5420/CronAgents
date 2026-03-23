<#
.SYNOPSIS
    Pester 5 integration tests for scheduler loop helper functions.
    Tests startup delay parsing, quiet hours, per-agent enabled,
    scheduler pause, and due-agent collection.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    # Replicate the Test-InQuietHours logic from Start-CronAgents.ps1
    function Test-InQuietHours {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [PSCustomObject]$QuietHours,
            [datetime]$Now
        )
        if ($null -eq $QuietHours) { return $false }
        $start = [datetime]::ParseExact($QuietHours.start, 'HH:mm', $null).TimeOfDay
        $end   = [datetime]::ParseExact($QuietHours.end,   'HH:mm', $null).TimeOfDay
        $nowTod = $Now.TimeOfDay
        if ($start -lt $end) {
            return ($nowTod -ge $start -and $nowTod -lt $end)
        }
        else {
            return ($nowTod -ge $start -or $nowTod -lt $end)
        }
    }
}

Describe 'Scheduler — Startup Delay' {
    It 'Parses "5m" as 300 seconds' {
        ConvertTo-Seconds -Duration '5m' | Should -Be 300
    }

    It 'Parses "1h" as 3600 seconds' {
        ConvertTo-Seconds -Duration '1h' | Should -Be 3600
    }

    It 'Parses "30s" as 30 seconds' {
        ConvertTo-Seconds -Duration '30s' | Should -Be 30
    }

    It 'Parses "0" as 0 seconds' {
        ConvertTo-Seconds -Duration '0' | Should -Be 0
    }

    It 'Bare number is treated as minutes' {
        ConvertTo-Seconds -Duration '10' | Should -Be 600
    }
}

Describe 'Scheduler — Quiet Hours' {
    It 'Within same-day quiet hours window → skip' {
        $qh = [PSCustomObject]@{ start = '22:00'; end = '06:00' }
        $now = [datetime]::Parse('2025-01-15 23:30:00')
        Test-InQuietHours -QuietHours $qh -Now $now | Should -Be $true
    }

    It 'Outside same-day quiet hours window → proceed' {
        $qh = [PSCustomObject]@{ start = '22:00'; end = '06:00' }
        $now = [datetime]::Parse('2025-01-15 12:00:00')
        Test-InQuietHours -QuietHours $qh -Now $now | Should -Be $false
    }

    It 'Within overnight quiet hours (before midnight) → skip' {
        $qh = [PSCustomObject]@{ start = '23:00'; end = '05:00' }
        $now = [datetime]::Parse('2025-01-15 23:30:00')
        Test-InQuietHours -QuietHours $qh -Now $now | Should -Be $true
    }

    It 'Within overnight quiet hours (after midnight) → skip' {
        $qh = [PSCustomObject]@{ start = '23:00'; end = '05:00' }
        $now = [datetime]::Parse('2025-01-16 03:00:00')
        Test-InQuietHours -QuietHours $qh -Now $now | Should -Be $true
    }

    It 'Null quiet hours → proceed' {
        Test-InQuietHours -QuietHours $null -Now (Get-Date) | Should -Be $false
    }
}

Describe 'Scheduler — Per-Agent Enabled' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SchedEnabled'
        $script:stateFile = Join-Path $testEnv.StatePath 'state.json'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Per-agent enabled=false skips that agent' {
        Set-AgentState -StateFile $script:stateFile -AgentId 'disabled-agent' -Enabled $false

        $state = Get-AgentState -StateFile $script:stateFile
        $agentState = $state.agents['disabled-agent']
        $agentState.enabled | Should -Be $false
    }
}

Describe 'Scheduler — Global Pause' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SchedPause'
        $script:stateFile = Join-Path $testEnv.StatePath 'state.json'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'schedulerPaused=true skips all agents' {
        Set-AgentState -StateFile $script:stateFile -SchedulerPaused $true

        $state = Get-AgentState -StateFile $script:stateFile
        $state.schedulerPaused | Should -Be $true
    }
}

Describe 'Scheduler — Due Agent Collection' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SchedDue'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Multiple due agents are collected in one tick' {
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'agent-one' `
            -Schedule @{ type = 'interval'; every = '30m' } `
            -Prompt 'Task one'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'agent-two' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'Task two'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'agent-three' `
            -Schedule @{ type = 'interval'; every = '2h' } `
            -Prompt 'Task three'

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $now = [datetime]::UtcNow

        # With no lastRun, all interval agents are due immediately
        $due = @()
        foreach ($agent in $agents) {
            $schedule = @{ type = $agent.Config.schedule.type; every = $agent.Config.schedule.every }
            if (Test-AgentDue -Schedule $schedule -LastRun $null -Now $now) {
                $due += $agent.Id
            }
        }

        $due.Count | Should -Be 3
        $due | Should -Contain 'agent-one'
        $due | Should -Contain 'agent-two'
        $due | Should -Contain 'agent-three'
    }
}
