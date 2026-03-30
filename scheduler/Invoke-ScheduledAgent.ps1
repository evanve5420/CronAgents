<#
.SYNOPSIS
    Runs a single CronAgents agent via Copilot CLI.

.DESCRIPTION
    Called by the scheduler loop or CLI 'run' command. Imports the shared
    CronAgents module, builds the Copilot CLI invocation, executes with
    timeout/retry, records metadata, and invokes the run-summarizer agent.

.PARAMETER AgentId
    Unique identifier for the agent (filename stem of its config).

.PARAMETER AgentConfig
    Parsed per-agent configuration object (from Get-AgentConfigs).

.PARAMETER GlobalConfig
    Parsed global configuration object (from Import-CronAgentsConfig).

.PARAMETER RepoRoot
    Absolute path to the repository root.

.PARAMETER PersonalRepoPath
    Optional path to the personal repo (~/.cronagents). When provided, Copilot
    CLI runs with WorkingDirectory set to this path instead of RepoRoot.

.PARAMETER RunsRoot
    Directory for storing run artifacts. Defaults to <RepoRoot>/.cronstate/runs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AgentId,
    [Parameter(Mandatory)] [PSCustomObject]$AgentConfig,
    [Parameter(Mandatory)] [PSCustomObject]$GlobalConfig,
    [Parameter(Mandatory)] [string]$RepoRoot,
    [string]$PersonalRepoPath,
    [hashtable]$RunIfSnapshot,
    [string]$RunsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Import shared module ---
Import-Module (Join-Path $PSScriptRoot 'lib\CronAgents.psd1') -Force

# --- Defaults ---
$stateRoot = if ($PersonalRepoPath) { Join-Path $PersonalRepoPath '.cronstate' } else { Join-Path $RepoRoot '.cronstate' }
if (-not $RunsRoot) {
    $RunsRoot = Join-Path $stateRoot 'runs'
}

# --- State file path ---
$stateFile = Join-Path $stateRoot 'state.json'

# --- Result tracking ---
$exitCode     = -1
$timedOut     = $false
$startTime    = $null
$endTime      = $null
$retryAttempt = 0
$runDir       = $null
$envKeys      = @()

function Split-CommandLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine
    )

    $errors = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize($CommandLine, [ref]$errors) |
        Where-Object { $_.Type -notin @('NewLine', 'LineContinuation', 'Comment') }

    if ($errors -and $errors.Count -gt 0) {
        throw "Unable to parse command line '$CommandLine'."
    }

    $parts = @($tokens | ForEach-Object { $_.Content } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        throw "Command line '$CommandLine' did not contain an executable."
    }

    return [string[]]$parts
}

function New-CommandProcessStartInfo {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.ProcessStartInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [string[]]$Arguments
    )

    $commandParts = Split-CommandLine -CommandLine $CommandLine
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $commandParts[0]
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if ($commandParts.Count -gt 1) {
        foreach ($part in $commandParts[1..($commandParts.Count - 1)]) {
            $psi.ArgumentList.Add($part)
        }
    }

    foreach ($argument in @($Arguments)) {
        $psi.ArgumentList.Add($argument)
    }

    return $psi
}

