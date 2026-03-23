<#
.SYNOPSIS
    Pester 5 integration tests for git sync workflows.
    Tests Initialize-UserBranch and Invoke-BranchSync
    against temporary git repositories.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    # Helper: create a temp git repo with an initial commit on master
    function New-TempGitRepo {
        param([string]$Name)
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Git-$Name-$random"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        Push-Location $dir
        try {
            git init --initial-branch master 2>&1 | Out-Null
            git config user.email 'test@test.com' 2>&1 | Out-Null
            git config user.name 'Test User' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $dir 'README.md') -Value '# Test Repo' -Encoding UTF8
            git add . 2>&1 | Out-Null
            git commit -m 'Initial commit' 2>&1 | Out-Null
        }
        finally {
            Pop-Location
        }

        return $dir
    }

    function Remove-TempGitRepo {
        param([string]$Path)
        if ($Path -and (Test-Path $Path)) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Sync Workflow — Initialize-UserBranch' {
    BeforeEach {
        $script:gitRepo = New-TempGitRepo -Name 'SyncInit'
    }
    AfterEach {
        Remove-TempGitRepo -Path $script:gitRepo
    }

    It 'Creates branch from master when none exists' {
        $result = Initialize-UserBranch -RepoRoot $script:gitRepo `
            -BranchPrefix 'agents' -UserName 'test-user'

        $result.Created    | Should -Be $true
        $result.BranchName | Should -Be 'agents/test-user'
        $result.Message    | Should -Match 'Created new branch'

        # Verify we're on the new branch
        Push-Location $script:gitRepo
        try {
            $currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
            $currentBranch | Should -Be 'agents/test-user'
        }
        finally {
            Pop-Location
        }
    }

    It 'Checks out existing branch' {
        # Create the branch first
        Push-Location $script:gitRepo
        try {
            git checkout -b 'agents/test-user' 2>&1 | Out-Null
            git checkout master 2>&1 | Out-Null
        }
        finally {
            Pop-Location
        }

        $result = Initialize-UserBranch -RepoRoot $script:gitRepo `
            -BranchPrefix 'agents' -UserName 'test-user'

        $result.Created    | Should -Be $false
        $result.BranchName | Should -Be 'agents/test-user'
        $result.Message    | Should -Match 'existing branch'
    }

    It 'Aborts on dirty working tree' {
        # Create an uncommitted file
        Set-Content -Path (Join-Path $script:gitRepo 'dirty.txt') -Value 'uncommitted' -Encoding UTF8

        $result = Initialize-UserBranch -RepoRoot $script:gitRepo `
            -BranchPrefix 'agents' -UserName 'test-user'

        $result.Created | Should -Be $false
        $result.Message | Should -Match 'uncommitted changes'
    }
}

Describe 'Sync Workflow — Invoke-BranchSync' {
    BeforeEach {
        # Create a "remote" bare repo and a "local" clone
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $script:bareRepo  = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Bare-$random"
        $script:localRepo = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Local-$random"

        # Init bare repo
        New-Item -ItemType Directory -Path $script:bareRepo -Force | Out-Null
        Push-Location $script:bareRepo
        try { git init --bare 2>&1 | Out-Null } finally { Pop-Location }

        # Clone it
        git clone $script:bareRepo $script:localRepo 2>&1 | Out-Null

        Push-Location $script:localRepo
        try {
            git config user.email 'test@test.com' 2>&1 | Out-Null
            git config user.name 'Test User' 2>&1 | Out-Null
            # Create master with a commit
            git checkout -b master 2>&1 | Out-Null
            Set-Content -Path (Join-Path $script:localRepo 'README.md') -Value '# Base' -Encoding UTF8
            git add . 2>&1 | Out-Null
            git commit -m 'Base commit' 2>&1 | Out-Null
            git push origin master 2>&1 | Out-Null

            # Create user branch
            git checkout -b 'agents/test-user' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $script:localRepo 'agent.txt') -Value 'agent work' -Encoding UTF8
            git add . 2>&1 | Out-Null
            git commit -m 'Agent work' 2>&1 | Out-Null
        }
        finally { Pop-Location }
    }

    AfterEach {
        Remove-TempGitRepo -Path $script:localRepo
        Remove-TempGitRepo -Path $script:bareRepo
    }

    It 'Clean merge succeeds' {
        # Push a new commit to master in the bare repo via the local clone
        Push-Location $script:localRepo
        try {
            git checkout master 2>&1 | Out-Null
            Set-Content -Path (Join-Path $script:localRepo 'master-update.txt') -Value 'new on master' -Encoding UTF8
            git add . 2>&1 | Out-Null
            git commit -m 'Master update' 2>&1 | Out-Null
            git push origin master 2>&1 | Out-Null
            git checkout 'agents/test-user' 2>&1 | Out-Null
        }
        finally { Pop-Location }

        $result = Invoke-BranchSync -RepoRoot $script:localRepo -BaseBranch 'master'

        $result.Success    | Should -Be $true
        $result.CleanMerge | Should -Be $true
    }
}
