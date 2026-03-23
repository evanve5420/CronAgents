Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Get-RunDirectoryAge
# -------------------------------------------------------------------
function Get-RunDirectoryAge {
    [CmdletBinding()]
    [OutputType([System.Nullable[timespan]])]
    param(
        [Parameter(Mandatory)][string]$DirectoryName,
        [Parameter(Mandatory)][datetime]$Now
    )

    # Expected format: yyyyMMddTHHmmss_agentid_nonce
    if ($DirectoryName -notmatch '^(\d{8}T\d{6})_') {
        return $null
    }

    $timestampStr = $Matches[1]
    try {
        $parsed = [datetime]::ParseExact(
            $timestampStr,
            'yyyyMMddTHHmmss',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        return $Now - $parsed
    }
    catch {
        return $null
    }
}

# -------------------------------------------------------------------
# Invoke-RetentionCleanup
# -------------------------------------------------------------------
function Invoke-RetentionCleanup {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RunsRoot,
        [Parameter()][int]$RetentionDays = 14,
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string[]]$DiscoveredAgentIds
    )

    $deleted   = 0
    $preserved = 0
    $staleRemoved = [System.Collections.Generic.List[string]]::new()
    $now = (Get-Date).ToUniversalTime()

    # ---------------------------------------------------------------
    # Phase 1 — Run directory cleanup
    # ---------------------------------------------------------------
    if ($RetentionDays -eq 0) {
        Write-CronAgentsLog -Level 'debug' -Message 'RetentionDays is 0 — skipping run directory cleanup.'
    }
    elseif (Test-Path $RunsRoot) {
        $dirs = Get-ChildItem -LiteralPath $RunsRoot -Directory -ErrorAction SilentlyContinue

        foreach ($dir in $dirs) {
            try {
                $age = Get-RunDirectoryAge -DirectoryName $dir.Name -Now $now
                if ($null -eq $age) {
                    Write-CronAgentsLog -Level 'debug' -Message "Skipping directory with unparseable name: $($dir.Name)"
                    $preserved++
                    continue
                }

                if ($age.TotalDays -gt $RetentionDays) {
                    # Check for unprocessed feedback before deleting
                    $hasFeedback = $false
                    try {
                        $feedbackFile = Join-Path $dir.FullName 'feedback.md'
                        $hasFeedback = Test-FeedbackPresent -FeedbackPath $feedbackFile
                    }
                    catch {
                        Write-CronAgentsLog -Level 'warn' -Message "Failed to check feedback for '$($dir.Name)': $_"
                    }

                    if ($hasFeedback) {
                        Write-CronAgentsLog -Level 'info' -Message "Preserving '$($dir.Name)' — has unprocessed feedback."
                        $preserved++
                    }
                    else {
                        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                        Write-CronAgentsLog -Level 'debug' -Message "Deleted expired run directory: $($dir.Name)"
                        $deleted++
                    }
                }
                else {
                    $preserved++
                }
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Error processing run directory '$($dir.Name)': $_"
                $preserved++
            }
        }
    }

    # ---------------------------------------------------------------
    # Phase 2 — Stale state.json entries
    # ---------------------------------------------------------------
    if (Test-Path $StateFile) {
        try {
            $state = Get-AgentState -StateFile $StateFile
            $agentKeys = @($state.agents.Keys)

            foreach ($agentId in $agentKeys) {
                if ($agentId -in $DiscoveredAgentIds) {
                    continue
                }

                # Only remove if no run directories exist for this agent
                $hasRuns = $false
                if (Test-Path $RunsRoot) {
                    $agentDirs = Get-ChildItem -LiteralPath $RunsRoot -Directory -Filter "*_${agentId}_*" -ErrorAction SilentlyContinue
                    if ($agentDirs -and @($agentDirs).Count -gt 0) {
                        $hasRuns = $true
                    }
                }

                if (-not $hasRuns) {
                    $state.agents.Remove($agentId)
                    $staleRemoved.Add($agentId)
                    Write-CronAgentsLog -Level 'info' -Message "Removed stale agent entry from state: $agentId"
                }
            }

            if ($staleRemoved.Count -gt 0) {
                Write-StateAtomically -StateFile $StateFile -State $state
            }
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Failed to clean stale state entries: $_"
        }
    }

    # ---------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------
    Write-CronAgentsLog -Level 'info' -Message "Retention cleanup complete: $deleted deleted, $preserved preserved, $($staleRemoved.Count) stale agent(s) removed."

    return [PSCustomObject]@{
        DeletedCount      = $deleted
        PreservedCount    = $preserved
        StaleAgentsRemoved = [string[]]$staleRemoved.ToArray()
    }
}
