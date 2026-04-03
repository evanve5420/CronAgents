<#
.SYNOPSIS
    Manages an isolated Copilot CLI home directory for scheduled agent runs.

.DESCRIPTION
    When the Copilot CLI shares COPILOT_HOME with an active VS Code session,
    it auto-connects to the IDE's MCP server and may hang indefinitely during
    initialization (the daemon is shared and can deadlock under contention).

    This module creates a separate COPILOT_HOME for scheduled runs with
    ide.auto_connect disabled, giving each scheduled agent process its own
    daemon and eliminating contention with interactive sessions.
#>

function Initialize-SchedulerCopilotHome {
    <#
    .SYNOPSIS
        Ensures the scheduler's isolated Copilot CLI home directory exists
        with the necessary configuration and credentials.
    .PARAMETER StateRoot
        The scheduler state root directory (e.g., ~/.cronagents/.cronstate).
    .OUTPUTS
        The full path to the scheduler's copilot home directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$StateRoot
    )

    $copilotHome = Join-Path $StateRoot 'copilot-home'

    if (-not (Test-Path $copilotHome)) {
        New-Item -Path $copilotHome -ItemType Directory -Force | Out-Null
        Write-CronAgentsLog -Level 'info' -Message "Created scheduler copilot home: $copilotHome"
    }

    # Write config.json with IDE auto-connect disabled
    $configFile = Join-Path $copilotHome 'config.json'
    $needsWrite = $true

    if (Test-Path $configFile) {
        try {
            $existing = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($existing.'ide.auto_connect' -eq $false -and
                $existing.'banner' -eq 'never' -and
                $existing.'autoUpdate' -eq $false) {
                $needsWrite = $false
            }
        }
        catch { <# corrupt file — rewrite #> }
    }

    if ($needsWrite) {
        $config = @{
            'ide.auto_connect' = $false
            'banner'           = 'never'
            'autoUpdate'       = $false
        }
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
        Write-CronAgentsLog -Level 'debug' -Message "Wrote scheduler copilot config: $configFile"
    }

    # Sync MCP server config from the default copilot home
    Sync-McpConfig -SchedulerCopilotHome $copilotHome

    return $copilotHome
}

function Sync-McpConfig {
    <#
    .SYNOPSIS
        Copies the MCP server configuration from the default ~/.copilot
        directory to the scheduler's copilot home, if it exists and is newer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchedulerCopilotHome
    )

    $defaultHome = if ($env:COPILOT_HOME) {
        $env:COPILOT_HOME
    }
    else {
        Join-Path $HOME '.copilot'
    }

    $sourceMcp = Join-Path $defaultHome 'mcp-config.json'
    $destMcp   = Join-Path $SchedulerCopilotHome 'mcp-config.json'

    if (-not (Test-Path $sourceMcp)) { return }

    $needsCopy = $true
    if (Test-Path $destMcp) {
        $srcTime  = (Get-Item $sourceMcp).LastWriteTimeUtc
        $destTime = (Get-Item $destMcp).LastWriteTimeUtc
        if ($destTime -ge $srcTime) { $needsCopy = $false }
    }

    if ($needsCopy) {
        Copy-Item -Path $sourceMcp -Destination $destMcp -Force
        Write-CronAgentsLog -Level 'debug' -Message "Synced MCP config to scheduler copilot home."
    }
}

function Get-CopilotAuthToken {
    <#
    .SYNOPSIS
        Retrieves a GitHub token for Copilot CLI authentication.
        Falls back through COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN,
        and finally `gh auth token`.
    .OUTPUTS
        The token string, or $null if unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Check environment variables in precedence order
    foreach ($var in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        $val = [System.Environment]::GetEnvironmentVariable($var)
        if ($val) { return $val }
    }

    # Try gh CLI
    try {
        $token = & gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $token) {
            return $token.Trim()
        }
    }
    catch { <# gh not available #> }

    return $null
}
