<#
.SYNOPSIS
    Pester 5 tests for feedback targeting: Get-FeedbackTarget and
    Read-SubagentManifest functions, and integration with Get-RunHistory.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

Describe 'Get-FeedbackTarget' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-FeedbackTarget-$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $script:tempDir) {
            Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns HasTarget=$false when file does not exist' {
        $result = Get-FeedbackTarget -FeedbackPath (Join-Path $script:tempDir 'nonexistent.md')
        $result.HasTarget | Should -Be $false
        $result.Agent | Should -BeNullOrEmpty
        $result.Files | Should -HaveCount 0
    }

    It 'Returns HasTarget=$false for feedback without ## Target section' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        Set-Content -LiteralPath $fbPath -Value "Too verbose. Focus only on security issues." -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $false
        $result.Agent | Should -BeNullOrEmpty
        $result.FeedbackText | Should -BeLike '*Too verbose*'
    }

    It 'Returns HasTarget=$false for empty feedback file' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        Set-Content -LiteralPath $fbPath -Value '' -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $false
    }

    It 'Returns HasTarget=$false for comment-only feedback stub' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
<!-- Feedback for agent run: my-agent -->
<!-- Write your feedback below. -->
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $false
        $result.FeedbackText | Should -BeNullOrEmpty
    }

    It 'Parses ## Target with agent and files' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: worker
files:
- .github/agents/worker.agent.md
- .github/skills/worker/SKILL.md

## Feedback
The worker should validate inputs before editing files.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Agent | Should -Be 'worker'
        $result.Files | Should -HaveCount 2
        $result.Files[0] | Should -Be '.github/agents/worker.agent.md'
        $result.Files[1] | Should -Be '.github/skills/worker/SKILL.md'
        $result.FeedbackText | Should -BeLike '*validate inputs*'
    }

    It 'Parses ## Target with agent only (no files)' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: security-scanner

## Feedback
Stop flagging test fixtures.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Agent | Should -Be 'security-scanner'
        $result.Files | Should -HaveCount 0
        $result.FeedbackText | Should -BeLike '*test fixtures*'
    }

    It 'Strips HTML comment lines before parsing' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
<!-- Feedback for agent run: orchestrator -->
<!-- Write your feedback below. -->

## Target
agent: worker

## Feedback
Be more careful with edits.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Agent | Should -Be 'worker'
        $result.FeedbackText | Should -BeLike '*more careful*'
    }

    It 'Preserves feedback text outside of ## Target section' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
Some preamble text.

## Target
agent: docs-gen

## Feedback
Add examples to the docs.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Agent | Should -Be 'docs-gen'
        $result.FeedbackText | Should -BeLike '*preamble*'
        $result.FeedbackText | Should -BeLike '*Add examples*'
    }

    It 'Returns HasTarget=$false when ## Target has no agent field' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
files:
- some/file.md

## Feedback
Missing agent field.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $false
    }

    It 'Handles inline files: value on the same line' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: worker
files: .github/agents/worker.agent.md

## Feedback
Fix the inline file case.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Agent | Should -Be 'worker'
        $result.Files | Should -HaveCount 1
        $result.Files[0] | Should -Be '.github/agents/worker.agent.md'
    }

    It 'Rejects file paths with directory traversal' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: worker
files:
- ../../etc/passwd
- .github/agents/worker.agent.md

## Feedback
Traversal should be filtered.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $true
        $result.Files | Should -HaveCount 1
        $result.Files[0] | Should -Be '.github/agents/worker.agent.md'
    }

    It 'Rejects absolute file paths' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: worker
files:
- /etc/passwd
- .github/agents/worker.agent.md

## Feedback
Absolute path should be filtered.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.Files | Should -HaveCount 1
        $result.Files[0] | Should -Be '.github/agents/worker.agent.md'
    }

    It 'Returns HasTarget=$false for invalid agent name' {
        $fbPath = Join-Path $script:tempDir 'feedback.md'
        $content = @"
## Target
agent: ../evil/agent

## Feedback
Invalid agent name.
"@
        Set-Content -LiteralPath $fbPath -Value $content -Encoding UTF8

        $result = Get-FeedbackTarget -FeedbackPath $fbPath
        $result.HasTarget | Should -Be $false
        $result.Agent | Should -BeNullOrEmpty
    }
}

