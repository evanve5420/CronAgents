<#
.SYNOPSIS
    CronAgents CLI — interactive TUI and command-line interface.

.DESCRIPTION
    Main user-facing entry point for CronAgents. Provides subcommands for
    running agents, checking status, pausing/resuming, viewing feedback,
    and an interactive numbered menu when invoked without arguments.

.PARAMETER Command
    Subcommand to execute (run, status, list, pause, resume, feedback,
    evaluate, doctor, install, uninstall, sync, branch, help).

.PARAMETER Argument
    Optional argument for the subcommand (e.g. agent-id).

.PARAMETER Help
    Show usage information.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$Command,
    [Parameter(Position=1)] [string]$Argument,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Bootstrap ────────────────────────────────────────────────────────
$RepoRoot   = $PSScriptRoot
$ModulePath = Join-Path $PSScriptRoot 'scheduler/lib/CronAgents.psd1'
$ConfigPath = Join-Path $RepoRoot 'cronagents.json'
$StateFile  = Join-Path $RepoRoot '.cronstate/state.json'
$RunsRoot   = Join-Path $RepoRoot '.cronstate/runs'

Import-Module $ModulePath -Force

# ── Helpers ──────────────────────────────────────────────────────────

function Get-Config {
    [OutputType([PSCustomObject])]
    param()
    return Import-CronAgentsConfig -ConfigPath $ConfigPath
}

function Get-Agents {
    [OutputType([PSCustomObject[]])]
    param()
    $result = @(Get-AgentConfigs -RepoRoot $RepoRoot)
    Write-Output -NoEnumerate $result
}

function Resolve-Agent {
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Id)
    $agents = Get-Agents
    $match = $agents | Where-Object { $_.Id -eq $Id }
    if (-not $match) {
        Write-Host "Unknown agent ID: '$Id'" -ForegroundColor Red
        Write-Host "Available agents: $(($agents | ForEach-Object { $_.Id }) -join ', ')"
        return $null
    }
    return $match
}

function ConvertTo-ScheduleHashtable {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Schedule)
    $ht = @{ type = $Schedule.type }
    if ($Schedule.PSObject.Properties['every']) { $ht['every'] = $Schedule.every }
    if ($Schedule.PSObject.Properties['time'])  { $ht['time']  = $Schedule.time }
    if ($Schedule.PSObject.Properties['day'])   { $ht['day']   = $Schedule.day }
    return $ht
}

function Format-Schedule {
    [OutputType([string])]
    param([Parameter(Mandatory)]$Schedule)
    switch ($Schedule.type) {
        'interval' { return "every $($Schedule.every)" }
        'daily'    { return "daily at $($Schedule.time)" }
        'weekly'   { return "$($Schedule.day) at $($Schedule.time)" }
        default    { return $Schedule.type }
    }
}

function Get-SafeBranchHeader {
    [OutputType([string])]
    param()
    try {
        $config = Get-Config
        $branchInfo = Get-CronAgentsBranch -RepoRoot $RepoRoot -BranchPrefix $config.versioning.branchPrefix
        $div = Get-BranchDivergence -RepoRoot $RepoRoot
        $header = "CronAgents (branch: $($branchInfo.CurrentBranch)"
        if ($div.Behind -gt 0) {
            $header += ", $($div.Behind) behind master"
        }
        $header += ")"
        return $header
    }
    catch {
        return "CronAgents"
    }
}

# ── Subcommand: run ──────────────────────────────────────────────────

