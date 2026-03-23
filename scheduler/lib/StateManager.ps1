Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        schemaVersion   = 1
        schedulerPaused = $false
        agents          = @{}
    }
}

function Initialize-StateFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-Path $Path)) {
        $default = Get-DefaultState
        $json = $default | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    }
}

function Read-StateFromStream {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.IO.FileStream]$Stream
    )

    $Stream.Position = 0
    $reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
    try {
        $content = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    $obj = $content | ConvertFrom-Json
    $state = @{
        schemaVersion   = if ($null -ne $obj.schemaVersion) { [int]$obj.schemaVersion } else { 1 }
        schedulerPaused = if ($null -ne $obj.schedulerPaused) { [bool]$obj.schedulerPaused } else { $false }
        agents          = @{}
    }

    if ($obj.agents -and $obj.agents.PSObject.Properties) {
        foreach ($prop in $obj.agents.PSObject.Properties) {
            $state.agents[$prop.Name] = @{
                lastRun = if ($prop.Value.lastRun) { $prop.Value.lastRun } else { $null }
                enabled = if ($null -ne $prop.Value.enabled) { [bool]$prop.Value.enabled } else { $true }
            }
        }
    }

    return $state
}

function Write-StateAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][hashtable]$State
    )

    $ordered = [ordered]@{
        schemaVersion   = $State.schemaVersion
        schedulerPaused = $State.schedulerPaused
        agents          = [ordered]@{}
    }
    foreach ($key in ($State.agents.Keys | Sort-Object)) {
        $agent = $State.agents[$key]
        $ordered.agents[$key] = [ordered]@{
            lastRun = $agent.lastRun
            enabled = $agent.enabled
        }
    }

    $json = $ordered | ConvertTo-Json -Depth 10
    $tmpPath = "$StateFile.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpPath -Destination $StateFile -Force
}

function Get-AgentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter()][string]$AgentId
    )

    try {
        Initialize-StateFile -Path $StateFile

        $stream = [System.IO.FileStream]::new(
            $StateFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $state = Read-StateFromStream -Stream $stream
        }
        finally {
            $stream.Dispose()
        }

        if ($AgentId) {
            if ($state.agents.ContainsKey($AgentId)) {
                return $state.agents[$AgentId]
            }
            return $null
        }
        return $state
    }
    catch {
        Write-CronAgentsLog -Level 'WARN' -Message "State file '$StateFile' is corrupted or unreadable: $_. Resetting to defaults."
        Reset-AgentState -StateFile $StateFile

        if ($AgentId) {
            return $null
        }
        return Get-DefaultState
    }
}

function Set-AgentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter()][string]$AgentId,
        [Parameter()][datetime]$LastRun,
        [Parameter()][bool]$Enabled,
        [Parameter()][bool]$SchedulerPaused
    )

    $hasLastRun = $PSBoundParameters.ContainsKey('LastRun')
    $hasEnabled = $PSBoundParameters.ContainsKey('Enabled')
    $hasPaused  = $PSBoundParameters.ContainsKey('SchedulerPaused')

    try {
        Initialize-StateFile -Path $StateFile

        $stream = [System.IO.FileStream]::new(
            $StateFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $state = Read-StateFromStream -Stream $stream

            if ($hasPaused) {
                $state.schedulerPaused = $SchedulerPaused
            }

            if ($AgentId) {
                if (-not $state.agents.ContainsKey($AgentId)) {
                    $state.agents[$AgentId] = @{
                        lastRun = $null
                        enabled = $true
                    }
                }

                if ($hasLastRun) {
                    $state.agents[$AgentId].lastRun = $LastRun.ToString('o')
                }

                if ($hasEnabled) {
                    $state.agents[$AgentId].enabled = $Enabled
                }
            }
        }
        finally {
            $stream.Dispose()
        }

        Write-StateAtomically -StateFile $StateFile -State $state
    }
    catch {
        Write-CronAgentsLog -Level 'ERROR' -Message "Failed to update state file '$StateFile': $_"
        throw
    }
}

function Reset-AgentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateFile
    )

    $dir = Split-Path -Path $StateFile -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $state = Get-DefaultState
    Write-StateAtomically -StateFile $StateFile -State $state
    Write-CronAgentsLog -Level 'WARN' -Message "State file '$StateFile' has been reset to defaults."
}
