# -----------------------------------------------------------------------
# RunManager.ps1 — Run directory creation, metadata, and output capture
#
# Provides New-RunDirectory (creates timestamped run dirs with feedback
# stubs), Write-RunMetadata (writes meta.json), and Get-RunHistory
# (reads and filters past runs). Designed to be dot-sourced as a nested
# module via CronAgents.psd1.
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CronAgentsIsoTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Time
    )

    return $Time.ToUniversalTime().ToString('o')
}

# -------------------------------------------------------------------
# New-RunDirectory
# -------------------------------------------------------------------
function New-RunDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RunsRoot,

        [Parameter(Mandatory)]
        [string]$AgentId
    )

    # Compact ISO timestamp (filesystem-safe)
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')

    # 4-char lowercase hex nonce via cryptographic RNG
    $rngBytes = [byte[]]::new(2)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($rngBytes)
    }
    finally {
        $rng.Dispose()
    }
    $nonce = ($rngBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $dirName = "${timestamp}_${AgentId}_${nonce}"
    $runDir  = Join-Path $RunsRoot $dirName

    # Create the run directory (and parents if needed)
    New-Item -Path $runDir -ItemType Directory -Force | Out-Null

    # Create feedback.md stub
    $feedbackPath = Join-Path $runDir 'feedback.md'
    $feedbackContent = @"
<!-- Feedback for agent run: $AgentId -->
<!-- Write your feedback below. The feedback evaluator will process it. -->
<!-- Leave empty to skip feedback for this run. -->

"@
    Set-Content -LiteralPath $feedbackPath -Value $feedbackContent -Encoding UTF8 -NoNewline

    Write-CronAgentsLog -Level 'debug' -Message "Created run directory: $runDir"

    return $runDir
}

# -------------------------------------------------------------------
# Initialize-RunMetadata — preliminary meta.json written at run start
# -------------------------------------------------------------------
function Initialize-RunMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory,

        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$AgentName,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $meta = [ordered]@{
        agentId           = $AgentId
        agentName         = $AgentName
        prompt            = $Prompt
        startTime         = ConvertTo-CronAgentsIsoTimestamp -Time ([datetime]::UtcNow)
        endTime           = $null
        exitCode          = $null
        timedOut          = $false
        retryAttempt      = 0
        feedbackProcessed = $false
    }

    $metaPath = Join-Path $RunDirectory 'meta.json'
    $json = $meta | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $metaPath -Value $json -Encoding UTF8

    Write-CronAgentsLog -Level 'debug' -Message "Initialized run metadata in: $metaPath"
}

# -------------------------------------------------------------------
# Write-RunMetadata
# -------------------------------------------------------------------
function Write-RunMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory,

        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$AgentName,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [datetime]$StartTime,

        [Parameter(Mandatory)]
        [datetime]$EndTime,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [bool]$TimedOut = $false,

        [int]$RetryAttempt = 0
    )

    $meta = [ordered]@{
        agentId           = $AgentId
        agentName         = $AgentName
        prompt            = $Prompt
        startTime         = ConvertTo-CronAgentsIsoTimestamp -Time $StartTime
        endTime           = ConvertTo-CronAgentsIsoTimestamp -Time $EndTime
        exitCode          = $ExitCode
        timedOut          = $TimedOut
        retryAttempt      = $RetryAttempt
        feedbackProcessed = $false
    }

    $metaPath = Join-Path $RunDirectory 'meta.json'
    $json = $meta | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $metaPath -Value $json -Encoding UTF8

    Write-CronAgentsLog -Level 'debug' -Message "Wrote run metadata to: $metaPath"
}

# -------------------------------------------------------------------
# Test-FeedbackPresent (helper)
# -------------------------------------------------------------------
function Test-FeedbackPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FeedbackPath
    )

    if (-not (Test-Path -LiteralPath $FeedbackPath)) {
        return $false
    }

    $lines = Get-Content -LiteralPath $FeedbackPath -ErrorAction SilentlyContinue
    if (-not $lines) { return $false }

    # Strip HTML comment lines and check if anything substantive remains
    $nonCommentContent = ($lines | Where-Object { $_ -notmatch '^\s*<!--.*-->\s*$' }) -join ''
    return ($nonCommentContent.Trim().Length -gt 0)
}

