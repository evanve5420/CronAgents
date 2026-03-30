<#
.SYNOPSIS
    Pester 5 tests for PersonalRepo.ps1 — personal repo management,
    path resolution, validation, initialization, and config merging
    for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== Get-PersonalRepoPath =====

Describe 'Get-PersonalRepoPath' {
    It 'Returns default path when no config' {
        $result = Get-PersonalRepoPath
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Expands tilde to HOME' {
        $result = Get-PersonalRepoPath -ConfigPath '~/.my-agents'
        $expected = Join-Path $HOME '.my-agents'
        $result | Should -Be $expected
    }

    It 'Returns absolute path for relative input' {
        $result = Get-PersonalRepoPath -ConfigPath './agents'
        [System.IO.Path]::IsPathRooted($result) | Should -Be $true
    }

    It 'Handles empty string same as null' {
        $result = Get-PersonalRepoPath -ConfigPath ''
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Handles whitespace-only same as null' {
        $result = Get-PersonalRepoPath -ConfigPath '   '
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Handles explicit absolute path' {
        $absPath = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\my\agents' } else { '/opt/my/agents' }
        $result = Get-PersonalRepoPath -ConfigPath $absPath
        $result | Should -Be $absPath
    }
}

# ===== Test-PersonalRepoValid =====

