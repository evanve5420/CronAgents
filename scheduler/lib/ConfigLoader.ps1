# -----------------------------------------------------------------------
# ConfigLoader.ps1 — Config loading, validation, and agent discovery
#
# Provides Import-CronAgentsConfig (global config), Test-CronAgentsConfig
# (validation), and Get-AgentConfigs (per-agent discovery). Designed to be
# dot-sourced as a nested module via CronAgents.psd1.
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AgentRegistrationSuffix = '.agent-registration.json'

# Valid enum values
$script:ValidLogLevels   = @('debug', 'info', 'warn', 'error')
$script:ValidScheduleTypes = @('interval', 'daily', 'weekly')
$script:DurationPattern  = '^[0-9]+(m|h|s)?$|^0$'
$script:TimePattern      = '^([01]\d|2[0-3]):[0-5]\d$'
$script:SafeIdentifierPattern = '^[A-Za-z0-9._-]+$'

# -------------------------------------------------------------------
# Helper: Find-RepoRoot — walk up from the current directory to find
# the repo root (contains cronagents.json or .git/).
# -------------------------------------------------------------------
function Find-RepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $dir = Get-Location
    while ($dir) {
        if ((Test-Path (Join-Path $dir 'cronagents.json')) -or
            (Test-Path (Join-Path $dir '.git'))) {
            return $dir.ToString()
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    throw 'Cannot locate repo root (no cronagents.json or .git found in parent directories).'
}

# -------------------------------------------------------------------
# Helper: ConvertTo-OrderedPSObject — ensure a value is a PSCustomObject.
# -------------------------------------------------------------------
function ConvertTo-OrderedPSObject {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return [PSCustomObject]@{}
    }
    if ($InputObject -is [PSCustomObject]) {
        return $InputObject
    }
    if ($InputObject -is [hashtable]) {
        return [PSCustomObject]$InputObject
    }
    return [PSCustomObject]@{}
}

# -------------------------------------------------------------------
# Helper: Test-CronAgentsSafeIdentifier — validate filename-safe IDs
# used for agent IDs, question IDs, and run directory segments.
# -------------------------------------------------------------------
function Test-CronAgentsSafeIdentifier {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value -match $script:SafeIdentifierPattern -and
        $Value -eq [System.IO.Path]::GetFileName($Value))
}

# -------------------------------------------------------------------
# Import-CronAgentsConfig
# -------------------------------------------------------------------
function Import-CronAgentsConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ConfigPath
    )

    # Resolve config path
    if (-not $ConfigPath) {
        $root = Find-RepoRoot
        $ConfigPath = Join-Path $root 'cronagents.json'
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "CronAgents config file not found: $ConfigPath"
    }

    # Parse JSON
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse CronAgents config '$ConfigPath': $_"
    }

    # Build personalRepo sub-object with defaults
    $personalRepoRaw = if ($parsed.PSObject.Properties['personalRepo']) { $parsed.personalRepo } else { $null }
    $personalRepoRaw = ConvertTo-OrderedPSObject -InputObject $personalRepoRaw

    $personalRepo = [PSCustomObject]@{
        path                   = if ($null -ne $personalRepoRaw -and
                                     $null -ne $personalRepoRaw.PSObject.Properties['path'] -and
                                     $null -ne $personalRepoRaw.path)
                                 { $personalRepoRaw.path } else { '~/.cronagents' }
        userName               = if ($null -ne $personalRepoRaw -and
                                     $null -ne $personalRepoRaw.PSObject.Properties['userName'])
                                 { $personalRepoRaw.userName } else { $null }
        autoCommitFeedback     = if ($null -ne $personalRepoRaw -and
                                     $null -ne $personalRepoRaw.PSObject.Properties['autoCommitFeedback'] -and
                                     $null -ne $personalRepoRaw.autoCommitFeedback)
                                 { [bool]$personalRepoRaw.autoCommitFeedback } else { $true }
        defaultWorkingDirectory = if ($null -ne $personalRepoRaw -and
                                      $null -ne $personalRepoRaw.PSObject.Properties['defaultWorkingDirectory'])
                                  { $personalRepoRaw.defaultWorkingDirectory } else { $null }
    }

    # Build top-level config with defaults
    $config = [PSCustomObject]@{
        autoFeedback  = if ($null -ne $parsed.PSObject.Properties['autoFeedback'] -and
                            $null -ne $parsed.autoFeedback)
                        { [bool]$parsed.autoFeedback } else { $false }
        maxRunHistory = if ($null -ne $parsed.PSObject.Properties['maxRunHistory'] -and
                            $null -ne $parsed.maxRunHistory)
                        { [int]$parsed.maxRunHistory } else { 50 }
        copilotPath   = if ($null -ne $parsed.PSObject.Properties['copilotPath'] -and
                            $null -ne $parsed.copilotPath)
                        { $parsed.copilotPath } else { 'copilot' }
        retentionDays = if ($null -ne $parsed.PSObject.Properties['retentionDays'] -and
                            $null -ne $parsed.retentionDays)
                        { [int]$parsed.retentionDays } else { 14 }
        startupDelay  = if ($null -ne $parsed.PSObject.Properties['startupDelay'] -and
                            $null -ne $parsed.startupDelay)
                        { $parsed.startupDelay } else { '5m' }
        logLevel      = if ($null -ne $parsed.PSObject.Properties['logLevel'] -and
                            $null -ne $parsed.logLevel)
                        { $parsed.logLevel } else { 'info' }
        quietHours    = if ($null -ne $parsed.PSObject.Properties['quietHours'] -and
                            $null -ne $parsed.quietHours)
                        { $parsed.quietHours } else { $null }
        notifications = if ($null -ne $parsed.PSObject.Properties['notifications'] -and
                            $null -ne $parsed.notifications)
                        { [bool]$parsed.notifications } else { $true }
        questionExpirationDays = if ($null -ne $parsed.PSObject.Properties['questionExpirationDays'] -and
                            $null -ne $parsed.questionExpirationDays)
                        { [int]$parsed.questionExpirationDays } else { 7 }
        personalRepo  = $personalRepo
    }

    # Validate
    $errors = Test-CronAgentsConfig -Config $config
    if ($errors.Count -gt 0) {
        $detail = $errors -join '; '
        throw "CronAgents config validation failed: $detail"
    }

    return $config
}

