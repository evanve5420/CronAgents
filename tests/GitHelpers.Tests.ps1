<#
.SYNOPSIS
    Pester 5 tests for GitHelpers.ps1 — git branch operations,
    username resolution, and slugification for CronAgents.
#>

BeforeAll {
    # Dot-source Logger first (GitHelpers depends on Write-CronAgentsLog)
    . (Join-Path $PSScriptRoot '..\scheduler\lib\Logger.ps1')
    . (Join-Path $PSScriptRoot '..\scheduler\lib\GitHelpers.ps1')
}

# ===== ConvertTo-Slug =====

Describe 'ConvertTo-Slug' {
    It 'Lowercases input' {
        ConvertTo-Slug -Value 'Alice' | Should -Be 'alice'
    }

    It 'Replaces spaces with hyphens' {
        ConvertTo-Slug -Value 'John Doe' | Should -Be 'john-doe'
    }

    It 'Strips non-alphanumeric characters except hyphens' {
        ConvertTo-Slug -Value 'user@name!' | Should -Be 'username'
    }

    It 'Collapses multiple hyphens' {
        ConvertTo-Slug -Value 'a - - b' | Should -Be 'a-b'
    }

    It 'Trims leading and trailing hyphens' {
        ConvertTo-Slug -Value '-hello-' | Should -Be 'hello'
    }

    It 'Handles complex real-world names' {
        ConvertTo-Slug -Value "O'Brien, Jane (Admin)" | Should -Be 'obrien-jane-admin'
    }

    It 'Handles multiple whitespace types' {
        ConvertTo-Slug -Value "first`tsecond" | Should -Be 'first-second'
    }
}

# ===== Resolve-CronAgentsUserName =====

Describe 'Resolve-CronAgentsUserName' {
    It 'Prefers ConfigUserName when provided' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Test User'
        $result | Should -Be 'test-user'
    }

    It 'Falls back to env:USERNAME when no config and no RepoRoot' {
        # env:USERNAME should always be set on Windows
        $result = Resolve-CronAgentsUserName
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Slugifies ConfigUserName' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Jane O Smith'
        $result | Should -Be 'jane-o-smith'
    }
}

# ===== Get-CronAgentsBranch =====

Describe 'Get-CronAgentsBranch' {
    BeforeAll {
        $repoDir = Join-Path $TestDrive 'branch-repo'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        & git -C $repoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $repoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'file.txt') -Value 'hello'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'init' 2>&1 | Out-Null
    }

    It 'Returns current branch name' {
        $result = Get-CronAgentsBranch -RepoRoot $repoDir -UserName 'someone'
        $result.CurrentBranch | Should -Be 'main'
    }

    It 'Detects when not on user branch' {
        $result = Get-CronAgentsBranch -RepoRoot $repoDir -UserName 'someone'
        $result.IsUserBranch | Should -Be $false
    }

    It 'Computes expected branch from prefix and username' {
        $result = Get-CronAgentsBranch -RepoRoot $repoDir -BranchPrefix 'agents' -UserName 'alice'
        $result.ExpectedBranch | Should -Be 'agents/alice'
        $result.BranchPrefix | Should -Be 'agents'
    }

    It 'Detects when on user branch' {
        & git -C $repoDir checkout -b 'agents/test-user' 2>&1 | Out-Null
        $result = Get-CronAgentsBranch -RepoRoot $repoDir -UserName 'test-user'
        $result.IsUserBranch | Should -Be $true
        $result.CurrentBranch | Should -Be 'agents/test-user'
        & git -C $repoDir checkout main 2>&1 | Out-Null
    }
}

# ===== Get-BranchDivergence =====

Describe 'Get-BranchDivergence' {
    BeforeAll {
        $repoDir = Join-Path $TestDrive 'diverge-repo'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        & git -C $repoDir init --initial-branch=master 2>&1 | Out-Null
        & git -C $repoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'file.txt') -Value 'base'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'base commit' 2>&1 | Out-Null

        # Create user branch and add a commit
        & git -C $repoDir checkout -b 'agents/tester' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'user-file.txt') -Value 'user change'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'user commit' 2>&1 | Out-Null

        # Go back to master and add a commit
        & git -C $repoDir checkout master 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'master-file.txt') -Value 'master change'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'master commit' 2>&1 | Out-Null
    }

    It 'Counts ahead and behind correctly' {
        $result = Get-BranchDivergence -RepoRoot $repoDir -UserBranch 'agents/tester' -BaseBranch 'master'
        $result.Ahead  | Should -Be 1
        $result.Behind | Should -Be 1
    }

    It 'Returns a LastSync datetime' {
        $result = Get-BranchDivergence -RepoRoot $repoDir -UserBranch 'agents/tester' -BaseBranch 'master'
        $result.LastSync | Should -Not -BeNullOrEmpty
        $result.LastSync | Should -BeOfType [datetime]
    }

    It 'Defaults UserBranch to current branch' {
        & git -C $repoDir checkout 'agents/tester' 2>&1 | Out-Null
        $result = Get-BranchDivergence -RepoRoot $repoDir -BaseBranch 'master'
        $result.Ahead | Should -Be 1
        & git -C $repoDir checkout master 2>&1 | Out-Null
    }
}

# ===== Initialize-UserBranch =====

