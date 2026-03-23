<#
.SYNOPSIS
    Pester 5 tests for ConfigLoader.ps1 — config loading, validation,
    and agent discovery for CronAgents.
#>

BeforeAll {
    # Dot-source Logger first (ConfigLoader depends on Write-CronAgentsLog)
    . (Join-Path $PSScriptRoot '..\scheduler\lib\Logger.ps1')
    . (Join-Path $PSScriptRoot '..\scheduler\lib\ConfigLoader.ps1')
}

# ===== Import-CronAgentsConfig =====

Describe 'Import-CronAgentsConfig' {
    BeforeAll {
        $fixtureDir = Join-Path $TestDrive 'config-fixtures'
        New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    }

    It 'Loads a fully-specified config' {
        $json = @'
{
    "autoFeedback": true,
    "maxRunHistory": 100,
    "copilotPath": "/usr/bin/copilot",
    "retentionDays": 30,
    "startupDelay": "10m",
    "logLevel": "debug",
    "quietHours": { "start": "22:00", "end": "06:00" },
    "versioning": {
        "syncPolicy": "auto",
        "userName": "testuser",
        "autoCommitFeedback": false,
        "branchPrefix": "custom"
    }
}
'@
        $path = Join-Path $fixtureDir 'full.json'
        Set-Content -Path $path -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.autoFeedback  | Should -Be $true
        $cfg.maxRunHistory | Should -Be 100
        $cfg.copilotPath   | Should -Be '/usr/bin/copilot'
        $cfg.retentionDays | Should -Be 30
        $cfg.startupDelay  | Should -Be '10m'
        $cfg.logLevel      | Should -Be 'debug'
        $cfg.quietHours.start | Should -Be '22:00'
        $cfg.quietHours.end   | Should -Be '06:00'
        $cfg.versioning.syncPolicy         | Should -Be 'auto'
        $cfg.versioning.userName           | Should -Be 'testuser'
        $cfg.versioning.autoCommitFeedback | Should -Be $false
        $cfg.versioning.branchPrefix       | Should -Be 'custom'
    }

    It 'Applies all defaults for an empty config' {
        $path = Join-Path $fixtureDir 'empty.json'
        Set-Content -Path $path -Value '{}' -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.autoFeedback  | Should -Be $false
        $cfg.maxRunHistory | Should -Be 50
        $cfg.copilotPath   | Should -Be 'copilot'
        $cfg.retentionDays | Should -Be 14
        $cfg.startupDelay  | Should -Be '5m'
        $cfg.logLevel      | Should -Be 'info'
        $cfg.quietHours    | Should -BeNullOrEmpty
        $cfg.versioning.syncPolicy         | Should -Be 'notify'
        $cfg.versioning.userName           | Should -BeNullOrEmpty
        $cfg.versioning.autoCommitFeedback | Should -Be $true
        $cfg.versioning.branchPrefix       | Should -Be 'agents'
    }

    It 'Applies versioning defaults when versioning block is partial' {
        $json = '{ "versioning": { "syncPolicy": "manual" } }'
        $path = Join-Path $fixtureDir 'partial-ver.json'
        Set-Content -Path $path -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.versioning.syncPolicy         | Should -Be 'manual'
        $cfg.versioning.autoCommitFeedback | Should -Be $true
        $cfg.versioning.branchPrefix       | Should -Be 'agents'
    }

    It 'Throws on invalid JSON' {
        $path = Join-Path $fixtureDir 'bad.json'
        Set-Content -Path $path -Value 'NOT JSON' -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*parse*'
    }

    It 'Throws on missing file' {
        { Import-CronAgentsConfig -ConfigPath (Join-Path $fixtureDir 'nope.json') } | Should -Throw '*not found*'
    }

    It 'Throws on invalid logLevel' {
        $json = '{ "logLevel": "verbose" }'
        $path = Join-Path $fixtureDir 'bad-level.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*logLevel*'
    }

    It 'Throws on negative retentionDays' {
        $json = '{ "retentionDays": -1 }'
        $path = Join-Path $fixtureDir 'neg-ret.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*retentionDays*'
    }

    It 'Throws on invalid startupDelay' {
        $json = '{ "startupDelay": "five minutes" }'
        $path = Join-Path $fixtureDir 'bad-delay.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*startupDelay*'
    }

    It 'Throws on invalid syncPolicy' {
        $json = '{ "versioning": { "syncPolicy": "yolo" } }'
        $path = Join-Path $fixtureDir 'bad-sync.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*syncPolicy*'
    }

    It 'Accepts startupDelay of "0"' {
        $json = '{ "startupDelay": "0" }'
        $path = Join-Path $fixtureDir 'delay-zero.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.startupDelay | Should -Be '0'
    }

    It 'Accepts startupDelay with seconds unit' {
        $json = '{ "startupDelay": "30s" }'
        $path = Join-Path $fixtureDir 'delay-s.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.startupDelay | Should -Be '30s'
    }
}

