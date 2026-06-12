<#
.SYNOPSIS
    Pester 5 tests for the CopilotHome module
    (Initialize-SchedulerCopilotHome, Sync-McpConfig, Get-CopilotAuthToken).
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    function Get-FileSha256 {
        param([Parameter(Mandatory)][string]$Path)
        return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    }
}

Describe 'Initialize-SchedulerCopilotHome' {
    BeforeEach {
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-CopilotHome-$(
            [System.IO.Path]::GetRandomFileName().Replace('.', '')
        )"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:testDir) {
            Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates copilot-home directory on first call' {
        $result = Initialize-SchedulerCopilotHome -StateRoot $script:testDir
        $result | Should -Be (Join-Path $script:testDir 'copilot-home')
        Test-Path $result | Should -BeTrue
    }

    It 'writes config.json with ide.auto_connect disabled' {
        $copilotHome = Initialize-SchedulerCopilotHome -StateRoot $script:testDir
        $config = Get-Content (Join-Path $copilotHome 'config.json') -Raw | ConvertFrom-Json
        $config.'ide.auto_connect' | Should -BeFalse
        $config.'banner' | Should -Be 'never'
        $config.'autoUpdate' | Should -BeFalse
    }

    It 'is idempotent — does not rewrite config when values match' {
        $copilotHome = Initialize-SchedulerCopilotHome -StateRoot $script:testDir
        $configFile = Join-Path $copilotHome 'config.json'
        $initialContent = Get-Content $configFile -Raw
        $initialHash = Get-FileSha256 -Path $configFile

        Initialize-SchedulerCopilotHome -StateRoot $script:testDir | Out-Null
        $finalContent = Get-Content $configFile -Raw
        $finalHash = Get-FileSha256 -Path $configFile

        $finalContent | Should -Be $initialContent
        $finalHash | Should -Be $initialHash
    }

    It 'rewrites config when values are stale' {
        $copilotHome = Initialize-SchedulerCopilotHome -StateRoot $script:testDir
        $configFile = Join-Path $copilotHome 'config.json'
        $expectedContent = Get-Content $configFile -Raw

        # Tamper with the config
        @{ 'ide.auto_connect' = $true; banner = 'always'; autoUpdate = $true } |
            ConvertTo-Json | Set-Content $configFile -Encoding UTF8
        $tamperedContent = Get-Content $configFile -Raw

        Initialize-SchedulerCopilotHome -StateRoot $script:testDir | Out-Null
        $fixedContent = Get-Content $configFile -Raw

        $tamperedContent | Should -Not -Be $expectedContent
        $fixedContent | Should -Be $expectedContent
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
        $config.'ide.auto_connect' | Should -BeFalse
    }

    It 'rewrites config when file is corrupt JSON' {
        $copilotHome = Initialize-SchedulerCopilotHome -StateRoot $script:testDir
        $configFile = Join-Path $copilotHome 'config.json'

        'not-valid-json{{{' | Set-Content $configFile -Encoding UTF8

        { Initialize-SchedulerCopilotHome -StateRoot $script:testDir } | Should -Not -Throw
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
        $config.'ide.auto_connect' | Should -BeFalse
    }
}

Describe 'Sync-McpConfig' {
    BeforeEach {
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-McpSync-$(
            [System.IO.Path]::GetRandomFileName().Replace('.', '')
        )"
        $script:schedulerHome = Join-Path $script:testDir 'scheduler-copilot'
        New-Item -ItemType Directory -Path $script:schedulerHome -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:testDir) {
            Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes empty mcp-config.json when destination does not exist' {
        & (Get-Module CronAgents) { Sync-McpConfig -SchedulerCopilotHome $args[0] } $script:schedulerHome

        $destMcp = Join-Path $script:schedulerHome 'mcp-config.json'
        Test-Path $destMcp | Should -BeTrue
        $content = Get-Content $destMcp -Raw | ConvertFrom-Json
        ($content.mcpServers.PSObject.Properties | Measure-Object).Count | Should -Be 0
    }

    It 'overwrites existing mcp-config.json with empty servers' {
        $destMcp = Join-Path $script:schedulerHome 'mcp-config.json'
        '{"mcpServers":{"heavy-server":{"command":"npx","args":["server"]}}}' |
            Set-Content $destMcp -Encoding UTF8

        & (Get-Module CronAgents) { Sync-McpConfig -SchedulerCopilotHome $args[0] } $script:schedulerHome

        $content = Get-Content $destMcp -Raw | ConvertFrom-Json
        ($content.mcpServers.PSObject.Properties | Measure-Object).Count | Should -Be 0
    }
}

