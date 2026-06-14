# -----------------------------------------------------------------------
# PersonalRepo.ps1 — Personal repo management for CronAgents
#
# Manages the separate personal git repo (~/.cronagents/) where users
# store their agent definitions, skills, and scheduling configurations.
# Also provides username resolution, slug helpers, and feedback commits.
#
# Depends on: Logger.ps1 (Write-CronAgentsLog)
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Private helper: Assert-GitAvailable
# -------------------------------------------------------------------
function Assert-GitAvailable {
    [CmdletBinding()]
    param()
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is not installed or not on PATH.'
    }
}

# -------------------------------------------------------------------
# Private helper: Invoke-Git
# Runs a git command, captures stdout, and checks LASTEXITCODE.
# Returns trimmed stdout on success; throws on failure.
# -------------------------------------------------------------------
function Invoke-Git {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = if ($output) { ($output | Out-String).Trim() } else { "git exited with code $LASTEXITCODE" }
        throw "git $($Arguments -join ' ') failed: $msg"
    }
    return ($output | Out-String).Trim()
}

# -------------------------------------------------------------------
# ConvertTo-Slug
# Lowercase, spaces→hyphens, strip non-alphanumeric except hyphens,
# collapse multiple hyphens, trim leading/trailing hyphens.
# -------------------------------------------------------------------
function ConvertTo-Slug {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $slug = $Value.ToLower()
    $slug = $slug -replace '\s+', '-'
    $slug = $slug -replace '[^a-z0-9\-]', ''
    $slug = $slug -replace '-{2,}', '-'
    $slug = $slug.Trim('-')
    return $slug
}

# -------------------------------------------------------------------
# Resolve-GitHubHandle
# Tries GitHub-specific identity sources before falling back to a
# display name. Prefers repo-local git config, then the active gh CLI
# login when available.
# -------------------------------------------------------------------
function Resolve-GitHubHandle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$RepoRoot
    )

    if ($RepoRoot) {
        try {
            Assert-GitAvailable
            $gitHubUser = Invoke-Git -Arguments @('-C', $RepoRoot, 'config', 'github.user')
            if ($gitHubUser) {
                Write-CronAgentsLog -Level 'debug' -Message "GitHub handle from git config github.user: $gitHubUser"
                return ConvertTo-Slug -Value $gitHubUser
            }
        }
        catch {
            Write-CronAgentsLog -Level 'debug' -Message "Could not read git config github.user: $_"
        }
    }

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        try {
            $statusText = (& $gh.Source auth status 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0) {
                $match = [regex]::Match($statusText, 'account\s+([A-Za-z0-9][A-Za-z0-9\-]*)')
                if ($match.Success) {
                    $handle = $match.Groups[1].Value
                    Write-CronAgentsLog -Level 'debug' -Message "GitHub handle from gh auth status: $handle"
                    return ConvertTo-Slug -Value $handle
                }
            }
        }
        catch {
            Write-CronAgentsLog -Level 'debug' -Message "Could not resolve GitHub handle from gh auth status: $_"
        }
    }

    return $null
}

# ===================================================================
# Resolve-CronAgentsUserName
# ===================================================================
function Resolve-CronAgentsUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$ConfigUserName,

        [Parameter()]
        [string]$RepoRoot
    )

    # 1. Explicit config value
    if ($ConfigUserName) {
        Write-CronAgentsLog -Level 'debug' -Message "Username from config: $ConfigUserName"
        return ConvertTo-Slug -Value $ConfigUserName
    }

    # 2. GitHub-specific identity sources
    $gitHubHandle = Resolve-GitHubHandle -RepoRoot $RepoRoot
    if ($gitHubHandle) {
        return $gitHubHandle
    }

    # 3. git config user.name
    if ($RepoRoot) {
        try {
            Assert-GitAvailable
            $gitName = Invoke-Git -Arguments @('-C', $RepoRoot, 'config', 'user.name')
            if ($gitName) {
                Write-CronAgentsLog -Level 'debug' -Message "Username from git config: $gitName"
                return ConvertTo-Slug -Value $gitName
            }
        }
        catch {
            Write-CronAgentsLog -Level 'debug' -Message "Could not read git config user.name: $_"
        }
    }

    # 4. Environment variable (cross-platform)
    $envUser = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { $null }
    if ($envUser) {
        Write-CronAgentsLog -Level 'debug' -Message "Username from environment: $envUser"
        return ConvertTo-Slug -Value $envUser
    }

    throw 'Cannot resolve username: no config value, GitHub handle, git config, or USERNAME/USER environment variable available.'
}

