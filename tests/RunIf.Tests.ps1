<#
.SYNOPSIS
    Pester 5 tests for runIf parsing, evaluation, and script conditions.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    $script:hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

    function Initialize-TestGitRepo {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init 2>$null | Out-Null
        & git -C $Path config user.email 'cronagents-tests@example.com'
        & git -C $Path config user.name 'CronAgents Tests'
    }

    function New-TestGitCommit {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$FileName,
            [Parameter(Mandatory)][string]$Content
        )

        Set-Content -Path (Join-Path $Path $FileName) -Value $Content -Encoding UTF8
        & git -C $Path add --all
        & git -C $Path commit -m "test $([guid]::NewGuid())" --quiet
        return ((& git -C $Path rev-parse HEAD) | Select-Object -First 1).Trim()
    }
}

Describe 'ConvertTo-AgentRunIfDefinition' {
    It 'Parses git-dirty' {
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'git-dirty'
        $runIf.type | Should -Be 'git-dirty'
    }

    It 'Parses file-changed:path' {
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'file-changed:package.json'
        $runIf.type | Should -Be 'file-changed'
        $runIf.path | Should -Be 'package.json'
    }

    It 'Parses script object form' {
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf ([PSCustomObject]@{ script = '.cronagents/scripts/should-run.ps1' })
        $runIf.type | Should -Be 'script'
        $runIf.script | Should -Be '.cronagents/scripts/should-run.ps1'
    }

    It 'Rejects unsupported values' {
        { ConvertTo-AgentRunIfDefinition -RunIf 'branch-dirty' } | Should -Throw '*Unsupported runIf value*'
    }
}

Describe 'Get-AgentRunIfExecutionRoot' {
    It 'Prefers workingDirectory when set' {
        $infraRoot = Join-Path $TestDrive 'infra'
        $personalRoot = Join-Path $TestDrive 'personal'
        New-Item -ItemType Directory -Path $infraRoot, $personalRoot -Force | Out-Null
        $agentConfig = [PSCustomObject]@{ workingDirectory = '.\project' }
        $root = Get-AgentRunIfExecutionRoot -AgentConfig $agentConfig -RepoRoot $infraRoot -PersonalRepoPath $personalRoot
        $root | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $personalRoot 'project')))
    }

    It 'Falls back to personal repo then repo root' {
        $infraRoot = Join-Path $TestDrive 'infra'
        $personalRoot = Join-Path $TestDrive 'personal'
        New-Item -ItemType Directory -Path $infraRoot, $personalRoot -Force | Out-Null
        $agentConfig = [PSCustomObject]@{ workingDirectory = $null }
        (Get-AgentRunIfExecutionRoot -AgentConfig $agentConfig -RepoRoot $infraRoot -PersonalRepoPath $personalRoot) | Should -Be ([System.IO.Path]::GetFullPath($personalRoot))
        (Get-AgentRunIfExecutionRoot -AgentConfig $agentConfig -RepoRoot $infraRoot -PersonalRepoPath $null) | Should -Be ([System.IO.Path]::GetFullPath($infraRoot))
    }
}