function Invoke-RunCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    if (-not $AgentId) {
        Write-Host "Usage: cronagents.ps1 run <agent-id>" -ForegroundColor Yellow
        return
    }

    $agent = Resolve-Agent -Id $AgentId
    if (-not $agent) { return }

    $invokeScript = Join-Path $RepoRoot 'scheduler/Invoke-ScheduledAgent.ps1'
    if (-not (Test-Path $invokeScript)) {
        Write-Host "Invoke-ScheduledAgent.ps1 not found at: $invokeScript" -ForegroundColor Red
        return
    }

    Write-Host "Running agent '$AgentId'..." -ForegroundColor Cyan
    try {
        $globalConfig = Get-Config
        & $invokeScript -AgentId $agent.Id `
                        -AgentConfig $agent.Config `
                        -GlobalConfig $globalConfig `
                        -RepoRoot $RepoRoot `
                        -RunsRoot $RunsRoot
        Write-Host "Agent '$AgentId' completed." -ForegroundColor Green
    }
    catch {
        Write-Host "Agent '$AgentId' failed: $_" -ForegroundColor Red
    }
}

# ── Subcommand: status ───────────────────────────────────────────────

function Invoke-StatusCommand {
    [CmdletBinding()]
    param()

    $state = Get-AgentState -StateFile $StateFile
    $now   = [datetime]::UtcNow

    # Global pause
    if ($state.schedulerPaused) {
        Write-Host ""
        Write-Host "  *** SCHEDULER IS PAUSED ***" -ForegroundColor Red
        Write-Host ""
    }

    # Branch info
    try {
        $config = Get-Config
        $branchInfo = Get-CronAgentsBranch -RepoRoot $RepoRoot -BranchPrefix $config.versioning.branchPrefix
        $div = Get-BranchDivergence -RepoRoot $RepoRoot
        Write-Host "  Branch: $($branchInfo.CurrentBranch)" -ForegroundColor Cyan
        if ($div.Behind -gt 0) {
            Write-Host "  Behind master: $($div.Behind) commits" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    catch {
        # Git info is optional
    }

    $agents = Get-Agents
    if ($agents.Count -eq 0) {
        Write-Host "  No agents discovered." -ForegroundColor Yellow
        return
    }

    # Table header
    Write-Host ("  {0,-20} {1,-10} {2,-22} {3,-22} {4,-22} {5}" -f `
        'Agent', 'Status', 'Schedule', 'Last Run', 'Next Run', 'Feedback')
    Write-Host ("  " + ("-" * 105))

    foreach ($a in $agents) {
        $agentState = if ($state.agents.ContainsKey($a.Id)) { $state.agents[$a.Id] } else { $null }
        $enabled    = if ($agentState -and $null -ne $agentState.enabled) { $agentState.enabled } else { $true }
        $statusStr  = if ($enabled) { 'Enabled' } else { 'Disabled' }
        $statusColor = if ($enabled) { 'Green' } else { 'DarkGray' }

        $schedStr = Format-Schedule -Schedule $a.Config.schedule

        # Last run
        $lastRunStr = '-'
        $lastRunDt  = $null
        if ($agentState -and $agentState.lastRun) {
            try {
                $lastRunDt  = [datetime]::Parse($agentState.lastRun)
                $lastRunStr = $lastRunDt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            }
            catch { $lastRunStr = $agentState.lastRun }
        }

        # Next run
        $nextRunStr = '-'
        try {
            $schedHt  = ConvertTo-ScheduleHashtable -Schedule $a.Config.schedule
            $nextRun  = Get-NextRunTime -Schedule $schedHt -LastRun $lastRunDt -Now $now
            $nextRunStr = $nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        }
        catch { }

        # Pending feedback
        $feedbackCount = 0
        try {
            $runs = Get-RunHistory -RunsRoot $RunsRoot -AgentId $a.Id
            $feedbackCount = @($runs | Where-Object { $_.HasFeedback -and -not $_.FeedbackProcessed }).Count
        }
        catch { }
        $fbStr = if ($feedbackCount -gt 0) { "$feedbackCount pending" } else { '-' }

        $line = "  {0,-20} {1,-10} {2,-22} {3,-22} {4,-22} {5}" -f `
            $a.Id, $statusStr, $schedStr, $lastRunStr, $nextRunStr, $fbStr
        Write-Host $line -ForegroundColor $statusColor
    }
}

# ── Subcommand: list ─────────────────────────────────────────────────

function Invoke-ListCommand {
    [CmdletBinding()]
    param()

    $agents = Get-Agents
    $now    = [datetime]::UtcNow
    $state  = Get-AgentState -StateFile $StateFile

    if ($agents.Count -eq 0) {
        Write-Host "  No agents discovered." -ForegroundColor Yellow
        return
    }

    Write-Host ("  {0,-20} {1,-25} {2,-22} {3}" -f 'ID', 'Name', 'Schedule', 'Next Run')
    Write-Host ("  " + ("-" * 90))

    foreach ($a in $agents) {
        $name      = $a.Config.name
        $schedStr  = Format-Schedule -Schedule $a.Config.schedule

        $agentState = if ($state.agents.ContainsKey($a.Id)) { $state.agents[$a.Id] } else { $null }
        $lastRunDt  = $null
        if ($agentState -and $agentState.lastRun) {
            try { $lastRunDt = [datetime]::Parse($agentState.lastRun) } catch { }
        }

        $nextRunStr = '-'
        try {
            $schedHt  = ConvertTo-ScheduleHashtable -Schedule $a.Config.schedule
            $nextRun  = Get-NextRunTime -Schedule $schedHt -LastRun $lastRunDt -Now $now
            $nextRunStr = $nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        }
        catch { }

        Write-Host ("  {0,-20} {1,-25} {2,-22} {3}" -f $a.Id, $name, $schedStr, $nextRunStr)
    }
}

# ── Subcommand: pause ────────────────────────────────────────────────

function Invoke-PauseCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    if (-not $AgentId) {
        Set-AgentState -StateFile $StateFile -SchedulerPaused $true
        Write-Host "Scheduler paused globally." -ForegroundColor Yellow
    }
    else {
        $agent = Resolve-Agent -Id $AgentId
        if (-not $agent) { return }
        Set-AgentState -StateFile $StateFile -AgentId $AgentId -Enabled $false
        Write-Host "Agent '$AgentId' disabled." -ForegroundColor Yellow
    }
}

# ── Subcommand: resume ───────────────────────────────────────────────

function Invoke-ResumeCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    if (-not $AgentId) {
        Set-AgentState -StateFile $StateFile -SchedulerPaused $false
        Write-Host "Scheduler resumed." -ForegroundColor Green
    }
    else {
        $agent = Resolve-Agent -Id $AgentId
        if (-not $agent) { return }
        Set-AgentState -StateFile $StateFile -AgentId $AgentId -Enabled $true
        Write-Host "Agent '$AgentId' enabled." -ForegroundColor Green
    }
}

