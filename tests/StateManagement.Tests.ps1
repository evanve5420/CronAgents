<#
.SYNOPSIS
    Pester 5 tests for StateManager.ps1 — state.json read/write/recovery
    for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== Initialize-StateFile & Get-AgentState =====

Describe 'State file initialization' {
    It 'Creates state.json and parent directories if they do not exist' {
        $stateDir  = Join-Path $TestDrive 'init-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'

        $state = Get-AgentState -StateFile $stateFile
        Test-Path $stateFile | Should -Be $true
        $state.schemaVersion   | Should -Be 1
        $state.schedulerPaused | Should -Be $false
        $state.agents.Count    | Should -Be 0
    }

    It 'Reads existing state correctly' {
        $stateDir  = Join-Path $TestDrive 'read-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $true
            agents          = [ordered]@{
                'agent-a' = [ordered]@{ lastRun = '2025-06-15T10:00:00.0000000'; enabled = $true }
                'agent-b' = [ordered]@{ lastRun = $null; enabled = $false }
            }
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $state = Get-AgentState -StateFile $stateFile
        $state.schedulerPaused | Should -Be $true
        $state.agents.Count    | Should -Be 2
        $state.agents['agent-a'].enabled | Should -Be $true
        $state.agents['agent-a'].lastRun | Should -Not -BeNullOrEmpty
        $state.agents['agent-b'].enabled | Should -Be $false
    }

    It 'Returns specific agent state when AgentId is provided' {
        $stateDir  = Join-Path $TestDrive 'agent-specific\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{
                'my-agent' = [ordered]@{ lastRun = '2025-06-15T10:00:00.0000000'; enabled = $true }
            }
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $agentState = Get-AgentState -StateFile $stateFile -AgentId 'my-agent'
        $agentState | Should -Not -BeNullOrEmpty
        $agentState.enabled | Should -Be $true

        $missing = Get-AgentState -StateFile $stateFile -AgentId 'nonexistent'
        $missing | Should -BeNullOrEmpty
    }
}

# ===== Set-AgentState =====

Describe 'Set-AgentState' {
    It 'Updates one agent timestamp without disturbing others' {
        $stateDir  = Join-Path $TestDrive 'update-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{
                'agent-a' = [ordered]@{ lastRun = '2025-06-15T10:00:00.0000000'; enabled = $true }
                'agent-b' = [ordered]@{ lastRun = '2025-06-15T08:00:00.0000000'; enabled = $true }
            }
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $newTime = [datetime]::new(2025, 6, 15, 12, 0, 0)
        Set-AgentState -StateFile $stateFile -AgentId 'agent-a' -LastRun $newTime

        $state = Get-AgentState -StateFile $stateFile
        ([datetime]$state.agents['agent-a'].lastRun).Hour | Should -Be 12
        ([datetime]$state.agents['agent-b'].lastRun).Hour | Should -Be 8
    }

    It 'Handles enabled/disabled toggle' {
        $stateDir  = Join-Path $TestDrive 'toggle-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{
                'test-agent' = [ordered]@{ lastRun = $null; enabled = $true }
            }
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        Set-AgentState -StateFile $stateFile -AgentId 'test-agent' -Enabled $false
        $state = Get-AgentState -StateFile $stateFile
        $state.agents['test-agent'].enabled | Should -Be $false

        Set-AgentState -StateFile $stateFile -AgentId 'test-agent' -Enabled $true
        $state = Get-AgentState -StateFile $stateFile
        $state.agents['test-agent'].enabled | Should -Be $true
    }

    It 'Handles schedulerPaused flag' {
        $stateDir  = Join-Path $TestDrive 'paused-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{}
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        Set-AgentState -StateFile $stateFile -SchedulerPaused $true
        $state = Get-AgentState -StateFile $stateFile
        $state.schedulerPaused | Should -Be $true

        Set-AgentState -StateFile $stateFile -SchedulerPaused $false
        $state = Get-AgentState -StateFile $stateFile
        $state.schedulerPaused | Should -Be $false
    }

    It 'Creates agent entry if it does not exist' {
        $stateDir  = Join-Path $TestDrive 'create-agent\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{}
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $runTime = [datetime]::new(2025, 6, 15, 10, 0, 0)
        Set-AgentState -StateFile $stateFile -AgentId 'new-agent' -LastRun $runTime

        $state = Get-AgentState -StateFile $stateFile
        $state.agents.ContainsKey('new-agent') | Should -Be $true
        ([datetime]$state.agents['new-agent'].lastRun).Hour | Should -Be 10
        $state.agents['new-agent'].enabled | Should -Be $true
    }

    It 'Persists nested runIf state' {
        $stateDir  = Join-Path $TestDrive 'runif-state\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        $runIfState = @{
            gitDirty = @{
                head = 'abc123'
            }
            fileChanged = @{
                'package.json' = '2026-03-30T20:00:00.0000000Z'
            }
        }

        Set-AgentState -StateFile $stateFile -AgentId 'runif-agent' -RunIfState $runIfState

        $state = Get-AgentState -StateFile $stateFile
        $state.agents['runif-agent'].runIfState.gitDirty.head | Should -Be 'abc123'
        $state.agents['runif-agent'].runIfState.fileChanged['package.json'] | Should -Be '2026-03-30T20:00:00.0000000Z'
    }
}

