<#
.SYNOPSIS
    Pester 5 integration tests for Invoke-RetentionCleanup.
    Tests run directory lifecycle: deletion, preservation,
    feedback-protected runs, and retentionDays=0.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    # Helper: creates a fake run directory with the expected naming pattern
    function New-FakeRunDir {
        param(
            [string]$RunsRoot,
            [string]$AgentId,
            [datetime]$Timestamp,
            [string]$FeedbackContent,
            [switch]$FeedbackProcessed
        )
        $ts   = $Timestamp.ToString('yyyyMMddTHHmmss')
        $name = "${ts}_${AgentId}_abcd"
        $dir  = Join-Path $RunsRoot $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        # Create meta.json
        $meta = [ordered]@{
            agentId           = $AgentId
            agentName         = $AgentId
            prompt            = 'test'
            startTime         = $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
            endTime           = $Timestamp.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss')
            exitCode          = 0
            timedOut          = $false
            retryAttempt      = 0
            feedbackProcessed = [bool]$FeedbackProcessed
        }
        $meta | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

        # Create feedback.md
        if ($FeedbackContent) {
            Set-Content -LiteralPath (Join-Path $dir 'feedback.md') -Value $FeedbackContent -Encoding UTF8
        }
        else {
            # Write only comment stubs (empty feedback)
            $stub = "<!-- Feedback for agent run: $AgentId -->`n<!-- Leave empty to skip. -->`n"
            Set-Content -LiteralPath (Join-Path $dir 'feedback.md') -Value $stub -Encoding UTF8 -NoNewline
        }

        return $dir
    }
}

Describe 'Retention Cleanup' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'Retention'
        $script:stateFile = Join-Path $testEnv.StatePath 'state.json'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Deletes run directories older than retentionDays' {
        $old = [datetime]::UtcNow.AddDays(-20)
        $oldDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent' -Timestamp $old

        $result = Invoke-RetentionCleanup -RunsRoot $testEnv.RunsRoot `
            -RetentionDays 14 -StateFile $script:stateFile `
            -DiscoveredAgentIds @('test-agent')

        Test-Path $oldDir | Should -Be $false
        $result.DeletedCount | Should -BeGreaterOrEqual 1
    }

    It 'Preserves run directories within retentionDays' {
        $recent = [datetime]::UtcNow.AddDays(-3)
        $recentDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent' -Timestamp $recent

        $result = Invoke-RetentionCleanup -RunsRoot $testEnv.RunsRoot `
            -RetentionDays 14 -StateFile $script:stateFile `
            -DiscoveredAgentIds @('test-agent')

        Test-Path $recentDir | Should -Be $true
        $result.PreservedCount | Should -BeGreaterOrEqual 1
    }

    It 'Does NOT delete runs with unprocessed feedback regardless of age' {
        $old = [datetime]::UtcNow.AddDays(-30)
        $protectedDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent' `
            -Timestamp $old -FeedbackContent 'Please fix the linting issues.'

        $result = Invoke-RetentionCleanup -RunsRoot $testEnv.RunsRoot `
            -RetentionDays 7 -StateFile $script:stateFile `
            -DiscoveredAgentIds @('test-agent')

        Test-Path $protectedDir | Should -Be $true
        $result.PreservedCount | Should -BeGreaterOrEqual 1
    }

    It 'retentionDays=0 means never delete' {
        $old = [datetime]::UtcNow.AddDays(-365)
        $ancientDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent' -Timestamp $old

        $result = Invoke-RetentionCleanup -RunsRoot $testEnv.RunsRoot `
            -RetentionDays 0 -StateFile $script:stateFile `
            -DiscoveredAgentIds @('test-agent')

        Test-Path $ancientDir | Should -Be $true
        $result.DeletedCount | Should -Be 0
    }

    It 'Defaults to 14 days' {
        # Verify Import-CronAgentsConfig returns 14 as the default retentionDays
        $configPath = Join-Path $testEnv.Root 'cronagents.json'
        $config = Import-CronAgentsConfig -ConfigPath $configPath
        $config.retentionDays | Should -Be 14
    }
}