function Invoke-CopilotRun {
    <#
    .SYNOPSIS
        Builds and executes the Copilot CLI process for one attempt.
        Returns a hashtable with ExitCode, TimedOut, StartTime, EndTime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunDirectory,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $copilotPath = if ($GlobalConfig.copilotPath) { $GlobalConfig.copilotPath } else { 'copilot' }
    $outputFile  = Join-Path $RunDirectory 'output.md'

    Write-CronAgentsLog -Level 'debug' -Message "Copilot command: $copilotPath $($Arguments -join ' ')"

    $psi = New-CommandProcessStartInfo -CommandLine $copilotPath `
        -WorkingDirectory $(if ($PersonalRepoPath) { $PersonalRepoPath } else { $RepoRoot }) `
        -Arguments $Arguments

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $attemptStart = [datetime]::UtcNow
    $proc.Start() | Out-Null

    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()

    $timeoutMs  = $TimeoutSeconds * 1000
    $didTimeout = -not $proc.WaitForExit($timeoutMs)

    if ($didTimeout) {
        Write-CronAgentsLog -Level 'warn' -Message "Agent '$AgentId' timed out after ${TimeoutSeconds}s — killing process."
        try { $proc.Kill($true) } catch { <# best-effort #> }
        try { $proc.WaitForExit(5000) } catch { <# best-effort #> }
    }

    # Ensure async reads complete
    [void]$stdout.Wait(5000)
    [void]$stderr.Wait(5000)

    $stdoutText = if ($stdout.IsCompleted) { $stdout.Result } else { '' }
    $stderrText = if ($stderr.IsCompleted) { $stderr.Result } else { '' }

    # Write stdout to output file
    [System.IO.File]::WriteAllText($outputFile, $stdoutText, [System.Text.Encoding]::UTF8)

    # Append stderr to output if present
    if ($stderrText) {
        $separator = "`n`n---`n**stderr:**`n"
        [System.IO.File]::AppendAllText($outputFile, "$separator$stderrText", [System.Text.Encoding]::UTF8)
    }

    $attemptEnd = [datetime]::UtcNow
    $code = if ($didTimeout) { -1 } else { $proc.ExitCode }
    $proc.Dispose()

    return @{
        ExitCode  = $code
        TimedOut  = $didTimeout
        StartTime = $attemptStart
        EndTime   = $attemptEnd
    }
}

function Build-CopilotArguments {
    <#
    .SYNOPSIS
        Assembles the CLI argument list from agent and global config.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $args_ = [System.Collections.Generic.List[string]]::new()

    # Prompt (always)
    $args_.Add('-p')
    $args_.Add($AgentConfig.prompt)

    # Silent mode
    $args_.Add('--silent')

    # Agent mode vs prompt-only mode
    if ($AgentConfig.PSObject.Properties['agent'] -and
        -not [string]::IsNullOrWhiteSpace($AgentConfig.agent)) {
        $args_.Add("--agent=$($AgentConfig.agent)")
        $args_.Add('--add-dir=.github/agents')
    }
    else {
        $args_.Add('--allow-all-tools')
    }

    # Session share file
    $sharePath = Join-Path $runDir 'session.md'
    $args_.Add("--share=$sharePath")

    # Model override
    if ($AgentConfig.PSObject.Properties['model'] -and
        -not [string]::IsNullOrWhiteSpace($AgentConfig.model)) {
        $args_.Add("--model=$($AgentConfig.model)")
    }

    # Deny tools
    $denyTools = @($AgentConfig.denyTools)
    if ($AgentConfig.PSObject.Properties['denyTools'] -and $denyTools.Count -gt 0) {
        foreach ($tool in $denyTools) {
            $args_.Add("--deny-tool=$tool")
        }
    }

    # Extra CLI flags
    $extraCliFlags = @($AgentConfig.extraCliFlags)
    if ($AgentConfig.PSObject.Properties['extraCliFlags'] -and $extraCliFlags.Count -gt 0) {
        foreach ($flag in $extraCliFlags) {
            $args_.Add($flag)
        }
    }

    # Working-directory scoping
    $agentWd = $null
    if ($AgentConfig.PSObject.Properties['workingDirectory'] -and
        -not [string]::IsNullOrWhiteSpace($AgentConfig.workingDirectory)) {
        $agentWd = $AgentConfig.workingDirectory
    }

    if ($agentWd) {
        $args_.Add("--add-dir=$agentWd")
        if ($PersonalRepoPath) { $args_.Add("--add-dir=$PersonalRepoPath") }
        $args_.Add("--add-dir=$RepoRoot")
    }
    else {
        $args_.Add('--allow-all')
    }

    # Unattended execution
    $args_.Add('--no-ask-user')

    return [string[]]$args_.ToArray()
}

function Set-AgentEnvVars {
    <#
    .SYNOPSIS
        Sets process-level environment variables from agent config.
        Returns the keys that were set so they can be cleaned up later.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $setKeys = [System.Collections.Generic.List[string]]::new()

    if (-not $AgentConfig.PSObject.Properties['envVars'] -or
        $null -eq $AgentConfig.envVars) {
        return [string[]]@()
    }

    foreach ($prop in $AgentConfig.envVars.PSObject.Properties) {
        Write-CronAgentsLog -Level 'debug' -Message "Setting env var: $($prop.Name)"
        [System.Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, 'Process')
        $setKeys.Add($prop.Name)
    }

    return [string[]]$setKeys.ToArray()
}

function Remove-AgentEnvVars {
    <#
    .SYNOPSIS
        Removes previously-set environment variables.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Keys
    )

    foreach ($key in $Keys) {
        Write-CronAgentsLog -Level 'debug' -Message "Removing env var: $key"
        [System.Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
}

try {
    # ------------------------------------------------------------------
    # Step 1 — Pre-flight: battery check
    # ------------------------------------------------------------------
    if ($AgentConfig.PSObject.Properties['skipOnBattery'] -and $AgentConfig.skipOnBattery) {
        if (Test-OnBatteryPower) {
            Write-CronAgentsLog -Level 'info' -Message "Agent '$AgentId' skipped — machine is on battery power."
            return [PSCustomObject]@{
                AgentId       = $AgentId
                RunDirectory  = $null
                ExitCode      = 0
                TimedOut      = $false
                Skipped       = $true
                StartTime     = $null
                EndTime       = $null
                RetryAttempts = 0
            }
        }
    }

    # ------------------------------------------------------------------
    # Step 2 — Create run directory and initialize log
    # ------------------------------------------------------------------
    $runDir = New-RunDirectory -RunsRoot $RunsRoot -AgentId $AgentId
    Write-CronAgentsLog -Level 'debug' -Message "Run directory created: $runDir"

    Initialize-RunLog -RunDirectory $runDir | Out-Null
    Write-CronAgentsLog -Level 'info' -Message "Starting agent '$AgentId' — run dir: $runDir"

    # ------------------------------------------------------------------
    # Step 3 — Build arguments and set env vars
    # ------------------------------------------------------------------
    $cliArgs   = Build-CopilotArguments
    $envKeys   = Set-AgentEnvVars
    $timeoutSec = ConvertTo-Seconds -Duration ($AgentConfig.timeout)

    # ------------------------------------------------------------------
    # Step 4 — Execute with retry logic
    # ------------------------------------------------------------------
    $maxRetries = if ($AgentConfig.PSObject.Properties['retryCount'] -and $AgentConfig.retryCount -gt 0) {
        [int]$AgentConfig.retryCount
    } else { 0 }

    $retryAttempt = 0
    $result = $null

    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        if ($attempt -gt 0) {
            $retryAttempt = $attempt
            Write-CronAgentsLog -Level 'warn' -Message "Retrying agent '$AgentId' — attempt $attempt of $maxRetries"
        }

        $result = Invoke-CopilotRun -RunDirectory $runDir -TimeoutSeconds $timeoutSec -Arguments $cliArgs

        $exitCode  = $result.ExitCode
        $timedOut  = $result.TimedOut
        $startTime = if ($attempt -eq 0) { $result.StartTime } else { $startTime }
        $endTime   = $result.EndTime

        if ($exitCode -eq 0) {
            Write-CronAgentsLog -Level 'info' -Message "Agent '$AgentId' completed successfully (attempt $($attempt + 1))."
            break
        }

        if ($attempt -lt $maxRetries) {
            Write-CronAgentsLog -Level 'warn' -Message "Agent '$AgentId' failed with exit code $exitCode — will retry."
        }
        else {
            $level = if ($timedOut) { 'warn' } else { 'error' }
            $reason = if ($timedOut) { 'timed out' } else { "exit code $exitCode" }
            Write-CronAgentsLog -Level $level -Message "Agent '$AgentId' failed after $($attempt + 1) attempt(s): $reason."
        }
    }

    # ------------------------------------------------------------------
    # Step 5 — Clean up env vars
    # ------------------------------------------------------------------
    Remove-AgentEnvVars -Keys $envKeys

    # ------------------------------------------------------------------
    # Step 6 — Write run metadata
    # ------------------------------------------------------------------
    Write-RunMetadata -RunDirectory $runDir -AgentId $AgentId `
        -AgentName $AgentConfig.name -Prompt $AgentConfig.prompt `
        -ExitCode $exitCode -TimedOut $timedOut `
        -StartTime $startTime -EndTime $endTime `
        -RetryAttempt $retryAttempt

    # ------------------------------------------------------------------
    # Step 6b — Notify on failure (best-effort)
    # ------------------------------------------------------------------
    if ($exitCode -ne 0) {
        try {
            Send-AgentFailureNotification `
                -AgentId $AgentId -AgentName $AgentConfig.name `
                -ExitCode $exitCode -TimedOut $timedOut `
                -GlobalConfig $GlobalConfig -AgentConfig $AgentConfig
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Failure notification error for '$AgentId': $_ — continuing."
        }
    }

    # ------------------------------------------------------------------
    # Step 7 — Invoke run-summarizer (best-effort)
    # ------------------------------------------------------------------
    try {
        $copilotPath   = if ($GlobalConfig.copilotPath) { $GlobalConfig.copilotPath } else { 'copilot' }
        $summaryFile   = Join-Path $runDir 'summary.md'
        $summaryShare  = Join-Path $runDir 'summarizer-session.md'
        $schedulerDir  = Join-Path $RepoRoot 'scheduler'
        $summaryPrompt = "Summarize the agent run in directory: $runDir. Read output.md and meta.json."

        $summaryArgs = @(
            "--agent=run-summarizer"
            '-p'
            $summaryPrompt
            '--silent'
            "--add-dir=$schedulerDir"
            '--allow-all-tools'
            "--share=$summaryShare"
            '--no-ask-user'
        )

        Write-CronAgentsLog -Level 'debug' -Message "Invoking run-summarizer for '$AgentId'."

        $sumPsi = New-CommandProcessStartInfo -CommandLine $copilotPath `
            -WorkingDirectory $(if ($PersonalRepoPath) { $PersonalRepoPath } else { $RepoRoot }) `
            -Arguments $summaryArgs

        $sumProc = [System.Diagnostics.Process]::new()
        $sumProc.StartInfo = $sumPsi
        $sumProc.Start() | Out-Null

        $sumStdout = $sumProc.StandardOutput.ReadToEndAsync()
        # Allow summarizer up to 2 minutes
        if (-not $sumProc.WaitForExit(120000)) {
            Write-CronAgentsLog -Level 'warn' -Message "Run-summarizer timed out for '$AgentId' — killing."
            try { $sumProc.Kill($true) } catch { <# best-effort #> }
        }

        [void]$sumStdout.Wait(5000)
        $sumText = if ($sumStdout.IsCompleted) { $sumStdout.Result } else { '' }
        [System.IO.File]::WriteAllText($summaryFile, $sumText, [System.Text.Encoding]::UTF8)
        $sumProc.Dispose()

        Write-CronAgentsLog -Level 'debug' -Message "Run-summarizer completed for '$AgentId'."
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Run-summarizer failed for '$AgentId': $_ — continuing."
    }

    # ------------------------------------------------------------------
    # Step 8 — Update agent state
    # ------------------------------------------------------------------
    if ($AgentConfig.PSObject.Properties['runIf'] -and
        $null -ne $AgentConfig.runIf -and
        -not $PSBoundParameters.ContainsKey('RunIfSnapshot')) {
        $executionRoot = Get-AgentRunIfExecutionRoot -AgentConfig $AgentConfig -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath
        $snapshotResult = Get-AgentRunIfSnapshot -RunIf $AgentConfig.runIf -ExecutionRoot $executionRoot
        if ($snapshotResult.Success) {
            $RunIfSnapshot = $snapshotResult.Snapshot
        } else {
            Write-CronAgentsLog -Level 'warn' -Message "Snapshot capture failed for '$AgentId': $($snapshotResult.Reason) — preserving previous runIfState."
            $existingState = Get-AgentState -StateFile $stateFile -AgentId $AgentId
            $RunIfSnapshot = if ($existingState -and $existingState.ContainsKey('runIfState')) { $existingState.runIfState } else { @{} }
        }
    }

    Set-AgentState -StateFile $stateFile -AgentId $AgentId -LastRun ([datetime]::UtcNow) -RunIfState $RunIfSnapshot
    Write-CronAgentsLog -Level 'debug' -Message "Agent state updated for '$AgentId'."

    # ------------------------------------------------------------------
    # Step 9 — Return result
    # ------------------------------------------------------------------
    return [PSCustomObject]@{
        AgentId       = $AgentId
        RunDirectory  = $runDir
        ExitCode      = $exitCode
        TimedOut      = $timedOut
        Skipped       = $false
        StartTime     = $startTime
        EndTime       = $endTime
        RetryAttempts = $retryAttempt
    }
}
catch {
    # ------------------------------------------------------------------
    # Unexpected error — write metadata marking the run as failed
    # ------------------------------------------------------------------
    Write-CronAgentsLog -Level 'error' -Message "Unexpected error running agent '$AgentId': $_"

    if ($runDir -and (Test-Path $runDir)) {
        try {
            Write-RunMetadata -RunDirectory $runDir -AgentId $AgentId `
                -AgentName $AgentConfig.name -Prompt $AgentConfig.prompt `
                -ExitCode -1 -TimedOut $false `
                -StartTime $startTime -EndTime ([datetime]::UtcNow) `
                -RetryAttempt $retryAttempt
        }
        catch {
            Write-CronAgentsLog -Level 'error' -Message "Failed to write failure metadata: $_"
        }
    }

    # Clean up env vars if they were set
    if ($envKeys) {
        try { Remove-AgentEnvVars -Keys $envKeys } catch { <# best-effort #> }
    }

    return [PSCustomObject]@{
        AgentId       = $AgentId
        RunDirectory  = $runDir
        ExitCode      = -1
        TimedOut      = $false
        Skipped       = $false
        StartTime     = $startTime
        EndTime       = [datetime]::UtcNow
        RetryAttempts = $retryAttempt
    }
}