# ===================================================================
# New-FeedbackCommit
# ===================================================================
function New-FeedbackCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$Summary,

        [Parameter(Mandatory)]
        [string[]]$ChangedFiles
    )

    Assert-GitAvailable

    try {
        foreach ($file in $ChangedFiles) {
            $null = Invoke-Git -Arguments @('-C', $RepoRoot, 'add', $file)
        }

        $commitMsg = "feedback: $AgentId — $Summary"
        $null = Invoke-Git -Arguments @('-C', $RepoRoot, 'commit', '-m', $commitMsg)

        $hash = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-parse', 'HEAD')
        Write-CronAgentsLog -Level 'info' -Message "Feedback commit $hash for agent '$AgentId'"

        return [PSCustomObject]@{
            Success    = $true
            CommitHash = $hash
            Message    = "Committed feedback for $AgentId ($hash)."
        }
    }
    catch {
        Write-CronAgentsLog -Level 'error' -Message "Feedback commit failed for agent '$AgentId': $_"
        return [PSCustomObject]@{
            Success    = $false
            CommitHash = $null
            Message    = "Feedback commit failed: $_"
        }
    }
}

# ===================================================================
# Get-PersonalRepoPath
# ===================================================================
function Get-PersonalRepoPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    if ($ConfigPath -and $ConfigPath.Trim()) {
        $expanded = $ConfigPath -replace '^~', $HOME
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $HOME '.cronagents'))
}

# ===================================================================
# Test-PersonalRepoValid
# ===================================================================
function Test-PersonalRepoValid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $errors.Add("Directory does not exist: $Path")
    }
    else {
        $gitDir = Join-Path $Path '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            $errors.Add("Not a git repository (missing .git): $Path")
        }

        $agentsDir = Join-Path $Path '.github' 'agents'
        if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) {
            $errors.Add("Missing directory: .github/agents/")
        }

        $cronagentsDir = Join-Path $Path '.cronagents' 'agents'
        if (-not (Test-Path -LiteralPath $cronagentsDir -PathType Container)) {
            $errors.Add("Missing directory: .cronagents/agents/")
        }
    }

    return [PSCustomObject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = [string[]]$errors.ToArray()
    }
}

# ===================================================================
# Initialize-PersonalRepo
# ===================================================================
function Initialize-PersonalRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter()]
        [string]$InfraRepoRoot
    )

    # If repo already exists and is valid, return early
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $validation = Test-PersonalRepoValid -Path $Path
        if ($validation.Valid) {
            Write-CronAgentsLog -Level 'info' -Message "Personal repo already exists and is valid: $Path"
            return [PSCustomObject]@{
                Path    = $Path
                Created = $false
                Message = "Personal repo already exists at $Path."
            }
        }
    }

    Write-CronAgentsLog -Level 'info' -Message "Initializing personal repo at $Path for user '$UserName'"

    Assert-GitAvailable

    # Create directory structure
    $dirs = @(
        (Join-Path $Path '.github' 'agents')
        (Join-Path $Path '.github' 'skills')
        (Join-Path $Path '.github' 'instructions')
        (Join-Path $Path '.cronagents' 'agents')
        (Join-Path $Path '.cronstate')
        (Join-Path $Path '.cronstate' 'runs')
    )
    foreach ($dir in $dirs) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-CronAgentsLog -Level 'debug' -Message "Created directory: $dir"
    }

    # Create .gitignore
    $gitignorePath = Join-Path $Path '.gitignore'
    [System.IO.File]::WriteAllText($gitignorePath, ".cronstate/`n", [System.Text.Encoding]::UTF8)
    Write-CronAgentsLog -Level 'debug' -Message "Created .gitignore"

    # Create cronagents.json
    $configPath = Join-Path $Path 'cronagents.json'
    $configContent = @'
{
}
'@
    [System.IO.File]::WriteAllText($configPath, $configContent, [System.Text.Encoding]::UTF8)
    Write-CronAgentsLog -Level 'debug' -Message "Created cronagents.json"

    # Create copilot-instructions.md
    $instructionsPath = Join-Path $Path '.github' 'copilot-instructions.md'
    $instructionsContent = "Personal CronAgents repository for $UserName. Agent definitions and scheduling configs live here.`n"
    [System.IO.File]::WriteAllText($instructionsPath, $instructionsContent, [System.Text.Encoding]::UTF8)
    Write-CronAgentsLog -Level 'debug' -Message "Created .github/copilot-instructions.md"

    # git init
    $null = Invoke-Git -Arguments @('-C', $Path, 'init')
    Write-CronAgentsLog -Level 'debug' -Message "Initialized git repository"

    # Configure git user from infra repo or fallbacks
    $gitUserName  = $null
    $gitUserEmail = $null
    $infraRoot = if ($InfraRepoRoot) { $InfraRepoRoot } else { (Get-Location).Path }

    try {
        $gitUserName  = Invoke-Git -Arguments @('-C', $infraRoot, 'config', 'user.name')
    }
    catch {
        Write-CronAgentsLog -Level 'debug' -Message "Could not read user.name from infra repo: $_"
    }
    try {
        $gitUserEmail = Invoke-Git -Arguments @('-C', $infraRoot, 'config', 'user.email')
    }
    catch {
        Write-CronAgentsLog -Level 'debug' -Message "Could not read user.email from infra repo: $_"
    }

    if (-not $gitUserName)  { $gitUserName  = $UserName }
    if (-not $gitUserEmail) { $gitUserEmail = "$UserName@cronagents.local" }

    $null = Invoke-Git -Arguments @('-C', $Path, 'config', 'user.name',  $gitUserName)
    $null = Invoke-Git -Arguments @('-C', $Path, 'config', 'user.email', $gitUserEmail)
    Write-CronAgentsLog -Level 'debug' -Message "Configured git user: $gitUserName <$gitUserEmail>"

    # Stage and commit
    $null = Invoke-Git -Arguments @('-C', $Path, 'add', '-A')
    $null = Invoke-Git -Arguments @('-C', $Path, 'commit', '-m', 'Initialize personal CronAgents repo')
    Write-CronAgentsLog -Level 'info' -Message "Personal repo initialized and committed at $Path"

    return [PSCustomObject]@{
        Path    = $Path
        Created = $true
        Message = "Personal repo initialized at $Path."
    }
}

