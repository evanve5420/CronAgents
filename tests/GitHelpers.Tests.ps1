<#
.SYNOPSIS
    Pester 5 tests for GitHelpers.ps1 — git branch operations,
    username resolution, and slugification for CronAgents.
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

# ===== Get-CronAgentsBranch =====

Describe 'Get-CronAgentsBranch' {
    BeforeAll {
        $script:branchRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-branch-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:branchRepoDir -Force | Out-Null
        & git -C $script:branchRepoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $script:branchRepoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $script:branchRepoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:branchRepoDir 'file.txt') -Value 'hello'
        & git -C $script:branchRepoDir add . 2>&1 | Out-Null
        & git -C $script:branchRepoDir commit -m 'init' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-Item -Path $script:branchRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns current branch name' {
        $result = Get-CronAgentsBranch -RepoRoot $script:branchRepoDir -UserName 'someone'
        $result.CurrentBranch | Should -Be 'main'
    }

    It 'Detects when not on user branch' {
        $result = Get-CronAgentsBranch -RepoRoot $script:branchRepoDir -UserName 'someone'
        $result.IsUserBranch | Should -Be $false
    }

    It 'Computes expected branch from prefix and username' {
        $result = Get-CronAgentsBranch -RepoRoot $script:branchRepoDir -BranchPrefix 'agents' -UserName 'alice'
        $result.ExpectedBranch | Should -Be 'agents/alice'
        $result.BranchPrefix | Should -Be 'agents'
    }

    It 'Detects when on user branch' {
        & git -C $script:branchRepoDir checkout -b 'personal-agents/test-user' 2>&1 | Out-Null
        try {
            $result = Get-CronAgentsBranch -RepoRoot $script:branchRepoDir -UserName 'test-user'
            $result.IsUserBranch | Should -Be $true
            $result.CurrentBranch | Should -Be 'personal-agents/test-user'
        }
        finally {
            & git -C $script:branchRepoDir checkout main 2>&1 | Out-Null
        }
    }

    It 'Uses default BranchPrefix of personal-agents' {
        $result = Get-CronAgentsBranch -RepoRoot $script:branchRepoDir -UserName 'bob'
        $result.ExpectedBranch | Should -Be 'personal-agents/bob'
    }
}

# ===== Get-BranchDivergence =====

Describe 'Get-BranchDivergence' {
    BeforeAll {
        $script:divergeRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-diverge-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:divergeRepoDir -Force | Out-Null
        & git -C $script:divergeRepoDir init --initial-branch=master 2>&1 | Out-Null
        & git -C $script:divergeRepoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $script:divergeRepoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:divergeRepoDir 'file.txt') -Value 'base'
        & git -C $script:divergeRepoDir add . 2>&1 | Out-Null
        & git -C $script:divergeRepoDir commit -m 'base commit' 2>&1 | Out-Null

        # Create user branch and add a commit
        & git -C $script:divergeRepoDir checkout -b 'agents/tester' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:divergeRepoDir 'user-file.txt') -Value 'user change'
        & git -C $script:divergeRepoDir add . 2>&1 | Out-Null
        & git -C $script:divergeRepoDir commit -m 'user commit' 2>&1 | Out-Null

        # Go back to master and add a commit
        & git -C $script:divergeRepoDir checkout master 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:divergeRepoDir 'master-file.txt') -Value 'master change'
        & git -C $script:divergeRepoDir add . 2>&1 | Out-Null
        & git -C $script:divergeRepoDir commit -m 'master commit' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-Item -Path $script:divergeRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Counts ahead and behind correctly' {
        $result = Get-BranchDivergence -RepoRoot $script:divergeRepoDir -UserBranch 'agents/tester' -BaseBranch 'master'
        $result.Ahead  | Should -Be 1
        $result.Behind | Should -Be 1
    }

    It 'Returns a LastSync datetime' {
        $result = Get-BranchDivergence -RepoRoot $script:divergeRepoDir -UserBranch 'agents/tester' -BaseBranch 'master'
        $result.LastSync | Should -Not -BeNullOrEmpty
        $result.LastSync | Should -BeOfType [datetime]
    }

    It 'Defaults UserBranch to current branch' {
        & git -C $script:divergeRepoDir checkout 'agents/tester' 2>&1 | Out-Null
        try {
            $result = Get-BranchDivergence -RepoRoot $script:divergeRepoDir -BaseBranch 'master'
            $result.Ahead | Should -Be 1
        }
        finally {
            & git -C $script:divergeRepoDir checkout master 2>&1 | Out-Null
        }
    }
}