# ── Subcommand: feedback ─────────────────────────────────────────────

function Invoke-FeedbackCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    $runs = if ($AgentId) {
        $agent = Resolve-Agent -Id $AgentId
        if (-not $agent) { return }
        @(Get-RunHistory -RunsRoot $RunsRoot -AgentId $AgentId)
    }
    else {
        @(Get-RunHistory -RunsRoot $RunsRoot)
    }

    # Find most recent unprocessed feedback
    $pending = $runs | Where-Object { -not $_.FeedbackProcessed } | Select-Object -First 1

    if (-not $pending) {
        Write-Host "No pending feedback found." -ForegroundColor Yellow
        return
    }

    $feedbackPath = Join-Path $pending.RunDirectory 'feedback.md'
    Write-Host "Feedback file: $feedbackPath" -ForegroundColor Cyan

    # Try to open in editor
    $editor = $env:EDITOR
    if ($editor -and (Get-Command $editor -ErrorAction SilentlyContinue)) {
        & $editor $feedbackPath
    }
    elseif (Get-Command code -ErrorAction SilentlyContinue) {
        & code $feedbackPath
    }
    else {
        Write-Host "Open the file above in your preferred editor to provide feedback."
    }
}

# ── Subcommand: evaluate ─────────────────────────────────────────────