# -------------------------------------------------------------------
# Get-RunHistory
# -------------------------------------------------------------------
function Get-RunHistory {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RunsRoot,

        [string]$AgentId,

        [int]$MaxResults
    )

    if (-not (Test-Path -LiteralPath $RunsRoot)) {
        return @()
    }

    $dirs = Get-ChildItem -LiteralPath $RunsRoot -Directory

    $results = @()

    foreach ($dir in $dirs) {
        $resolvedRun = Resolve-CronAgentsRunPath -RunId $dir.Name -RunsRoot $RunsRoot
        if (-not $resolvedRun.IsValid -or -not $resolvedRun.Exists) {
            continue
        }
        $tsRaw = $resolvedRun.TimestampToken
        $extractedId = $resolvedRun.AgentId

        # Filter by AgentId if specified
        if ($AgentId -and $extractedId -ne $AgentId) {
            continue
        }

        # Parse timestamp
        $parsedTime = $null
        try {
            $parsedTime = [datetime]::ParseExact($tsRaw, 'yyyyMMddTHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
            $parsedTime = [datetime]::SpecifyKind($parsedTime, [System.DateTimeKind]::Utc)
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Could not parse timestamp from directory: $($dir.Name)"
            continue
        }

        # Read meta.json (graceful on failure)
        $meta = $null
        $feedbackProcessed = $false
        $metaPath = Join-Path $dir.FullName 'meta.json'
        if (Test-Path -LiteralPath $metaPath) {
            try {
                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $feedbackProcessed = [bool]($meta.feedbackProcessed)
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Could not read meta.json in: $($dir.FullName)"
            }
        }

        # Check feedback
        $feedbackPath = Join-Path $dir.FullName 'feedback.md'
        $hasFeedback  = Test-FeedbackPresent -FeedbackPath $feedbackPath

        # Check summary
        $summaryPath = Join-Path $dir.FullName 'summary.md'
        $hasSummary  = Test-Path -LiteralPath $summaryPath

        $results += [PSCustomObject]@{
            RunDirectory      = $resolvedRun.Path
            AgentId           = $extractedId
            Timestamp         = $parsedTime
            Meta              = $meta
            HasFeedback       = $hasFeedback
            FeedbackProcessed = $feedbackProcessed
            HasSummary        = $hasSummary
        }
    }

    # Sort descending by timestamp (most recent first)
    $results = $results | Sort-Object -Property Timestamp -Descending

    # Limit results if MaxResults is specified
    if ($PSBoundParameters.ContainsKey('MaxResults') -and $MaxResults -gt 0) {
        $results = $results | Select-Object -First $MaxResults
    }

    return @($results)
}

# -------------------------------------------------------------------
# Resolve-CronAgentsRunPath — validate a run ID and resolve its path
# -------------------------------------------------------------------
function Resolve-CronAgentsRunPath {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$RunsRoot
    )

    $invalidResult = [PSCustomObject]@{
        IsValid        = $false
        Exists         = $false
        Path           = $null
        AgentId        = $null
        TimestampToken = $null
        Reason         = 'invalid-format'
    }

    if ($RunId -ne [System.IO.Path]::GetFileName($RunId)) {
        return $invalidResult
    }

    if ($RunId -notmatch '^(?<Timestamp>[0-9]{8}T[0-9]{6})_(?<AgentId>.+)_(?<Nonce>[0-9a-f]{4})$') {
        return $invalidResult
    }

    $agentId = $Matches['AgentId']
    if (-not (Test-CronAgentsSafeIdentifier -Value $agentId)) {
        return $invalidResult
    }

    $runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
    $runDir = [System.IO.Path]::GetFullPath((Join-Path $RunsRoot $RunId))

    # Ensure resolved path stays under runs root
    $prefix = $runsRootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $runDir.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $invalidResult
    }

    $exists = Test-Path -LiteralPath $runDir -PathType Container
    if ($exists) {
        $item = Get-Item -LiteralPath $runDir -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
            return [PSCustomObject]@{
                IsValid        = $false
                Exists         = $true
                Path           = $null
                AgentId        = $agentId
                TimestampToken = $Matches['Timestamp']
                Reason         = 'reparse-point'
            }
        }
    }

    return [PSCustomObject]@{
        IsValid        = $true
        Exists         = $exists
        Path           = $runDir
        AgentId        = $agentId
        TimestampToken = $Matches['Timestamp']
        Reason         = $null
    }
}

