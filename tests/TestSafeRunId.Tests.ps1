<#
.SYNOPSIS
    Pester 5 tests for Test-SafeRunId.
    Validates run ID format checking and path traversal protection.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

Describe 'Test-SafeRunId' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'SafeRunId'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    Context 'Valid run IDs' {
        It 'Returns the resolved directory for a valid run ID' {
            $runId = '20260101T120000_my-agent_abcd'
            $result = Test-SafeRunId -RunId $runId -RunsRoot $testEnv.RunsRoot

            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*$runId"
        }

        It 'Returns correct path with agent names containing dots' {
            $runId = '20260101T120000_my.agent_abcd'
            $result = Test-SafeRunId -RunId $runId -RunsRoot $testEnv.RunsRoot

            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*$runId"
        }

        It 'Returns correct path with agent names containing underscores' {
            $runId = '20260101T120000_my_agent_abcd'
            $result = Test-SafeRunId -RunId $runId -RunsRoot $testEnv.RunsRoot

            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*$runId"
        }
    }

    Context 'Invalid format' {
        It 'Returns null for plain text' {
            $result = Test-SafeRunId -RunId 'not-a-run-id' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for missing nonce' {
            $result = Test-SafeRunId -RunId '20260101T120000_agent' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for invalid nonce characters' {
            $result = Test-SafeRunId -RunId '20260101T120000_agent_ZZZZ' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for nonce with wrong length' {
            $result = Test-SafeRunId -RunId '20260101T120000_agent_abc' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Path traversal protection' {
        It 'Returns null for directory traversal with ../' {
            $result = Test-SafeRunId -RunId '../escape' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for directory traversal with ..\' {
            $result = Test-SafeRunId -RunId '..\..\etc' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for absolute path injection' {
            $result = Test-SafeRunId -RunId '/etc/passwd' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for Windows absolute path injection' {
            $result = Test-SafeRunId -RunId 'C:\Windows\System32' -RunsRoot $testEnv.RunsRoot
            $result | Should -BeNullOrEmpty
        }
    }
}
