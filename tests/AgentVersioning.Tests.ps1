<#
.SYNOPSIS
    Pester 5 tests for PersonalRepo.ps1 — slug, username resolution,
    and personal repo config defaults for CronAgents.
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

# ===== PersonalRepo config defaults =====

Describe 'PersonalRepo config defaults' {
    It 'Missing personalRepo block yields path=~/.cronagents, userName=null, autoCommitFeedback=true, defaultWorkingDirectory=null' {
        $configDir = Join-Path $TestDrive 'pr-defaults-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value '{}' -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.personalRepo.path                    | Should -Be '~/.cronagents'
        $cfg.personalRepo.userName                | Should -BeNullOrEmpty
        $cfg.personalRepo.autoCommitFeedback      | Should -Be $true
        $cfg.personalRepo.defaultWorkingDirectory | Should -BeNullOrEmpty
    }

    It 'Partial personalRepo block inherits defaults' {
        $configDir = Join-Path $TestDrive 'pr-partial-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $json = '{ "personalRepo": { "userName": "alice" } }'
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.personalRepo.userName                | Should -Be 'alice'
        $cfg.personalRepo.path                    | Should -Be '~/.cronagents'
        $cfg.personalRepo.autoCommitFeedback      | Should -Be $true
        $cfg.personalRepo.defaultWorkingDirectory | Should -BeNullOrEmpty
    }

    It 'Full personalRepo block overrides all defaults' {
        $configDir = Join-Path $TestDrive 'pr-full-test'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $json = @'
{
    "personalRepo": {
        "path": "~/my-agents",
        "userName": "custom-user",
        "autoCommitFeedback": false,
        "defaultWorkingDirectory": "C:\\work"
    }
}
'@
        Set-Content -Path (Join-Path $configDir 'cronagents.json') -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath (Join-Path $configDir 'cronagents.json')
        $cfg.personalRepo.path                    | Should -Be '~/my-agents'
        $cfg.personalRepo.userName                | Should -Be 'custom-user'
        $cfg.personalRepo.autoCommitFeedback      | Should -Be $false
        $cfg.personalRepo.defaultWorkingDirectory | Should -Be 'C:\work'
    }
}
