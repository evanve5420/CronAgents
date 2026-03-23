# -----------------------------------------------------------------------
# GitHelpers.ps1 — Git branch operations for CronAgents
#
# Provides functions for user-branch management, divergence checks,
# merge/sync, feedback commits, and username resolution. Designed to be
# dot-sourced as a nested module via CronAgents.psd1.
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

    # 2. git config user.name
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

    # 3. Environment variable
    if ($env:USERNAME) {
        Write-CronAgentsLog -Level 'debug' -Message "Username from env:USERNAME: $env:USERNAME"
        return ConvertTo-Slug -Value $env:USERNAME
    }

    throw 'Cannot resolve username: no config value, git config, or USERNAME environment variable available.'
}

# ===================================================================
# Get-CronAgentsBranch
# ===================================================================
function Get-CronAgentsBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [string]$BranchPrefix = 'agents',

        [Parameter()]
        [string]$UserName
    )

    Assert-GitAvailable

    $currentBranch = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')

    if (-not $UserName) {
        $UserName = Resolve-CronAgentsUserName -RepoRoot $RepoRoot
    }

    $expectedBranch = "$BranchPrefix/$UserName"
    $isUserBranch   = $currentBranch -eq $expectedBranch

    Write-CronAgentsLog -Level 'debug' -Message "Current branch: $currentBranch, expected: $expectedBranch, match: $isUserBranch"

    return [PSCustomObject]@{
        CurrentBranch  = $currentBranch
        IsUserBranch   = $isUserBranch
        ExpectedBranch = $expectedBranch
        BranchPrefix   = $BranchPrefix
    }
}

# ===================================================================
# Get-BranchDivergence
# ===================================================================
function Get-BranchDivergence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [string]$UserBranch,

        [Parameter()]
        [string]$BaseBranch = 'master'
    )

    Assert-GitAvailable

    if (-not $UserBranch) {
        $UserBranch = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
    }

    $ahead   = 0
    $behind  = 0
    $lastSync = $null

    try {
        $aheadStr = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-list', '--count', "$BaseBranch..$UserBranch")
        $ahead = [int]$aheadStr
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Could not compute ahead count for $UserBranch vs $BaseBranch`: $_"
    }

    try {
        $behindStr = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-list', '--count', "$UserBranch..$BaseBranch")
        $behind = [int]$behindStr
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Could not compute behind count for $UserBranch vs $BaseBranch`: $_"
    }

    try {
        $mergeBase = Invoke-Git -Arguments @('-C', $RepoRoot, 'merge-base', $UserBranch, $BaseBranch)
        if ($mergeBase) {
            $dateStr = Invoke-Git -Arguments @('-C', $RepoRoot, 'show', '-s', '--format=%ci', $mergeBase)
            if ($dateStr) {
                $lastSync = [datetime]::Parse($dateStr)
            }
        }
    }
    catch {
        Write-CronAgentsLog -Level 'debug' -Message "Could not determine merge-base timestamp: $_"
    }

    return [PSCustomObject]@{
        Ahead    = $ahead
        Behind   = $behind
        LastSync = $lastSync
    }
}