# ===================================================================
# Import-PersonalRepoConfig
# ===================================================================
function Import-PersonalRepoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PersonalRepoPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$BaseConfig
    )

    $personalConfigPath = Join-Path $PersonalRepoPath 'cronagents.json'

    if (-not (Test-Path -LiteralPath $personalConfigPath -PathType Leaf)) {
        Write-CronAgentsLog -Level 'debug' -Message "No personal cronagents.json found at $personalConfigPath"
        return $BaseConfig
    }

    $raw = Get-Content -LiteralPath $personalConfigPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or -not $raw.Trim()) {
        Write-CronAgentsLog -Level 'debug' -Message "Personal cronagents.json is empty"
        return $BaseConfig
    }

    try {
        $personalConfig = $raw | ConvertFrom-Json
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Failed to parse personal cronagents.json: $_"
        return $BaseConfig
    }

    # Deep-clone base config to avoid mutating the original
    $merged = $BaseConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    # Top-level fields where an explicit JSON null is a meaningful override
    # (e.g. "quietHours": null disables inherited quiet hours) rather than a
    # "leave the inherited value alone" signal. For every other field a null
    # personal value is ignored so users don't accidentally blank out scalars.
    $nullableOverrideFields = @('quietHours')

    foreach ($prop in $personalConfig.PSObject.Properties) {
        # Always skip the schema reference.
        if ($prop.Name -eq '$schema') {
            continue
        }

        # Skip null values unless the field treats null as an intentional
        # override that disables the inherited setting.
        if ($null -eq $prop.Value -and $prop.Name -notin $nullableOverrideFields) {
            continue
        }

        if ($prop.Name -eq 'personalRepo' -and
            $null -ne $merged.PSObject.Properties[$prop.Name] -and
            $prop.Value -is [PSCustomObject]) {
            # Property-level merge for personalRepo sub-object so users can
            # override e.g. userName without losing the default path.
            foreach ($subProp in $prop.Value.PSObject.Properties) {
                if ($null -ne $subProp.Value) {
                    if ($null -eq $merged.$($prop.Name).PSObject.Properties[$subProp.Name]) {
                        $merged.$($prop.Name) | Add-Member -NotePropertyName $subProp.Name -NotePropertyValue $subProp.Value
                    }
                    else {
                        $merged.$($prop.Name).$($subProp.Name) = $subProp.Value
                    }
                }
            }
        }
        else {
            # Top-level override (wholesale replacement — intentional for
            # atomic objects like quietHours where partial merge would be
            # surprising, e.g. overriding start but keeping the old end).
            if ($null -eq $merged.PSObject.Properties[$prop.Name]) {
                $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            }
            else {
                $merged.$($prop.Name) = $prop.Value
            }
        }
    }

    Write-CronAgentsLog -Level 'info' -Message "Merged personal config from $personalConfigPath"
    return $merged
}