function Invoke-EvaluateCommand {
    [CmdletBinding()]
    param()

    $runs = @(Get-RunHistory -RunsRoot $RunsRoot)
    $pending = @($runs | Where-Object { $_.HasFeedback -and -not $_.FeedbackProcessed })

    if ($pending.Count -eq 0) {
        Write-Host "No runs with unprocessed feedback found." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($pending.Count) run(s) with pending feedback." -ForegroundColor Cyan

    $config = Get-Config
    $copilotPath = $config.copilotPath

    if (-not (Get-Command $copilotPath -ErrorAction SilentlyContinue)) {
        Write-Host "Copilot CLI not found at '$copilotPath'. Cannot evaluate feedback." -ForegroundColor Red
        return
    }

    foreach ($run in $pending) {
        $feedbackPath = Join-Path $run.RunDirectory 'feedback.md'
        Write-Host "  Evaluating: $($run.AgentId) ($($run.Timestamp.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor DarkCyan
        try {
            $prompt = "Evaluate the following agent feedback and update the agent configuration or prompt accordingly. " +
                      "Agent: $($run.AgentId). Feedback file: $feedbackPath. Run directory: $($run.RunDirectory)."
            $copilotArgs = @('--non-interactive', '-m', $prompt)
            & $copilotPath @copilotArgs 2>&1 | Out-Null

            # Mark as processed
            $metaPath = Join-Path $run.RunDirectory 'meta.json'
            if (Test-Path $metaPath) {
                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $meta.feedbackProcessed = $true
                $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding UTF8
            }
            Write-Host "    Done." -ForegroundColor Green
        }
        catch {
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    }
}

# ── Subcommand: doctor ───────────────────────────────────────────────

function Invoke-DoctorCommand {
    [CmdletBinding()]
    param()

    $healthScript = Join-Path $RepoRoot 'scheduler/Test-CronAgentsHealth.ps1'
    if (-not (Test-Path $healthScript)) {
        Write-Host "Test-CronAgentsHealth.ps1 not found at: $healthScript" -ForegroundColor Red
        return
    }

    try {
        & $healthScript
    }
    catch {
        Write-Host "Health check failed: $_" -ForegroundColor Red
    }
}

# ── Subcommand: install ──────────────────────────────────────────────

function Invoke-InstallCommand {
    [CmdletBinding()]
    param()

    $installScript = Join-Path $RepoRoot 'scheduler/Install-CronAgents.ps1'
    if (-not (Test-Path $installScript)) {
        Write-Host "Install-CronAgents.ps1 not found at: $installScript" -ForegroundColor Red
        return
    }

    try {
        & $installScript -RepoRoot $RepoRoot
    }
    catch {
        Write-Host "Install failed: $_" -ForegroundColor Red
    }
}

# ── Subcommand: uninstall ────────────────────────────────────────────

function Invoke-UninstallCommand {
    [CmdletBinding()]
    param()

    $uninstallScript = Join-Path $RepoRoot 'scheduler/Uninstall-CronAgents.ps1'
    if (-not (Test-Path $uninstallScript)) {
        Write-Host "Uninstall-CronAgents.ps1 not found at: $uninstallScript" -ForegroundColor Red
        return
    }

    try {
        & $uninstallScript
    }
    catch {
        Write-Host "Uninstall failed: $_" -ForegroundColor Red
    }
}

# ── Subcommand: sync ─────────────────────────────────────────────────

function Invoke-SyncCommand {
    [CmdletBinding()]
    param()

    Write-Host "Syncing from master..." -ForegroundColor Cyan
    try {
        $config = Get-Config
        $result = Invoke-BranchSync -RepoRoot $RepoRoot -CopilotPath $config.copilotPath
        if ($result.Success) {
            Write-Host $result.Message -ForegroundColor Green
        }
        else {
            Write-Host $result.Message -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Sync failed: $_" -ForegroundColor Red
    }
}

# ── Subcommand: branch ───────────────────────────────────────────────

function Invoke-BranchCommand {
    [CmdletBinding()]
    param()

    try {
        $config     = Get-Config
        $branchInfo = Get-CronAgentsBranch -RepoRoot $RepoRoot -BranchPrefix $config.versioning.branchPrefix
        $divergence = Get-BranchDivergence -RepoRoot $RepoRoot

        Write-Host ""
        Write-Host "  Current branch : $($branchInfo.CurrentBranch)" -ForegroundColor Cyan
        Write-Host "  Expected branch: $($branchInfo.ExpectedBranch)"
        Write-Host "  On user branch : $($branchInfo.IsUserBranch)"
        Write-Host "  Ahead of master: $($divergence.Ahead)"
        Write-Host "  Behind master  : $($divergence.Behind)"
        if ($divergence.LastSync) {
            Write-Host "  Last sync      : $($divergence.LastSync.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))"
        }
        Write-Host ""
    }
    catch {
        Write-Host "Could not retrieve branch info: $_" -ForegroundColor Red
    }
}

# ── Help ─────────────────────────────────────────────────────────────

function Show-Usage {
    Write-Host ""
    Write-Host "CronAgents CLI" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: cronagents.ps1 [command] [argument]" -ForegroundColor White
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  run <agent-id>       Run an agent immediately"
    Write-Host "  status               Show status of all agents"
    Write-Host "  list                 List all discovered agents"
    Write-Host "  pause [agent-id]     Pause scheduler or disable an agent"
    Write-Host "  resume [agent-id]    Resume scheduler or enable an agent"
    Write-Host "  feedback [agent-id]  Open most recent pending feedback"
    Write-Host "  evaluate             Process all pending feedback"
    Write-Host "  doctor               Run health checks"
    Write-Host "  install              Register scheduled task & bootstrap branch"
    Write-Host "  uninstall            Remove scheduled task"
    Write-Host "  sync                 Merge latest changes from master"
    Write-Host "  branch               Show branch info & divergence"
    Write-Host "  help, --help         Show this help message"
    Write-Host ""
    Write-Host "Run without arguments for an interactive menu."
    Write-Host ""
}

# ── Interactive TUI ──────────────────────────────────────────────────

function Show-InteractiveMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Write-Host ""
        Write-Host (Get-SafeBranchHeader) -ForegroundColor Cyan
        Write-Host ([char]0x2500 * 30)
        Write-Host " 1) Status & upcoming runs"
        Write-Host " 2) Trigger ad-hoc run"
        Write-Host " 3) Pause / Resume"
        Write-Host " 4) View run history"
        Write-Host " 5) Submit feedback"
        Write-Host " 6) Health check (doctor)"
        Write-Host " 7) Sync from master"
        Write-Host " 8) Branch info"
        Write-Host " 9) Exit"
        Write-Host ([char]0x2500 * 30)

        $choice = Read-Host "Select [1-9]"

        switch ($choice) {
            '1' { Invoke-StatusCommand }
            '2' { Invoke-TuiAdHocRun }
            '3' { Invoke-TuiPauseResume }
            '4' { Invoke-TuiRunHistory }
            '5' { Invoke-TuiFeedback }
            '6' { Invoke-DoctorCommand }
            '7' { Invoke-SyncCommand }
            '8' { Invoke-BranchCommand }
            '9' { Write-Host "Goodbye." -ForegroundColor Cyan; return }
            default { Write-Host "Invalid selection. Please enter 1-9." -ForegroundColor Yellow }
        }
    }
}

# ── TUI: Ad-hoc run ─────────────────────────────────────────────────

function Invoke-TuiAdHocRun {
    [CmdletBinding()]
    param()

    $agents = Get-Agents
    if ($agents.Count -eq 0) {
        Write-Host "  No agents discovered." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Select an agent to run:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $agents.Count; $i++) {
        Write-Host "  $($i + 1)) $($agents[$i].Id) — $($agents[$i].Config.name)"
    }
    Write-Host "  0) Back"
    $pick = Read-Host "Select"

    if ($pick -eq '0' -or [string]::IsNullOrWhiteSpace($pick)) { return }

    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $agents.Count) {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        return
    }

    Invoke-RunCommand -AgentId $agents[$idx - 1].Id
}

