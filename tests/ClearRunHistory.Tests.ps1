<#
.SYNOPSIS
    Pester 5 tests for Clear-RunHistory.
    Tests single-run, per-agent, all-runs deletion and edge cases.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    function New-FakeRunDir {
        param(
            [string]$RunsRoot,
            [string]$AgentId,
            [datetime]$Timestamp,
            [string]$Nonce = 'abcd',
            [switch]$Active
        )
        $ts   = $Timestamp.ToString('yyyyMMddTHHmmss')
        $name = "${ts}_${AgentId}_${Nonce}"
        $dir  = Join-Path $RunsRoot $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $meta = [ordered]@{
            agentId           = $AgentId
            agentName         = $AgentId
            prompt            = 'test'
            startTime         = $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
            endTime           = if ($Active) { $null } else { $Timestamp.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss') }
            exitCode          = if ($Active) { $null } else { 0 }
            timedOut          = $false
            retryAttempt      = 0
            feedbackProcessed = $false
        }
        $meta | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

        $stub = "<!-- Feedback for agent run: $AgentId -->`n"
        Set-Content -LiteralPath (Join-Path $dir 'feedback.md') -Value $stub -Encoding UTF8 -NoNewline

        return $dir
    }
}

Describe 'Clear-RunHistory' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'ClearRuns'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    Context 'Single run deletion (-RunId)' {
        It 'Deletes a specific run by ID' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts
            $runId = Split-Path $dir -Leaf

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId

            Test-Path $dir | Should -Be $false
            $result.DeletedCount | Should -Be 1
            $result.SkippedCount | Should -Be 0
            $result.Errors.Count | Should -Be 0
        }

        It 'Returns 0 deleted for non-existent run ID' {
            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId '20260101T120000_nonexistent_abcd'

            $result.DeletedCount | Should -Be 0
            $result.SkippedCount | Should -Be 1
        }

        It 'Rejects invalid run ID format' {
            { Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId '../escape' } | Should -Throw '*Invalid run ID format*'
        }

        It 'Rejects path traversal in run ID' {
            { Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId '..\..\etc' } | Should -Throw '*Invalid run ID format*'
        }

        It 'Does not delete other runs when deleting a single run' {
            $ts1 = [datetime]::UtcNow.AddHours(-2)
            $ts2 = [datetime]::UtcNow.AddHours(-1)
            $dir1 = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts1 -Nonce 'aa01'
            $dir2 = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts2 -Nonce 'aa02'
            $runId1 = Split-Path $dir1 -Leaf

            Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId1

            Test-Path $dir1 | Should -Be $false
            Test-Path $dir2 | Should -Be $true
        }
    }

    Context 'Agent-scoped deletion (-AgentId)' {
        It 'Deletes all runs for the specified agent' {
            $ts1 = [datetime]::UtcNow.AddHours(-3)
            $ts2 = [datetime]::UtcNow.AddHours(-1)
            $dir1 = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts1 -Nonce 'aa01'
            $dir2 = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts2 -Nonce 'aa02'

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a'

            Test-Path $dir1 | Should -Be $false
            Test-Path $dir2 | Should -Be $false
            $result.DeletedCount | Should -Be 2
        }

        It 'Does not delete runs for other agents' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dirA = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Nonce 'aa01'
            $dirB = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-b' -Timestamp $ts -Nonce 'bb01'

            Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a'

            Test-Path $dirA | Should -Be $false
            Test-Path $dirB | Should -Be $true
        }

        It 'Returns 0 if no runs exist for the agent' {
            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'no-such-agent'
            $result.DeletedCount | Should -Be 0
        }
    }

    Context 'All runs deletion (-All)' {
        It 'Deletes all runs across all agents' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dirA = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Nonce 'aa01'
            $dirB = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-b' -Timestamp $ts -Nonce 'bb01'
            $dirC = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-c' -Timestamp $ts -Nonce 'cc01'

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -All

            Test-Path $dirA | Should -Be $false
            Test-Path $dirB | Should -Be $false
            Test-Path $dirC | Should -Be $false
            $result.DeletedCount | Should -Be 3
        }

        It 'Returns 0 when runs root is empty' {
            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -All
            $result.DeletedCount | Should -Be 0
        }
    }

    Context 'Edge cases' {
        It 'Returns gracefully when runs root does not exist' {
            $nonExistent = Join-Path $testEnv.Root 'no-such-runs'
            $result = Clear-RunHistory -RunsRoot $nonExistent -All

            $result.DeletedCount | Should -Be 0
            $result.SkippedCount | Should -Be 0
        }

        It 'Throws when no scope parameter is specified' {
            { Clear-RunHistory -RunsRoot $testEnv.RunsRoot } | Should -Throw '*Specify exactly one*'
        }

        It 'Ignores non-matching directories when clearing all' {
            New-Item -ItemType Directory -Path (Join-Path $testEnv.RunsRoot 'random-dir') -Force | Out-Null
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -All

            Test-Path $dir | Should -Be $false
            Test-Path (Join-Path $testEnv.RunsRoot 'random-dir') | Should -Be $true
            $result.DeletedCount | Should -Be 1
        }
    }

    Context 'Active run protection' {
        It 'Refuses to delete a single active run by RunId' {
            $ts = [datetime]::UtcNow.AddMinutes(-5)
            $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Active
            $runId = Split-Path $dir -Leaf

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId

            Test-Path $dir | Should -Be $true
            $result.DeletedCount | Should -Be 0
            $result.SkippedCount | Should -Be 1
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -BeLike '*still active*'
        }

        It 'Skips active runs when clearing by AgentId' {
            $ts1 = [datetime]::UtcNow.AddHours(-2)
            $ts2 = [datetime]::UtcNow.AddMinutes(-5)
            $finishedDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts1 -Nonce 'aa01'
            $activeDir   = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts2 -Nonce 'aa02' -Active

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a'

            Test-Path $finishedDir | Should -Be $false
            Test-Path $activeDir | Should -Be $true
            $result.DeletedCount | Should -Be 1
            $result.SkippedCount | Should -Be 1
        }

        It 'Skips active runs when clearing all' {
            $ts1 = [datetime]::UtcNow.AddHours(-1)
            $ts2 = [datetime]::UtcNow.AddMinutes(-2)
            $finishedDir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts1 -Nonce 'aa01'
            $activeDir   = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-b' -Timestamp $ts2 -Nonce 'bb01' -Active

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -All

            Test-Path $finishedDir | Should -Be $false
            Test-Path $activeDir | Should -Be $true
            $result.DeletedCount | Should -Be 1
            $result.SkippedCount | Should -Be 1
        }
    }

    Context 'Regex safety for AgentId' {
        It 'Does not match other agents when AgentId contains dots' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dirDotted = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'foo.bar' -Timestamp $ts -Nonce 'aa01'
            $dirSimilar = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'fooXbar' -Timestamp $ts -Nonce 'bb01'

            $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'foo.bar'

            Test-Path $dirDotted | Should -Be $false
            Test-Path $dirSimilar | Should -Be $true
            $result.DeletedCount | Should -Be 1
        }

        It 'Does not match other agents when AgentId contains regex metacharacters' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            # Agent ID with a dot that regex would treat as wildcard
            $target = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'my.agent' -Timestamp $ts -Nonce 'aa01'
            $bystander = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'myXagent' -Timestamp $ts -Nonce 'bb01'

            Clear-RunHistory -RunsRoot $testEnv.RunsRoot -AgentId 'my.agent'

            Test-Path $target | Should -Be $false
            Test-Path $bystander | Should -Be $true
        }
    }
}