Describe 'Resolve-RunMcpConfig' {
    BeforeEach {
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-McpResolve-$(
            [System.IO.Path]::GetRandomFileName().Replace('.', '')
        )"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
        $script:srcConfig = Join-Path $script:testDir 'mcp-config.json'
        @'
{
  "mcpServers": {
    "ado-mcp": { "type": "stdio", "command": "npx", "args": ["-y", "@azure-devops/mcp", "msazure"] },
    "teams":   { "type": "stdio", "command": "agency", "args": ["mcp", "teams"] },
    "mail":    { "type": "local", "command": "agency", "args": ["mcp", "mail"] }
  },
  "inputs": [ { "id": "tok", "type": "promptString" } ]
}
'@ | Set-Content -LiteralPath $script:srcConfig -Encoding UTF8

        function Get-ServerCount {
            param([string]$Json)
            $cfg = $Json | ConvertFrom-Json
            return ($cfg.mcpServers.PSObject.Properties | Measure-Object).Count
        }
    }
    AfterEach {
        if (Test-Path $script:testDir) {
            Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns all servers verbatim when McpServers is $null' {
        $json = Resolve-RunMcpConfig -McpServers $null -SourceConfigPath $script:srcConfig
        Get-ServerCount $json | Should -Be 3
        $cfg = $json | ConvertFrom-Json
        $cfg.mcpServers.'ado-mcp' | Should -Not -BeNullOrEmpty
        $cfg.mcpServers.teams     | Should -Not -BeNullOrEmpty
        $cfg.mcpServers.mail      | Should -Not -BeNullOrEmpty
    }

    It 'returns no servers when McpServers is an empty array' {
        $json = Resolve-RunMcpConfig -McpServers @() -SourceConfigPath $script:srcConfig
        Get-ServerCount $json | Should -Be 0
    }

    It 'returns only the requested subset by name' {
        $json = Resolve-RunMcpConfig -McpServers @('ado-mcp', 'teams') -SourceConfigPath $script:srcConfig
        Get-ServerCount $json | Should -Be 2
        $cfg = $json | ConvertFrom-Json
        $cfg.mcpServers.'ado-mcp' | Should -Not -BeNullOrEmpty
        $cfg.mcpServers.teams     | Should -Not -BeNullOrEmpty
        $cfg.mcpServers.PSObject.Properties.Name | Should -Not -Contain 'mail'
    }

    It 'preserves server definition details in the subset' {
        $json = Resolve-RunMcpConfig -McpServers @('ado-mcp') -SourceConfigPath $script:srcConfig
        $cfg = $json | ConvertFrom-Json
        $cfg.mcpServers.'ado-mcp'.command | Should -Be 'npx'
        $cfg.mcpServers.'ado-mcp'.args    | Should -Contain '@azure-devops/mcp'
    }

    It 'skips unknown server names without failing' {
        $json = Resolve-RunMcpConfig -McpServers @('ado-mcp', 'does-not-exist') -SourceConfigPath $script:srcConfig
        Get-ServerCount $json | Should -Be 1
        ($json | ConvertFrom-Json).mcpServers.'ado-mcp' | Should -Not -BeNullOrEmpty
    }

    It 'carries over inputs when subsetting' {
        $json = Resolve-RunMcpConfig -McpServers @('ado-mcp') -SourceConfigPath $script:srcConfig
        $cfg = $json | ConvertFrom-Json
        $cfg.inputs[0].id | Should -Be 'tok'
    }

    It 'falls back to empty servers when the source file is missing' {
        $missing = Join-Path $script:testDir 'nope.json'
        $json = Resolve-RunMcpConfig -McpServers $null -SourceConfigPath $missing
        Get-ServerCount $json | Should -Be 0
    }

    It 'falls back to empty servers when the source is invalid JSON' {
        'not-valid-json{{{' | Set-Content -LiteralPath $script:srcConfig -Encoding UTF8
        $json = Resolve-RunMcpConfig -McpServers @('ado-mcp') -SourceConfigPath $script:srcConfig
        Get-ServerCount $json | Should -Be 0
    }

    It 'falls back to empty servers when the source is invalid JSON on the all-servers path' {
        'not-valid-json{{{' | Set-Content -LiteralPath $script:srcConfig -Encoding UTF8
        $json = Resolve-RunMcpConfig -McpServers $null -SourceConfigPath $script:srcConfig
        $json | Should -Be '{"mcpServers": {}}'
        Get-ServerCount $json | Should -Be 0
    }

    It 'falls back to empty servers when the source is empty/whitespace on the all-servers path' {
        "   `n  " | Set-Content -LiteralPath $script:srcConfig -Encoding UTF8
        $json = Resolve-RunMcpConfig -McpServers $null -SourceConfigPath $script:srcConfig
        $json | Should -Be '{"mcpServers": {}}'
        Get-ServerCount $json | Should -Be 0
    }
}

Describe 'Initialize-RunCopilotHome' {
    BeforeEach {
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-RunHome-$(
            [System.IO.Path]::GetRandomFileName().Replace('.', '')
        )"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
        $script:runDir = Join-Path $script:testDir 'run'
        New-Item -ItemType Directory -Path $script:runDir -Force | Out-Null
        $script:srcConfig = Join-Path $script:testDir 'mcp-config.json'
        @'
{
  "mcpServers": {
    "ado-mcp": { "type": "stdio", "command": "npx", "args": ["-y", "@azure-devops/mcp"] },
    "teams":   { "type": "stdio", "command": "agency", "args": ["mcp", "teams"] }
  }
}
'@ | Set-Content -LiteralPath $script:srcConfig -Encoding UTF8

        function Get-RunServerCount {
            param([string]$CopilotHome)
            $cfg = Get-Content (Join-Path $CopilotHome 'mcp-config.json') -Raw | ConvertFrom-Json
            return ($cfg.mcpServers.PSObject.Properties | Measure-Object).Count
        }
    }
    AfterEach {
        if (Test-Path $script:testDir) {
            Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates the copilot-home directory and config.json' {
        $home_ = Initialize-RunCopilotHome -RunDirectory $script:runDir -McpServers @() -McpConfigPath $script:srcConfig
        Test-Path $home_ | Should -BeTrue
        $config = Get-Content (Join-Path $home_ 'config.json') -Raw | ConvertFrom-Json
        $config.'ide.auto_connect' | Should -BeFalse
    }

    It 'writes all source servers when McpServers is $null' {
        $home_ = Initialize-RunCopilotHome -RunDirectory $script:runDir -McpServers $null -McpConfigPath $script:srcConfig
        Get-RunServerCount $home_ | Should -Be 2
    }

    It 'writes an empty mcp-config when McpServers is an empty array' {
        $home_ = Initialize-RunCopilotHome -RunDirectory $script:runDir -McpServers @() -McpConfigPath $script:srcConfig
        Get-RunServerCount $home_ | Should -Be 0
    }

    It 'writes only the named subset of servers' {
        $home_ = Initialize-RunCopilotHome -RunDirectory $script:runDir -McpServers @('teams') -McpConfigPath $script:srcConfig
        Get-RunServerCount $home_ | Should -Be 1
        $cfg = Get-Content (Join-Path $home_ 'mcp-config.json') -Raw | ConvertFrom-Json
        $cfg.mcpServers.teams | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-CopilotAuthToken' {
    It 'returns env var when COPILOT_GITHUB_TOKEN is set' {
        $prev = $env:COPILOT_GITHUB_TOKEN
        try {
            $env:COPILOT_GITHUB_TOKEN = 'test-token-cgt'
            $result = Get-CopilotAuthToken
            $result | Should -Be 'test-token-cgt'
        }
        finally {
            $env:COPILOT_GITHUB_TOKEN = $prev
        }
    }

    It 'prefers COPILOT_GITHUB_TOKEN over GH_TOKEN' {
        $prevCGT = $env:COPILOT_GITHUB_TOKEN
        $prevGH  = $env:GH_TOKEN
        try {
            $env:COPILOT_GITHUB_TOKEN = 'copilot-token'
            $env:GH_TOKEN             = 'gh-token'
            $result = Get-CopilotAuthToken
            $result | Should -Be 'copilot-token'
        }
        finally {
            $env:COPILOT_GITHUB_TOKEN = $prevCGT
            $env:GH_TOKEN             = $prevGH
        }
    }

    It 'falls back to GH_TOKEN when COPILOT_GITHUB_TOKEN is not set' {
        $prevCGT = $env:COPILOT_GITHUB_TOKEN
        $prevGH  = $env:GH_TOKEN
        $prevGIT = $env:GITHUB_TOKEN
        try {
            $env:COPILOT_GITHUB_TOKEN = $null
            $env:GH_TOKEN             = 'gh-fallback'
            $env:GITHUB_TOKEN         = $null
            $result = Get-CopilotAuthToken
            $result | Should -Be 'gh-fallback'
        }
        finally {
            $env:COPILOT_GITHUB_TOKEN = $prevCGT
            $env:GH_TOKEN             = $prevGH
            $env:GITHUB_TOKEN         = $prevGIT
        }
    }

    It 'falls back to GITHUB_TOKEN when others are not set' {
        $prevCGT = $env:COPILOT_GITHUB_TOKEN
        $prevGH  = $env:GH_TOKEN
        $prevGIT = $env:GITHUB_TOKEN
        try {
            $env:COPILOT_GITHUB_TOKEN = $null
            $env:GH_TOKEN             = $null
            $env:GITHUB_TOKEN         = 'github-fallback'
            $result = Get-CopilotAuthToken
            $result | Should -Be 'github-fallback'
        }
        finally {
            $env:COPILOT_GITHUB_TOKEN = $prevCGT
            $env:GH_TOKEN             = $prevGH
            $env:GITHUB_TOKEN         = $prevGIT
        }
    }
}