Describe 'Read-SubagentManifest' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Manifest-$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $script:tempDir) {
            Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns empty array when subagents.json does not exist' {
        $result = Read-SubagentManifest -RunDirectory $script:tempDir
        $result | Should -HaveCount 0
    }

    It 'Reads a valid manifest array' {
        $manifest = @(
            @{ name = 'worker'; agent = 'worker'; profile = '.github/agents/worker.agent.md'; skills = @('.github/skills/worker/SKILL.md') }
            @{ name = 'reviewer'; agent = 'code-reviewer'; profile = '.github/agents/code-reviewer.agent.md'; skills = @() }
        )
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $script:tempDir)
        $result | Should -HaveCount 2
        $result[0].Name | Should -Be 'worker'
        $result[0].Agent | Should -Be 'worker'
        $result[0].Profile | Should -Be '.github/agents/worker.agent.md'
        $result[0].Skills | Should -HaveCount 1
        $result[1].Name | Should -Be 'reviewer'
        $result[1].Agent | Should -Be 'code-reviewer'
    }

    It 'Reads a single-object manifest (not wrapped in array)' {
        $manifest = @{ name = 'solo'; agent = 'solo-agent'; profile = 'agents/solo.agent.md'; skills = @() }
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $script:tempDir)
        $result | Should -HaveCount 1
        $result[0].Name | Should -Be 'solo'
    }

    It 'Skips entries missing required fields' {
        $manifest = @(
            @{ name = 'good'; agent = 'good-agent' }
            @{ name = 'bad-no-agent' }
            @{ agent = 'bad-no-name' }
        )
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $script:tempDir)
        $result | Should -HaveCount 1
        $result[0].Name | Should -Be 'good'
    }

    It 'Skips entries with invalid name or agent identifiers' {
        $manifest = @(
            @{ name = 'valid'; agent = 'valid-agent' }
            @{ name = '../bad'; agent = 'ok' }
            @{ name = 'ok'; agent = 'has spaces' }
        )
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $script:tempDir)
        $result | Should -HaveCount 1
        $result[0].Name | Should -Be 'valid'
    }

    It 'Returns empty array for invalid JSON' {
        Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Value 'not json' -Encoding UTF8

        $result = Read-SubagentManifest -RunDirectory $script:tempDir
        $result | Should -HaveCount 0
    }

    It 'Handles missing optional fields gracefully' {
        $manifest = @(
            @{ name = 'minimal'; agent = 'min-agent' }
        )
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:tempDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $script:tempDir)
        $result | Should -HaveCount 1
        $result[0].Profile | Should -BeNullOrEmpty
        $result[0].Skills | Should -HaveCount 0
    }
}

Describe 'Feedback targeting integration' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'FeedbackTargeting'
    }

    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Get-RunHistory includes runs that have targeted feedback' {
        $now = [datetime]::UtcNow
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'orchestrator'
        Write-RunMetadata -RunDirectory $runDir -AgentId 'orchestrator' `
            -AgentName 'Orchestrator' -Prompt 'Scan all modules' `
            -StartTime $now.AddMinutes(-5) -EndTime $now.AddMinutes(-4) -ExitCode 0

        # Write targeted feedback
        $content = @"
## Target
agent: worker

## Feedback
Validate inputs before editing.
"@
        Set-Content -LiteralPath (Join-Path $runDir 'feedback.md') -Value $content -Encoding UTF8

        $runs = Get-RunHistory -RunsRoot $testEnv.RunsRoot
        $run = $runs | Where-Object { $_.AgentId -eq 'orchestrator' }
        $run | Should -Not -BeNullOrEmpty
        $run.HasFeedback | Should -Be $true
        $run.FeedbackProcessed | Should -Be $false

        # Verify target can be parsed from the run's feedback
        $target = Get-FeedbackTarget -FeedbackPath (Join-Path $run.RunDirectory 'feedback.md')
        $target.HasTarget | Should -Be $true
        $target.Agent | Should -Be 'worker'
    }

    It 'Subagent manifest is readable from a run directory' {
        $now = [datetime]::UtcNow
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'orchestrator'
        Write-RunMetadata -RunDirectory $runDir -AgentId 'orchestrator' `
            -AgentName 'Orchestrator' -Prompt 'Scan all modules' `
            -StartTime $now.AddMinutes(-3) -EndTime $now.AddMinutes(-2) -ExitCode 0

        # Write subagent manifest
        $manifest = @(
            @{ name = 'worker'; agent = 'worker'; profile = '.github/agents/worker.agent.md'; skills = @('.github/skills/worker/SKILL.md') }
        )
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $runDir 'subagents.json') -Encoding UTF8

        $result = @(Read-SubagentManifest -RunDirectory $runDir)
        $result | Should -HaveCount 1
        $result[0].Name | Should -Be 'worker'
        $result[0].Profile | Should -Be '.github/agents/worker.agent.md'
    }
}
