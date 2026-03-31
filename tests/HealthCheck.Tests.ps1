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

Describe 'Health Check — Valid Config' -Tag 'WindowsOnly' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthValid'
        # Ensure state file exists and is valid
        $stateFile = Join-Path $testEnv.PersonalRepoRoot '.cronstate' 'state.json'
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

Describe 'Health Check — Corrupted State' -Tag 'WindowsOnly' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthCorrupt'
        $stateFile = Join-Path $testEnv.PersonalRepoRoot '.cronstate' 'state.json'
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

Describe 'Health Check — Invalid Config' -Tag 'WindowsOnly' {
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

        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Warn'
        $agentCheck.Message | Should -Match ([regex]::Escape((Join-Path $testEnv.Root '.cronagents' 'agents')))
    }
}

Describe 'Health Check — Task Path' -Tag 'WindowsOnly' {
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

Describe 'Health Check — Agent Config Discovery' -Tag 'WindowsOnly' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthAgents'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Reports Warn with scanned locations when no agents exist' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Warn'
        $agentCheck.Message | Should -Match 'No agents discovered in:'
        $agentCheck.Message | Should -Match '\.cronagents[\\/]agents'
    }

    It 'Reports Pass when agents exist in infra repo' {
        New-TestAgentConfig -TestEnv $testEnv -AgentId 'test-agent' `
            -Schedule @{ type = 'daily'; time = '09:00' } `
            -Prompt 'Test prompt'

        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Pass'
        $agentCheck.Message | Should -Match '1 agents? discovered'
    }

    It 'Reports Pass when agents exist only in personal repo' {
        # Point personalRepo.path at a temp directory within the test env
        $personalRoot = Join-Path $testEnv.Root 'personal-repo'
        $personalAgentsDir = Join-Path $personalRoot '.cronagents' 'agents'
        New-Item -Path $personalAgentsDir -ItemType Directory -Force | Out-Null

        # Update cronagents.json to point at the temp personal repo
        $cfg = Get-Content $testEnv.ConfigPath -Raw | ConvertFrom-Json
        $cfg.personalRepo.path = $personalRoot
        $cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        # Create an agent registration in the personal repo only
        $agentReg = [ordered]@{
            name     = 'personal-agent'
            prompt   = 'Personal test prompt'
            schedule = @{ type = 'daily'; time = '10:00' }
        }
        $agentReg | ConvertTo-Json -Depth 5 |
            Out-File -FilePath (Join-Path $personalAgentsDir 'personal-agent.agent-registration.json') -Encoding utf8

        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Pass'
        $agentCheck.Message | Should -Match '1 agents? discovered'
    }

    It 'Warn message includes personal repo path when configured' {
        $personalRoot = Join-Path $testEnv.Root 'personal-repo-empty'
        $personalAgentsDir = Join-Path $personalRoot '.cronagents' 'agents'
        New-Item -Path $personalAgentsDir -ItemType Directory -Force | Out-Null

        $cfg = Get-Content $testEnv.ConfigPath -Raw | ConvertFrom-Json
        $cfg.personalRepo.path = $personalRoot
        $cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Warn'
        # Message should mention both scanned locations
        $agentCheck.Message | Should -Match ([regex]::Escape($personalRoot))
    }
}

Describe 'Health Check — Personal Repo State and Runs' -Tag 'WindowsOnly' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthPersonalPaths'
        $script:externalPersonalRoot = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -Path (Join-Path $script:externalPersonalRoot '.cronagents' 'agents') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:externalPersonalRoot '.cronstate' 'runs') -ItemType Directory -Force | Out-Null

        $cfg = Get-Content -LiteralPath $testEnv.ConfigPath -Raw | ConvertFrom-Json
        $cfg.personalRepo.path = $script:externalPersonalRoot
        $cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        $state = @{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = @{}
        }
        $state | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $script:externalPersonalRoot '.cronstate' 'state.json') -Encoding UTF8

        @{
            name     = 'Tracked Agent'
            prompt   = 'Track personal repo state'
            schedule = @{ type = 'daily'; time = '09:00' }
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:externalPersonalRoot '.cronagents' 'agents' 'tracked-agent.agent-registration.json') -Encoding UTF8

        New-Item -Path (Join-Path $script:externalPersonalRoot '.cronstate' 'runs' '20260331T230000_orphan-agent_ab12') -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Uses personal repo state and runs roots when configured outside RepoRoot' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'

        $agentCheck = $result.Checks | Where-Object { $_.Name -eq 'Agent Configs' }
        $agentCheck.Status | Should -Be 'Pass'

        $stateCheck = $result.Checks | Where-Object { $_.Name -eq 'State File' }
        $stateCheck.Status | Should -Be 'Pass'

        $runsCheck = $result.Checks | Where-Object { $_.Name -eq 'Run Directories' }
        $runsCheck.Status | Should -Be 'Warn'
        $runsCheck.Message | Should -Match 'orphan-agent'
    }
}

Describe 'Health Check — Notifications' -Tag 'WindowsOnly' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'HealthNotif'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Returns a Notifications check with Pass or Warn status' {
        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'
        $result | Should -Not -BeNullOrEmpty

        $notifCheck = $result.Checks | Where-Object { $_.Name -eq 'Notifications' }
        $notifCheck | Should -Not -BeNullOrEmpty
        $notifCheck.Status | Should -BeIn @('Pass', 'Warn')
    }

    It 'Reports Pass when notifications are globally disabled' {
        $configContent = [ordered]@{
            '$schema'     = './cronagents.schema.json'
            logLevel      = 'info'
            notifications = $false
        }
        $configContent | ConvertTo-Json -Depth 5 |
            Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        $result = & $healthScript -RepoRoot $testEnv.Root -TaskPath '\CronAgents-Test\'

        $notifCheck = $result.Checks | Where-Object { $_.Name -eq 'Notifications' }
        $notifCheck.Status | Should -Be 'Pass'
        $notifCheck.Message | Should -Match 'Disabled globally'
    }
}