# -------------------------------------------------------------------
# Test-SafeRunId — validate a run ID and resolve its directory path
# -------------------------------------------------------------------
function Test-SafeRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$RunsRoot
    )

    $resolvedRun = Resolve-CronAgentsRunPath -RunId $RunId -RunsRoot $RunsRoot
    if (-not $resolvedRun.IsValid) {
        return $null
    }

    return $resolvedRun.Path
}

# -------------------------------------------------------------------
# Clear-RunHistory
# -------------------------------------------------------------------
function Clear-RunHistory {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RunsRoot,

        [string]$RunId,

        [string]$AgentId,

        [switch]$All
    )

    $deleted  = 0
    $skipped  = 0
    $errors   = [System.Collections.Generic.List[string]]::new()

    # Validate parameters — exactly one scope must be specified
    $scopeCount = [int][bool]$RunId + [int][bool]$AgentId + [int][bool]$All
    if ($scopeCount -ne 1) {
        throw 'Specify exactly one of -RunId, -AgentId, or -All.'
    }

    if (-not (Test-Path -LiteralPath $RunsRoot)) {
        return [PSCustomObject]@{
            DeletedCount = 0
            SkippedCount = 0
            Errors       = [string[]]@()
        }
    }

    # Helper: returns $true when meta.json indicates the run is still active.
    # A run with no exitCode/endTime but an existing output.md is considered
    # incomplete (the process exited without writing final metadata), not active.
    $isRunActive = {
        param([string]$Dir)
        $metaPath = Join-Path $Dir 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath)) { return $false }
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $noExit = ($null -eq $meta.PSObject.Properties['exitCode']) -or ($null -eq $meta.exitCode)
            $noEnd  = ($null -eq $meta.PSObject.Properties['endTime'])  -or [string]::IsNullOrEmpty($meta.endTime)
            if (-not ($noExit -and $noEnd)) { return $false }
            # output.md is written after the agent process exits; its presence
            # means the process finished but final metadata was never recorded.
            $hasOutput = Test-Path -LiteralPath (Join-Path $Dir 'output.md')
            return (-not $hasOutput)
        }
        catch { return $false }
    }

    # ── Single run ──────────────────────────────────────────────
    if ($RunId) {
        $resolvedRun = Resolve-CronAgentsRunPath -RunId $RunId -RunsRoot $RunsRoot
        if (-not $resolvedRun.IsValid) {
            throw "Invalid run ID format: $RunId"
        }

        if ($resolvedRun.Exists) {
            $runDir = $resolvedRun.Path
            if (& $isRunActive $runDir) {
                Write-CronAgentsLog -Level 'info' -Message "Skipping active run: $RunId"
                $errors.Add("Run '$RunId' is still active and cannot be deleted.")
                $skipped++
            }
            else {
                try {
                    Remove-Item -LiteralPath $runDir -Recurse -Force
                    $deleted++
                    Write-CronAgentsLog -Level 'info' -Message "Cleared run: $RunId"
                }
                catch {
                    $errors.Add("Failed to delete $RunId`: $_")
                    Write-CronAgentsLog -Level 'warn' -Message "Failed to delete run $RunId`: $_"
                }
            }
        }
        else {
            $skipped++
        }
    }

    # ── Agent runs ──────────────────────────────────────────────
    elseif ($AgentId) {
        $escapedAgentId = [regex]::Escape($AgentId)
        $dirs = Get-ChildItem -LiteralPath $RunsRoot -Directory |
            Where-Object { $_.Name -match "^(\d{8}T\d{6})_${escapedAgentId}_([0-9a-f]{4})$" }

        foreach ($dir in $dirs) {
            if (& $isRunActive $dir.FullName) {
                Write-CronAgentsLog -Level 'info' -Message "Skipping active run: $($dir.Name)"
                $skipped++
                continue
            }
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                $deleted++
            }
            catch {
                $errors.Add("Failed to delete $($dir.Name)`: $_")
                $skipped++
            }
        }
        Write-CronAgentsLog -Level 'info' -Message "Cleared $deleted run(s) for agent: $AgentId"
    }

    # ── All runs ────────────────────────────────────────────────
    elseif ($All) {
        $dirs = Get-ChildItem -LiteralPath $RunsRoot -Directory |
            Where-Object { $_.Name -match '^(\d{8}T\d{6})_(.+)_([0-9a-f]{4})$' }

        foreach ($dir in $dirs) {
            if (& $isRunActive $dir.FullName) {
                Write-CronAgentsLog -Level 'info' -Message "Skipping active run: $($dir.Name)"
                $skipped++
                continue
            }
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                $deleted++
            }
            catch {
                $errors.Add("Failed to delete $($dir.Name)`: $_")
                $skipped++
            }
        }
        Write-CronAgentsLog -Level 'info' -Message "Cleared all run history: $deleted run(s) deleted."
    }

    return [PSCustomObject]@{
        DeletedCount = $deleted
        SkippedCount = $skipped
        Errors       = [string[]]$errors.ToArray()
    }
}