# ===== Test-CronAgentsConfig =====

Describe 'Test-CronAgentsConfig' {
    It 'Returns empty array for valid config' {
        $cfg = [PSCustomObject]@{
            autoFeedback  = $false
            maxRunHistory = 50
            copilotPath   = 'copilot'
            retentionDays = 14
            startupDelay  = '5m'
            logLevel      = 'info'
            quietHours    = $null
            versioning    = [PSCustomObject]@{
                syncPolicy         = 'notify'
                userName           = $null
                autoCommitFeedback = $true
                branchPrefix       = 'agents'
            }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        $errors | Should -HaveCount 0
    }

    It 'Reports invalid logLevel' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'trace'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = $null
            versioning    = [PSCustomObject]@{ syncPolicy = 'auto' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        $errors | Should -Contain ($errors | Where-Object { $_ -match 'logLevel' })
    }

    It 'Reports invalid quietHours.start' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = [PSCustomObject]@{ start = '25:00'; end = '06:00' }
            versioning    = [PSCustomObject]@{ syncPolicy = 'notify' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'quietHours.start' }) | Should -Not -BeNullOrEmpty
    }

    It 'Reports missing quietHours.end' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = [PSCustomObject]@{ start = '22:00' }
            versioning    = [PSCustomObject]@{ syncPolicy = 'notify' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'quietHours.*start and end' }) | Should -Not -BeNullOrEmpty
    }

    It 'Validates valid quietHours passes' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = [PSCustomObject]@{ start = '22:00'; end = '06:00' }
            versioning    = [PSCustomObject]@{ syncPolicy = 'notify' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        $errors | Should -HaveCount 0
    }

    It 'Reports multiple errors at once' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'nope'
            maxRunHistory = -5
            retentionDays = -1
            startupDelay  = 'bad'
            quietHours    = $null
            versioning    = [PSCustomObject]@{ syncPolicy = 'yolo' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        $errors.Count | Should -BeGreaterOrEqual 4
    }
}

# ===== Get-AgentConfigs =====

