<#
.SYNOPSIS
    Deterministic markdown dashboard generator for CronAgents.
.DESCRIPTION
    Reads run history from .cronstate/runs and produces a markdown dashboard
    with a summary table (one row per agent, most-recent run) and a detailed
    Recent Runs section. No LLM calls — purely deterministic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [string]$RunsRoot,
    [string]$OutputPath,
    [string]$PersonalRepoPath,
    [int]$MaxRunHistory = 50,
    [int]$RetentionDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/CronAgents.psd1') -Force

# ── Defaults ────────────────────────────────────────────────────────
$stateRoot = if ($PersonalRepoPath) { Join-Path $PersonalRepoPath '.cronstate' } else { Join-Path $RepoRoot '.cronstate' }
if (-not $RunsRoot)   { $RunsRoot   = Join-Path $stateRoot 'runs' }
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot 'dashboard.md' }

# ── Helpers ─────────────────────────────────────────────────────────

function Format-RunTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Time)

    $local   = $Time.ToLocalTime()
    $now     = [datetime]::Now
    $timeStr = $local.ToString('h:mm tt')   # e.g. "2:41 PM"
    $dayDiff = ($now.Date - $local.Date).Days

    if ($dayDiff -eq 0)  { return "Today, $timeStr" }
    if ($dayDiff -eq 1)  { return "Yesterday, $timeStr" }
    if ($dayDiff -le 6)  { return "$($local.ToString('ddd')), $timeStr" }
    if ($local.Year -eq $now.Year) { return "$($local.ToString('MMM d')), $timeStr" }
    return "$($local.ToString('MMM d yyyy')), $timeStr"
}

function Get-StatusIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Run)

    $meta = $Run.Meta
    if ($null -eq $meta) { return '❓' }

    if ($null -eq $meta.exitCode) {
        # Check if the run is actually stale
        if ($Run.RunDirectory) {
            $status = Test-RunActive -RunDirectory $Run.RunDirectory
            if ($status.IsStale)      { return '💀' }
            if ($status.IsIncomplete) { return '⚠️' }
        }
        return '🔄'
    }
    if ($meta.timedOut)                  { return '⏱️' }
    if ($meta.retryAttempt -gt 0 -and
        $meta.exitCode -eq 0)           { return '🔄' }

    # Detect skipped-on-battery via exitCode 75 (EX_TEMPFAIL convention)
    if ($meta.exitCode -eq 75)          { return '⏭️' }

    if ($meta.exitCode -eq 0)           { return '✅' }
    return '❌'
}

function Get-StatusLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Run)

    $meta = $Run.Meta
    if ($null -eq $meta) { return 'Unknown' }

    if ($null -eq $meta.exitCode) {
        # Check if the run is actually stale
        if ($Run.RunDirectory) {
            $status = Test-RunActive -RunDirectory $Run.RunDirectory
            if ($status.IsStale)      { return 'Stale' }
            if ($status.IsIncomplete) { return 'Incomplete' }
        }
        return 'Running'
    }
    if ($meta.timedOut)         { return 'Timed Out' }
    if ($meta.exitCode -eq 75) { return 'Skipped' }
    if ($meta.exitCode -eq 0)  { return 'Success' }
    return 'Failed'
}

function Get-DurationString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Run)

    $meta = $Run.Meta
    if ($null -eq $meta -or $null -eq $meta.exitCode) {
        return '—'
    }
    if ($null -eq $meta.startTime -or $null -eq $meta.endTime) {
        return '—'
    }

    try {
        $start = [datetime]::Parse($meta.startTime)
        $end   = [datetime]::Parse($meta.endTime)
        $span  = $end - $start

        $parts = @()
        if ($span.TotalHours -ge 1) {
            $parts += "$([math]::Floor($span.TotalHours))h"
        }
        if ($span.Minutes -gt 0 -or $span.TotalHours -ge 1) {
            $parts += "$($span.Minutes)m"
        }
        $parts += "$($span.Seconds)s"
        return ($parts -join ' ')
    }
    catch {
        return '—'
    }
}

