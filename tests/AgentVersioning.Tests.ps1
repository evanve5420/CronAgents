<#
.SYNOPSIS
    Pester 5 tests for GitHelpers.ps1 versioning functions — slug,
    branch detection, and config defaults for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== Username Slugification =====

Describe 'Username slugification via ConvertTo-Slug' {
    It 'Converts spaces to hyphens and lowercases' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'John Doe' } | Should -Be 'john-doe'
    }

    It 'Strips special characters' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'user@domain.com' } | Should -Be 'userdomaincom'
    }

    It 'Handles uppercase with numbers' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'Admin123' } | Should -Be 'admin123'
    }

    It 'Collapses multiple special chars into single hyphen' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'first---second' } | Should -Be 'first-second'
    }

    It 'Strips leading and trailing hyphens from result' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '---name---' } | Should -Be 'name'
    }

    It 'Handles real Windows username with domain prefix' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'DOMAIN\Username' } | Should -Be 'domainusername'
    }

    It 'Handles names with apostrophes and parentheses' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "O'Connor (Dev)" } | Should -Be 'oconnor-dev'
    }

    It 'Handles multiple whitespace types (tabs, multiple spaces)' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "first   second`tthird" } | Should -Be 'first-second-third'
    }
}

# ===== Resolve-CronAgentsUserName =====

Describe 'Resolve-CronAgentsUserName slugification' {
    It 'Slugifies config username with spaces' {
        Resolve-CronAgentsUserName -ConfigUserName 'Jane Smith' | Should -Be 'jane-smith'
    }

    It 'Slugifies config username with mixed case' {
        Resolve-CronAgentsUserName -ConfigUserName 'AdminUser' | Should -Be 'adminuser'
    }

    It 'Returns non-empty value from env:USERNAME fallback' {
        $result = Resolve-CronAgentsUserName
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match '^[a-z0-9][a-z0-9\-]*[a-z0-9]$|^[a-z0-9]$'
    }
}

# ===== Branch detection with temp git repos =====

Describe 'Branch detection in temp git repos' {
    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-ver-test-$(Get-Random)"
        New-Item $script:tempDir -ItemType Directory -Force | Out-Null
        Push-Location $script:tempDir
        & git init --initial-branch=main 2>&1 | Out-Null
        & git config user.email 'test@test.com' 2>&1 | Out-Null
        & git config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:tempDir 'readme.md') -Value '# Test'
        & git add . 2>&1 | Out-Null
        & git commit -m 'initial commit' 2>&1 | Out-Null
    }

    AfterAll {
        Pop-Location
        Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Identifies current branch as main' {
        $result = Get-CronAgentsBranch -RepoRoot $script:tempDir -UserName 'test-user'
        $result.CurrentBranch | Should -Be 'main'
    }

    It 'Reports IsUserBranch as false when on main' {
        $result = Get-CronAgentsBranch -RepoRoot $script:tempDir -UserName 'test-user'
        $result.IsUserBranch | Should -Be $false
    }

    It 'Reports IsUserBranch as true when on personal-agents/test-user' {
        & git -C $script:tempDir checkout -b 'personal-agents/test-user' 2>&1 | Out-Null
        try {
            $result = Get-CronAgentsBranch -RepoRoot $script:tempDir -UserName 'test-user'
            $result.IsUserBranch | Should -Be $true
            $result.CurrentBranch | Should -Be 'personal-agents/test-user'
        }
        finally {
            & git -C $script:tempDir checkout main 2>&1 | Out-Null
        }
    }

    It 'Builds expected branch from prefix and username' {
        $result = Get-CronAgentsBranch -RepoRoot $script:tempDir -BranchPrefix 'dev' -UserName 'alice'
        $result.ExpectedBranch | Should -Be 'dev/alice'
        $result.BranchPrefix | Should -Be 'dev'
    }

    It 'Resolves username from git config when no ConfigUserName' {
        $stubDir = Join-Path $script:tempDir 'bin'
        $originalPath = $env:PATH
        try {
            New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
            Set-Content -Path (Join-Path $stubDir 'gh.cmd') -Value "@echo off`r`nexit /b 1" -Encoding ASCII
            $env:PATH = "$stubDir;$originalPath"

            $result = Resolve-CronAgentsUserName -RepoRoot $script:tempDir
            $result | Should -Be 'test-user'
        }
        finally {
            $env:PATH = $originalPath
        }
    }
}

