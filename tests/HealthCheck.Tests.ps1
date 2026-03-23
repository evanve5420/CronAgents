<#
.SYNOPSIS
    Pester 5 integration tests for Test-CronAgentsHealth.ps1.
    Tests health check reporting against valid and invalid configs
    using the \CronAgents-Test\ task path.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $healthScript = Join-Path $repoRoot 'scheduler' 'Test-CronAgentsHealth.ps1'
}

Describe 'Health Check — Valid Config' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthValid'
        # Ensure state file exists and is valid
        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        $state = @{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = @{}
        }
        $state | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $stateFile -Encoding UTF8
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Reports pass for valid config' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $result | Should -Not -BeNullOrEmpty

        # Global Config check should pass
        $configCheck = $result.Checks | Where-Object { $_.Name -eq 'Global Config' }
        $configCheck.Status | Should -Be 'Pass'

        # State File check should pass
        $stateCheck = $result.Checks | Where-Object { $_.Name -eq 'State File' }
        $stateCheck.Status | Should -Be 'Pass'
    }
}

Describe 'Health Check — Corrupted State' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthCorrupt'
        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        Set-Content -LiteralPath $stateFile -Value 'NOT VALID JSON {{{{' -Encoding UTF8
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Reports error for corrupted state.json' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $result | Should -Not -BeNullOrEmpty

        $stateCheck = $result.Checks | Where-Object { $_.Name -eq 'State File' }
        $stateCheck.Status | Should -BeIn @('Fail', 'Warn')
    }
}

Describe 'Health Check — Invalid Config' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthBadCfg'
        # Overwrite cronagents.json with invalid content
        $configPath = Join-Path $testEnv.Root 'cronagents.json'
        $badConfig = @{
            logLevel      = 'nonexistent'
            retentionDays = -5
        }
        $badConfig | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Reports error for invalid config' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $result | Should -Not -BeNullOrEmpty

        $configCheck = $result.Checks | Where-Object { $_.Name -eq 'Global Config' }
        $configCheck.Status | Should -Be 'Fail'
    }
}

Describe 'Health Check — Task Path' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthTaskPath'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'All tests use \CronAgents-Test\ task path' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $result | Should -Not -BeNullOrEmpty

        # Task Scheduler check should be Warn (no tasks) since we use a test path
        $taskCheck = $result.Checks | Where-Object { $_.Name -eq 'Task Scheduler' }
        $taskCheck | Should -Not -BeNullOrEmpty
        $taskCheck.Status | Should -BeIn @('Warn', 'Pass')
    }
}