# ===== Corrupted state recovery =====

Describe 'State recovery from corruption' {
    It 'Recovers from corrupted state.json and resets to defaults' {
        $stateDir  = Join-Path $TestDrive 'corrupt-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        Set-Content -LiteralPath $stateFile -Value 'NOT VALID JSON {{{{' -Encoding UTF8

        $state = Get-AgentState -StateFile $stateFile
        $state.schemaVersion   | Should -Be 1
        $state.schedulerPaused | Should -Be $false
        $state.agents.Count    | Should -Be 0
    }

    It 'Recovers from empty state file' {
        $stateDir  = Join-Path $TestDrive 'empty-state\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        Set-Content -LiteralPath $stateFile -Value '' -Encoding UTF8

        $state = Get-AgentState -StateFile $stateFile
        $state.schemaVersion   | Should -Be 1
        $state.schedulerPaused | Should -Be $false
    }
}

# ===== Atomic writes =====

Describe 'Write-StateAtomically' {
    It 'Uses temp file pattern for atomic writes' {
        $stateDir  = Join-Path $TestDrive 'atomic-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        # Create initial state
        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{}
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        Set-AgentState -StateFile $stateFile -AgentId 'atomic-agent' -LastRun ([datetime]::new(2025, 1, 1))

        # Verify state was written correctly (atomic write succeeded)
        $state = Get-AgentState -StateFile $stateFile
        $state.agents.ContainsKey('atomic-agent') | Should -Be $true

        # Temp file should not remain
        Test-Path "$stateFile.tmp" | Should -Be $false
    }
}

# ===== Reset-AgentState =====

Describe 'Reset-AgentState' {
    It 'Resets state to defaults' {
        $stateDir  = Join-Path $TestDrive 'reset-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $true
            agents          = [ordered]@{
                'agent-x' = [ordered]@{ lastRun = '2025-06-15T10:00:00'; enabled = $false }
            }
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        Reset-AgentState -StateFile $stateFile

        $state = Get-AgentState -StateFile $stateFile
        $state.schedulerPaused | Should -Be $false
        $state.agents.Count    | Should -Be 0
    }

    It 'Creates parent directory if needed' {
        $stateDir  = Join-Path $TestDrive 'reset-new\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'

        Reset-AgentState -StateFile $stateFile

        Test-Path $stateFile | Should -Be $true
        $state = Get-AgentState -StateFile $stateFile
        $state.schemaVersion | Should -Be 1
    }
}

# ===== Concurrent-like writes =====

Describe 'Sequential writes for different agents' {
    It 'Both agent updates persist correctly' {
        $stateDir  = Join-Path $TestDrive 'concurrent-test\.cronstate'
        $stateFile = Join-Path $stateDir 'state.json'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $existingState = [ordered]@{
            schemaVersion   = 1
            schedulerPaused = $false
            agents          = [ordered]@{}
        }
        $existingState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $time1 = [datetime]::new(2025, 6, 15, 10, 0, 0)
        $time2 = [datetime]::new(2025, 6, 15, 11, 0, 0)

        Set-AgentState -StateFile $stateFile -AgentId 'agent-1' -LastRun $time1
        Set-AgentState -StateFile $stateFile -AgentId 'agent-2' -LastRun $time2

        $state = Get-AgentState -StateFile $stateFile
        $state.agents.ContainsKey('agent-1') | Should -Be $true
        $state.agents.ContainsKey('agent-2') | Should -Be $true
        ([datetime]$state.agents['agent-1'].lastRun).Hour | Should -Be 10
        ([datetime]$state.agents['agent-2'].lastRun).Hour | Should -Be 11
    }
}
