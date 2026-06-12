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
    It also writes the per-run MCP server config, selected from the user's
    ~/.copilot/mcp-config.json according to the agent's `mcpServers`
    registration field (all servers, a named subset, or none).
#>

function Initialize-RunCopilotHome {
    <#
    .SYNOPSIS
        Creates a fresh, isolated COPILOT_HOME directory for a single agent
        run so it gets its own daemon with no stale-process contention.
    .PARAMETER RunDirectory
        The run-specific directory (e.g., ~/.cronagents/.cronstate/runs/<runId>).
    .PARAMETER McpServers
        Which MCP servers the run should have, from the agent's registration:
          * $null  => copy ALL servers from the source MCP config.
          * @()    => no servers (built-in tools only).
          * names  => only the named servers found in the source config.
        Defaults to @() (no servers) when omitted, so a caller that forgets the
        parameter gets the safe, built-in-tools-only behavior.
    .PARAMETER McpConfigPath
        Path to the source MCP config to select servers from. Defaults to the
        user's ~/.copilot/mcp-config.json.
    .OUTPUTS
        The full path to the per-run copilot home directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$McpServers = @(),

        [string]$McpConfigPath
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

    # mcp-config.json — selected per the agent's `mcpServers` field. When no
    # source path is given, fall back to the user's ~/.copilot/mcp-config.json.
    if (-not $McpConfigPath) {
        $McpConfigPath = Join-Path (Join-Path $HOME '.copilot') 'mcp-config.json'
    }
    $mcpJson = Resolve-RunMcpConfig -McpServers $McpServers -SourceConfigPath $McpConfigPath
    [System.IO.File]::WriteAllText(
        (Join-Path $copilotHome 'mcp-config.json'),
        $mcpJson,
        [System.Text.Encoding]::UTF8
    )

    Write-CronAgentsLog -Level 'debug' -Message "Created per-run copilot home: $copilotHome"
    return $copilotHome
}

function Resolve-RunMcpConfig {
    <#
    .SYNOPSIS
        Builds the mcp-config.json content for a single agent run.
    .DESCRIPTION
        Resolves which MCP servers a run should have based on the agent's
        `mcpServers` registration field:
          * $null             -> copy ALL servers from the source config (verbatim).
          * empty array (@())  -> no servers ('{"mcpServers": {}}').
          * array of names     -> only the named servers found in the source
                                  config, plus the source's `inputs` (if any).
        A missing source file, invalid JSON, or unknown server names degrade
        gracefully to built-in tools only, logging a warning.
    .PARAMETER McpServers
        Server names to include, $null for all, or @() for none.
    .PARAMETER SourceConfigPath
        Path to the user's mcp-config.json (e.g. ~/.copilot/mcp-config.json).
    .OUTPUTS
        JSON string suitable for writing to a run's mcp-config.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$McpServers,

        [string]$SourceConfigPath
    )

    $emptyConfig = '{"mcpServers": {}}'

    # Explicit empty array => built-in tools only.
    if ($null -ne $McpServers -and $McpServers.Count -eq 0) {
        return $emptyConfig
    }

    if ([string]::IsNullOrWhiteSpace($SourceConfigPath) -or
        -not (Test-Path -LiteralPath $SourceConfigPath)) {
        Write-CronAgentsLog -Level 'warn' -Message "MCP source config not found at '$SourceConfigPath' — run will use built-in tools only."
        return $emptyConfig
    }

    try {
        $raw = Get-Content -LiteralPath $SourceConfigPath -Raw -ErrorAction Stop
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Failed to read MCP source config '$SourceConfigPath': $_ — run will use built-in tools only."
        return $emptyConfig
    }

    # $null => use every server from the source config. Validate the JSON first
    # so a malformed, empty, or whitespace-only source — or one whose shape isn't
    # an object carrying an `mcpServers` map — degrades to built-in tools only
    # (per this function's contract) instead of copying unusable content into the
    # run. The raw text is returned verbatim when valid to preserve its formatting.
    if ($null -eq $McpServers) {
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-CronAgentsLog -Level 'warn' -Message "MCP source config '$SourceConfigPath' is empty — run will use built-in tools only."
            return $emptyConfig
        }
        try {
            $parsedAll = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "MCP source config '$SourceConfigPath' is not valid JSON: $_ — run will use built-in tools only."
            return $emptyConfig
        }
        # A valid-but-unexpected JSON value (e.g. [], a scalar, or an object
        # without mcpServers) is treated as malformed and degrades to built-in
        # tools only rather than writing an unusable config into the run.
        if ($null -eq $parsedAll -or
            -not $parsedAll.PSObject.Properties['mcpServers'] -or
            $null -eq $parsedAll.mcpServers) {
            Write-CronAgentsLog -Level 'warn' -Message "MCP source config '$SourceConfigPath' has no 'mcpServers' object — run will use built-in tools only."
            return $emptyConfig
        }
        return $raw
    }

    # Named subset — select only the requested servers from the source config.
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "MCP source config '$SourceConfigPath' is not valid JSON: $_ — run will use built-in tools only."
        return $emptyConfig
    }

    $available = @{}
    if ($parsed.PSObject.Properties['mcpServers'] -and $null -ne $parsed.mcpServers) {
        foreach ($prop in $parsed.mcpServers.PSObject.Properties) {
            $available[$prop.Name] = $prop.Value
        }
    }

    $selected = [ordered]@{}
    foreach ($name in $McpServers) {
        if ($available.ContainsKey($name)) {
            $selected[$name] = $available[$name]
        }
        else {
            Write-CronAgentsLog -Level 'warn' -Message "Requested MCP server '$name' not found in '$SourceConfigPath' — skipping."
        }
    }

    $result = [ordered]@{ mcpServers = $selected }
    if ($parsed.PSObject.Properties['inputs'] -and $null -ne $parsed.inputs) {
        $result['inputs'] = $parsed.inputs
    }

    return ($result | ConvertTo-Json -Depth 20)
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
