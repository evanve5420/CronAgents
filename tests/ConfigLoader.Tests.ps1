<#
.SYNOPSIS
    Pester 5 tests for ConfigLoader.ps1 — config loading, validation,
    and agent discovery for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== Import-CronAgentsConfig =====

Describe 'Import-CronAgentsConfig' {
    BeforeAll {
        $fixtureDir = Join-Path $TestDrive 'config-fixtures'
        New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    }

    It 'Loads a fully-specified config with all fields' {
        $json = @'
{
    "autoFeedback": true,
    "maxRunHistory": 100,
    "copilotPath": "/usr/bin/copilot",
    "retentionDays": 30,
    "startupDelay": "10m",
    "logLevel": "debug",
    "quietHours": { "start": "22:00", "end": "06:00" },
    "personalRepo": {
        "path": "~/.cronagents",
        "userName": "testuser",
        "autoCommitFeedback": false,
        "defaultWorkingDirectory": null
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
        $cfg.versioning                          | Should -BeNullOrEmpty
        $cfg.personalRepo.path                   | Should -Be '~/.cronagents'
        $cfg.personalRepo.userName               | Should -Be 'testuser'
        $cfg.personalRepo.autoCommitFeedback     | Should -Be $false
        $cfg.personalRepo.defaultWorkingDirectory | Should -BeNullOrEmpty
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
        $cfg.versioning                          | Should -BeNullOrEmpty
        $cfg.personalRepo.path                   | Should -Be '~/.cronagents'
        $cfg.personalRepo.userName               | Should -BeNullOrEmpty
        $cfg.personalRepo.autoCommitFeedback     | Should -Be $true
        $cfg.personalRepo.defaultWorkingDirectory | Should -BeNullOrEmpty
    }

    It 'Applies personalRepo defaults when personalRepo block is partial' {
        $json = '{ "personalRepo": { "userName": "alice" } }'
        $path = Join-Path $fixtureDir 'partial-pr.json'
        Set-Content -Path $path -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.personalRepo.userName               | Should -Be 'alice'
        $cfg.personalRepo.path                   | Should -Be '~/.cronagents'
        $cfg.personalRepo.autoCommitFeedback     | Should -Be $true
        $cfg.personalRepo.defaultWorkingDirectory | Should -BeNullOrEmpty
    }

    It 'Throws on malformed JSON' {
        $path = Join-Path $fixtureDir 'bad.json'
        Set-Content -Path $path -Value 'NOT JSON {{{' -Encoding UTF8
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

    It 'Throws on empty personalRepo.path' {
        $json = '{ "personalRepo": { "path": "" } }'
        $path = Join-Path $fixtureDir 'bad-pr-path.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*personalRepo.path*'
    }

    It 'Throws on invalid startupDelay' {
        $json = '{ "startupDelay": "five minutes" }'
        $path = Join-Path $fixtureDir 'bad-delay.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        { Import-CronAgentsConfig -ConfigPath $path } | Should -Throw '*startupDelay*'
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

    It 'Accepts each valid logLevel value' {
        foreach ($level in @('debug', 'info', 'warn', 'error')) {
            $json = "{ `"logLevel`": `"$level`" }"
            $path = Join-Path $fixtureDir "level-$level.json"
            Set-Content -Path $path -Value $json -Encoding UTF8
            $cfg = Import-CronAgentsConfig -ConfigPath $path
            $cfg.logLevel | Should -Be $level
        }
    }

    It 'Accepts various personalRepo.path formats' {
        foreach ($prPath in @('~/.cronagents', 'C:\my\agents', './local')) {
            $json = "{ `"personalRepo`": { `"path`": `"$($prPath -replace '\\','\\')`" } }"
            $path = Join-Path $fixtureDir "pr-path-$($prPath -replace '[\\/:~.]','_').json"
            Set-Content -Path $path -Value $json -Encoding UTF8
            $cfg = Import-CronAgentsConfig -ConfigPath $path
            $cfg.personalRepo.path | Should -Be $prPath
        }
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
            versioning    = $null
            personalRepo  = [PSCustomObject]@{
                path                    = '~/.cronagents'
                userName                = $null
                autoCommitFeedback      = $true
                defaultWorkingDirectory = $null
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
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'logLevel' }) | Should -Not -BeNullOrEmpty
    }

    It 'Reports empty personalRepo.path' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = $null
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'personalRepo\.path' }) | Should -Not -BeNullOrEmpty
    }

    It 'Reports negative retentionDays' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = -5
            startupDelay  = '0'
            quietHours    = $null
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'retentionDays' }) | Should -Not -BeNullOrEmpty
    }

    It 'Reports negative maxRunHistory' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = -1
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = $null
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'maxRunHistory' }) | Should -Not -BeNullOrEmpty
    }

    It 'Reports invalid quietHours.start' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = [PSCustomObject]@{ start = '25:00'; end = '06:00' }
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
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
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'quietHours.*start and end' }) | Should -Not -BeNullOrEmpty
    }

    It 'Passes with valid quietHours' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = '0'
            quietHours    = [PSCustomObject]@{ start = '22:00'; end = '06:00' }
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
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
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        $errors.Count | Should -BeGreaterOrEqual 4
    }

    It 'Reports invalid startupDelay format' {
        $cfg = [PSCustomObject]@{
            logLevel      = 'info'
            maxRunHistory = 0
            retentionDays = 0
            startupDelay  = 'abc'
            quietHours    = $null
            versioning    = $null
            personalRepo  = [PSCustomObject]@{ path = '~/.cronagents' }
        }
        $errors = Test-CronAgentsConfig -Config $cfg
        ($errors | Where-Object { $_ -match 'startupDelay' }) | Should -Not -BeNullOrEmpty
    }
}

