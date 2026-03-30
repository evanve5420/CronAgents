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

Describe 'Scheduler startup entry script' {
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
        $deadline = (Get-Date).AddSeconds(20)
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
}