# -------------------------------------------------------------------
# Test-CronAgentsConfig
# -------------------------------------------------------------------
function Test-CronAgentsConfig {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    [System.Collections.Generic.List[string]]$errors = @()

    # logLevel
    if ($Config.logLevel -notin $script:ValidLogLevels) {
        $errors.Add("logLevel must be one of: $($script:ValidLogLevels -join ', '). Got: '$($Config.logLevel)'")
    }

    # personalRepo.path
    if ($Config.PSObject.Properties['personalRepo'] -and $null -ne $Config.personalRepo -and
        $Config.personalRepo.PSObject.Properties['path'] -and
        [string]::IsNullOrWhiteSpace($Config.personalRepo.path)) {
        $errors.Add("personalRepo.path must not be empty when specified.")
    }

    # retentionDays
    if ($Config.retentionDays -isnot [int] -or $Config.retentionDays -lt 0) {
        $errors.Add("retentionDays must be a non-negative integer. Got: '$($Config.retentionDays)'")
    }

    # maxRunHistory
    if ($Config.maxRunHistory -isnot [int] -or $Config.maxRunHistory -lt 0) {
        $errors.Add("maxRunHistory must be a non-negative integer. Got: '$($Config.maxRunHistory)'")
    }

    # startupDelay
    if ($Config.startupDelay -notmatch $script:DurationPattern) {
        $errors.Add("startupDelay must match duration pattern (e.g. '5m', '1h', '30s', '0'). Got: '$($Config.startupDelay)'")
    }

    # quietHours
    if ($null -ne $Config.quietHours) {
        $qh = $Config.quietHours
        $hasStart = $null -ne $qh.PSObject.Properties['start']
        $hasEnd   = $null -ne $qh.PSObject.Properties['end']

        if (-not $hasStart -or -not $hasEnd) {
            $errors.Add('quietHours must have both start and end fields when not null')
        }
        else {
            if ($qh.start -notmatch $script:TimePattern) {
                $errors.Add("quietHours.start must be a valid HH:mm string. Got: '$($qh.start)'")
            }
            if ($qh.end -notmatch $script:TimePattern) {
                $errors.Add("quietHours.end must be a valid HH:mm string. Got: '$($qh.end)'")
            }
        }
    }

    return ,$errors.ToArray()
}

