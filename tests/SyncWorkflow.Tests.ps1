<#
.SYNOPSIS
    Pester 5 integration tests for personal repo workflows.
    Tests Initialize-PersonalRepo and agent discovery against
    temporary git repositories.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    # Helper: create a temp personal repo with full structure
    function New-TempPersonalRepo {
        param([string]$Name, [string]$UserName = 'test-user')
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-PR-$Name-$random"

        $result = Initialize-PersonalRepo -Path $dir -UserName $UserName
        return $dir
    }

    function Remove-TempRepo {
        param([string]$Path)
        if ($Path -and (Test-Path $Path)) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Personal Repo Workflow — Initialize-PersonalRepo' {
    BeforeEach {
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $script:repoDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-PRWorkflow-$random"
    }
    AfterEach {
        Remove-TempRepo -Path $script:repoDir
    }

    It 'Creates personal repo from scratch' {
        $result = Initialize-PersonalRepo -Path $script:repoDir -UserName 'test-user'

        $result.Created | Should -Be $true
        $result.Path    | Should -Be $script:repoDir

        # Verify git repo
        (Test-Path (Join-Path $script:repoDir '.git')) | Should -Be $true

        # Verify full directory structure
        (Test-Path (Join-Path $script:repoDir '.github' 'agents'))     | Should -Be $true
        (Test-Path (Join-Path $script:repoDir '.github' 'skills'))     | Should -Be $true
        (Test-Path (Join-Path $script:repoDir '.cronagents' 'agents')) | Should -Be $true
        (Test-Path (Join-Path $script:repoDir '.cronstate' 'runs'))    | Should -Be $true

        # Verify validation passes
        $validation = Test-PersonalRepoValid -Path $script:repoDir
        $validation.Valid | Should -Be $true
    }

    It 'Is idempotent — second call returns Created=false' {
        $first = Initialize-PersonalRepo -Path $script:repoDir -UserName 'test-user'
        $first.Created | Should -Be $true

        $second = Initialize-PersonalRepo -Path $script:repoDir -UserName 'test-user'
        $second.Created | Should -Be $false
        $second.Path    | Should -Be $script:repoDir
    }

    It 'Configures git user from environment' {
        Initialize-PersonalRepo -Path $script:repoDir -UserName 'test-user' | Out-Null

        $gitUserName  = & git -C $script:repoDir config user.name 2>&1
        $gitUserEmail = & git -C $script:repoDir config user.email 2>&1

        $gitUserName  | Should -Not -BeNullOrEmpty
        $gitUserEmail | Should -Not -BeNullOrEmpty
    }
}

Describe 'Personal Repo Workflow — Agent Discovery' {
    BeforeAll {
        # Create an infra repo with a .cronagents/agents dir and one agent
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $script:infraRepo = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Infra-$random"
        New-Item -ItemType Directory -Path (Join-Path $script:infraRepo '.cronagents' 'agents') -Force | Out-Null

        $infraAgent = [ordered]@{
            name     = 'Shared Agent'
            schedule = [ordered]@{ type = 'daily'; time = '09:00' }
            prompt   = 'Do shared things'
        }
        $infraAgent | ConvertTo-Json | Set-Content -Path (Join-Path $script:infraRepo '.cronagents' 'agents' 'shared-agent.agent-registration.json') -Encoding UTF8
    }

    AfterAll {
        Remove-TempRepo -Path $script:infraRepo
        Remove-TempRepo -Path $script:personalRepo
    }

    BeforeEach {
        $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $script:personalRepo = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-PersonalDisc-$random"
        New-Item -ItemType Directory -Path (Join-Path $script:personalRepo '.cronagents' 'agents') -Force | Out-Null
    }

    AfterEach {
        Remove-TempRepo -Path $script:personalRepo
    }

    It 'Discovers agents from personal repo' {
        $personalAgent = [ordered]@{
            name     = 'My Agent'
            schedule = [ordered]@{ type = 'daily'; time = '08:00' }
            prompt   = 'Do personal things'
        }
        $personalAgent | ConvertTo-Json | Set-Content -Path (Join-Path $script:personalRepo '.cronagents' 'agents' 'my-agent.agent-registration.json') -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $script:infraRepo -PersonalRepoPath $script:personalRepo
        $agentIds = $agents | ForEach-Object { $_.Id }
        $agentIds | Should -Contain 'my-agent'
    }

    It 'Personal repo agents take precedence over infra repo' {
        # Create an agent in personal repo with same ID as infra repo
        $overrideAgent = [ordered]@{
            name     = 'My Shared Override'
            schedule = [ordered]@{ type = 'daily'; time = '10:00' }
            prompt   = 'Personal override of shared agent'
        }
        $overrideAgent | ConvertTo-Json | Set-Content -Path (Join-Path $script:personalRepo '.cronagents' 'agents' 'shared-agent.agent-registration.json') -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $script:infraRepo -PersonalRepoPath $script:personalRepo
        $sharedAgent = $agents | Where-Object { $_.Id -eq 'shared-agent' }
        $sharedAgent | Should -Not -BeNullOrEmpty
        $sharedAgent.Config.prompt | Should -Be 'Personal override of shared agent'
    }

    It 'Infra agent with "agent" field resolves against infra repo, not personal repo' {
        # Place a .agent.md in the infra repo only
        $infraGhAgents = Join-Path $script:infraRepo '.github' 'agents'
        New-Item -ItemType Directory -Path $infraGhAgents -Force | Out-Null
        Set-Content -Path (Join-Path $infraGhAgents 'infra-review.agent.md') `
            -Value '# Infra Review Agent' -Encoding UTF8

        # Register an infra agent that references the .agent.md by name
        $infraReg = [ordered]@{
            name     = 'Infra Review'
            agent    = 'infra-review'
            schedule = [ordered]@{ type = 'daily'; time = '07:00' }
            prompt   = 'Review infra'
        }
        $infraReg | ConvertTo-Json | Set-Content `
            -Path (Join-Path $script:infraRepo '.cronagents' 'agents' 'infra-review.agent-registration.json') `
            -Encoding UTF8

        $agents = Get-AgentConfigs -RepoRoot $script:infraRepo -PersonalRepoPath $script:personalRepo
        $review = $agents | Where-Object { $_.Id -eq 'infra-review' }
        $review | Should -Not -BeNullOrEmpty
        # The AgentFilePath must resolve inside the infra repo, not be $null
        $review.AgentFilePath | Should -Not -BeNullOrEmpty
        $review.AgentFilePath | Should -BeLike "$($script:infraRepo)*"
    }
}
