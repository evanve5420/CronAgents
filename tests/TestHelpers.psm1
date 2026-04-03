# Test helper module for CronAgents tests
# Provides setup/teardown utilities and assertion helpers

$ErrorActionPreference = 'Stop'

function New-TestEnvironment {
    <#
    .SYNOPSIS
        Creates an isolated temp directory structure for testing.
    .PARAMETER Name
        Test suite name used in the temp directory path.
    .OUTPUTS
        PSCustomObject with Root, ConfigPath, StatePath, RunsRoot, AgentsDir,
        PersonalRepoRoot, and MockLogPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $random = [System.IO.Path]::GetRandomFileName().Replace('.', '')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-Test-$Name-$random"
    $personalRepoRoot = Join-Path $root 'personal-repo'

    # Create directory structure
    $dirs = @(
        (Join-Path $root '.cronagents' 'agents')
        (Join-Path $root '.github' 'agents')
        (Join-Path $root '.cronstate' 'runs')
        (Join-Path $root 'scheduler' 'lib')
        (Join-Path $root 'scheduler' 'agents')
        (Join-Path $personalRepoRoot '.cronagents' 'agents')
        (Join-Path $personalRepoRoot '.github' 'agents')
        (Join-Path $personalRepoRoot '.cronstate' 'runs')
    )
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # Copy real agent .md files into the test environment
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    # Handle case where PSScriptRoot is the tests dir directly
    if (-not $repoRoot -or -not (Test-Path (Join-Path $repoRoot 'scheduler' 'agents'))) {
        $repoRoot = Split-Path $PSScriptRoot -Parent
    }
    $realAgentsDir = Join-Path $repoRoot 'scheduler' 'agents'
    if (Test-Path $realAgentsDir) {
        Get-ChildItem -Path $realAgentsDir -Filter '*.agent.md' | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $root 'scheduler' 'agents' $_.Name)
        }
    }

    # Resolve mock copilot path
    $mockCopilotPath = Join-Path $PSScriptRoot 'mocks' 'copilot.ps1'

    # Create mock invocation log path
    $mockLogPath = Join-Path $root 'mock-invocations.jsonl'

    # Create cronagents.json with mock copilotPath
    $config = [ordered]@{
        '$schema'      = './cronagents.schema.json'
        autoFeedback   = $false
        maxRunHistory  = 50
        copilotPath    = "pwsh -NoProfile -File `"$mockCopilotPath`""
        retentionDays  = 14
        startupDelay   = '0'
        logLevel       = 'debug'
        quietHours     = $null
        versioning     = $null
        personalRepo   = [ordered]@{
            path                    = $personalRepoRoot
            userName                = 'test-user'
            autoCommitFeedback      = $false
            defaultWorkingDirectory = $null
        }
    }
    $configPath = Join-Path $root 'cronagents.json'
    $config | ConvertTo-Json -Depth 5 | Out-File -FilePath $configPath -Encoding utf8

    # Set environment variable for mock log
    $env:CRONAGENTS_MOCK_LOG = $mockLogPath

    [PSCustomObject]@{
        Root            = $root
        ConfigPath      = $configPath
        StatePath       = Join-Path $root '.cronstate'
        RunsRoot        = Join-Path $root '.cronstate' 'runs'
        AgentsDir       = Join-Path $root '.cronagents' 'agents'
        PersonalRepoRoot = $personalRepoRoot
        MockLogPath     = $mockLogPath
    }
}

function Remove-TestEnvironment {
    <#
    .SYNOPSIS
        Cleans up a test environment created by New-TestEnvironment.
    .PARAMETER TestEnv
        The PSCustomObject returned by New-TestEnvironment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TestEnv
    )

    # Clear the mock log env var
    if ($env:CRONAGENTS_MOCK_LOG -eq $TestEnv.MockLogPath) {
        Remove-Item Env:\CRONAGENTS_MOCK_LOG -ErrorAction SilentlyContinue
    }

    # Remove temp directory tree
    if ($TestEnv.Root -and (Test-Path $TestEnv.Root)) {
        Remove-Item -Path $TestEnv.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-MockInvocations {
    <#
    .SYNOPSIS
        Parses the JSONL mock invocation log.
    .PARAMETER LogPath
        Path to the mock-invocations.jsonl file.
    .OUTPUTS
        Array of parsed invocation objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath
    )

    if (-not (Test-Path $LogPath)) { return @() }

    Get-Content -Path $LogPath -Encoding utf8 |
        Where-Object { $_.Trim() -ne '' } |
        ForEach-Object { $_ | ConvertFrom-Json }
}

function Initialize-TestGitRepo {
    <#
    .SYNOPSIS
        Creates a test git repository with deterministic local config.
    .PARAMETER Path
        Repository path to create or initialize.
    .PARAMETER UserEmail
        Git user.email value for the test repository.
    .PARAMETER UserName
        Git user.name value for the test repository.
    .PARAMETER InitialBranch
        Optional initial branch name passed to git init.
    .PARAMETER GitHubUser
        Optional github.user config value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$UserEmail = 'test@test.com',
        [string]$UserName = 'Test User',
        [string]$InitialBranch,
        [string]$GitHubUser
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    $initArgs = @('-C', $Path, 'init')
    if ($InitialBranch) {
        $initArgs += "--initial-branch=$InitialBranch"
    }

    & git @initArgs 2>$null | Out-Null
    & git -C $Path config user.email $UserEmail 2>&1 | Out-Null
    & git -C $Path config user.name $UserName 2>&1 | Out-Null

    if ($PSBoundParameters.ContainsKey('GitHubUser')) {
        & git -C $Path config github.user $GitHubUser 2>&1 | Out-Null
    }

    return $Path
}

function New-TestGitCommit {
    <#
    .SYNOPSIS
        Writes a file, creates a commit, and returns the resulting commit hash.
    .PARAMETER Path
        Repository root path.
    .PARAMETER FileName
        Relative file path to write before committing.
    .PARAMETER Content
        File content to write.
    .PARAMETER Message
        Optional commit message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Content,
        [string]$Message
    )

    Set-Content -Path (Join-Path $Path $FileName) -Value $Content -Encoding UTF8
    & git -C $Path add --all 2>&1 | Out-Null

    $commitMessage = if ($Message) { $Message } else { "test $([guid]::NewGuid())" }
    & git -C $Path commit -m $commitMessage --quiet 2>&1 | Out-Null

    return ((& git -C $Path rev-parse HEAD) | Select-Object -First 1).Trim()
}

function New-TestAgentConfig {
    <#
    .SYNOPSIS
        Creates a per-agent registration file in the test environment's agents dir.
    .PARAMETER TestEnv
        The PSCustomObject returned by New-TestEnvironment.
    .PARAMETER AgentId
        Identifier used as the registration filename stem.
    .PARAMETER Schedule
        Hashtable describing the schedule (e.g. @{ type='daily'; time='09:00' }).
    .PARAMETER Prompt
        The prompt string for the agent.
    .PARAMETER Agent
        Optional agent name passed via --agent flag.
    .PARAMETER Timeout
        Optional timeout string (e.g. '10m').
    .PARAMETER Name
        Optional display name. Defaults to AgentId.
    .OUTPUTS
        PSCustomObject with the agent config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TestEnv,
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][hashtable]$Schedule,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Agent,
        [string]$Timeout,
        [string]$Name,
        $RunIf
    )

    $agentConfig = [ordered]@{
        name     = if ($Name) { $Name } else { $AgentId }
        prompt   = $Prompt
        schedule = $Schedule
    }

    if ($Agent) { $agentConfig['agent'] = $Agent }
    if ($Timeout) { $agentConfig['timeout'] = $Timeout }
    if ($PSBoundParameters.ContainsKey('RunIf')) { $agentConfig['runIf'] = $RunIf }

    $filePath = Join-Path $TestEnv.AgentsDir "$AgentId.agent-registration.json"
    $agentConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

    [PSCustomObject]$agentConfig
}

function New-TestRunDirectory {
    <#
    .SYNOPSIS
        Creates a pre-built run directory with artifacts for testing.
    .PARAMETER TestEnv
        The PSCustomObject returned by New-TestEnvironment.
    .PARAMETER AgentId
        Agent identifier used in the run directory name.
    .PARAMETER ExitCode
        Simulated exit code to write to exit-code file.
    .PARAMETER FeedbackContent
        Optional feedback markdown content to write.
    .PARAMETER FeedbackProcessed
        If true, marks feedback as already processed.
    .PARAMETER HasSummary
        If true, writes a mock summary file.
    .OUTPUTS
        PSCustomObject with RunDir path and Timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TestEnv,
        [Parameter(Mandatory)][string]$AgentId,
        [int]$ExitCode = 0,
        [string]$FeedbackContent,
        [switch]$FeedbackProcessed,
        [switch]$HasSummary
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runDir = Join-Path $TestEnv.RunsRoot $AgentId $timestamp
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    # Exit code
    $ExitCode | Out-File -FilePath (Join-Path $runDir 'exit-code') -Encoding utf8 -NoNewline

    # Output log
    "Mock output for $AgentId run at $timestamp" |
        Out-File -FilePath (Join-Path $runDir 'output.log') -Encoding utf8

    # Summary
    if ($HasSummary) {
        "## Run Summary`n`nAgent: $AgentId`nStatus: $(if ($ExitCode -eq 0) { 'success' } else { 'failure' })" |
            Out-File -FilePath (Join-Path $runDir 'summary.md') -Encoding utf8
    }

    # Feedback
    if ($FeedbackContent) {
        $FeedbackContent |
            Out-File -FilePath (Join-Path $runDir 'feedback.md') -Encoding utf8

        if ($FeedbackProcessed) {
            'true' | Out-File -FilePath (Join-Path $runDir 'feedback-processed') -Encoding utf8 -NoNewline
        }
    }

    [PSCustomObject]@{
        RunDir    = $runDir
        Timestamp = $timestamp
    }
}

Export-ModuleMember -Function @(
    'New-TestEnvironment'
    'Remove-TestEnvironment'
    'Get-MockInvocations'
    'Initialize-TestGitRepo'
    'New-TestGitCommit'
    'New-TestAgentConfig'
    'New-TestRunDirectory'
)
