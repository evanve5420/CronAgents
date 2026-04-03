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

    # List directories matching the <timestamp>_<agentId>_<nonce> pattern
    $dirs = Get-ChildItem -LiteralPath $RunsRoot -Directory |
        Where-Object { $_.Name -match '^(\d{8}T\d{6})_(.+)_([0-9a-f]{4})$' }

    $results = @()

    foreach ($dir in $dirs) {
        if ($dir.Name -notmatch '^(\d{8}T\d{6})_(.+)_([0-9a-f]{4})$') {
            continue
        }
        $tsRaw      = $Matches[1]
        $extractedId = $Matches[2]

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
            RunDirectory      = $dir.FullName
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

    # Strict format: 20240101T123456_<safe-name>_1a2b
    if ($RunId -notmatch '^[0-9]{8}T[0-9]{6}_[A-Za-z0-9._-]+_[0-9a-f]{4}$') {
        return $null
    }
    # Must not contain directory separators or traversal segments
    if ($RunId -ne [System.IO.Path]::GetFileName($RunId)) {
        return $null
    }
    $runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
    $runDir = [System.IO.Path]::GetFullPath((Join-Path $RunsRoot $RunId))
    # Ensure resolved path stays under runs root
    $prefix = $runsRootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $runDir.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $runDir
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

    # Helper: returns $true when meta.json indicates the run is still active
    $isRunActive = {
        param([string]$Dir)
        $metaPath = Join-Path $Dir 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath)) { return $false }
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # A run is active when it has no final exitCode and no endTime
            $noExit = ($null -eq $meta.PSObject.Properties['exitCode']) -or ($null -eq $meta.exitCode)
            $noEnd  = ($null -eq $meta.PSObject.Properties['endTime'])  -or [string]::IsNullOrEmpty($meta.endTime)
            return ($noExit -and $noEnd)
        }
        catch { return $false }
    }

    # ── Single run ──────────────────────────────────────────────
    if ($RunId) {
        $runDir = Test-SafeRunId -RunId $RunId -RunsRoot $RunsRoot
        if (-not $runDir) {
            throw "Invalid run ID format: $RunId"
        }

        if (Test-Path -LiteralPath $runDir) {
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
