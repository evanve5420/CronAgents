# ---------------------------------------------------------------------------
# SummaryParser.ps1 — Parse structured frontmatter from summary.md files
# ---------------------------------------------------------------------------
# Summary files may contain optional YAML frontmatter with metadata:
#
#   ---
#   attention: true
#   headline: "Short one-line description"
#   ---
#   Full summary body text here...
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
        Body      = ''
        Raw       = ''
        ReadError = $null
    }

    # Read content — when MetadataOnly, read just the first 20 lines (enough for frontmatter + first body line)
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

        return [PSCustomObject]@{
            Attention = $attention
            Headline  = $headline
            Body      = $body.TrimStart("`r", "`n").TrimEnd()
            Raw       = $Content
            ReadError = $null
        }
    }

    # No frontmatter — entire content is the body
    $defaults.Body = $Content.TrimEnd()
    return $defaults
}