function Get-FeedbackCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Run,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $runDir = $Run.RunDirectory
    $relDir = Get-RelativePath -From $RepoRoot -To $runDir

    if ($Run.FeedbackProcessed) {
        $resultPath = "$relDir/feedback-result.md" -replace '\\', '/'
        return "✅ [Processed]($resultPath)"
    }

    if ($Run.HasFeedback) {
        $fbPath = "$relDir/feedback.md" -replace '\\', '/'
        return "📝 [Pending]($fbPath)"
    }

    return '—'
}

function Get-DetailCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Run,
        [Parameter(Mandatory)][hashtable]$SummaryCache
    )

    if (-not $Run.HasSummary) { return 'summary pending' }

    $cached = $SummaryCache[$Run.RunDirectory]
    if (-not $cached -or $cached.ReadError) { return 'summary pending' }

    $parsed = $cached
    $display = if ($parsed.Headline) { $parsed.Headline } elseif ($parsed.Body) { ($parsed.Body -split '\r?\n', 2)[0].TrimStart('#', ' ') } else { 'summary pending' }
    if ($display.Length -gt 120) {
        $display = $display.Substring(0, 120) + '...'
    }
    # Escape Markdown metacharacters to prevent table/formatting corruption
    $display = ConvertTo-SafeTableCell -Text $display
    return $display
}

function ConvertTo-SafeTableCell {
    <#
    .SYNOPSIS
        Escapes Markdown metacharacters in agent-controlled text for safe
        embedding in Markdown table cells and inline contexts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text = $Text -replace '(\r\n|\n|\r)', ' '
    # Escape pipe (table), brackets (links), backticks, asterisks, underscores
    $Text = $Text -replace '([|`*_\[\]\\])', '\$1'
    return $Text.Trim()
}

