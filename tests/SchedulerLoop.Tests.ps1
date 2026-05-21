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

Describe 'Scheduler — Per-Agent Quiet Hours' {
    It 'Skips only due agents whose effective quiet hours are active' {
        $globalQuietHours = [PSCustomObject]@{ start = '22:00'; end = '06:00' }
        $tickStart = [datetime]::Parse('2025-01-15 23:30:00', [System.Globalization.CultureInfo]::InvariantCulture)
        $schedule = [PSCustomObject]@{ type = 'interval'; every = '1h' }
        $agents = @(
            [PSCustomObject]@{
                Id = 'inherits-global'
                Config = [PSCustomObject]@{ schedule = $schedule }
            },
            [PSCustomObject]@{
                Id = 'disables-quiet-hours'
                Config = [PSCustomObject]@{ schedule = $schedule; quietHours = $null }
            },
            [PSCustomObject]@{
                Id = 'override-inactive'
                Config = [PSCustomObject]@{
                    schedule = $schedule
                    quietHours = [PSCustomObject]@{ start = '01:00'; end = '02:00' }
                }
            },
            [PSCustomObject]@{
                Id = 'override-active'
                Config = [PSCustomObject]@{
                    schedule = $schedule
                    quietHours = [PSCustomObject]@{ start = '18:00'; end = '08:00' }
                }
            }
        )

        $queued = @()
        foreach ($agent in $agents) {
            $scheduleHt = ConvertTo-ScheduleHashtable -Schedule $agent.Config.schedule
            if (-not (Test-AgentDue -Schedule $scheduleHt -LastRun $null -Now $tickStart)) { continue }

            $quietHours = Resolve-AgentQuietHours -AgentConfig $agent.Config -GlobalQuietHours $globalQuietHours
            if (Test-InQuietHours -QuietHours $quietHours -Now $tickStart) { continue }

            $queued += $agent.Id
        }

        $queued | Should -Not -Contain 'inherits-global'
        $queued | Should -Contain 'disables-quiet-hours'
        $queued | Should -Contain 'override-inactive'
        $queued | Should -Not -Contain 'override-active'
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

    It 'Manual agents (no schedule) are never due' {
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'scheduled-agent' `
            -Schedule @{ type = 'interval'; every = '30m' } `
            -Prompt 'Scheduled task'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'manual-agent' `
            -Prompt 'Manual task'

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $now = [datetime]::UtcNow

        $due = @()
        foreach ($agent in $agents) {
            if ($null -eq $agent.Config.schedule) { continue }
            $schedule = @{ type = $agent.Config.schedule.type; every = $agent.Config.schedule.every }
            if (Test-AgentDue -Schedule $schedule -LastRun $null -Now $now) {
                $due += $agent.Id
            }
        }

        $due.Count | Should -Be 1
        $due | Should -Contain 'scheduled-agent'
        $due | Should -Not -Contain 'manual-agent'
    }

    It 'runIf can suppress an otherwise-due agent' {
        $trackedFile = Join-Path $testEnv.Root 'package.json'
        Set-Content -Path $trackedFile -Value '{ "name": "scheduler-test" }' -Encoding UTF8
        $trackedStamp = (Get-Item $trackedFile).LastWriteTimeUtc.ToString('o')

        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'conditional-agent' `
            -Schedule @{ type = 'interval'; every = '30m' } `
            -Prompt 'Task one' `
            -RunIf 'file-changed:package.json'

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        Set-AgentState -StateFile $stateFile -AgentId 'conditional-agent' -RunIfState @{
            fileChanged = @{
                'package.json' = $trackedStamp
            }
        }

        $state = Get-AgentState -StateFile $stateFile
        $agent = $agents[0]
        $due = Test-AgentDue -Schedule @{ type = 'interval'; every = '30m' } -LastRun $null -Now ([datetime]::UtcNow)
        $shouldRun = Test-AgentRunIf -RunIf $agent.Config.runIf `
            -ExecutionRoot $testEnv.Root `
            -AgentId $agent.Id `
            -StateFile $stateFile `
            -RunIfState $state.agents['conditional-agent'].runIfState

        $due | Should -Be $true
        $shouldRun | Should -Be $false
    }
}

Describe 'Scheduler startup entry script' -Tag 'Slow' {
    BeforeEach {
        $script:testEnv = New-TestEnvironment -Name 'SchedStartup'
        $script:startScript = Join-Path $repoRoot 'scheduler' 'Start-CronAgents.ps1'
        $script:stdoutPath = Join-Path $script:testEnv.Root 'scheduler-stdout.log'
        $script:stderrPath = Join-Path $script:testEnv.Root 'scheduler-stderr.log'
    }

    AfterEach {
        if ($script:schedulerProcess -and -not $script:schedulerProcess.HasExited) {
            Stop-Process -Id $script:schedulerProcess.Id
            $script:schedulerProcess.WaitForExit()
        }
        Remove-TestEnvironment -TestEnv $script:testEnv
    }

    It 'Stays running past startup with a valid config' {
        $startArgs = @{
            FilePath               = 'pwsh'
            ArgumentList           = @('-NoProfile', '-File', $script:startScript, '-RepoRoot', $script:testEnv.Root, '-ConfigPath', $script:testEnv.ConfigPath)
            PassThru               = $true
            RedirectStandardOutput = $script:stdoutPath
            RedirectStandardError  = $script:stderrPath
        }
        if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }
        $script:schedulerProcess = Start-Process @startArgs

        Start-Sleep -Seconds 2

        if ($script:schedulerProcess.HasExited) {
            $stdout = if (Test-Path $script:stdoutPath) { Get-Content $script:stdoutPath -Raw } else { '' }
            $stderr = if (Test-Path $script:stderrPath) { Get-Content $script:stderrPath -Raw } else { '' }
            throw "Scheduler exited during startup. Stdout: $stdout`nStderr: $stderr"
        }

        $script:schedulerProcess.HasExited | Should -Be $false
    }

    It 'Generates dashboard.md on its first tick' {
        $startArgs = @{
            FilePath               = 'pwsh'
            ArgumentList           = @('-NoProfile', '-File', $script:startScript, '-RepoRoot', $script:testEnv.Root, '-ConfigPath', $script:testEnv.ConfigPath)
            PassThru               = $true
            RedirectStandardOutput = $script:stdoutPath
            RedirectStandardError  = $script:stderrPath
        }
        if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }
        $script:schedulerProcess = Start-Process @startArgs

        $dashboardPath = Join-Path $script:testEnv.Root 'dashboard.md'
        # Under the multi-worker test runner, the startup script can take longer
        # to reach its first dashboard write on busy CI hosts.
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $dashboardPath)) {
            if ($script:schedulerProcess.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }

        if (-not (Test-Path $dashboardPath)) {
            $stdout = if (Test-Path $script:stdoutPath) { Get-Content $script:stdoutPath -Raw } else { '' }
            $stderr = if (Test-Path $script:stderrPath) { Get-Content $script:stderrPath -Raw } else { '' }
            throw "Dashboard was not generated. Stdout: $stdout`nStderr: $stderr"
        }

        (Get-Content $dashboardPath -Raw) | Should -Match '# CronAgents Dashboard'
    }

    It 'Exits cleanly when another scheduler is already running' {
        # Start the first scheduler instance
        $startArgs1 = @{
            FilePath               = 'pwsh'
            ArgumentList           = @('-NoProfile', '-File', $script:startScript, '-RepoRoot', $script:testEnv.Root, '-ConfigPath', $script:testEnv.ConfigPath)
            PassThru               = $true
            RedirectStandardOutput = $script:stdoutPath
            RedirectStandardError  = $script:stderrPath
        }
        if ($IsWindows) { $startArgs1.WindowStyle = 'Hidden' }
        $script:schedulerProcess = Start-Process @startArgs1

        # Wait for the PID file to appear
        $pidFile = Join-Path $script:testEnv.PersonalRepoRoot '.cronstate' 'scheduler.pid'
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $pidFile)) {
            if ($script:schedulerProcess.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }

        $script:schedulerProcess.HasExited | Should -Be $false
        (Test-Path $pidFile) | Should -Be $true

        # Start a second scheduler instance — it should exit immediately
        $stdout2 = Join-Path $script:testEnv.Root 'scheduler-stdout2.log'
        $stderr2 = Join-Path $script:testEnv.Root 'scheduler-stderr2.log'
        $startArgs2 = @{
            FilePath               = 'pwsh'
            ArgumentList           = @('-NoProfile', '-File', $script:startScript, '-RepoRoot', $script:testEnv.Root, '-ConfigPath', $script:testEnv.ConfigPath)
            PassThru               = $true
            RedirectStandardOutput = $stdout2
            RedirectStandardError  = $stderr2
        }
        if ($IsWindows) { $startArgs2.WindowStyle = 'Hidden' }
        $proc2 = Start-Process @startArgs2

        # Wait for the second instance to exit
        $proc2.WaitForExit(15000) | Should -Be $true
        $proc2.ExitCode | Should -Be 0
    }
}

