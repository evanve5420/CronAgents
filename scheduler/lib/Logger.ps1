# -----------------------------------------------------------------------
# Logger.ps1 — Structured logging for CronAgents
#
# Provides Write-CronAgentsLog (level-gated structured logging) and
# Initialize-RunLog (per-run log file setup). Designed to be dot-sourced
# as a nested module via CronAgents.psd1.
#
# Log format:  [ISO-8601-timestamp] [LEVEL] Message
# Level order: debug < info < warn < error
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script-scoped state — set once at startup via the helper functions below.
$script:LogLevel      = 'info'
$script:GlobalLogFile = $null
$script:RunLogFile    = $null

# Numeric severity used for level comparisons.
$script:LevelMap = @{
    'debug' = 0
    'info'  = 1
    'warn'  = 2
    'error' = 3
}

# -------------------------------------------------------------------
# Helper: Set-CronAgentsLogLevel
# -------------------------------------------------------------------
function Set-CronAgentsLogLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('debug', 'info', 'warn', 'error')]
        [string]$Level
    )
    $script:LogLevel = $Level
}

# -------------------------------------------------------------------
# Helper: Get-CronAgentsLogLevel
# -------------------------------------------------------------------
function Get-CronAgentsLogLevel {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:LogLevel
}

# -------------------------------------------------------------------
# Helper: Set-CronAgentsLogFile
# -------------------------------------------------------------------
function Set-CronAgentsLogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $script:GlobalLogFile = $Path
}

# -------------------------------------------------------------------
# Initialize-RunLog
# -------------------------------------------------------------------
function Initialize-RunLog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory
    )

    $script:RunLogFile = Join-Path $RunDirectory 'scheduler.log'

    $parentDir = Split-Path -Path $script:RunLogFile -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $script:RunLogFile)) {
        New-Item -Path $script:RunLogFile -ItemType File -Force | Out-Null
    }

    return $script:RunLogFile
}

# -------------------------------------------------------------------
# Write-CronAgentsLog
# -------------------------------------------------------------------
function Write-CronAgentsLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('debug', 'info', 'warn', 'error')]
        [string]$Level = 'info',

        [string]$LogFile,

        [switch]$ConsoleOutput
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $tag       = $Level.ToUpper()
    $line      = "[$timestamp] [$tag] $Message"

    # --- Global scheduler log (level-gated) ---
    $msgSeverity       = $script:LevelMap[$Level]
    $configuredSeverity = $script:LevelMap[$script:LogLevel]

    if ($msgSeverity -ge $configuredSeverity -and $script:GlobalLogFile) {
        try {
            $dir = Split-Path -Path $script:GlobalLogFile -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Add-Content -LiteralPath $script:GlobalLogFile -Value $line -ErrorAction Stop
        }
        catch {
            # Best-effort — swallow write failures
        }
    }

    # --- Per-run log (always written, regardless of level) ---
    if ($script:RunLogFile) {
        try {
            Add-Content -LiteralPath $script:RunLogFile -Value $line -ErrorAction Stop
        }
        catch {
            # Best-effort
        }
    }

    # --- Explicit LogFile override ---
    if ($LogFile) {
        try {
            $dir = Split-Path -Path $LogFile -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop
        }
        catch {
            # Best-effort
        }
    }

    # --- Console output ---
    if ($ConsoleOutput) {
        switch ($Level) {
            'error' { Write-Warning $line }
            'warn'  { Write-Warning $line }
            default { Write-Host $line }
        }
    }
}
