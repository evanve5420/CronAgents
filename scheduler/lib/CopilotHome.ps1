<#
.SYNOPSIS
    Manages isolated Copilot CLI home directories for scheduled agent runs.

.DESCRIPTION
    The Copilot CLI uses a long-lived daemon process keyed by COPILOT_HOME.
    When the scheduler shares COPILOT_HOME with an active VS Code session (or
    a previous timed-out run), the new process connects to the stale/busy
    daemon and hangs indefinitely.

    This module creates a **unique COPILOT_HOME per run** inside the run
    directory, guaranteeing a fresh daemon every time with zero contention.
    It also writes an empty MCP server config so unattended runs don't
    spawn heavyweight MCP server processes.
#>

function Initialize-RunCopilotHome {
    <#
    .SYNOPSIS
        Creates a fresh, isolated COPILOT_HOME directory for a single agent
        run so it gets its own daemon with no stale-process contention.
    .PARAMETER RunDirectory
        The run-specific directory (e.g., ~/.cronagents/.cronstate/runs/<runId>).
    .OUTPUTS
        The full path to the per-run copilot home directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory
    )

    $copilotHome = Join-Path $RunDirectory 'copilot-home'
    New-Item -Path $copilotHome -ItemType Directory -Force | Out-Null

    # config.json — disable IDE auto-connect, banners, and auto-update
    $config = @{
        'ide.auto_connect' = $false
        'banner'           = 'never'
        'autoUpdate'       = $false
    }
    $configJson = $config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText(
        (Join-Path $copilotHome 'config.json'),
        $configJson,
        [System.Text.Encoding]::UTF8
    )

    # mcp-config.json — empty; agents use built-in tools only.
    # Agents needing specific MCP servers can opt in via extraCliFlags.
    [System.IO.File]::WriteAllText(
        (Join-Path $copilotHome 'mcp-config.json'),
        '{"mcpServers": {}}',
        [System.Text.Encoding]::UTF8
    )

    Write-CronAgentsLog -Level 'debug' -Message "Created per-run copilot home: $copilotHome"
    return $copilotHome
}

# Keep the old name as a wrapper so existing callers don't break during
# the transition.  The shared copilot-home approach is deprecated.
function Initialize-SchedulerCopilotHome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$StateRoot
    )

    # Create the legacy shared directory for backward compat only.
    $copilotHome = Join-Path $StateRoot 'copilot-home'
    if (-not (Test-Path $copilotHome)) {
        New-Item -Path $copilotHome -ItemType Directory -Force | Out-Null
    }

    # Write or repair config.json — always validate the expected values so
    # stale or corrupt files are corrected automatically.
    $expectedConfig = @{
        'ide.auto_connect' = $false
        'banner'           = 'never'
        'autoUpdate'       = $false
    }
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
        catch { <# corrupt JSON — overwrite #> }
    }
    if ($needsWrite) {
        $expectedConfig | ConvertTo-Json -Depth 5 |
            Set-Content -Path $configFile -Encoding UTF8
    }

    # Always write empty MCP config — unattended runs use built-in tools only.
    Sync-McpConfig -SchedulerCopilotHome $copilotHome

    return $copilotHome
}

function Sync-McpConfig {
    <#
    .SYNOPSIS
        Writes an empty MCP server configuration to the scheduler copilot home.
        Previously this synced the interactive session's MCP config, but
        unattended runs now use built-in tools only to avoid spawning
        heavyweight MCP server processes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchedulerCopilotHome
    )

    [System.IO.File]::WriteAllText(
        (Join-Path $SchedulerCopilotHome 'mcp-config.json'),
        '{"mcpServers": {}}',
        [System.Text.Encoding]::UTF8
    )
}

function Clear-CopilotDaemonState {
    <#
    .SYNOPSIS
        Removes stale session-state and log directories from a copilot home
        directory so the next run starts a fresh daemon.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchedulerCopilotHome
    )

    foreach ($subdir in @('session-state', 'logs')) {
        $path = Join-Path $SchedulerCopilotHome $subdir
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-CronAgentsLog -Level 'debug' -Message "Cleared stale daemon state: $subdir"
        }
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