function Get-RelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $fromFull = (Resolve-Path -LiteralPath $From -ErrorAction Stop).Path.TrimEnd('\', '/')
    # To might not exist yet; normalise manually
    $toFull   = [System.IO.Path]::GetFullPath($To).TrimEnd('\', '/')

    if ($toFull.StartsWith($fromFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $toFull.Substring($fromFull.Length).TrimStart('\', '/')
        return $rel -replace '\\', '/'
    }
    return $toFull -replace '\\', '/'
}

function Get-TruncatedPrompt {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Run)

    $meta = $Run.Meta
    if ($null -eq $meta -or $null -eq $meta.prompt -or $meta.prompt.Length -eq 0) {
        return '—'
    }

    $prompt = $meta.prompt
    if ($prompt.Length -gt 100) {
        $prompt = $prompt.Substring(0, 100) + '...'
    }
    return $prompt
}

# ── Main ────────────────────────────────────────────────────────────

Write-CronAgentsLog -Level 'info' -Message "Generating dashboard from runs in: $RunsRoot"

$runs = @(Get-RunHistory -RunsRoot $RunsRoot -MaxResults $MaxRunHistory)

# Filter out runs for agents that are no longer registered (issue #90)
$getAgentParams = @{ RepoRoot = $RepoRoot }
if ($PersonalRepoPath) { $getAgentParams['PersonalRepoPath'] = $PersonalRepoPath }
try {
    $registeredIds = @(Get-AgentConfigs @getAgentParams | ForEach-Object { $_.Id })
    $runs = @($runs | Where-Object { $_.AgentId -in $registeredIds })
}
catch {
    Write-CronAgentsLog -Level 'warn' -Message "Dashboard generator: could not filter unregistered agent runs: $_"
}

# ── Summary table (most recent per agent) ───────────────────────────
$agentLatest = [ordered]@{}
foreach ($run in $runs) {
    if (-not $agentLatest.Contains($run.AgentId)) {
        $agentLatest[$run.AgentId] = $run
    }
}

$now = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# CronAgents Dashboard')
[void]$sb.AppendLine()
[void]$sb.AppendLine('> Auto-generated by CronAgents. Do not edit manually.')
[void]$sb.AppendLine("> Last updated: $now")
[void]$sb.AppendLine()

# ── Pre-parse all summaries once ────────────────────────────────────
$summaryCache = @{}
foreach ($run in $runs) {
    if (-not $run.HasSummary) { continue }
    $summaryPath = Join-Path $run.RunDirectory 'summary.md'
    $parsed = Read-SummaryFrontmatter -Path $summaryPath
    if ($parsed.ReadError) {
        Write-CronAgentsLog -Level 'debug' -Message "Failed to parse summary: $summaryPath — $($parsed.ReadError)"
    }
    $summaryCache[$run.RunDirectory] = $parsed
}

# ── Needs Attention section ─────────────────────────────────────────
$attentionRuns = @()
foreach ($run in $runs) {
    if (-not $run.HasSummary) { continue }
    $parsed = $summaryCache[$run.RunDirectory]
    if (-not $parsed -or $parsed.ReadError -or -not $parsed.Attention) { continue }
    $attentionRuns += [PSCustomObject]@{
        Run    = $run
        Parsed = $parsed
    }
}

if ($attentionRuns.Count -gt 0) {
    [void]$sb.AppendLine('## ⚠️ Needs Attention')
    [void]$sb.AppendLine()
    foreach ($item in $attentionRuns) {
        $run    = $item.Run
        $parsed = $item.Parsed
        $name   = if ($run.Meta -and $run.Meta.agentName) { $run.Meta.agentName } else { $run.AgentId }
        $rel    = Format-RunTime -Time $run.Timestamp
        $icon   = Get-StatusIcon -Run $run
        $headline = if ($parsed.Headline) { $parsed.Headline } else { ($parsed.Body -split '\r?\n', 2)[0].TrimStart('#', ' ') }
        $safeName     = ConvertTo-SafeTableCell -Text $name
        $safeHeadline = ConvertTo-SafeTableCell -Text $headline
        [void]$sb.AppendLine("- $icon **$safeName** ($rel) — $safeHeadline")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine()
}

[void]$sb.AppendLine('## Summary')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Agent | Last Run | Status | Questions | Feedback | Detail |')
[void]$sb.AppendLine('|-------|----------|--------|-----------|----------|--------|')

# Collect all pending questions for the questions column
$allPendingQuestions = @()
try {
    $allPendingQuestions = Get-PendingQuestions -StateRoot $stateRoot
}
catch { }

foreach ($agentId in $agentLatest.Keys) {
    $run  = $agentLatest[$agentId]
    $name = if ($run.Meta -and $run.Meta.agentName) { $run.Meta.agentName } else { $agentId }
    $safeName = ConvertTo-SafeTableCell -Text $name
    $rel  = Format-RunTime   -Time $run.Timestamp
    $icon = Get-StatusIcon   -Run  $run
    $fb   = Get-FeedbackCell -Run  $run -RepoRoot $RepoRoot
    $det  = Get-DetailCell   -Run  $run -SummaryCache $summaryCache

    # Questions count
    $agentQuestionCount = @($allPendingQuestions | Where-Object { $_.agentId -eq $agentId }).Count
    $qCell = if ($agentQuestionCount -gt 0) {
        "❓ [$agentQuestionCount pending](questions.md)"
    } else { '—' }

    [void]$sb.AppendLine("| $safeName | $rel | $icon | $qCell | $fb | $det |")
}

if ($agentLatest.Count -eq 0) {
    [void]$sb.AppendLine('| — | — | — | — | — | No runs recorded |')
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('---')
[void]$sb.AppendLine()

# ── Recent Runs detail ──────────────────────────────────────────────
[void]$sb.AppendLine('## Recent Runs')
[void]$sb.AppendLine()

if ($runs.Count -eq 0) {
    [void]$sb.AppendLine('No runs recorded yet.')
    [void]$sb.AppendLine()
}

foreach ($run in $runs) {
    $name      = if ($run.Meta -and $run.Meta.agentName) { $run.Meta.agentName } else { $run.AgentId }
    $localTs   = $run.Timestamp.ToLocalTime()
    $ts        = $localTs.ToString('MMM d, h:mm tt')
    $status    = Get-StatusLabel     -Run $run
    $duration  = Get-DurationString  -Run $run
    $prompt    = Get-TruncatedPrompt -Run $run
    $relDir    = Get-RelativePath -From $RepoRoot -To $run.RunDirectory

    [void]$sb.AppendLine("### $name — $ts")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Status:** $status")
    [void]$sb.AppendLine("**Duration:** $duration")
    [void]$sb.AppendLine("**Prompt:** $prompt")
    [void]$sb.AppendLine()

    # Summary content
    if ($run.HasSummary) {
        $parsed = $summaryCache[$run.RunDirectory]
        if ($parsed -and -not $parsed.ReadError) {
            if ($parsed.Attention) {
                [void]$sb.AppendLine('> ⚠️ **This run needs your attention.**')
                [void]$sb.AppendLine()
            }
            [void]$sb.AppendLine($parsed.Body.TrimEnd())
        }
        else {
            [void]$sb.AppendLine('*Summary could not be read.*')
        }
    }
    else {
        [void]$sb.AppendLine('*No summary available.*')
    }

    [void]$sb.AppendLine()

    # Footer links
    $feedbackLink = "$relDir/feedback.md" -replace '\\', '/'
    $sessionLink  = "$relDir/session.md"  -replace '\\', '/'
    [void]$sb.AppendLine("[Feedback]($feedbackLink) | [Session]($sessionLink)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine()
}

# ── Write output ────────────────────────────────────────────────────
$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $sb.ToString().TrimEnd() -Encoding UTF8 -NoNewline

Write-CronAgentsLog -Level 'info' -Message "Dashboard written to: $OutputPath"

# ── Generate questions.md if there are pending questions ────────────
if ($allPendingQuestions.Count -gt 0) {
    $questionsPath = Join-Path $outDir 'questions.md'
    $qb = [System.Text.StringBuilder]::new()
    [void]$qb.AppendLine('# Pending Questions')
    [void]$qb.AppendLine()
    [void]$qb.AppendLine('> Auto-generated by CronAgents. Answer via `cronagents.ps1 questions`.')
    [void]$qb.AppendLine("> Last updated: $now")
    [void]$qb.AppendLine()

    # Sanitize agent-controlled strings for safe Markdown embedding
    function script:ConvertTo-SafeMarkdown {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        # Normalize newlines to spaces and escape leading # that could create headings
        $Text = $Text -replace '(\r\n|\n|\r)', ' '
        $Text = $Text -replace '^\s*#+', ''
        return $Text.Trim()
    }

    # Group by agent
    $qByAgent = @{}
    foreach ($q in $allPendingQuestions) {
        $aid = if ([string]::IsNullOrWhiteSpace($q.agentId)) { 'unknown' } else { $q.agentId }
        if (-not $qByAgent.ContainsKey($aid)) { $qByAgent[$aid] = @() }
        $qByAgent[$aid] += $q
    }

    foreach ($aid in ($qByAgent.Keys | Sort-Object)) {
        [void]$qb.AppendLine("## $(script:ConvertTo-SafeMarkdown $aid)")
        [void]$qb.AppendLine()
        foreach ($q in $qByAgent[$aid]) {
            [void]$qb.AppendLine("### $(script:ConvertTo-SafeMarkdown $q.question)")
            [void]$qb.AppendLine()
            if ($q.context) {
                [void]$qb.AppendLine("**Context:** $(script:ConvertTo-SafeMarkdown $q.context)")
                [void]$qb.AppendLine()
            }
            if ($q.choices -and $q.choices.Count -gt 0) {
                [void]$qb.AppendLine('**Choices:**')
                foreach ($c in $q.choices) {
                    $rec = if ($q.recommended -and $c -eq $q.recommended) { ' *(Recommended)*' } else { '' }
                    [void]$qb.AppendLine("- $(script:ConvertTo-SafeMarkdown $c)$rec")
                }
                [void]$qb.AppendLine('- *(or provide a custom response)*')
                [void]$qb.AppendLine()
            }
            if ($q.expiresAt) {
                try {
                    $exp = [datetime]::Parse($q.expiresAt)
                    $daysLeft = [math]::Ceiling(($exp - [datetime]::UtcNow).TotalDays)
                    if ($daysLeft -gt 0) {
                        [void]$qb.AppendLine("*Expires in $daysLeft day(s)*")
                    } else {
                        [void]$qb.AppendLine('*Expiring soon*')
                    }
                }
                catch { }
            }
            [void]$qb.AppendLine()
            [void]$qb.AppendLine('---')
            [void]$qb.AppendLine()
        }
    }

    Set-Content -LiteralPath $questionsPath -Value $qb.ToString().TrimEnd() -Encoding UTF8 -NoNewline
    Write-CronAgentsLog -Level 'info' -Message "Questions page written to: $questionsPath"
}
else {
    # Clean up questions.md if no pending questions
    $questionsPath = Join-Path $outDir 'questions.md'
    if (Test-Path -LiteralPath $questionsPath) {
        Remove-Item -LiteralPath $questionsPath -Force
    }
}
