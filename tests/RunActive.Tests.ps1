<#
.SYNOPSIS
    Pester 5 tests for Test-RunActive and Update-RunPid.
    Tests PID-based liveness, age-based staleness, and edge cases.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    function New-StaleRunDir {
        <#
        .SYNOPSIS
            Creates a run directory with configurable meta.json for testing
            Test-RunActive scenarios.
        #>
        param(
            [string]$RunsRoot,
            [string]$AgentId = 'test-agent',
            [datetime]$Timestamp,
            [string]$Nonce = 'abcd',
            [object]$ExitCode = $null,
            [object]$EndTime = $null,
            [switch]$WithOutput,
            [int]$ProcessId = 0,
            [datetime]$PidStartTime = [datetime]::MinValue,
            [switch]$NoPidStartTime
        )
        $ts   = $Timestamp.ToString('yyyyMMddTHHmmss')
        $name = "${ts}_${AgentId}_${Nonce}"
        $dir  = Join-Path $RunsRoot $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $meta = [ordered]@{
            agentId           = $AgentId
            agentName         = $AgentId
            prompt            = 'test'
            startTime         = $Timestamp.ToString('o')
            endTime           = $EndTime
            exitCode          = $ExitCode
            timedOut          = $false
            retryAttempt      = 0
            feedbackProcessed = $false
        }

        if ($ProcessId -gt 0) {
            $meta['pid'] = $ProcessId
            if (-not $NoPidStartTime -and $PidStartTime -ne [datetime]::MinValue) {
                $meta['pidStartTime'] = $PidStartTime.ToUniversalTime().ToString('o')
            }
        }

        $meta | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

        if ($WithOutput) {
            Set-Content -LiteralPath (Join-Path $dir 'output.md') -Value 'some output' -Encoding UTF8
        }

        return $dir
    }
}