# ===== Initialize-UserBranch =====

Describe 'Initialize-UserBranch' {
    BeforeAll {
        $script:initBranchDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-initbranch-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:initBranchDir -Force | Out-Null
        & git -C $script:initBranchDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $script:initBranchDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $script:initBranchDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:initBranchDir 'file.txt') -Value 'init'
        & git -C $script:initBranchDir add . 2>&1 | Out-Null
        & git -C $script:initBranchDir commit -m 'init' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-Item -Path $script:initBranchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates a new branch when it does not exist' {
        $result = Initialize-UserBranch -RepoRoot $script:initBranchDir -UserName 'newuser'
        $result.BranchName | Should -Be 'personal-agents/newuser'
        $result.Created | Should -Be $true
        $result.Message | Should -BeLike '*Created*'

        $current = & git -C $script:initBranchDir rev-parse --abbrev-ref HEAD
        $current | Should -Be 'personal-agents/newuser'
    }

    It 'Checks out existing branch without creating' {
        & git -C $script:initBranchDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $script:initBranchDir -UserName 'newuser'
        $result.BranchName | Should -Be 'personal-agents/newuser'
        $result.Created | Should -Be $false
        $result.Message | Should -BeLike '*existing*'
    }

    It 'Aborts on dirty working tree' {
        & git -C $script:initBranchDir checkout main 2>&1 | Out-Null
        Set-Content -Path (Join-Path $script:initBranchDir 'dirty.txt') -Value 'uncommitted'
        & git -C $script:initBranchDir add (Join-Path $script:initBranchDir 'dirty.txt') 2>&1 | Out-Null

        $result = Initialize-UserBranch -RepoRoot $script:initBranchDir -UserName 'dirtyuser'
        $result.Created | Should -Be $false
        $result.Message | Should -BeLike '*uncommitted*'

        & git -C $script:initBranchDir reset HEAD -- dirty.txt 2>&1 | Out-Null
        Remove-Item (Join-Path $script:initBranchDir 'dirty.txt') -ErrorAction SilentlyContinue
    }

    It 'Respects custom BranchPrefix' {
        & git -C $script:initBranchDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $script:initBranchDir -BranchPrefix 'custom' -UserName 'bob'
        $result.BranchName | Should -Be 'custom/bob'
        $result.Created | Should -Be $true
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

# ===== Invoke-BranchSync =====

Describe 'Invoke-BranchSync' {
    It 'Returns failure when fetch fails on missing remote' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-sync-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            & git -C $tempDir init --initial-branch=main 2>&1 | Out-Null
            & git -C $tempDir config user.email 'test@test.com' 2>&1 | Out-Null
            & git -C $tempDir config user.name 'Test User' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $tempDir 'file.txt') -Value 'hello'
            & git -C $tempDir add . 2>&1 | Out-Null
            & git -C $tempDir commit -m 'init' 2>&1 | Out-Null

            $result = Invoke-BranchSync -RepoRoot $tempDir -BaseBranch 'main'
            $result.Success | Should -Be $false
            $result.Message | Should -BeLike '*Fetch failed*'
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Versioning config defaults' {
    It 'Missing versioning block yields notify/null/true/personal-agents' {
        $configDir = Join-Path $TestDrive 'ver-defaults'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $json = '{}'
        $path = Join-Path $configDir 'cronagents.json'
        Set-Content -Path $path -Value $json -Encoding UTF8

        $cfg = Import-CronAgentsConfig -ConfigPath $path
        $cfg.versioning.syncPolicy         | Should -Be 'notify'
        $cfg.versioning.userName           | Should -BeNullOrEmpty
        $cfg.versioning.autoCommitFeedback | Should -Be $true
        $cfg.versioning.branchPrefix       | Should -Be 'personal-agents'
    }
}