# -------------------------------------------------------------------
# Get-FeedbackTarget — parse explicit target from feedback.md
# -------------------------------------------------------------------
function Get-FeedbackTarget {
    <#
    .SYNOPSIS
        Parses the ## Target section from a feedback.md file.
    .DESCRIPTION
        Returns a structured object with the target agent name, file list,
        and the remaining feedback text. When no ## Target section is
        present, HasTarget is $false and FeedbackText contains the full
        non-comment content.
    .PARAMETER FeedbackPath
        Path to the feedback.md file.
    .OUTPUTS
        PSCustomObject with HasTarget, Agent, Files, FeedbackText.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$FeedbackPath
    )

    if (-not (Test-Path -LiteralPath $FeedbackPath)) {
        return [PSCustomObject]@{ HasTarget = $false; Agent = $null; Files = @(); FeedbackText = '' }
    }

    $lines = @(Get-Content -LiteralPath $FeedbackPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (-not $lines) {
        return [PSCustomObject]@{ HasTarget = $false; Agent = $null; Files = @(); FeedbackText = '' }
    }

    # Strip HTML comment lines for content extraction
    $contentLines = @($lines | Where-Object { $_ -notmatch '^\s*<!--.*-->\s*$' })

    # Locate ## Target heading
    $targetIdx = -1
    for ($i = 0; $i -lt $contentLines.Count; $i++) {
        if ($contentLines[$i] -match '^\s*##\s+Target\s*$') {
            $targetIdx = $i
            break
        }
    }

    if ($targetIdx -lt 0) {
        return [PSCustomObject]@{
            HasTarget    = $false
            Agent        = $null
            Files        = @()
            FeedbackText = ($contentLines -join "`n").Trim()
        }
    }

    # Find end of target section (next ## heading or end of content)
    $targetEnd = $contentLines.Count
    for ($j = $targetIdx + 1; $j -lt $contentLines.Count; $j++) {
        if ($contentLines[$j] -match '^\s*##\s+') {
            $targetEnd = $j
            break
        }
    }

    # Extract target block lines
    $targetBlock = @($contentLines[($targetIdx + 1)..($targetEnd - 1)])

    $agent = $null
    $files = [System.Collections.Generic.List[string]]::new()
    $inFilesList = $false

    foreach ($line in $targetBlock) {
        if ($line -match '^\s*agent\s*:\s*(.+)$') {
            $agent = $Matches[1].Trim()
            $inFilesList = $false
            continue
        }
        # files: with inline value on the same line
        if ($line -match '^\s*files\s*:\s+(.+)$') {
            $filePath = $Matches[1].Trim()
            if ($filePath -notmatch '(^|[\\/])\.\.($|[\\/])' -and -not [System.IO.Path]::IsPathRooted($filePath)) {
                $files.Add($filePath)
            }
            else {
                Write-CronAgentsLog -Level 'warn' -Message "Ignoring suspicious file path in feedback target: '$filePath'"
            }
            $inFilesList = $false
            continue
        }
        if ($line -match '^\s*files\s*:\s*$') {
            $inFilesList = $true
            continue
        }
        if ($inFilesList -and $line -match '^\s*-\s+(.+)$') {
            $filePath = $Matches[1].Trim()
            if ($filePath -notmatch '(^|[\\/])\.\.($|[\\/])' -and -not [System.IO.Path]::IsPathRooted($filePath)) {
                $files.Add($filePath)
            }
            else {
                Write-CronAgentsLog -Level 'warn' -Message "Ignoring suspicious file path in feedback target: '$filePath'"
            }
            continue
        }
        # Non-matching line ends the files list
        if ($inFilesList -and $line.Trim() -ne '') {
            $inFilesList = $false
        }
    }

    # Validate agent name using the shared safe-identifier check
    if ($agent -and -not (Test-CronAgentsSafeIdentifier -Value $agent)) {
        Write-CronAgentsLog -Level 'warn' -Message "Feedback target has invalid agent name '$agent' — ignoring target"
        $agent = $null
    }

    # Collect feedback text (everything outside the target section)
    $feedbackParts = @()
    if ($targetIdx -gt 0) {
        $feedbackParts += $contentLines[0..($targetIdx - 1)]
    }
    if ($targetEnd -lt $contentLines.Count) {
        $feedbackParts += $contentLines[$targetEnd..($contentLines.Count - 1)]
    }

    # If there's a ## Feedback heading, strip it from the text
    $feedbackText = ($feedbackParts -join "`n") -replace '(?m)^\s*##\s+Feedback\s*$', ''
    $feedbackText = $feedbackText.Trim()

    return [PSCustomObject]@{
        HasTarget    = ($null -ne $agent)
        Agent        = $agent
        Files        = [string[]]$files.ToArray()
        FeedbackText = $feedbackText
    }
}