# ── TUI: Pause / Resume ─────────────────────────────────────────────

function Invoke-TuiPauseResume {
    [CmdletBinding()]
    param()

    $state = Get-AgentState -StateFile $StateFile
    $globalStatus = if ($state.schedulerPaused) { 'PAUSED' } else { 'Running' }
    $globalColor  = if ($state.schedulerPaused) { 'Red' } else { 'Green' }

    Write-Host ""
    Write-Host "  Scheduler: $globalStatus" -ForegroundColor $globalColor
    Write-Host ""
    Write-Host "  1) Global pause/resume"
    Write-Host "  2) Per-agent pause/resume"
    Write-Host "  3) Back"
    $pick = Read-Host "Select"

    switch ($pick) {
        '1' {
            if ($state.schedulerPaused) {
                Invoke-ResumeCommand
            }
            else {
                Invoke-PauseCommand
            }
        }
        '2' {
            $agents = Get-Agents
            if ($agents.Count -eq 0) {
                Write-Host "  No agents discovered." -ForegroundColor Yellow
                return
            }

            Write-Host ""
            for ($i = 0; $i -lt $agents.Count; $i++) {
                $agentState = if ($state.agents.ContainsKey($agents[$i].Id)) { $state.agents[$agents[$i].Id] } else { $null }
                $enabled = if ($agentState -and $null -ne $agentState.enabled) { $agentState.enabled } else { $true }
                $statusStr = if ($enabled) { 'Enabled' } else { 'Disabled' }
                $color = if ($enabled) { 'Green' } else { 'DarkGray' }
                Write-Host -NoNewline "  $($i + 1)) $($agents[$i].Id) — "
                Write-Host $statusStr -ForegroundColor $color
            }
            Write-Host "  0) Back"
            $agentPick = Read-Host "Select agent"

            if ($agentPick -eq '0' -or [string]::IsNullOrWhiteSpace($agentPick)) { return }

            $idx = 0
            if (-not [int]::TryParse($agentPick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $agents.Count) {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                return
            }

            $selectedAgent = $agents[$idx - 1]
            $agentState = if ($state.agents.ContainsKey($selectedAgent.Id)) { $state.agents[$selectedAgent.Id] } else { $null }
            $enabled = if ($agentState -and $null -ne $agentState.enabled) { $agentState.enabled } else { $true }

            if ($enabled) {
                Invoke-PauseCommand -AgentId $selectedAgent.Id
            }
            else {
                Invoke-ResumeCommand -AgentId $selectedAgent.Id
            }
        }
        '3' { return }
        default { Write-Host "Invalid selection." -ForegroundColor Yellow }
    }
}

# ── TUI: Run history ────────────────────────────────────────────────

function Invoke-TuiRunHistory {
    [CmdletBinding()]
    param()

    $runs = @(Get-RunHistory -RunsRoot $RunsRoot -MaxResults 20)
    if ($runs.Count -eq 0) {
        Write-Host "  No run history found." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Recent runs:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $runs.Count; $i++) {
        $r = $runs[$i]
        $exitStr = if ($r.Meta) { "exit=$($r.Meta.exitCode)" } else { 'no meta' }
        $ts = $r.Timestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Write-Host "  $($i + 1)) $($r.AgentId)  $ts  [$exitStr]"
    }
    Write-Host "  0) Back"

    $pick = Read-Host "Select run for details"
    if ($pick -eq '0' -or [string]::IsNullOrWhiteSpace($pick)) { return }

    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $runs.Count) {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        return
    }

    $selected = $runs[$idx - 1]
    Write-Host ""
    Write-Host "  Run directory: $($selected.RunDirectory)" -ForegroundColor Cyan
    if ($selected.Meta) {
        Write-Host "  Agent   : $($selected.Meta.agentId)"
        Write-Host "  Start   : $($selected.Meta.startTime)"
        Write-Host "  End     : $($selected.Meta.endTime)"
        Write-Host "  Exit    : $($selected.Meta.exitCode)"
        Write-Host "  Timed out: $($selected.Meta.timedOut)"
        Write-Host "  Feedback : $(if ($selected.HasFeedback) { 'Yes' } else { 'No' })"
        Write-Host "  Processed: $($selected.FeedbackProcessed)"
    }

    # Show summary if present
    $summaryPath = Join-Path $selected.RunDirectory 'summary.md'
    if (Test-Path $summaryPath) {
        Write-Host ""
        Write-Host "  --- Summary ---" -ForegroundColor DarkCyan
        Get-Content -LiteralPath $summaryPath | ForEach-Object { Write-Host "  $_" }
    }
}