Describe 'Test-AgentRunIf - built-in predicates' {
    It 'git-dirty runs on first observation, skips when unchanged, and runs after a new commit' {
        if (-not $script:hasGit) {
            Set-ItResult -Skipped -Because 'git is not installed'
            return
        }

        $repoPath = Join-Path $TestDrive 'git-repo'
        Initialize-TestGitRepo -Path $repoPath
        $null = New-TestGitCommit -Path $repoPath -FileName 'README.md' -Content 'first'

        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'git-dirty'
        $stateFile = Join-Path $repoPath '.cronstate\state.json'

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'git-agent' -StateFile $stateFile -RunIfState @{}) | Should -Be $true

        $snapshot = (Get-AgentRunIfSnapshot -RunIf $runIf -ExecutionRoot $repoPath).Snapshot
        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'git-agent' -StateFile $stateFile -RunIfState $snapshot) | Should -Be $false

        $null = New-TestGitCommit -Path $repoPath -FileName 'README.md' -Content 'second'
        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'git-agent' -StateFile $stateFile -RunIfState $snapshot) | Should -Be $true
    }

    It 'file-changed detects file updates and stable snapshots' {
        $repoPath = Join-Path $TestDrive 'file-repo'
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        $trackedFile = Join-Path $repoPath 'package.json'
        Set-Content -Path $trackedFile -Value '{ "name": "one" }' -Encoding UTF8

        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'file-changed:package.json'
        $stateFile = Join-Path $repoPath '.cronstate\state.json'

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'file-agent' -StateFile $stateFile -RunIfState @{}) | Should -Be $true

        $snapshot = (Get-AgentRunIfSnapshot -RunIf $runIf -ExecutionRoot $repoPath).Snapshot
        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'file-agent' -StateFile $stateFile -RunIfState $snapshot) | Should -Be $false

        Set-Content -Path $trackedFile -Value '{ "name": "two" }' -Encoding UTF8
        (Get-Item $trackedFile).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'file-agent' -StateFile $stateFile -RunIfState $snapshot) | Should -Be $true
    }

    It 'file-changed treats a missing file as a stable tracked state after first run' {
        $repoPath = Join-Path $TestDrive 'missing-file-repo'
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'file-changed:missing.json'
        $stateFile = Join-Path $repoPath '.cronstate\state.json'

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'missing-agent' -StateFile $stateFile -RunIfState @{}) | Should -Be $true

        $snapshot = (Get-AgentRunIfSnapshot -RunIf $runIf -ExecutionRoot $repoPath).Snapshot
        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'missing-agent' -StateFile $stateFile -RunIfState $snapshot) | Should -Be $false
    }
}

Describe 'Test-AgentRunIf - script predicate' {
    It 'Uses script stdout boolean and passes named parameters' {
        $repoPath = Join-Path $TestDrive 'script-repo'
        $scriptDir = Join-Path $repoPath '.cronagents\scripts'
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        $stateFile = Join-Path $repoPath '.cronstate\state.json'
        $contextFile = Join-Path $repoPath 'context.json'
        $scriptPath = Join-Path $scriptDir 'should-run.ps1'

        $scriptContent = @"
param(
    [string]`$RepoRoot,
    [string]`$AgentId,
    [string]`$StateFile
)

@{
    RepoRoot = `$RepoRoot
    AgentId = `$AgentId
    StateFile = `$StateFile
} | ConvertTo-Json -Compress | Set-Content -Path (Join-Path `$RepoRoot 'context.json') -Encoding UTF8

'false'
"@

        Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf ([PSCustomObject]@{ script = '.cronagents/scripts/should-run.ps1' })

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'script-agent' -StateFile $stateFile) | Should -Be $false

        $context = Get-Content -Path $contextFile -Raw | ConvertFrom-Json
        $context.RepoRoot | Should -Be $repoPath
        $context.AgentId | Should -Be 'script-agent'
        $context.StateFile | Should -Be $stateFile
    }

    It 'Fails open when the script exits non-zero' {
        $repoPath = Join-Path $TestDrive 'script-error-repo'
        $scriptDir = Join-Path $repoPath '.cronagents\scripts'
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        $stateFile = Join-Path $repoPath '.cronstate\state.json'
        $scriptPath = Join-Path $scriptDir 'should-run.ps1'

        Set-Content -Path $scriptPath -Value "throw 'boom'" -Encoding UTF8
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf ([PSCustomObject]@{ script = '.cronagents/scripts/should-run.ps1' })

        (Test-AgentRunIf -RunIf $runIf -ExecutionRoot $repoPath -AgentId 'script-agent' -StateFile $stateFile) | Should -Be $true
    }
}

Describe 'Get-AgentRunIfSnapshot - failure preserves prior state' {
    It 'Returns Success=$false for git-dirty in a non-git directory' {
        $nonGitDir = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $nonGitDir -Force | Out-Null
        $runIf = ConvertTo-AgentRunIfDefinition -RunIf 'git-dirty'
        $result = Get-AgentRunIfSnapshot -RunIf $runIf -ExecutionRoot $nonGitDir
        $result.Success | Should -BeFalse
        $result.Snapshot | Should -BeOfType [hashtable]
    }
}