# ===== Config defaults for versioning =====

Describe 'Versioning config defaults' {
    It 'Missing versioning block yields true/notify/null/true/personal-agents defaults' {
        $configDir = Join-Path $TestDrive 'ver-defaults-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value '{}' -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.versioning.enabled            | Should -Be $true
        $cfg.versioning.syncPolicy         | Should -Be 'notify'
        $cfg.versioning.userName           | Should -BeNullOrEmpty
        $cfg.versioning.autoCommitFeedback | Should -Be $true
        $cfg.versioning.branchPrefix       | Should -Be 'personal-agents'
    }

    It 'Partial versioning block inherits other defaults' {
        $configDir = Join-Path $TestDrive 'ver-partial-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $json = '{ "versioning": { "syncPolicy": "auto" } }'
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.versioning.enabled            | Should -Be $true
        $cfg.versioning.syncPolicy         | Should -Be 'auto'
        $cfg.versioning.autoCommitFeedback | Should -Be $true
        $cfg.versioning.branchPrefix       | Should -Be 'personal-agents'
    }

    It 'Full versioning block overrides all defaults' {
        $configDir = Join-Path $TestDrive 'ver-full-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $json = @'
{
    "versioning": {
        "enabled": false,
        "syncPolicy": "manual",
        "userName": "custom-user",
        "autoCommitFeedback": false,
        "branchPrefix": "custom"
    }
}
'@
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.versioning.enabled            | Should -Be $false
        $cfg.versioning.syncPolicy         | Should -Be 'manual'
        $cfg.versioning.userName           | Should -Be 'custom-user'
        $cfg.versioning.autoCommitFeedback | Should -Be $false
        $cfg.versioning.branchPrefix       | Should -Be 'custom'
    }
}

Describe 'Test-CronAgentsVersioningEnabled' {
    It 'Returns true when versioning.enabled is omitted' {
        $cfg = [PSCustomObject]@{
            versioning = [PSCustomObject]@{
                syncPolicy         = 'notify'
                userName           = $null
                autoCommitFeedback = $true
                branchPrefix       = 'personal-agents'
            }
        }

        Test-CronAgentsVersioningEnabled -Config $cfg | Should -Be $true
    }

    It 'Returns false when versioning.enabled is false' {
        $cfg = [PSCustomObject]@{
            versioning = [PSCustomObject]@{
                enabled            = $false
                syncPolicy         = 'notify'
                userName           = $null
                autoCommitFeedback = $true
                branchPrefix       = 'personal-agents'
            }
        }

        Test-CronAgentsVersioningEnabled -Config $cfg | Should -Be $false
    }
}

# ===== Initialize-UserBranch in temp repos =====

Describe 'Initialize-UserBranch in temp repo' {
    BeforeAll {
        $script:initDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-init-test-$(Get-Random)"
        New-Item $script:initDir -ItemType Directory -Force | Out-Null
        & git -C $script:initDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $script:initDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $script:initDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:initDir 'file.txt') -Value 'init'
        & git -C $script:initDir add . 2>&1 | Out-Null
        & git -C $script:initDir commit -m 'init' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-Item -Path $script:initDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates user branch with default prefix' {
        $result = Initialize-UserBranch -RepoRoot $script:initDir -UserName 'alice'
        $result.BranchName | Should -Be 'personal-agents/alice'
        $result.Created | Should -Be $true
    }

    It 'Switches to existing branch on second call' {
        & git -C $script:initDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $script:initDir -UserName 'alice'
        $result.Created | Should -Be $false
        $result.BranchName | Should -Be 'personal-agents/alice'
    }

    It 'Creates branch with custom prefix' {
        & git -C $script:initDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $script:initDir -BranchPrefix 'team' -UserName 'bob'
        $result.BranchName | Should -Be 'team/bob'
        $result.Created | Should -Be $true
    }
}