Describe 'Test-PersonalRepoValid' {
    It 'Returns Valid=false for non-existent path' {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nonexistent-$(Get-Random)"
        $result = Test-PersonalRepoValid -Path $fakePath
        $result.Valid | Should -Be $false
        $result.Errors.Count | Should -BeGreaterThan 0
    }

    It 'Returns Valid=false for non-git directory' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nogit-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            $result.Errors | Should -Contain "Not a git repository (missing .git): $tempDir"
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=false when missing .github/agents/' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-noagents-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Test User' 2>&1 | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            ($result.Errors | Where-Object { $_ -like '*Missing directory: .github/agents/*' }).Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=false when missing .cronagents/agents/' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nocrondir-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Test User' 2>&1 | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.github' 'agents') -Force | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            ($result.Errors | Where-Object { $_ -like '*Missing directory: .cronagents/agents/*' }).Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=true for complete structure' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-valid-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Test User' 2>&1 | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.github' 'agents') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.cronagents' 'agents') -Force | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns descriptive errors' {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-descriptive-$(Get-Random)"
        $result = Test-PersonalRepoValid -Path $fakePath
        $result.Errors | Should -Not -BeNullOrEmpty
        $result.Errors[0] | Should -BeLike '*does not exist*'
    }
}

# ===== Initialize-PersonalRepo =====

Describe 'Initialize-PersonalRepo' {
    BeforeAll {
        $script:initBaseDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-init-$(Get-Random)"
    }

    AfterAll {
        Remove-Item -Path $script:initBaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates a new personal repo with correct structure' {
        $repoPath = Join-Path $script:initBaseDir 'structure-test'
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'

        (Test-Path (Join-Path $repoPath '.github' 'agents'))       | Should -Be $true
        (Test-Path (Join-Path $repoPath '.github' 'skills'))       | Should -Be $true
        (Test-Path (Join-Path $repoPath '.github' 'instructions')) | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronagents' 'agents'))   | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronstate'))             | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronstate' 'runs'))     | Should -Be $true
    }

    It 'Returns Created=true for new repo' {
        $repoPath = Join-Path $script:initBaseDir 'created-test'
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $result.Created | Should -Be $true
        $result.Path | Should -Be $repoPath
        $result.Message | Should -Not -BeNullOrEmpty
    }

    It 'Creates .gitignore with .cronstate/' {
        $repoPath = Join-Path $script:initBaseDir 'gitignore-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        $gitignore = Get-Content -LiteralPath (Join-Path $repoPath '.gitignore') -Raw
        $gitignore | Should -BeLike '*.cronstate/*'
    }

    It 'Creates cronagents.json with $schema' {
        $repoPath = Join-Path $script:initBaseDir 'config-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        $configPath = Join-Path $repoPath 'cronagents.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.'$schema' | Should -Not -BeNullOrEmpty
        $config.'$schema' | Should -BeLike '*cronagents.schema.json*'
    }

    It 'Creates .github/copilot-instructions.md with username' {
        $repoPath = Join-Path $script:initBaseDir 'instructions-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'alice' | Out-Null

        $content = Get-Content -LiteralPath (Join-Path $repoPath '.github' 'copilot-instructions.md') -Raw
        $content | Should -BeLike '*alice*'
    }

    It 'Initializes git repo' {
        $repoPath = Join-Path $script:initBaseDir 'git-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        (Test-Path (Join-Path $repoPath '.git')) | Should -Be $true

        $log = & git -C $repoPath log --oneline 2>&1
        $commitCount = ($log | Measure-Object).Count
        $commitCount | Should -Be 1
    }

    It 'Returns Created=false for existing valid repo' {
        $repoPath = Join-Path $script:initBaseDir 'idempotent-test'
        $first = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $first.Created | Should -Be $true

        $second = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $second.Created | Should -Be $false
        $second.Path | Should -Be $repoPath
    }

    It 'Repairs partially initialized repo' {
        $repoPath = Join-Path $script:initBaseDir 'repair-test'
        # Create a partial structure — directory exists but missing required dirs
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        & git -C $repoPath init 2>&1 | Out-Null
        & git -C $repoPath config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoPath config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoPath 'placeholder.txt') -Value 'temp'
        & git -C $repoPath add . 2>&1 | Out-Null
        & git -C $repoPath commit -m 'partial' 2>&1 | Out-Null

        # Validation should fail — missing required dirs
        $validation = Test-PersonalRepoValid -Path $repoPath
        $validation.Valid | Should -Be $false

        # Initialize should repair
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'repair-user'
        $result.Created | Should -Be $true

        # Now it should be valid
        $validation = Test-PersonalRepoValid -Path $repoPath
        $validation.Valid | Should -Be $true
    }
}

# ===== Import-PersonalRepoConfig =====

Describe 'Import-PersonalRepoConfig' {
    BeforeAll {
        $script:configBaseDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-importcfg-$(Get-Random)"
        New-Item $script:configBaseDir -ItemType Directory -Force | Out-Null

        $script:baseConfig = [PSCustomObject]@{
            logLevel     = 'info'
            autoFeedback = $false
            personalRepo = [PSCustomObject]@{
                path                   = '~/.cronagents'
                userName               = $null
                autoCommitFeedback     = $true
                defaultWorkingDirectory = $null
            }
        }
    }

    AfterAll {
        Remove-Item -Path $script:configBaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns BaseConfig when no personal config file exists' {
        $fakePath = Join-Path $script:configBaseDir 'nonexistent-repo'
        $result = Import-PersonalRepoConfig -PersonalRepoPath $fakePath -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
        $result.autoFeedback | Should -Be $false
    }

    It 'Returns BaseConfig when personal config is empty' {
        $emptyDir = Join-Path $script:configBaseDir 'empty-config'
        New-Item $emptyDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $emptyDir 'cronagents.json') -Value '' -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $emptyDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
    }

    It 'Overrides top-level string properties' {
        $overrideDir = Join-Path $script:configBaseDir 'override-string'
        New-Item $overrideDir -ItemType Directory -Force | Out-Null
        $json = '{ "logLevel": "debug" }'
        Set-Content -Path (Join-Path $overrideDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $overrideDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'debug'
    }

    It 'Overrides top-level boolean properties' {
        $overrideDir = Join-Path $script:configBaseDir 'override-bool'
        New-Item $overrideDir -ItemType Directory -Force | Out-Null
        $json = '{ "autoFeedback": true }'
        Set-Content -Path (Join-Path $overrideDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $overrideDir -BaseConfig $script:baseConfig
        $result.autoFeedback | Should -Be $true
    }

    It 'Does not override with null values' {
        $nullDir = Join-Path $script:configBaseDir 'null-override'
        New-Item $nullDir -ItemType Directory -Force | Out-Null
        $json = '{ "logLevel": null }'
        Set-Content -Path (Join-Path $nullDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $nullDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
    }

    It 'Merges personalRepo sub-object at property level' {
        $mergeDir = Join-Path $script:configBaseDir 'merge-subrepo'
        New-Item $mergeDir -ItemType Directory -Force | Out-Null
        $json = '{ "personalRepo": { "userName": "alice" } }'
        Set-Content -Path (Join-Path $mergeDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $mergeDir -BaseConfig $script:baseConfig
        $result.personalRepo.userName | Should -Be 'alice'
        $result.personalRepo.path | Should -Be '~/.cronagents'
        $result.personalRepo.autoCommitFeedback | Should -Be $true
    }

    It 'Ignores $schema property' {
        $schemaDir = Join-Path $script:configBaseDir 'schema-ignore'
        New-Item $schemaDir -ItemType Directory -Force | Out-Null
        $json = '{ "$schema": "https://example.com/schema.json", "logLevel": "warn" }'
        Set-Content -Path (Join-Path $schemaDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $schemaDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'warn'
        # Base config should not gain a $schema property from personal config
        $result.PSObject.Properties['$schema'] | Should -BeNullOrEmpty
    }

    It 'Handles malformed JSON gracefully' {
        $badDir = Join-Path $script:configBaseDir 'bad-json'
        New-Item $badDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $badDir 'cronagents.json') -Value '{ invalid json }}}' -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $badDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
        $result.autoFeedback | Should -Be $false
    }
}
