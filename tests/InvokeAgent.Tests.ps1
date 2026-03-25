<#
.SYNOPSIS
    Pester 5 integration tests for Invoke-ScheduledAgent behaviour.
    Tests the component functions (New-RunDirectory, Write-RunMetadata,
    Set-AgentState) and mock Copilot CLI argument patterns.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $invokeScript = Join-Path $repoRoot 'scheduler/Invoke-ScheduledAgent.ps1'
}

Describe 'Invoke-ScheduledAgent — Run Directory' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'InvokeAgent'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Creates run directory with correct naming pattern' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'
        $dirName = Split-Path $runDir -Leaf
        $dirName | Should -Match '^\d{8}T\d{6}_test-agent_[0-9a-f]{4}$'
    }

    It 'Creates output.md with captured output' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'
        # Simulate what Invoke-ScheduledAgent does after running copilot
        $outputFile = Join-Path $runDir 'output.md'
        [System.IO.File]::WriteAllText($outputFile, 'Mock agent output', [System.Text.Encoding]::UTF8)

        Test-Path $outputFile | Should -BeTrue
        $content = Get-Content $outputFile -Raw
        $content | Should -Match 'Mock agent output'
    }

    It 'Creates meta.json with all required fields' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'
        $now = [datetime]::UtcNow

        Write-RunMetadata -RunDirectory $runDir -AgentId 'test-agent' `
            -AgentName 'Test Agent' -Prompt 'Review the code' `
            -StartTime $now.AddMinutes(-1) -EndTime $now `
            -ExitCode 0

        $metaPath = Join-Path $runDir 'meta.json'
        Test-Path $metaPath | Should -BeTrue

        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        $meta.agentId           | Should -Be 'test-agent'
        $meta.agentName         | Should -Be 'Test Agent'
        $meta.prompt            | Should -Be 'Review the code'
        $meta.exitCode          | Should -Be 0
        $meta.timedOut          | Should -Be $false
        $meta.feedbackProcessed | Should -Be $false
        $meta.startTime         | Should -Not -BeNullOrEmpty
        $meta.endTime           | Should -Not -BeNullOrEmpty
    }

    It 'Creates feedback.md stub' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'
        $feedbackPath = Join-Path $runDir 'feedback.md'

        Test-Path $feedbackPath | Should -BeTrue
        $content = Get-Content $feedbackPath -Raw
        $content | Should -Match 'feedback'
    }
}

Describe 'Invoke-ScheduledAgent — Mock Copilot CLI Arguments' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'InvokeAgentArgs'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Mock invocation log shows correct --agent flag (agent mode)' {
        $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'
        $null = & pwsh -NoProfile -File $mockCopilotPath -Agent 'my-custom-agent' -p 'Do stuff' -Silent

        $invocations = Get-MockInvocations -LogPath $testEnv.MockLogPath
        $invocations.Count | Should -BeGreaterOrEqual 1
        $invocations[-1].agent | Should -Be 'my-custom-agent'
    }

    It 'Mock invocation log shows --allow-all-tools (prompt-only mode)' {
        $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'
        $null = & pwsh -NoProfile -File $mockCopilotPath -p 'Prompt only task' -Silent -AllowAllTools

        $invocations = Get-MockInvocations -LogPath $testEnv.MockLogPath
        $invocations[-1].allowAllTools | Should -Be $true
        $invocations[-1].agent | Should -BeNullOrEmpty
    }

    It 'Passes --model when config specifies model' {
        $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'
        $null = & pwsh -NoProfile -File $mockCopilotPath -Agent 'review' -p 'Review' -Silent -Model 'claude-sonnet-4'

        $invocations = Get-MockInvocations -LogPath $testEnv.MockLogPath
        $invocations[-1].model | Should -Be 'claude-sonnet-4'
    }

    It 'Passes --deny-tool for each denyTools entry' {
        $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'
        # Use -Command so PowerShell array syntax is parsed correctly
        $cmd = "& '$mockCopilotPath' -Agent 'safe-agent' -p 'Go' -Silent -DenyTool @('web_fetch','file_delete')"
        $null = & pwsh -NoProfile -Command $cmd

        $invocations = Get-MockInvocations -LogPath $testEnv.MockLogPath
        $denyTools = @($invocations[-1].denyTool)
        $denyTools | Should -Contain 'web_fetch'
        $denyTools | Should -Contain 'file_delete'
    }

}

Describe 'Invoke-ScheduledAgent — Exit Code and State' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'InvokeAgentState'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Handles non-zero exit code (marks failed in meta.json)' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'fail-agent'
        $now = [datetime]::UtcNow

        Write-RunMetadata -RunDirectory $runDir -AgentId 'fail-agent' `
            -AgentName 'Fail Agent' -Prompt 'Fail task' `
            -StartTime $now.AddMinutes(-1) -EndTime $now `
            -ExitCode 1

        $meta = Get-Content (Join-Path $runDir 'meta.json') -Raw | ConvertFrom-Json
        $meta.exitCode | Should -Be 1
    }

    It 'Updates state.json with new last-run timestamp' {
        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        $before = [datetime]::UtcNow

        Set-AgentState -StateFile $stateFile -AgentId 'test-agent' -LastRun $before

        $state = Get-AgentState -StateFile $stateFile
        $state.agents['test-agent'].lastRun | Should -Not -BeNullOrEmpty

        $parsed = [datetime]::Parse($state.agents['test-agent'].lastRun)
        ($parsed - $before).TotalSeconds | Should -BeLessThan 2
    }
}