Describe 'Test-RunActive' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'RunActive'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    Context 'Finished runs' {
        It 'Returns not-active for a completed run with exit code 0' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ExitCode 0 -EndTime $ts.AddMinutes(5).ToString('o')

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.IsStale | Should -Be $false
            $result.IsIncomplete | Should -Be $false
            $result.Reason | Should -Be 'finished'
        }

        It 'Returns not-active for a failed run with exit code 1' {
            $ts = [datetime]::UtcNow.AddHours(-1)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ExitCode 1 -EndTime $ts.AddMinutes(5).ToString('o')

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.Reason | Should -Be 'finished'
        }
    }

    Context 'Incomplete runs (output.md exists, no final metadata)' {
        It 'Returns incomplete when output.md exists but exitCode/endTime are null' {
            $ts = [datetime]::UtcNow.AddMinutes(-10)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts -WithOutput

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.IsStale | Should -Be $false
            $result.IsIncomplete | Should -Be $true
            $result.Reason | Should -Be 'output-exists-no-metadata'
        }
    }

    Context 'PID-based liveness' {
        It 'Returns stale when recorded PID does not exist' {
            $ts = [datetime]::UtcNow.AddMinutes(-30)
            # Use a PID value that is invalid for real processes
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ProcessId ([int]::MaxValue) -PidStartTime $ts

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.IsStale | Should -Be $true
            $result.Reason | Should -Be 'pid-not-found'
        }

        It 'Returns active when recorded PID is alive with matching start time' {
            $ts = [datetime]::UtcNow.AddMinutes(-5)
            # Use the current process PID (which is definitely alive)
            $currentPid = $PID
            $currentProc = Get-Process -Id $currentPid
            $procStart = $currentProc.StartTime.ToUniversalTime()

            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ProcessId $currentPid -PidStartTime $procStart

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $true
            $result.IsStale | Should -Be $false
            $result.Reason | Should -Be 'pid-alive'
        }

        It 'Returns stale when PID is alive but start time does not match (recycled)' {
            $ts = [datetime]::UtcNow.AddMinutes(-5)
            $currentPid = $PID
            # Use a fake start time far in the past
            $fakeStart = [datetime]::UtcNow.AddDays(-30)

            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ProcessId $currentPid -PidStartTime $fakeStart

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.IsStale | Should -Be $true
            $result.Reason | Should -Be 'pid-recycled'
        }

        It 'Returns active when PID is alive but pidStartTime is missing (safe default)' {
            $ts = [datetime]::UtcNow.AddMinutes(-5)
            $currentPid = $PID
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts `
                -ProcessId $currentPid -NoPidStartTime

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $true
            $result.Reason | Should -Be 'pid-alive'
        }

        It 'Falls back to legacy detection when pid value is not numeric' {
            $ts = [datetime]::UtcNow.AddHours(-5)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts

            # Manually set a non-numeric pid
            $meta = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw | ConvertFrom-Json
            $meta | Add-Member -NotePropertyName 'pid' -NotePropertyValue 'not-a-number' -Force
            $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

            $result = Test-RunActive -RunDirectory $dir -StaleGraceHours 4
            # Should fall through to legacy age-based check (5h > 4h grace)
            $result.IsStale | Should -Be $true
            $result.Reason | Should -Be 'legacy-stale-by-age'
        }
    }

    Context 'Legacy runs (no PID recorded) — age-based fallback' {
        It 'Returns active for a recent legacy run within grace period' {
            $ts = [datetime]::UtcNow.AddMinutes(-30)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts

            $result = Test-RunActive -RunDirectory $dir -StaleGraceHours 4
            $result.IsActive | Should -Be $true
            $result.IsStale | Should -Be $false
            $result.Reason | Should -Be 'assumed-active'
        }

        It 'Returns stale for an old legacy run exceeding grace period' {
            $ts = [datetime]::UtcNow.AddHours(-5)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts

            $result = Test-RunActive -RunDirectory $dir -StaleGraceHours 4
            $result.IsActive | Should -Be $false
            $result.IsStale | Should -Be $true
            $result.Reason | Should -Be 'legacy-stale-by-age'
        }

        It 'Respects custom StaleGraceHours parameter' {
            $ts = [datetime]::UtcNow.AddMinutes(-90)
            $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts

            # With 1 hour grace: should be stale
            $result = Test-RunActive -RunDirectory $dir -StaleGraceHours 1
            $result.IsStale | Should -Be $true

            # With 3 hour grace: should be assumed-active
            $result2 = Test-RunActive -RunDirectory $dir -StaleGraceHours 3
            $result2.IsActive | Should -Be $true
        }
    }

    Context 'Edge cases' {
        It 'Returns not-active with no-meta when meta.json does not exist' {
            $dir = Join-Path $testEnv.RunsRoot 'empty-run'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.Reason | Should -Be 'no-meta'
        }

        It 'Returns not-active with unreadable-meta for corrupted meta.json' {
            $dir = Join-Path $testEnv.RunsRoot 'corrupt-run'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Value '{invalid json' -Encoding UTF8

            $result = Test-RunActive -RunDirectory $dir
            $result.IsActive | Should -Be $false
            $result.Reason | Should -Be 'unreadable-meta'
        }
    }
}

Describe 'Update-RunPid' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'UpdateRunPid'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Writes pid and pidStartTime to existing meta.json' {
        $ts = [datetime]::UtcNow
        $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts

        Update-RunPid -RunDirectory $dir -ProcessId 12345 -ProcessStartTime $ts

        $meta = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw | ConvertFrom-Json
        $meta.pid | Should -Be 12345
        $meta.pidStartTime | Should -Not -BeNullOrEmpty
    }

    It 'Preserves existing meta.json fields' {
        $ts = [datetime]::UtcNow
        $dir = New-StaleRunDir -RunsRoot $testEnv.RunsRoot -Timestamp $ts -AgentId 'my-agent'

        Update-RunPid -RunDirectory $dir -ProcessId 99 -ProcessStartTime $ts

        $meta = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw | ConvertFrom-Json
        $meta.agentId | Should -Be 'my-agent'
        $meta.pid | Should -Be 99
    }

    It 'Does not throw when meta.json is missing' {
        $dir = Join-Path $testEnv.RunsRoot 'no-meta'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        { Update-RunPid -RunDirectory $dir -ProcessId 1 -ProcessStartTime ([datetime]::UtcNow) } |
            Should -Not -Throw
    }
}

Describe 'Clear-RunHistory with stale runs' {
    BeforeAll {
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
                startTime         = $Timestamp.ToUniversalTime().ToString('o')
                endTime           = if ($Active) { $null } else { $Timestamp.AddMinutes(5).ToUniversalTime().ToString('o') }
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

    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'ClearStale'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Deletes a stale run with dead PID' {
        $ts = [datetime]::UtcNow.AddHours(-1)
        $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Active

        # Add a dead PID to make it stale
        $meta = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw | ConvertFrom-Json
        $meta | Add-Member -NotePropertyName 'pid' -NotePropertyValue ([int]::MaxValue) -Force
        $meta | Add-Member -NotePropertyName 'pidStartTime' -NotePropertyValue $ts.ToString('o') -Force
        $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

        $runId = Split-Path $dir -Leaf
        $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId

        Test-Path $dir | Should -Be $false
        $result.DeletedCount | Should -Be 1
        $result.SkippedCount | Should -Be 0
    }

    It 'Deletes a legacy stale run exceeding grace period' {
        $ts = [datetime]::UtcNow.AddHours(-5)
        $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Active

        $runId = Split-Path $dir -Leaf
        $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId

        Test-Path $dir | Should -Be $false
        $result.DeletedCount | Should -Be 1
    }

    It 'Still protects a genuinely active run (recent, no PID)' {
        $ts = [datetime]::UtcNow.AddMinutes(-5)
        $dir = New-FakeRunDir -RunsRoot $testEnv.RunsRoot -AgentId 'agent-a' -Timestamp $ts -Active

        $runId = Split-Path $dir -Leaf
        $result = Clear-RunHistory -RunsRoot $testEnv.RunsRoot -RunId $runId

        Test-Path $dir | Should -Be $true
        $result.DeletedCount | Should -Be 0
        $result.SkippedCount | Should -Be 1
    }
}
