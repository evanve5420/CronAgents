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

    It 'Initialize-RunMetadata writes preliminary meta.json with null exitCode' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'

        Initialize-RunMetadata -RunDirectory $runDir -AgentId 'test-agent' `
            -AgentName 'Test Agent' -Prompt 'Review the code'

        $metaPath = Join-Path $runDir 'meta.json'
        Test-Path $metaPath | Should -BeTrue

        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        $meta.agentId           | Should -Be 'test-agent'
        $meta.agentName         | Should -Be 'Test Agent'
        $meta.prompt            | Should -Be 'Review the code'
        $meta.exitCode          | Should -BeNullOrEmpty
        $meta.endTime           | Should -BeNullOrEmpty
        $meta.startTime         | Should -Not -BeNullOrEmpty
        $meta.timedOut          | Should -Be $false
        $meta.feedbackProcessed | Should -Be $false
    }

    It 'Write-RunMetadata overwrites Initialize-RunMetadata content' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'test-agent'
        $now = [datetime]::UtcNow

        Initialize-RunMetadata -RunDirectory $runDir -AgentId 'test-agent' `
            -AgentName 'Test Agent' -Prompt 'Review the code'

        Write-RunMetadata -RunDirectory $runDir -AgentId 'test-agent' `
            -AgentName 'Test Agent' -Prompt 'Review the code' `
            -StartTime $now.AddMinutes(-1) -EndTime $now `
            -ExitCode 0

        $meta = Get-Content (Join-Path $runDir 'meta.json') -Raw | ConvertFrom-Json
        $meta.exitCode  | Should -Be 0
        $meta.endTime   | Should -Not -BeNullOrEmpty
        $meta.startTime | Should -Not -BeNullOrEmpty
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
        $null = & pwsh -NoProfile -File $mockCopilotPath -Agent 'my-custom-agent' -p 'Do stuff' -Silent -AllowAllTools

        $invocations = Get-MockInvocations -LogPath $testEnv.MockLogPath
        $invocations.Count | Should -BeGreaterOrEqual 1
        $invocations[-1].agent | Should -Be 'my-custom-agent'
        $invocations[-1].allowAllTools | Should -Be $true
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

    It 'Persists runIf snapshot after a manual run' {
        Set-Content -Path (Join-Path $testEnv.Root 'package.json') -Value '{ "name": "invoke-agent-test" }' -Encoding UTF8
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'test-agent' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'Inspect package changes' `
            -RunIf 'file-changed:package.json'

        $globalConfig = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $agent = (Get-AgentConfigs -RepoRoot $testEnv.Root | Where-Object Id -eq 'test-agent')

        $result = & $invokeScript -AgentId $agent.Id `
            -AgentConfig $agent.Config `
            -GlobalConfig $globalConfig `
            -RepoRoot $testEnv.Root `
            -RunsRoot $testEnv.RunsRoot

        $result.ExitCode | Should -Be 0

        $state = Get-AgentState -StateFile (Join-Path $testEnv.StatePath 'state.json')
        $state.agents['test-agent'].runIfState.fileChanged.ContainsKey('package.json') | Should -Be $true
    }

    It 'Preserves prior runIfState when snapshot capture fails' {
        # Seed state with a known runIfState (simulate a previous successful run)
        $stateFile = Join-Path $testEnv.StatePath 'state.json'
        $priorSnapshot = @{ gitDirty = @{ head = 'abc1234deadbeef' } }
        Set-AgentState -StateFile $stateFile -AgentId 'test-agent' -LastRun ([datetime]::UtcNow).AddHours(-1) -RunIfState $priorSnapshot

        # Create agent with git-dirty runIf but root is NOT a git repo — snapshot will fail
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'test-agent' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'Check repo' `
            -RunIf 'git-dirty'

        $globalConfig = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $agent = (Get-AgentConfigs -RepoRoot $testEnv.Root | Where-Object Id -eq 'test-agent')

        # Run without passing RunIfSnapshot — forces Invoke-ScheduledAgent to capture its own
        $result = & $invokeScript -AgentId $agent.Id `
            -AgentConfig $agent.Config `
            -GlobalConfig $globalConfig `
            -RepoRoot $testEnv.Root `
            -RunsRoot $testEnv.RunsRoot

        $result.ExitCode | Should -Be 0

        # Prior runIfState should be preserved, not wiped to {}
        $state = Get-AgentState -StateFile $stateFile
        $state.agents['test-agent'].runIfState.gitDirty.head | Should -Be 'abc1234deadbeef'
    }
}

Describe 'Invoke-ScheduledAgent — Single-Word CopilotPath (Issue #15 Bug 1)' {
    <#
        When copilotPath is a single token (e.g. 'copilot'), Split-CommandLine
        returns a one-element array that PowerShell unwraps to a scalar. Under
        Set-StrictMode -Version Latest the subsequent .Count access fails.
        These tests verify the fix: the runner must work with single-word paths.
    #>

    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SingleWordPath'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Runs successfully with a single-word copilotPath' {
        # Rewrite cronagents.json with a single-word copilotPath pointing to
        # a wrapper whose absolute path is a single PowerShell token.
        $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'
        $wrapperDir  = Join-Path $testEnv.Root '.mock-bin'
        New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

        # Create a platform-appropriate wrapper
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $wrapperPath = Join-Path $wrapperDir 'mock-copilot.cmd'
            Set-Content -Path $wrapperPath -Encoding UTF8 -Value "@echo off`r`npwsh -NoProfile -File `"$mockCopilotPath`" %*"
        }
        else {
            $wrapperPath = Join-Path $wrapperDir 'mock-copilot'
            Set-Content -Path $wrapperPath -Encoding UTF8 -Value "#!/usr/bin/env pwsh`n& '$mockCopilotPath' @args"
            & chmod +x -- $wrapperPath
        }

        # Overwrite config with the single-word path (no spaces, no flags)
        $config = [ordered]@{
            autoFeedback  = $false
            maxRunHistory = 50
            copilotPath   = $wrapperPath
            retentionDays = 14
            startupDelay  = '0'
            logLevel      = 'debug'
            quietHours    = $null
            personalRepo  = [ordered]@{
                path               = '~/.cronagents'
                userName           = 'test-user'
                autoCommitFeedback = $false
            }
        }
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $testEnv.ConfigPath -Encoding UTF8

        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'single-word-agent' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'Verify single-word copilotPath works'

        $globalConfig = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $agent = Get-AgentConfigs -RepoRoot $testEnv.Root | Where-Object Id -eq 'single-word-agent'

        $result = & $invokeScript -AgentId $agent.Id `
            -AgentConfig $agent.Config `
            -GlobalConfig $globalConfig `
            -RepoRoot $testEnv.Root `
            -RunsRoot $testEnv.RunsRoot

        $result.ExitCode | Should -Be 0
        $result.RunDirectory | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $result.RunDirectory 'meta.json') | Should -BeTrue
    }
}

