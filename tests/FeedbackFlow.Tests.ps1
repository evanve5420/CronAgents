<#
.SYNOPSIS
    Pester 5 integration tests for the feedback lifecycle.
    Tests feedback discovery, filtering, and processing via
    Get-RunHistory and meta.json manipulation.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

Describe 'Feedback Flow' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'FeedbackFlow'

        # Create run directories with the correct naming pattern
        $now = [datetime]::UtcNow

        # Run 1: has non-empty feedback, not processed
        $runDir1 = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a'
        Write-RunMetadata -RunDirectory $runDir1 -AgentId 'agent-a' `
            -AgentName 'Agent A' -Prompt 'Task A' `
            -StartTime $now.AddMinutes(-10) -EndTime $now.AddMinutes(-9) `
            -ExitCode 0
        $fbPath1 = Join-Path $runDir1 'feedback.md'
        Set-Content -LiteralPath $fbPath1 -Value "Great work, but please add more tests." -Encoding UTF8

        # Run 2: has empty feedback.md (only comment stubs)
        $runDir2 = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-b'
        Write-RunMetadata -RunDirectory $runDir2 -AgentId 'agent-b' `
            -AgentName 'Agent B' -Prompt 'Task B' `
            -StartTime $now.AddMinutes(-8) -EndTime $now.AddMinutes(-7) `
            -ExitCode 0
        # feedback.md is already a stub from New-RunDirectory (comments only)

        # Run 3: feedback already processed
        $runDir3 = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-c'
        $metaContent = [ordered]@{
            agentId           = 'agent-c'
            agentName         = 'Agent C'
            prompt            = 'Task C'
            startTime         = $now.AddMinutes(-6).ToString('yyyy-MM-ddTHH:mm:ss')
            endTime           = $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ss')
            exitCode          = 0
            timedOut          = $false
            retryAttempt      = 0
            feedbackProcessed = $true
        }
        $metaContent | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $runDir3 'meta.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runDir3 'feedback.md') -Value "Already processed feedback." -Encoding UTF8

        $script:runDir1 = $runDir1
        $script:runDir2 = $runDir2
        $script:runDir3 = $runDir3
    }

    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Finds runs with non-empty feedback.md and feedbackProcessed=false' {
        $runs = Get-RunHistory -RunsRoot $testEnv.RunsRoot
        $pending = @($runs | Where-Object { $_.HasFeedback -and -not $_.FeedbackProcessed })

        $pending.Count | Should -BeGreaterOrEqual 1
        $pending.AgentId | Should -Contain 'agent-a'
    }

    It 'Skips runs with empty feedback.md' {
        $runs = Get-RunHistory -RunsRoot $testEnv.RunsRoot
        $agentBRun = $runs | Where-Object { $_.AgentId -eq 'agent-b' }
        $agentBRun | Should -Not -BeNullOrEmpty
        $agentBRun.HasFeedback | Should -Be $false
    }

    It 'Skips runs where feedbackProcessed is already true' {
        $runs = Get-RunHistory -RunsRoot $testEnv.RunsRoot
        $pending = @($runs | Where-Object { $_.HasFeedback -and -not $_.FeedbackProcessed })

        # agent-c has feedback but is already processed — should NOT be in pending
        $pending.AgentId | Should -Not -Contain 'agent-c'
    }

    It 'After processing: meta.json shows feedbackProcessed=true' {
        # Simulate the evaluator marking feedback as processed
        $metaPath = Join-Path $script:runDir1 'meta.json'
        $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $meta.feedbackProcessed = $true
        $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding UTF8

        # Re-read and verify
        $runs = Get-RunHistory -RunsRoot $testEnv.RunsRoot
        $agentARun = $runs | Where-Object { $_.AgentId -eq 'agent-a' }
        $agentARun.FeedbackProcessed | Should -Be $true
    }
}