# -------------------------------------------------------------------
# Helper: Resolve-AgentFilePath — locate the .agent.md for a given
# agent reference relative to the config file or standard locations.
# -------------------------------------------------------------------
function Resolve-AgentFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AgentRef,
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    # 1. Sibling file: same directory as the agent .json config
    $sibling = Join-Path $ConfigDir "$AgentRef.agent.md"
    if (Test-Path -LiteralPath $sibling) { return (Resolve-Path -LiteralPath $sibling).Path }

    # 2. Repo-level .github/agents/ directory
    $ghAgents = Join-Path $RepoRoot ".github\agents\$AgentRef.agent.md"
    if (Test-Path -LiteralPath $ghAgents) { return (Resolve-Path -LiteralPath $ghAgents).Path }

    # 3. Copilot default: .github/copilot-agents/<name>.agent.md
    $copilotDefault = Join-Path $RepoRoot ".github\copilot-agents\$AgentRef.agent.md"
    if (Test-Path -LiteralPath $copilotDefault) { return (Resolve-Path -LiteralPath $copilotDefault).Path }

    # 4. Direct path (the reference itself may be a relative or absolute path)
    # Resolve relative paths from $RepoRoot, not the process CWD
    $resolvedRef = if ([System.IO.Path]::IsPathRooted($AgentRef)) { $AgentRef }
                   else { Join-Path $RepoRoot $AgentRef }
    if (Test-Path -LiteralPath $resolvedRef) { return (Resolve-Path -LiteralPath $resolvedRef).Path }

    return $null
}

# -------------------------------------------------------------------
# Helper: Import-SingleAgentConfig — parse and default a single agent
# config file. Returns $null on validation failure.
# -------------------------------------------------------------------
function Import-SingleAgentConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $leafName = [System.IO.Path]::GetFileName($FilePath)
    if (-not $leafName.EndsWith($script:AgentRegistrationSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-CronAgentsLog -Level 'warn' -Message "Agent registration '$FilePath' does not use the required '$($script:AgentRegistrationSuffix)' suffix."
        return $null
    }

    $fileName = $leafName.Substring(0, $leafName.Length - $script:AgentRegistrationSuffix.Length)
    if (-not (Test-CronAgentsSafeIdentifier -Value $fileName)) {
        Write-CronAgentsLog -Level 'warn' -Message "Agent config '$FilePath' skipped — filename stem '$fileName' must use only letters, numbers, dots, underscores, or hyphens."
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Agent config '$FilePath' could not be parsed: $_"
        return $null
    }

    # --- Validation: required fields ---
    [System.Collections.Generic.List[string]]$valErrors = @()

    if (-not $parsed.PSObject.Properties['prompt'] -or [string]::IsNullOrWhiteSpace($parsed.prompt)) {
        $valErrors.Add('prompt is required')
    }
    $hasSchedule = $parsed.PSObject.Properties['schedule'] -and $null -ne $parsed.schedule
    if ($hasSchedule) {
        if (-not $parsed.schedule.PSObject.Properties['type'] -or
            $parsed.schedule.type -notin $script:ValidScheduleTypes) {
            $valErrors.Add("schedule.type must be one of: $($script:ValidScheduleTypes -join ', ')")
        }
    }

    $runIfDefinition = $null
    if ($parsed.PSObject.Properties['runIf'] -and $null -ne $parsed.runIf) {
        try {
            $runIfDefinition = ConvertTo-AgentRunIfDefinition -RunIf $parsed.runIf
        }
        catch {
            $valErrors.Add($_.Exception.Message)
        }
    }

    if ($valErrors.Count -gt 0) {
        $detail = $valErrors -join '; '
        Write-CronAgentsLog -Level 'warn' -Message "Agent config '$FilePath' skipped — validation errors: $detail"
        return $null
    }

    # --- Apply defaults ---
    $envVarsObj = if ($parsed.PSObject.Properties['envVars'] -and $null -ne $parsed.envVars) {
        $parsed.envVars
    } else {
        [PSCustomObject]@{}
    }

    $agentConfig = [PSCustomObject]@{
        name          = if ($parsed.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace($parsed.name))
                        { $parsed.name } else { $fileName }
        prompt        = $parsed.prompt
        schedule      = if ($hasSchedule) { $parsed.schedule } else { $null }
        timeout       = if ($parsed.PSObject.Properties['timeout'] -and -not [string]::IsNullOrWhiteSpace($parsed.timeout))
                        { $parsed.timeout } else { '10m' }
        skipOnBattery = if ($parsed.PSObject.Properties['skipOnBattery'] -and $null -ne $parsed.skipOnBattery)
                        { [bool]$parsed.skipOnBattery } else { $false }
        retryCount    = if ($parsed.PSObject.Properties['retryCount'] -and $null -ne $parsed.retryCount)
                        { [int]$parsed.retryCount } else { 0 }
        model         = if ($parsed.PSObject.Properties['model']) { $parsed.model } else { $null }
        denyTools     = if ($parsed.PSObject.Properties['denyTools'] -and $null -ne $parsed.denyTools)
                        { @($parsed.denyTools) } else { @() }
        extraCliFlags = if ($parsed.PSObject.Properties['extraCliFlags'] -and $null -ne $parsed.extraCliFlags)
                        { @($parsed.extraCliFlags) } else { @() }
        envVars       = $envVarsObj
        workingDirectory = if ($parsed.PSObject.Properties['workingDirectory'])
                           { $parsed.workingDirectory } else { $null }
        runIf         = $runIfDefinition
        notifyOnFailure = if ($parsed.PSObject.Properties['notifyOnFailure'] -and $null -ne $parsed.notifyOnFailure)
                          { [bool]$parsed.notifyOnFailure } else { $false }
        notifyOnSuccess = if ($parsed.PSObject.Properties['notifyOnSuccess'] -and $null -ne $parsed.notifyOnSuccess)
                          { [bool]$parsed.notifyOnSuccess } else { $false }
        raiseAttention  = if ($parsed.PSObject.Properties['raiseAttention'] -and
                             -not [string]::IsNullOrWhiteSpace($parsed.raiseAttention) -and
                             $parsed.raiseAttention -in @('all','failures-only','significant-changes','never'))
                          { ($parsed.raiseAttention).ToLowerInvariant() } else { 'all' }
    }

    if ($parsed.PSObject.Properties['notificationSound'] -and
        -not [string]::IsNullOrWhiteSpace($parsed.notificationSound)) {
        $agentConfig | Add-Member -NotePropertyName 'notificationSound' -NotePropertyValue $parsed.notificationSound
    }

    # Copy agent reference if present
    if ($parsed.PSObject.Properties['agent'] -and -not [string]::IsNullOrWhiteSpace($parsed.agent)) {
        $agentConfig | Add-Member -NotePropertyName 'agent' -NotePropertyValue $parsed.agent
    }

    # --- Resolve .agent.md path ---
    $agentFilePath = $null
    if ($agentConfig.PSObject.Properties['agent'] -and -not [string]::IsNullOrWhiteSpace($agentConfig.agent)) {
        $configDir = Split-Path $FilePath -Parent
        $agentFilePath = Resolve-AgentFilePath -AgentRef $agentConfig.agent `
                                                -ConfigDir $configDir `
                                                -RepoRoot $RepoRoot
    }

    return [PSCustomObject]@{
        Id            = $fileName
        ConfigPath    = (Resolve-Path $FilePath).Path
        Config        = $agentConfig
        AgentFilePath = $agentFilePath
    }
}

