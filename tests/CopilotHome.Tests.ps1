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
