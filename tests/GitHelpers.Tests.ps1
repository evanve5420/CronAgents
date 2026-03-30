<#
.SYNOPSIS
    Pester 5 tests for PersonalRepo.ps1 — slug helpers,
    username resolution, and feedback commits for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== ConvertTo-Slug =====

Describe 'ConvertTo-Slug' {
    It 'Lowercases input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'Alice' } | Should -Be 'alice'
    }

    It 'Replaces spaces with hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'John Doe' } | Should -Be 'john-doe'
    }

    It 'Strips non-alphanumeric characters except hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'user@name!' } | Should -Be 'username'
    }

    It 'Collapses multiple hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'a - - b' } | Should -Be 'a-b'
    }

    It 'Trims leading and trailing hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '-hello-' } | Should -Be 'hello'
    }

    It 'Handles complex real-world names' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "O'Brien, Jane (Admin)" } | Should -Be 'obrien-jane-admin'
    }

    It 'Handles tab characters as whitespace' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "first`tsecond" } | Should -Be 'first-second'
    }

    It 'Handles purely numeric input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '12345' } | Should -Be '12345'
    }

    It 'Handles single character' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'A' } | Should -Be 'a'
    }

    It 'Handles empty-after-strip input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '!!!' } | Should -Be ''
    }
}

# ===== Resolve-CronAgentsUserName =====

Describe 'Resolve-CronAgentsUserName' {
    It 'Prefers ConfigUserName when provided' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Test User'
        $result | Should -Be 'test-user'
    }

    It 'Falls back to env:USERNAME when no config and no RepoRoot' {
        $result = Resolve-CronAgentsUserName
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Slugifies ConfigUserName with special characters' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Jane O Smith'
        $result | Should -Be 'jane-o-smith'
    }

    It 'Prefers git config github.user when given a RepoRoot' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-ghuser-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Git Config User' 2>&1 | Out-Null
            & git -C $tempDir config github.user 'octocat-user' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $tempDir 'f.txt') -Value 'x'
            & git -C $tempDir add . 2>&1 | Out-Null
            & git -C $tempDir commit -m 'init' 2>&1 | Out-Null

            $result = Resolve-CronAgentsUserName -RepoRoot $tempDir
            $result | Should -Be 'octocat-user'
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Reads git config user.name when no GitHub handle is available' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-username-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        $stubDir = Join-Path $tempDir 'bin'
        $originalPath = $env:PATH
        try {
            New-Item $stubDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $stubDir 'gh.cmd') -Value "@echo off`r`nexit /b 1" -Encoding ASCII
            $env:PATH = "$stubDir;$originalPath"

            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Git Config User' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $tempDir 'f.txt') -Value 'x'
            & git -C $tempDir add . 2>&1 | Out-Null
            & git -C $tempDir commit -m 'init' 2>&1 | Out-Null

            $result = Resolve-CronAgentsUserName -RepoRoot $tempDir
            $result | Should -Be 'git-config-user'
        }
        finally {
            $env:PATH = $originalPath
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ConfigUserName takes precedence over git config' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-username-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            & git -C $tempDir init 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Git User' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $tempDir 'f.txt') -Value 'x'
            & git -C $tempDir add . 2>&1 | Out-Null
            & git -C $tempDir commit -m 'init' 2>&1 | Out-Null

            $result = Resolve-CronAgentsUserName -ConfigUserName 'Override User' -RepoRoot $tempDir
            $result | Should -Be 'override-user'
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===== New-FeedbackCommit =====

Describe 'New-FeedbackCommit' {
    BeforeAll {
        $script:feedbackRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-feedback-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:feedbackRepoDir -Force | Out-Null
        & git -C $script:feedbackRepoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $script:feedbackRepoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $script:feedbackRepoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:feedbackRepoDir 'file.txt') -Value 'initial'
        & git -C $script:feedbackRepoDir add . 2>&1 | Out-Null
        & git -C $script:feedbackRepoDir commit -m 'init' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-Item -Path $script:feedbackRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates a feedback commit with correct message format' {
        Set-Content -Path (Join-Path $script:feedbackRepoDir 'feedback.md') -Value 'good work'
        $result = New-FeedbackCommit -RepoRoot $script:feedbackRepoDir -AgentId 'daily-review' -Summary 'Looks good' -ChangedFiles @('feedback.md')
        $result.Success | Should -Be $true
        $result.CommitHash | Should -Not -BeNullOrEmpty
        $result.CommitHash.Length | Should -BeGreaterOrEqual 7

        $msg = & git -C $script:feedbackRepoDir log -1 --format=%s
        $msg | Should -BeLike 'feedback: daily-review*Looks good'
    }

    It 'Returns failure when file does not exist' {
        $result = New-FeedbackCommit -RepoRoot $script:feedbackRepoDir -AgentId 'test' -Summary 'no-op' -ChangedFiles @('nonexistent.txt')
        $result.Success | Should -Be $false
        $result.CommitHash | Should -BeNullOrEmpty
        $result.Message | Should -Not -BeNullOrEmpty
    }
}