# ===== Get-AgentConfigs =====

Describe 'Get-AgentConfigs' {
    It 'Discovers valid agent configs and applies defaults' {
        $repoRoot  = Join-Path $TestDrive 'repo-discover'
        $agentDir  = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

        $agentJson = @'
{
    "prompt": "Review code",
    "schedule": { "type": "daily", "time": "09:00" }
}
'@
        Set-Content -Path (Join-Path $agentDir 'daily-review.agent-registration.json') -Value $agentJson -Encoding UTF8

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

    It 'Derives agent ID from filename stem' {
        $repoRoot = Join-Path $TestDrive 'repo-id'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

        $json = '{ "prompt": "test", "schedule": { "type": "daily", "time": "08:00" } }'
        Set-Content -Path (Join-Path $agentDir 'my-custom-agent.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents[0].Id | Should -Be 'my-custom-agent'
    }

    It 'Resolves .agent.md from .github/agents' {
        $repoRoot = Join-Path $TestDrive 'repo-gh-agents'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        $profileDir = Join-Path $repoRoot '.github\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

        $agentJson = @'
{
    "agent": "my-agent",
    "prompt": "Do stuff",
    "schedule": { "type": "interval", "every": "1h" }
}
'@
        Set-Content -Path (Join-Path $agentDir 'my-agent-sched.agent-registration.json') -Value $agentJson -Encoding UTF8
        Set-Content -Path (Join-Path $profileDir 'my-agent.agent.md') -Value '# Agent' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $match = $agents | Where-Object { $_.Id -eq 'my-agent-sched' }
        $match | Should -Not -BeNullOrEmpty
        $match.AgentFilePath | Should -Not -BeNullOrEmpty
        $match.AgentFilePath | Should -BeLike '*my-agent.agent.md'
    }

    It 'Returns $null AgentFilePath when .agent.md not found' {
        $repoRoot = Join-Path $TestDrive 'repo-noagentmd'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

        $json = '{ "agent": "nonexistent-agent", "prompt": "Do stuff", "schedule": { "type": "daily", "time": "12:00" } }'
        Set-Content -Path (Join-Path $agentDir 'ghost.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $match = $agents | Where-Object { $_.Id -eq 'ghost' }
        $match.AgentFilePath | Should -BeNullOrEmpty
    }

    It 'Skips configs missing prompt (returns null)' {
        $repoRoot = Join-Path $TestDrive 'repo-noprompt'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        Set-Content -Path (Join-Path $agentDir 'no-prompt.agent-registration.json') -Value '{ "schedule": { "type": "daily", "time": "09:00" } }' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 0
    }

    It 'Skips configs missing schedule' {
        $repoRoot = Join-Path $TestDrive 'repo-nosched'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        Set-Content -Path (Join-Path $agentDir 'no-sched.agent-registration.json') -Value '{ "prompt": "hello" }' -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 0
    }

    It 'Skips configs with unknown schedule type' {
        $repoRoot = Join-Path $TestDrive 'repo-badtype'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        $json = '{ "prompt": "test", "schedule": { "type": "cron", "expr": "* * * * *" } }'
        Set-Content -Path (Join-Path $agentDir 'bad-type.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 0
    }

    It 'Deduplicates agent IDs across scan paths' {
        $repoRoot = Join-Path $TestDrive 'repo-dupe'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        $extraDir = Join-Path $TestDrive 'dupe-extra'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null

        $json = '{ "prompt": "test", "schedule": { "type": "daily", "time": "08:00" } }'
        Set-Content -Path (Join-Path $agentDir 'dupe.agent-registration.json') -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $extraDir 'dupe.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot -AdditionalPaths @($extraDir)
        $agents | Should -HaveCount 1
    }

    It 'Returns agents sorted by ID' {
        $repoRoot = Join-Path $TestDrive 'repo-sort'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

        $json = '{ "prompt": "test", "schedule": { "type": "daily", "time": "08:00" } }'
        Set-Content -Path (Join-Path $agentDir 'zeta.agent-registration.json')  -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $agentDir 'alpha.agent-registration.json') -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $agentDir 'mid.agent-registration.json')   -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
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
        $extraDir = Join-Path $TestDrive 'extra-agents2'
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
        $json = '{ "prompt": "extra", "schedule": { "type": "weekly", "day": "monday", "time": "10:00" } }'
        Set-Content -Path (Join-Path $extraDir 'bonus.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot (Join-Path $TestDrive 'empty-repo2') -AdditionalPaths @($extraDir)
        $agents | Should -HaveCount 1
        $agents[0].Id | Should -Be 'bonus'
        $agents[0].Config.schedule.type | Should -Be 'weekly'
    }

    It 'Uses agent name from JSON when provided' {
        $repoRoot = Join-Path $TestDrive 'repo-name'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        $json = '{ "name": "Custom Name", "prompt": "go", "schedule": { "type": "daily", "time": "07:00" } }'
        Set-Content -Path (Join-Path $agentDir 'my-agent.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents[0].Config.name | Should -Be 'Custom Name'
        $agents[0].Id          | Should -Be 'my-agent'
    }

    It 'Applies custom timeout, retryCount, and skipOnBattery' {
        $repoRoot = Join-Path $TestDrive 'repo-custom'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        $json = '{ "prompt": "go", "schedule": { "type": "daily", "time": "07:00" }, "timeout": "30m", "retryCount": 3, "skipOnBattery": true }'
        Set-Content -Path (Join-Path $agentDir 'custom.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents[0].Config.timeout       | Should -Be '30m'
        $agents[0].Config.retryCount    | Should -Be 3
        $agents[0].Config.skipOnBattery | Should -Be $true
    }

    It 'Validates prompt-only mode (no agent field)' {
        $repoRoot = Join-Path $TestDrive 'repo-promptonly'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        $json = '{ "prompt": "Just a prompt", "schedule": { "type": "interval", "every": "2h" } }'
        Set-Content -Path (Join-Path $agentDir 'prompt-only.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 1
        $agents[0].Config.PSObject.Properties['agent'] | Should -BeNullOrEmpty
    }

    It 'Validates agent mode (agent + prompt)' {
        $repoRoot = Join-Path $TestDrive 'repo-agentmode'
        $agentDir = Join-Path $repoRoot '.cronagents\agents'
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        $json = '{ "agent": "code-reviewer", "prompt": "Review code", "schedule": { "type": "daily", "time": "09:00" } }'
        Set-Content -Path (Join-Path $agentDir 'with-agent.agent-registration.json') -Value $json -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $repoRoot
        $agents | Should -HaveCount 1
        $agents[0].Config.agent | Should -Be 'code-reviewer'
        $agents[0].Config.prompt | Should -Be 'Review code'
    }
}

# ===== JSON Schema Files =====

Describe 'JSON Schema Files' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
    }

    It 'cronagents.schema.json parses as valid JSON' {
        $schemaPath = Join-Path $repoRoot 'cronagents.schema.json'
        { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'cronagents-agent.schema.json parses as valid JSON' {
        $schemaPath = Join-Path $repoRoot 'cronagents-agent.schema.json'
        { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
    }
}
