# ---------------------------------------------------------------------------
# SummaryParser.ps1 — Parse structured frontmatter from summary.md files
# ---------------------------------------------------------------------------
# Summary files may contain optional YAML frontmatter with metadata:
#
#   ---
#   attention: true
#   result: success
#   headline: "Short one-line description"
#   ---
#   Brief 1-5 sentence summary (first paragraph).
#
#   Optional details after a blank line...
#
# Summaries without frontmatter are treated as body-only (backwards-compatible).
# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest

function Read-SummaryFrontmatter {
    <#
    .SYNOPSIS
        Parses a summary.md file and extracts YAML frontmatter metadata.
    .DESCRIPTION
        Reads a summary.md file and returns an object with:
        - Attention  [bool]   — whether this run needs user attention
        - Result     [string] — success, failure, unknown, or $null
        - Headline   [string] — short one-liner for table display (or $null)
        - Brief      [string] — concise 1-5 sentence summary (first paragraph of body)
        - Body       [string] — the full summary text after the frontmatter
        - Raw        [string] — the original file content
        - ReadError  [string] — error message if file could not be read (or $null)
        Gracefully handles files without frontmatter (returns defaults).
        NOTE: Purpose-built parser for CronAgents summary frontmatter only.
        Supports scalar values for: attention, result, headline.
    .PARAMETER Path
        Full path to the summary.md file.
    .PARAMETER Content
        Raw string content of the summary (alternative to Path).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByPath')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'ByContent')]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$MetadataOnly
    )

    $defaults = [PSCustomObject]@{
        Attention = $false
        Result    = $null
        Headline  = $null
        Brief     = $null
        Body      = ''
        Raw       = ''
        ReadError = $null
    }

    # Read content — when MetadataOnly, read the first 20 lines (enough for frontmatter + first paragraph brief)
    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        if (-not (Test-Path -LiteralPath $Path)) {
            $defaults.ReadError = "File not found: $Path"
            return $defaults
        }
        try {
            if ($MetadataOnly) {
                $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 20 -ErrorAction Stop)
                $Content = $lines -join "`n"
            } else {
                $Content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            }
        }
        catch {
            $defaults.ReadError = "Failed to read: $_"
            return $defaults
        }
    }

    if ([string]::IsNullOrWhiteSpace($Content)) { return $defaults }

    $defaults.Raw = $Content

    # Check for YAML frontmatter delimited by --- on its own line
    # Pattern: starts with ---, then key: value lines, then closing ---
    $fmPattern = '(?s)\A\s*---\r?\n(.*?)\r?\n---\r?\n?(.*)'
    if ($Content -match $fmPattern) {
        $fmBlock = $Matches[1]
        $body    = $Matches[2]

        $attention = $false
        $result    = $null
        $headline  = $null

        foreach ($line in ($fmBlock -split '\r?\n')) {
            $line = $line.Trim()
            if ($line -match '^attention\s*:\s*(.+)$') {
                $val = $Matches[1].Trim().ToLower()
                $attention = $val -eq 'true' -or $val -eq 'yes' -or $val -eq '1'
            }
            elseif ($line -match '^result\s*:\s*(.+)$') {
                $val = script:Unquote-SummaryScalar -Value $Matches[1]
                $normalized = $val.Trim().ToLowerInvariant()
                if ($normalized -in @('success', 'failure', 'unknown')) { $result = $normalized }
            }
            elseif ($line -match '^headline\s*:\s*(.+)$') {
                $val = script:Unquote-SummaryScalar -Value $Matches[1]
                if ($val.Length -gt 0) { $headline = $val }
            }
        }

        $trimmedBody = $body.TrimStart("`r", "`n").TrimEnd()
        return [PSCustomObject]@{
            Attention = $attention
            Result    = $result
            Headline  = $headline
            Brief     = (script:Extract-Brief -Body $trimmedBody)
            Body      = $trimmedBody
            Raw       = $Content
            ReadError = $null
        }
    }

    # No frontmatter — entire content is the body
    $trimmed = $Content.TrimStart("`r", "`n").TrimEnd()
    $defaults.Brief = script:Extract-Brief -Body $trimmed
    $defaults.Body = $trimmed
    return $defaults
}

function Write-SummaryAttention {
    <#
    .SYNOPSIS
        Updates the attention field in a summary.md file's YAML frontmatter.
    .DESCRIPTION
        Rewrites the frontmatter to set attention to the specified value while
        preserving all other frontmatter fields and the body content.
        If the summary has no frontmatter, prepends a frontmatter block.
    .PARAMETER Path
        Full path to the summary.md file.
    .PARAMETER Attention
        The new value for the attention field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Attention
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Summary file not found: $Path"
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        throw "Failed to read summary file '$Path': $($_.Exception.Message)"
    }
    $attentionStr = if ($Attention) { 'true' } else { 'false' }
    $fmPattern = '(?s)\A\s*---\r?\n(.*?)\r?\n---\r?\n?(.*)'

    if ($content -match $fmPattern) {
        $fmBlock = $Matches[1]
        $body    = $Matches[2]

        # Replace or add the attention field in the frontmatter block
        $fmLines = $fmBlock -split '\r?\n'
        $found = $false
        $newLines = @()
        foreach ($line in $fmLines) {
            if ($line -match '^\s*attention\s*:') {
                $newLines += "attention: $attentionStr"
                $found = $true
            } else {
                $newLines += $line
            }
        }
        if (-not $found) {
            $newLines = @("attention: $attentionStr") + $newLines
        }

        $newContent = "---`n$($newLines -join "`n")`n---`n$body"
    } else {
        # No frontmatter — prepend one
        $newContent = "---`nattention: $attentionStr`n---`n$content"
    }

    Set-Content -LiteralPath $Path -Value $newContent -Encoding UTF8 -NoNewline -ErrorAction Stop
}

function script:Unquote-SummaryScalar {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function script:Extract-Brief {
    <#
    .SYNOPSIS
        Extracts the first paragraph of a summary body as the brief.
    .DESCRIPTION
        The brief is everything up to the first blank line (double newline).
        Returns $null if the body is empty.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    # Split on the first blank line (whitespace-only lines count as blank)
    $parts = $Body -split '\r?\n[ \t]*\r?\n', 2
    $first = $parts[0].Trim()
    if ($first.Length -eq 0) { return $null }
    return $first
}
