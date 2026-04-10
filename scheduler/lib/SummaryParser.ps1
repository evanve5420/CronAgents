# ---------------------------------------------------------------------------
# SummaryParser.ps1 — Parse structured frontmatter from summary.md files
# ---------------------------------------------------------------------------
# Summary files may contain optional YAML frontmatter with metadata:
#
#   ---
#   attention: true
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
        - Headline   [string] — short one-liner for table display (or $null)
        - Brief      [string] — concise 1-5 sentence summary (first paragraph of body)
        - Body       [string] — the full summary text after the frontmatter
        - Raw        [string] — the original file content
        - ReadError  [string] — error message if file could not be read (or $null)
        Gracefully handles files without frontmatter (returns defaults).
        NOTE: Purpose-built parser for CronAgents summary frontmatter only.
        Supports scalar values for: attention, headline.
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
        $headline  = $null

        foreach ($line in ($fmBlock -split '\r?\n')) {
            $line = $line.Trim()
            if ($line -match '^attention\s*:\s*(.+)$') {
                $val = $Matches[1].Trim().ToLower()
                $attention = $val -eq 'true' -or $val -eq 'yes' -or $val -eq '1'
            }
            elseif ($line -match '^headline\s*:\s*(.+)$') {
                $val = $Matches[1].Trim()
                # Strip surrounding quotes if present
                if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                    ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                    $val = $val.Substring(1, $val.Length - 2)
                }
                if ($val.Length -gt 0) { $headline = $val }
            }
        }

        $trimmedBody = $body.TrimStart("`r", "`n").TrimEnd()
        return [PSCustomObject]@{
            Attention = $attention
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

    # Split on the first blank line (two consecutive newlines with optional \r)
    $parts = $Body -split '(?:\r?\n){2,}', 2
    $first = $parts[0].Trim()
    if ($first.Length -eq 0) { return $null }
    return $first
}