Describe 'Invoke-ScheduledAgent — UTF-8 Output Capture' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'Utf8Capture'
    }
    AfterEach {
        Remove-Item Env:\CRONAGENTS_MOCK_OUTPUT -ErrorAction SilentlyContinue
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Captures smart punctuation without mojibake in output.md' {
        $expectedOutput = "I’m checking UTF-8 — this shouldn’t turn into mojibake."
        $env:CRONAGENTS_MOCK_OUTPUT = $expectedOutput

        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'utf8-agent' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'Verify UTF-8 output capture'

        $globalConfig = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $agent = Get-AgentConfigs -RepoRoot $testEnv.Root | Where-Object Id -eq 'utf8-agent'

        $result = & $invokeScript -AgentId $agent.Id `
            -AgentConfig $agent.Config `
            -GlobalConfig $globalConfig `
            -RepoRoot $testEnv.Root `
            -RunsRoot $testEnv.RunsRoot

        $result.ExitCode | Should -Be 0

        $outputPath = Join-Path $result.RunDirectory 'output.md'
        Test-Path $outputPath | Should -BeTrue

        $content = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
        $content.Contains($expectedOutput) | Should -BeTrue
        $content | Should -Not -Match 'ΓÇ'
        $content | Should -Not -Match 'â'
    }
}

Describe 'Invoke-ScheduledAgent — Failure Metadata (Issue #15 Bug 2)' {
    <#
        When the runner fails before Invoke-CopilotRun sets $startTime, the
        catch block must still write meta.json with a valid StartTime rather
        than propagating a null-to-DateTime conversion error.
    #>

    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'FailMeta'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Writes meta.json with valid timestamps when run fails before execution' {
        # Use a copilotPath that will cause an early failure during process start
        $config = [ordered]@{
            autoFeedback  = $false
            maxRunHistory = 50
            copilotPath   = '__nonexistent_binary_that_will_fail__'
            retentionDays = 14
            startupDelay  = '0'
            logLevel      = 'debug'
            quietHours    = $null
            personalRepo  = [ordered]@{
                path               = '~/.cronagents'
                userName           = 'test-user'
                autoCommitFeedback = $false
            }
        }
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $testEnv.ConfigPath -Encoding UTF8

        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'fail-meta-agent' `
            -Schedule @{ type = 'interval'; every = '1h' } `
            -Prompt 'This should fail early'

        $globalConfig = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $agent = Get-AgentConfigs -RepoRoot $testEnv.Root | Where-Object Id -eq 'fail-meta-agent'

        $result = & $invokeScript -AgentId $agent.Id `
            -AgentConfig $agent.Config `
            -GlobalConfig $globalConfig `
            -RepoRoot $testEnv.Root `
            -RunsRoot $testEnv.RunsRoot

        $result.ExitCode | Should -Be -1

        # The key assertion: meta.json must exist with valid timestamps
        $result.RunDirectory | Should -Not -BeNullOrEmpty
        Test-Path $result.RunDirectory | Should -BeTrue

        $metaPath = Join-Path $result.RunDirectory 'meta.json'
        Test-Path $metaPath | Should -BeTrue
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        $meta.exitCode  | Should -Be -1
        $meta.startTime | Should -Not -BeNullOrEmpty
        $meta.endTime   | Should -Not -BeNullOrEmpty

        { [DateTime]::Parse($meta.startTime) } | Should -Not -Throw
        { [DateTime]::Parse($meta.endTime) }   | Should -Not -Throw
    }
}