# -------------------------------------------------------------------
# Get-AgentConfigs
# -------------------------------------------------------------------
function Get-AgentConfigs {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$PersonalRepoPath,

        [string[]]$AdditionalPaths
    )

    [System.Collections.Generic.List[PSCustomObject]]$agents = @()
    [System.Collections.Generic.HashSet[string]]$seenIds = @()

    # Collect scan directories — personal repo first, then infra repo fallback.
    # Each entry tracks its own RepoRoot so agent file references resolve correctly.
    [System.Collections.Generic.List[PSCustomObject]]$scanDirs = @()

    if ($PersonalRepoPath) {
        $personalAgentsDir = Join-Path $PersonalRepoPath '.cronagents' 'agents'
        if (Test-Path $personalAgentsDir) {
            $scanDirs.Add([PSCustomObject]@{ Dir = $personalAgentsDir; RepoRoot = $PersonalRepoPath })
        }
    }

    $defaultDir = Join-Path $RepoRoot '.cronagents' 'agents'
    if (Test-Path $defaultDir) {
        $scanDirs.Add([PSCustomObject]@{ Dir = $defaultDir; RepoRoot = $RepoRoot })
    }

    if ($AdditionalPaths) {
        foreach ($p in $AdditionalPaths) {
            if (Test-Path $p) {
                $scanDirs.Add([PSCustomObject]@{ Dir = $p; RepoRoot = $RepoRoot })
            }
            else {
                Write-CronAgentsLog -Level 'warn' -Message "Additional agent scan path does not exist: $p"
            }
        }
    }

    foreach ($entry in $scanDirs) {
        $registrationFiles = Get-ChildItem -LiteralPath $entry.Dir -Filter "*.agent-registration.json" -File -ErrorAction SilentlyContinue
        foreach ($file in $registrationFiles) {
            $result = Import-SingleAgentConfig -FilePath $file.FullName -RepoRoot $entry.RepoRoot
            if ($null -eq $result) { continue }

            if ($seenIds.Contains($result.Id)) {
                Write-CronAgentsLog -Level 'warn' -Message "Duplicate agent ID '$($result.Id)' found in '$($file.FullName)' — skipping."
                continue
            }

            [void]$seenIds.Add($result.Id)
            $agents.Add($result)
        }
    }

    # Sort by ID and return
    $sorted = $agents | Sort-Object -Property Id
    return @($sorted)
}