# -------------------------------------------------------------------
# Read-SubagentManifest — read subagents.json from a run directory
# -------------------------------------------------------------------
function Read-SubagentManifest {
    <#
    .SYNOPSIS
        Reads the subagents.json manifest from a run directory.
    .DESCRIPTION
        Orchestrator agents can write a subagents.json file into the run
        directory declaring the subagents they spawned. This function
        reads and validates that manifest.
    .PARAMETER RunDirectory
        Path to the run directory containing subagents.json.
    .OUTPUTS
        Array of PSCustomObjects with Name, Agent, Profile, Skills.
        Returns empty array when no manifest exists or on parse failure.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory
    )

    $manifestPath = Join-Path $RunDirectory 'subagents.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Failed to parse subagents.json in: $RunDirectory"
        return @()
    }

    # Normalise to array (single object or array input)
    if ($raw -isnot [System.Array]) {
        $raw = @($raw)
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($entry in $raw) {
        # Require at least name and agent
        if (-not $entry.PSObject.Properties['name'] -or -not $entry.PSObject.Properties['agent']) {
            Write-CronAgentsLog -Level 'warn' -Message "Skipping subagent manifest entry missing name or agent in: $RunDirectory"
            continue
        }

        $nameStr  = [string]$entry.name
        $agentStr = [string]$entry.agent

        # Validate name/agent as safe identifiers
        if (-not (Test-CronAgentsSafeIdentifier -Value $nameStr) -or -not (Test-CronAgentsSafeIdentifier -Value $agentStr)) {
            Write-CronAgentsLog -Level 'warn' -Message "Subagent entry has invalid name/agent value — skipping"
            continue
        }

        $results.Add([PSCustomObject]@{
            Name    = $nameStr
            Agent   = $agentStr
            Profile = if ($entry.PSObject.Properties['profile']) { [string]$entry.profile } else { $null }
            Skills  = if ($entry.PSObject.Properties['skills']) { @($entry.skills | Where-Object { $_ -is [string] }) } else { @() }
        })
    }

    return @($results.ToArray())
}

# -------------------------------------------------------------------
# Build-FeedbackEvaluatorContext — shared prompt context for targeting
# -------------------------------------------------------------------
function Build-FeedbackEvaluatorContext {
    <#
    .SYNOPSIS
        Builds prompt context strings for the feedback evaluator from
        parsed target and manifest data.
    .PARAMETER FeedbackTarget
        PSCustomObject from Get-FeedbackTarget.
    .PARAMETER SubagentManifest
        Array from Read-SubagentManifest.
    .OUTPUTS
        String array of context fragments to append to the evaluator prompt.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$FeedbackTarget,

        [System.Object[]]$SubagentManifest = @()
    )

    $parts = [System.Collections.Generic.List[string]]::new()

    if ($FeedbackTarget.HasTarget) {
        $parts.Add("Feedback target: agent=$($FeedbackTarget.Agent)")
        if ($FeedbackTarget.Files.Count -gt 0) {
            $parts.Add("Target files: $($FeedbackTarget.Files -join ', ')")
        }
    }

    if ($SubagentManifest.Count -gt 0) {
        $manifestJson = $SubagentManifest | ConvertTo-Json -Depth 5 -Compress
        $parts.Add("Subagent manifest: $manifestJson")
    }

    return [string[]]$parts.ToArray()
}