Describe 'Scheduler — Recovery Detection' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SchedRecovery'
        $script:stateFile = Join-Path $testEnv.PersonalRepoRoot '.cronstate' 'state.json'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Detects overdue daily agents after scheduler downtime' {
        # Create a daily agent scheduled at 09:00
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'daily-check' `
            -Schedule @{ type = 'daily'; time = '09:00' } `
            -Prompt 'Daily task'

        # Set lastRun to 2 days ago and use a -Now after the schedule slot
        # so the test doesn't depend on what time CI runs (e.g. 01:51 UTC).
        $now = [datetime]::UtcNow.Date.AddHours(10)
        $twoDaysAgo = $now.AddDays(-2)
        Set-AgentState -StateFile $script:stateFile -AgentId 'daily-check' -LastRun $twoDaysAgo

        $missed = Get-OverdueAgents -RepoRoot $testEnv.Root `
            -StateFile $script:stateFile -Now $now

        $missed | Should -Contain 'daily-check'
    }

    It 'Does not flag recently-run agents as missed' {
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'recent-agent' `
            -Schedule @{ type = 'daily'; time = '09:00' } `
            -Prompt 'Recent task'

        # Set lastRun to just now
        Set-AgentState -StateFile $script:stateFile -AgentId 'recent-agent' -LastRun ([datetime]::UtcNow)

        $missed = Get-OverdueAgents -RepoRoot $testEnv.Root `
            -StateFile $script:stateFile -Now ([datetime]::UtcNow)

        $missed | Should -Not -Contain 'recent-agent'
    }

    It 'Skips disabled agents in overdue detection' {
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'disabled-agent' `
            -Schedule @{ type = 'interval'; every = '30m' } `
            -Prompt 'Disabled task'

        Set-AgentState -StateFile $script:stateFile -AgentId 'disabled-agent' -Enabled $false

        $missed = Get-OverdueAgents -RepoRoot $testEnv.Root `
            -StateFile $script:stateFile -Now ([datetime]::UtcNow)

        $missed | Should -Not -Contain 'disabled-agent'
    }

    It 'Skips manual-only agents in overdue detection' {
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'manual-agent' `
            -Prompt 'Manual task'

        $missed = Get-OverdueAgents -RepoRoot $testEnv.Root `
            -StateFile $script:stateFile -Now ([datetime]::UtcNow)

        $missed | Should -Not -Contain 'manual-agent'
    }
}