# ===================================================================
# Invoke-BranchSync
# ===================================================================
function Invoke-BranchSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [string]$BaseBranch = 'master',

        [Parameter()]
        [string]$CopilotPath,

        [Parameter()]
        [string]$RunDirectory
    )

    Assert-GitAvailable

    # --- Fetch ---
    try {
        $null = Invoke-Git -Arguments @('-C', $RepoRoot, 'fetch', 'origin', $BaseBranch)
        Write-CronAgentsLog -Level 'info' -Message "Fetched origin/$BaseBranch"
    }
    catch {
        Write-CronAgentsLog -Level 'error' -Message "Failed to fetch origin/$BaseBranch`: $_"
        return [PSCustomObject]@{
            Success       = $false
            CleanMerge    = $false
            ConflictFiles = @()
            Message       = "Fetch failed: $_"
        }
    }

    # --- Merge ---
    $mergeOutput = & git -C $RepoRoot merge "origin/$BaseBranch" --no-edit 2>&1
    $mergeExitCode = $LASTEXITCODE

    if ($mergeExitCode -eq 0) {
        Write-CronAgentsLog -Level 'info' -Message "Clean merge of origin/$BaseBranch"
        return [PSCustomObject]@{
            Success       = $true
            CleanMerge    = $true
            ConflictFiles = @()
            Message       = "Clean merge of origin/$BaseBranch completed."
        }
    }

    # --- Conflicts detected ---
    Write-CronAgentsLog -Level 'warn' -Message "Merge conflicts detected with origin/$BaseBranch"

    $conflictOutput = & git -C $RepoRoot diff --name-only --diff-filter=U 2>&1
    $conflictFiles = @()
    if ($LASTEXITCODE -eq 0 -and $conflictOutput) {
        $conflictFiles = @($conflictOutput | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    }

    Write-CronAgentsLog -Level 'warn' -Message "Conflicted files: $($conflictFiles -join ', ')"

    # --- Attempt agent-assisted resolution ---
    $resolved = $false
    if ($CopilotPath -and (Get-Command $CopilotPath -ErrorAction SilentlyContinue)) {
        Write-CronAgentsLog -Level 'info' -Message "Attempting agent-assisted conflict resolution via $CopilotPath"
        try {
            $prompt = "Resolve the following git merge conflicts in repo '$RepoRoot'. Conflicted files: $($conflictFiles -join ', '). " +
                      "For each file, pick the correct resolution, edit the file to remove conflict markers, then stage it with 'git add'."

            $copilotArgs = @('--non-interactive', '-m', $prompt)
            $copilotOutput = & $CopilotPath @copilotArgs 2>&1
            Write-CronAgentsLog -Level 'debug' -Message "Copilot output: $($copilotOutput | Out-String)"

            # Check if conflicts remain
            $remaining = & git -C $RepoRoot diff --name-only --diff-filter=U 2>&1
            if ($LASTEXITCODE -eq 0 -and -not $remaining) {
                & git -C $RepoRoot commit --no-edit 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $resolved = $true
                    Write-CronAgentsLog -Level 'info' -Message 'Agent-assisted conflict resolution succeeded.'
                }
            }
        }
        catch {
            Write-CronAgentsLog -Level 'warn' -Message "Agent-assisted resolution failed: $_"
        }

        if ($RunDirectory) {
            try {
                $sessionLog = Join-Path $RunDirectory 'conflict-resolution.log'
                $logContent = "Conflict resolution attempt at $(Get-Date -Format 'o')`nFiles: $($conflictFiles -join ', ')`nResolved: $resolved"
                $dir = Split-Path -Path $sessionLog -Parent
                if ($dir -and -not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                [System.IO.File]::WriteAllText($sessionLog, $logContent, [System.Text.Encoding]::UTF8)
            }
            catch {
                Write-CronAgentsLog -Level 'debug' -Message "Could not write conflict resolution log: $_"
            }
        }
    }

    if ($resolved) {
        return [PSCustomObject]@{
            Success       = $true
            CleanMerge    = $false
            ConflictFiles = $conflictFiles
            Message       = "Merge conflicts in $($conflictFiles.Count) file(s) resolved by agent."
        }
    }

    # --- Abort unresolved merge ---
    Write-CronAgentsLog -Level 'warn' -Message 'Aborting unresolved merge.'
    & git -C $RepoRoot merge --abort 2>&1 | Out-Null

    return [PSCustomObject]@{
        Success       = $false
        CleanMerge    = $false
        ConflictFiles = $conflictFiles
        Message       = "Merge conflicts in $($conflictFiles.Count) file(s) could not be resolved: $($conflictFiles -join ', ')"
    }
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
# Initialize-UserBranch
# ===================================================================
function Initialize-UserBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [string]$BranchPrefix = 'agents',

        [Parameter(Mandatory)]
        [string]$UserName
    )

    Assert-GitAvailable

    $branchName = "$BranchPrefix/$UserName"

    # 1. Check for dirty working tree
    $status = & git -C $RepoRoot status --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in '$RepoRoot': $($status | Out-String)"
    }
    if ($status) {
        Write-CronAgentsLog -Level 'warn' -Message "Dirty working tree in '$RepoRoot' — aborting branch initialisation."
        return [PSCustomObject]@{
            BranchName = $branchName
            Created    = $false
            Message    = 'Working tree has uncommitted changes. Commit or stash them first.'
        }
    }

    # 2. Check if branch already exists
    $existing = & git -C $RepoRoot branch --list $branchName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git branch --list failed: $($existing | Out-String)"
    }

    $existsTrimmed = ($existing | Out-String).Trim()
    if ($existsTrimmed) {
        $null = Invoke-Git -Arguments @('-C', $RepoRoot, 'checkout', $branchName)
        Write-CronAgentsLog -Level 'info' -Message "Checked out existing branch '$branchName'."
        return [PSCustomObject]@{
            BranchName = $branchName
            Created    = $false
            Message    = "Switched to existing branch '$branchName'."
        }
    }

    # 3. Create new branch
    $null = Invoke-Git -Arguments @('-C', $RepoRoot, 'checkout', '-b', $branchName)
    Write-CronAgentsLog -Level 'info' -Message "Created and checked out new branch '$branchName'."
    return [PSCustomObject]@{
        BranchName = $branchName
        Created    = $true
        Message    = "Created new branch '$branchName'."
    }
}