# ── TUI: Submit feedback ────────────────────────────────────────────

function Invoke-TuiFeedback {
    [CmdletBinding()]
    param()

    $runs = @(Get-RunHistory -RunsRoot $RunsRoot)
    $pending = @($runs | Where-Object { -not $_.FeedbackProcessed })

    if ($pending.Count -eq 0) {
        Write-Host "  No pending feedback found." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Runs with pending feedback:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $r  = $pending[$i]
        $ts = $r.Timestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        $fb = if ($r.HasFeedback) { '[has feedback]' } else { '[empty]' }
        Write-Host "  $($i + 1)) $($r.AgentId)  $ts  $fb"
    }
    Write-Host "  0) Back"

    $pick = Read-Host "Select"
    if ($pick -eq '0' -or [string]::IsNullOrWhiteSpace($pick)) { return }

    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $pending.Count) {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        return
    }

    $selected = $pending[$idx - 1]
    $feedbackPath = Join-Path $selected.RunDirectory 'feedback.md'
    Write-Host "Feedback file: $feedbackPath" -ForegroundColor Cyan

    $editor = $env:EDITOR
    if ($editor -and (Get-Command $editor -ErrorAction SilentlyContinue)) {
        & $editor $feedbackPath
    }
    elseif (Get-Command code -ErrorAction SilentlyContinue) {
        & code $feedbackPath
    }
    else {
        Write-Host "Open the file above in your preferred editor to submit feedback."
    }
}

# ── Dispatch ─────────────────────────────────────────────────────────

if ($Help -or $Command -eq '--help' -or $Command -eq 'help') {
    Show-Usage
    return
}

if (-not $Command) {
    Show-InteractiveMenu
    return
}

try {
    switch ($Command.ToLower()) {
        'run'       { Invoke-RunCommand -AgentId $Argument }
        'status'    { Invoke-StatusCommand }
        'list'      { Invoke-ListCommand }
        'pause'     { Invoke-PauseCommand -AgentId $Argument }
        'resume'    { Invoke-ResumeCommand -AgentId $Argument }
        'feedback'  { Invoke-FeedbackCommand -AgentId $Argument }
        'evaluate'  { Invoke-EvaluateCommand }
        'doctor'    { Invoke-DoctorCommand }
        'install'   { Invoke-InstallCommand }
        'uninstall' { Invoke-UninstallCommand }
        'sync'      { Invoke-SyncCommand }
        'branch'    { Invoke-BranchCommand }
        default {
            Write-Host "Unknown command: '$Command'" -ForegroundColor Red
            Show-Usage
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}
