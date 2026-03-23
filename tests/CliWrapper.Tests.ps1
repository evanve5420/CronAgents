<#
.SYNOPSIS
    Pester 5 integration tests for cronagents.ps1 CLI subcommands.
    Tests the module functions that the CLI wrapper delegates to,
    plus direct invocation for output-level checks.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $cliScript = Join-Path $repoRoot 'cronagents.ps1'
}

Describe 'CLI Wrapper — status' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'CliStatus'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'daily-review' `
            -Schedule @{ type = 'daily'; time = '09:00' } `
            -Prompt 'Review code changes'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'status outputs agent information' {
        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agents.Count | Should -BeGreaterOrEqual 1

        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        $state = Get-AgentState -StateFile $stateFile
        $state | Should -Not -BeNullOrEmpty
        $state.schedulerPaused | Should -Be $false
    }
}

Describe 'CLI Wrapper — list' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'CliList'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'agent-alpha' `
            -Schedule @{ type = 'interval'; every = '2h' } `
            -Prompt 'Alpha task'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'agent-beta' `
            -Schedule @{ type = 'daily'; time = '14:00' } `
            -Prompt 'Beta task'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'list shows discovered agents' {
        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agents.Count | Should -Be 2
        $agents[0].Id | Should -Be 'agent-alpha'
        $agents[1].Id | Should -Be 'agent-beta'
    }
}

Describe 'CLI Wrapper — pause / resume' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'CliPause'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'pausable-agent' `
            -Schedule @{ type = 'daily'; time = '10:00' } `
            -Prompt 'Test pause'
        $script:stateFile = Join-Path $testEnv.StatePath 'state.json'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'pause sets schedulerPaused=true in state' {
        Set-AgentState -StateFile $script:stateFile -SchedulerPaused $true

        $state = Get-AgentState -StateFile $script:stateFile
        $state.schedulerPaused | Should -Be $true
    }

    It 'resume clears schedulerPaused' {
        Set-AgentState -StateFile $script:stateFile -SchedulerPaused $true
        Set-AgentState -StateFile $script:stateFile -SchedulerPaused $false

        $state = Get-AgentState -StateFile $script:stateFile
        $state.schedulerPaused | Should -Be $false
    }

    It 'pause agent-id sets enabled=false for that agent' {
        Set-AgentState -StateFile $script:stateFile -AgentId 'pausable-agent' -Enabled $false

        $state = Get-AgentState -StateFile $script:stateFile
        $state.agents['pausable-agent'].enabled | Should -Be $false
    }

    It 'resume agent-id sets enabled=true' {
        Set-AgentState -StateFile $script:stateFile -AgentId 'pausable-agent' -Enabled $false
        Set-AgentState -StateFile $script:stateFile -AgentId 'pausable-agent' -Enabled $true

        $state = Get-AgentState -StateFile $script:stateFile
        $state.agents['pausable-agent'].enabled | Should -Be $true
    }
}

Describe 'CLI Wrapper — doctor' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'CliDoctor'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'doctor runs health checks' {
        $healthScript = Join-Path $repoRoot 'scheduler' 'Test-CronAgentsHealth.ps1'
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'

        $result | Should -Not -BeNullOrEmpty
        $result.Checks.Count | Should -BeGreaterOrEqual 1
        $result.PSObject.Properties.Name | Should -Contain 'Overall'
    }
}

Describe 'CLI Wrapper — unknown command' {
    It 'Unknown command shows help' {
        $output = & $cliScript 'xyznonexistent' 6>&1 2>&1
        $text = ($output | Out-String)
        $text | Should -Match 'Unknown command|Usage|Commands'
    }
}