Describe 'Get-AgentConfigs' {
    BeforeAll {
        $repoRoot  = Join-Path $TestDrive 'repo'
        $agentDir  = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    }

    It 'Discovers valid agent configs and applies defaults' {
        $agentJson = @'
{
    "prompt": "Review code",
    "schedule": { "type": "daily", "time": "09:00" }
}
'@
        Set-Content -Path (Join-Path $agentDir 'daily-review.json') -Value $agentJson -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 1
        $agents[0].Id            | Should -Be 'daily-review'
        $agents[0].Config.prompt | Should -Be 'Review code'
        $agents[0].Config.timeout       | Should -Be '10m'
        $agents[0].Config.skipOnBattery | Should -Be $false
        $agents[0].Config.retryCount    | Should -Be 0
        $agents[0].Config.model         | Should -BeNullOrEmpty
        $agents[0].Config.name          | Should -Be 'daily-review'
        $agents[0].AgentFilePath        | Should -BeNullOrEmpty
    }

    It 'Resolves .agent.md sibling file' {
        $agentJson = @'
{
    "agent": "my-agent",
    "prompt": "Do stuff",
    "schedule": { "type": "interval", "every": "1h" }
}
'@
        Set-Content -Path (Join-Path $agentDir 'my-agent-sched.json') -Value $agentJson -Encoding UTF8
        # Create sibling .agent.md
        Set-Content -Path (Join-Path $agentDir 'my-agent.agent.md') -Value '# Agent' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $match = $agents | Where-Object { $_.Id -eq 'my-agent-sched' }
        $match | Should -Not -BeNullOrEmpty
        $match.AgentFilePath | Should -Not -BeNullOrEmpty
        $match.AgentFilePath | Should -BeLike '*my-agent.agent.md'
    }

    It 'Returns $null AgentFilePath when .agent.md not found' {
        $agentJson = @'
{
    "agent": "nonexistent-agent",
    "prompt": "Do stuff",
    "schedule": { "type": "daily", "time": "12:00" }
}
'@
        $dir2 = Join-Path $TestDrive 'repo2\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
        Set-Content -Path (Join-Path $dir2 'ghost.json') -Value $agentJson -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo2')
        $match = $agents | Where-Object { $_.Id -eq 'ghost' }
        $match.AgentFilePath | Should -BeNullOrEmpty
    }

    It 'Skips configs missing prompt' {
        $dir3 = Join-Path $TestDrive 'repo3\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir3 -Force | Out-Null
        Set-Content -Path (Join-Path $dir3 'no-prompt.json') -Value '{ "schedule": { "type": "daily", "time": "09:00" } }' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo3')
        $agents | Should -HaveCount 0
    }

    It 'Skips configs missing schedule' {
        $dir4 = Join-Path $TestDrive 'repo4\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir4 -Force | Out-Null
        Set-Content -Path (Join-Path $dir4 'no-sched.json') -Value '{ "prompt": "hello" }' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo4')
        $agents | Should -HaveCount 0
    }

    It 'Skips configs with invalid schedule type' {
        $dir5 = Join-Path $TestDrive 'repo5\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir5 -Force | Out-Null
        $json = '{ "prompt": "test", "schedule": { "type": "cron", "expr": "* * * * *" } }'
        Set-Content -Path (Join-Path $dir5 'bad-type.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo5')
        $agents | Should -HaveCount 0
    }

    It 'Detects duplicate agent IDs across scan paths' {
        $dir6a = Join-Path $TestDrive 'repo6\.cronagents\agents'
        $dir6b = Join-Path $TestDrive 'repo6-extra'
        New-Item -ItemType Directory -Path $dir6a -Force | Out-Null
        New-Item -ItemType Directory -Path $dir6b -Force | Out-Null

        $json = '{ "prompt": "test", "schedule": { "type": "daily", "time": "08:00" } }'
        Set-Content -Path (Join-Path $dir6a 'dupe.json') -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $dir6b 'dupe.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo6') -AdditionalPaths @($dir6b)
        $agents | Should -HaveCount 1
    }

    It 'Returns agents sorted by ID' {
        $dir7 = Join-Path $TestDrive 'repo7\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir7 -Force | Out-Null

        $json = '{ "prompt": "test", "schedule": { "type": "daily", "time": "08:00" } }'
        Set-Content -Path (Join-Path $dir7 'zeta.json')  -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $dir7 'alpha.json') -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $dir7 'mid.json')   -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo7')
        $agents | Should -HaveCount 3
        $agents[0].Id | Should -Be 'alpha'
        $agents[1].Id | Should -Be 'mid'
        $agents[2].Id | Should -Be 'zeta'
    }

    It 'Returns empty array when agents directory does not exist' {
        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'nonexistent-repo')
        $agents | Should -HaveCount 0
    }

    It 'Scans additional paths' {
        $extraDir = Join-Path $TestDrive 'extra-agents'
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
        $json = '{ "prompt": "extra", "schedule": { "type": "weekly", "day": "monday", "time": "10:00" } }'
        Set-Content -Path (Join-Path $extraDir 'bonus.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'empty-repo') -AdditionalPaths @($extraDir)
        $agents | Should -HaveCount 1
        $agents[0].Id | Should -Be 'bonus'
        $agents[0].Config.schedule.type | Should -Be 'weekly'
    }

    It 'Uses agent name from JSON when provided' {
        $dir8 = Join-Path $TestDrive 'repo8\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir8 -Force | Out-Null
        $json = '{ "name": "Custom Name", "prompt": "go", "schedule": { "type": "daily", "time": "07:00" } }'
        Set-Content -Path (Join-Path $dir8 'my-agent.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo8')
        $agents[0].Config.name | Should -Be 'Custom Name'
        $agents[0].Id          | Should -Be 'my-agent'
    }

    It 'Applies custom timeout and retryCount' {
        $dir9 = Join-Path $TestDrive 'repo9\.cronagents\agents'
        New-Item -ItemType Directory -Path $dir9 -Force | Out-Null
        $json = '{ "prompt": "go", "schedule": { "type": "daily", "time": "07:00" }, "timeout": "30m", "retryCount": 3, "skipOnBattery": true }'
        Set-Content -Path (Join-Path $dir9 'custom.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'repo9')
        $agents[0].Config.timeout       | Should -Be '30m'
        $agents[0].Config.retryCount    | Should -Be 3
        $agents[0].Config.skipOnBattery | Should -Be $true
    }
}