Describe 'Initialize-UserBranch' {
    BeforeAll {
        $repoDir = Join-Path $TestDrive 'init-branch-repo'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        & git -C $repoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $repoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'file.txt') -Value 'init'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'init' 2>&1 | Out-Null
    }

    It 'Creates a new branch when it does not exist' {
        $result = Initialize-UserBranch -RepoRoot $repoDir -UserName 'newuser'
        $result.BranchName | Should -Be 'agents/newuser'
        $result.Created | Should -Be $true
        $result.Message | Should -BeLike '*Created*'

        # Verify we are on the new branch
        $current = & git -C $repoDir rev-parse --abbrev-ref HEAD
        $current | Should -Be 'agents/newuser'
    }

    It 'Checks out existing branch without creating' {
        & git -C $repoDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $repoDir -UserName 'newuser'
        $result.BranchName | Should -Be 'agents/newuser'
        $result.Created | Should -Be $false
        $result.Message | Should -BeLike '*existing*'
    }

    It 'Aborts on dirty working tree' {
        & git -C $repoDir checkout main 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'dirty.txt') -Value 'uncommitted'
        & git -C $repoDir add (Join-Path $repoDir 'dirty.txt') 2>&1 | Out-Null

        $result = Initialize-UserBranch -RepoRoot $repoDir -UserName 'dirtyuser'
        $result.Created | Should -Be $false
        $result.Message | Should -BeLike '*uncommitted*'

        # Clean up
        & git -C $repoDir reset HEAD -- dirty.txt 2>&1 | Out-Null
        Remove-Item (Join-Path $repoDir 'dirty.txt') -ErrorAction SilentlyContinue
    }

    It 'Respects custom BranchPrefix' {
        & git -C $repoDir checkout main 2>&1 | Out-Null
        $result = Initialize-UserBranch -RepoRoot $repoDir -BranchPrefix 'custom' -UserName 'bob'
        $result.BranchName | Should -Be 'custom/bob'
        $result.Created | Should -Be $true
    }
}

# ===== New-FeedbackCommit =====

Describe 'New-FeedbackCommit' {
    BeforeAll {
        $repoDir = Join-Path $TestDrive 'feedback-repo'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        & git -C $repoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $repoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'file.txt') -Value 'initial'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'init' 2>&1 | Out-Null
    }

    It 'Creates a feedback commit with correct message' {
        Set-Content -Path (Join-Path $repoDir 'feedback.md') -Value 'good work'
        $result = New-FeedbackCommit -RepoRoot $repoDir -AgentId 'daily-review' -Summary 'Looks good' -ChangedFiles @('feedback.md')
        $result.Success | Should -Be $true
        $result.CommitHash | Should -Not -BeNullOrEmpty
        $result.CommitHash.Length | Should -BeGreaterOrEqual 7

        # Verify commit message
        $msg = & git -C $repoDir log -1 --format=%s
        $msg | Should -BeLike 'feedback: daily-review*Looks good'
    }

    It 'Returns failure when no changes to commit' {
        $result = New-FeedbackCommit -RepoRoot $repoDir -AgentId 'test' -Summary 'no-op' -ChangedFiles @('nonexistent.txt')
        $result.Success | Should -Be $false
        $result.CommitHash | Should -BeNullOrEmpty
        $result.Message | Should -Not -BeNullOrEmpty
    }
}

# ===== Invoke-BranchSync =====

Describe 'Invoke-BranchSync' {
    It 'Returns failure when fetch fails on missing remote' {
        $repoDir = Join-Path $TestDrive 'sync-repo'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        & git -C $repoDir init --initial-branch=main 2>&1 | Out-Null
        & git -C $repoDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $repoDir config user.name 'Test User' 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repoDir 'file.txt') -Value 'hello'
        & git -C $repoDir add . 2>&1 | Out-Null
        & git -C $repoDir commit -m 'init' 2>&1 | Out-Null

        # No remote configured, so fetch should fail
        $result = Invoke-BranchSync -RepoRoot $repoDir -BaseBranch 'main'
        $result.Success | Should -Be $false
        $result.Message | Should -BeLike '*Fetch failed*'
    }

    It 'Performs a clean merge when no conflicts' {
        # Set up a "remote" (bare) and a clone
        $bareDir = Join-Path $TestDrive 'bare-sync'
        $cloneDir = Join-Path $TestDrive 'clone-sync'

        & git init --bare $bareDir 2>&1 | Out-Null
        & git clone $bareDir $cloneDir 2>&1 | Out-Null
        & git -C $cloneDir config user.email 'test@test.com' 2>&1 | Out-Null
        & git -C $cloneDir config user.name 'Test User' 2>&1 | Out-Null

        Set-Content -Path (Join-Path $cloneDir 'file.txt') -Value 'init'
        & git -C $cloneDir add . 2>&1 | Out-Null
        & git -C $cloneDir commit -m 'init' 2>&1 | Out-Null
        & git -C $cloneDir push origin master 2>&1 | Out-Null

        # Create user branch
        & git -C $cloneDir checkout -b agents/tester 2>&1 | Out-Null
        Set-Content -Path (Join-Path $cloneDir 'user.txt') -Value 'user work'
        & git -C $cloneDir add . 2>&1 | Out-Null
        & git -C $cloneDir commit -m 'user commit' 2>&1 | Out-Null

        # Add a non-conflicting commit to master via bare
        & git -C $cloneDir checkout master 2>&1 | Out-Null
        Set-Content -Path (Join-Path $cloneDir 'other.txt') -Value 'master work'
        & git -C $cloneDir add . 2>&1 | Out-Null
        & git -C $cloneDir commit -m 'master commit' 2>&1 | Out-Null
        & git -C $cloneDir push origin master 2>&1 | Out-Null

        # Switch to user branch and sync
        & git -C $cloneDir checkout agents/tester 2>&1 | Out-Null
        $result = Invoke-BranchSync -RepoRoot $cloneDir -BaseBranch 'master'
        $result.Success | Should -Be $true
        $result.CleanMerge | Should -Be $true
        $result.ConflictFiles | Should -HaveCount 0
    }
}
