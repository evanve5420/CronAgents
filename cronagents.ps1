<#
.SYNOPSIS
    CronAgents CLI — interactive TUI and command-line interface.

.DESCRIPTION
    Main user-facing entry point for CronAgents. Provides subcommands for
    running agents, checking status, pausing/resuming, viewing feedback,
    and an interactive numbered menu when invoked without arguments.

.PARAMETER Command
    Subcommand to execute (run, status, list, pause, resume, feedback,
    evaluate, clear, doctor, install, uninstall, migrate, help).

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

Import-Module $ModulePath -Force

$PersonalRepoConfig = Import-CronAgentsConfig -ConfigPath $ConfigPath
$PersonalRepoPath   = Get-PersonalRepoPath -ConfigPath $PersonalRepoConfig.personalRepo.path
$StateFile  = Join-Path $PersonalRepoPath '.cronstate/state.json'
$RunsRoot   = Join-Path $PersonalRepoPath '.cronstate/runs'

# ── Helpers ──────────────────────────────────────────────────────────

function Get-Config {
    [OutputType([PSCustomObject])]
    param()
    return Import-CronAgentsConfig -ConfigPath $ConfigPath
}

function Get-Agents {
    [OutputType([PSCustomObject[]])]
    param()
    $result = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
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
    param([AllowNull()]$Schedule)
    if ($null -eq $Schedule) { return $null }
    $ht = @{ type = $Schedule.type }
    if ($Schedule.PSObject.Properties['every']) { $ht['every'] = $Schedule.every }
    if ($Schedule.PSObject.Properties['time'])  { $ht['time']  = $Schedule.time }
    if ($Schedule.PSObject.Properties['day'])   { $ht['day']   = $Schedule.day }
    return $ht
}

function Format-Schedule {
    [OutputType([string])]
    param([AllowNull()]$Schedule)
    if ($null -eq $Schedule) { return 'manual' }
    switch ($Schedule.type) {
        'interval' { return "every $($Schedule.every)" }
        'daily'    { return "daily at $($Schedule.time)" }
        'weekly'   { return "$($Schedule.day) at $($Schedule.time)" }
        default    { return $Schedule.type }
    }
}

function Get-SafeHeader {
    [OutputType([string])]
    param()
    try {
        $validation = Test-PersonalRepoValid -Path $PersonalRepoPath
        if ($validation.Valid) {
            return "CronAgents (personal repo: $PersonalRepoPath)"
        }
        return "CronAgents (personal repo: not initialized)"
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
                        -PersonalRepoPath $PersonalRepoPath `
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
        $validation = Test-PersonalRepoValid -Path $PersonalRepoPath
        if ($validation.Valid) {
            Write-Host "  Personal repo: $PersonalRepoPath" -ForegroundColor Cyan
        }
        else {
            Write-Host "  Personal repo: not initialized" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    catch {
        # Personal repo info is optional
    }

    $agents = Get-Agents
    if ($agents.Count -eq 0) {
        Write-Host "  No agents discovered." -ForegroundColor Yellow
        return
    }

    # Table header
    Write-Host ("  {0,-20} {1,-10} {2,-22} {3,-22} {4,-22} {5,-15} {6}" -f `
        'Agent', 'Status', 'Schedule', 'Last Run', 'Next Run', 'Questions', 'Feedback')
    Write-Host ("  " + ("-" * 120))

    $stateRoot = Join-Path $PersonalRepoPath '.cronstate'

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
        $nextRunStr = if ($null -eq $a.Config.schedule) { 'n/a' } else { '-' }
        try {
            $schedHt  = ConvertTo-ScheduleHashtable -Schedule $a.Config.schedule
            $nextRun  = Get-NextRunTime -Schedule $schedHt -LastRun $lastRunDt -Now $now
            if ($null -ne $nextRun) {
                $nextRunStr = $nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            }
        }
        catch { }

        # Pending questions
        $qCount = 0
        try {
            $qCount = (Get-PendingQuestions -StateRoot $stateRoot -AgentId $a.Id).Count
        }
        catch { }
        $qStr = if ($qCount -gt 0) { "❓ $qCount pending" } else { '-' }

        # Check if blocked by questions
        if ($qCount -gt 0 -and $enabled) {
            $statusStr = 'Blocked'
            $statusColor = 'Yellow'
        }

        # Pending feedback
        $feedbackCount = 0
        try {
            $runs = Get-RunHistory -RunsRoot $RunsRoot -AgentId $a.Id
            $feedbackCount = @($runs | Where-Object { $_.HasFeedback -and -not $_.FeedbackProcessed }).Count
        }
        catch { }
        $fbStr = if ($feedbackCount -gt 0) { "$feedbackCount pending" } else { '-' }

        $line = "  {0,-20} {1,-10} {2,-22} {3,-22} {4,-22} {5,-15} {6}" -f `
            $a.Id, $statusStr, $schedStr, $lastRunStr, $nextRunStr, $qStr, $fbStr
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

        $nextRunStr = if ($null -eq $a.Config.schedule) { 'n/a' } else { '-' }
        try {
            $schedHt  = ConvertTo-ScheduleHashtable -Schedule $a.Config.schedule
            $nextRun  = Get-NextRunTime -Schedule $schedHt -LastRun $lastRunDt -Now $now
            if ($null -ne $nextRun) {
                $nextRunStr = $nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            }
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

# ── Subcommand: questions ────────────────────────────────────────────

function Invoke-QuestionsCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    $stateRoot = Join-Path $PersonalRepoPath '.cronstate'
    $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId $AgentId

    if ($pending.Count -eq 0) {
        Write-Host "No pending questions." -ForegroundColor Yellow
        return
    }

    # Group by agent
    $byAgent = @{}
    foreach ($q in $pending) {
        $aid = if ([string]::IsNullOrWhiteSpace($q.agentId)) {
            if (-not [string]::IsNullOrWhiteSpace($AgentId)) { $AgentId } else { 'unknown' }
        } else { $q.agentId }
        if (-not $byAgent.ContainsKey($aid)) { $byAgent[$aid] = @() }
        $byAgent[$aid] += $q
    }

    Write-Host ""
    Write-Host "Pending questions ($($pending.Count) total):" -ForegroundColor Cyan
    Write-Host ""

    $allQuestions = @()
    $idx = 1
    foreach ($aid in $byAgent.Keys) {
        Write-Host "  Agent: $aid" -ForegroundColor White
        foreach ($q in $byAgent[$aid]) {
            $allQuestions += $q
            $expStr = ''
            if ($q.expiresAt) {
                try {
                    $exp = [datetime]::Parse($q.expiresAt)
                    $daysLeft = [math]::Ceiling(($exp - [datetime]::UtcNow).TotalDays)
                    if ($daysLeft -gt 0) { $expStr = " (expires in ${daysLeft}d)" }
                    else { $expStr = " (expiring soon)" }
                }
                catch { }
            }
            Write-Host "    $idx) $($q.question)$expStr" -ForegroundColor Gray
            if ($q.context) {
                Write-Host "       Context: $($q.context)" -ForegroundColor DarkGray
            }
            $idx++
        }
        Write-Host ""
    }

    Write-Host "  0) Back (answer later)"
    $pick = Read-Host "Select a question to answer"

    if ($pick -eq '0' -or [string]::IsNullOrWhiteSpace($pick)) { return }

    $qIdx = 0
    if (-not [int]::TryParse($pick, [ref]$qIdx) -or $qIdx -lt 1 -or $qIdx -gt $allQuestions.Count) {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        return
    }

    $selected = $allQuestions[$qIdx - 1]
    Invoke-AnswerQuestion -Question $selected -StateRoot $stateRoot
}

function Invoke-AnswerQuestion {
    <#
    .SYNOPSIS
        Presents a single question to the user with choices + freeform option.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Question,
        [Parameter(Mandatory)][string]$StateRoot
    )

    Write-Host ""
    Write-Host "Question: $($Question.question)" -ForegroundColor Cyan
    if ($Question.context) {
        Write-Host "Context: $($Question.context)" -ForegroundColor DarkGray
    }
    Write-Host ""

    $choices = @($Question.choices)
    $hasChoices = $choices.Count -gt 0

    if ($hasChoices) {
        for ($i = 0; $i -lt $choices.Count; $i++) {
            $label = $choices[$i]
            $rec = ''
            if ($Question.recommended -and $label -eq $Question.recommended) {
                $rec = ' (Recommended)'
            }
            Write-Host "  $($i + 1)) $label$rec"
        }
        Write-Host "  $($choices.Count + 1)) Custom response..."
        Write-Host ""

        $pick = Read-Host "Select"
        $pickIdx = 0
        if ([int]::TryParse($pick, [ref]$pickIdx)) {
            if ($pickIdx -ge 1 -and $pickIdx -le $choices.Count) {
                $answer = $choices[$pickIdx - 1]
            }
            elseif ($pickIdx -eq $choices.Count + 1) {
                $answer = Read-Host "Your response"
            }
            else {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Yellow
            return
        }
    }
    else {
        $answer = Read-Host "Your response"
    }

    if ([string]::IsNullOrWhiteSpace($answer)) {
        Write-Host "No answer provided. Question left unanswered." -ForegroundColor Yellow
        return
    }

    Set-QuestionAnswer -StateRoot $StateRoot -AgentId $Question.agentId `
        -QuestionId $Question.id -Answer $answer

    Write-Host "Answer recorded. The agent will receive it on its next run." -ForegroundColor Green
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

# ── Subcommand: migrate ───────────────────────────────────────────────

function Invoke-MigrateCommand {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "CronAgents Migration: personal-branches → personal-repo" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The branch-based model (cronagents/<user>) has been replaced with a" -ForegroundColor White
    Write-Host "standalone personal repo at: $PersonalRepoPath" -ForegroundColor White
    Write-Host ""
    Write-Host "Migration steps:" -ForegroundColor Yellow
    Write-Host "  1. Run './cronagents.ps1 install' to initialize the personal repo."
    Write-Host "  2. Copy any custom agent .md files from your old branch into:"
    Write-Host "     $PersonalRepoPath\agents\"
    Write-Host "  3. Feedback history will start fresh in the personal repo."
    Write-Host "  4. The old cronagents/<user> branch can be deleted once migrated."
    Write-Host ""
}

# ── Subcommand: dashboard ─────────────────────────────────────────────

function Invoke-DashboardCommand {
    [CmdletBinding()]
    param()

    $dashboardScript = Join-Path $RepoRoot 'scheduler/Start-DashboardServer.ps1'
    if (-not (Test-Path -LiteralPath $dashboardScript)) {
        Write-Host "Start-DashboardServer.ps1 not found at: $dashboardScript" -ForegroundColor Red
        return
    }

    Write-Host "Starting HTML dashboard..." -ForegroundColor Cyan
    try {
        & $dashboardScript -RepoRoot $RepoRoot
    }
    catch {
        Write-Host "Dashboard failed: $_" -ForegroundColor Red
    }
}

# ── Clear command ────────────────────────────────────────────────────

function Invoke-ClearCommand {
    [CmdletBinding()]
    param([string]$AgentId)

    if ($AgentId) {
        # Clear all runs for a specific agent
        $agents = Get-Agents
        $match = $agents | Where-Object { $_.Id -eq $AgentId } | Select-Object -First 1
        if (-not $match) {
            Write-Host "Unknown agent: '$AgentId'" -ForegroundColor Red
            return
        }

        $runs = @(Get-RunHistory -RunsRoot $RunsRoot -AgentId $AgentId)
        if ($runs.Count -eq 0) {
            Write-Host "  No run history for agent '$AgentId'." -ForegroundColor Yellow
            return
        }

        Write-Host "This will delete $($runs.Count) run(s) for agent '$AgentId'." -ForegroundColor Yellow
        $confirm = Read-Host "Confirm? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }

        $result = Clear-RunHistory -RunsRoot $RunsRoot -AgentId $AgentId
        Write-Host "  Deleted $($result.DeletedCount) run(s)." -ForegroundColor Green
    }
    else {
        # Clear all runs
        $runs = @(Get-RunHistory -RunsRoot $RunsRoot)
        if ($runs.Count -eq 0) {
            Write-Host "  No run history found." -ForegroundColor Yellow
            return
        }

        Write-Host "This will delete ALL $($runs.Count) run(s) for every agent." -ForegroundColor Yellow
        $confirm = Read-Host "Confirm? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }

        $result = Clear-RunHistory -RunsRoot $RunsRoot -All
        Write-Host "  Deleted $($result.DeletedCount) run(s)." -ForegroundColor Green
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
    Write-Host "  questions [agent-id] View and answer pending agent questions"
    Write-Host "  clear [agent-id]     Clear run history (all or per agent)"
    Write-Host "  dashboard             Open the HTML dashboard in a browser"
    Write-Host "  doctor               Run health checks"
    Write-Host "  install              Register scheduled task & init personal repo"
    Write-Host "  uninstall            Remove scheduled task"
    Write-Host "  migrate              Show migration guide from branch model"
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
        # Count pending questions for menu badge
        $questionCount = 0
        try {
            $stateRoot = Join-Path $PersonalRepoPath '.cronstate'
            $questionCount = (Get-PendingQuestions -StateRoot $stateRoot).Count
        }
        catch { }
        $qBadge = if ($questionCount -gt 0) { " ($questionCount pending)" } else { '' }

        Write-Host ""
        Write-Host (Get-SafeHeader) -ForegroundColor Cyan
        Write-Host ([char]0x2500 * 30)
        Write-Host " 1) Status & upcoming runs"
        Write-Host " 2) Trigger ad-hoc run"
        Write-Host " 3) Pause / Resume"
        Write-Host " 4) View run history"
        Write-Host " 5) Clear run history"
        Write-Host " 6) Submit feedback"
        Write-Host " 7) Pending questions$qBadge"
        Write-Host " 8) Health check (doctor)"
        Write-Host " 9) Open HTML dashboard"
        Write-Host "10) Exit"
        Write-Host ([char]0x2500 * 30)

        $choice = Read-Host "Select [1-10]"

        switch ($choice) {
            '1'  { Invoke-StatusCommand }
            '2'  { Invoke-TuiAdHocRun }
            '3'  { Invoke-TuiPauseResume }
            '4'  { Invoke-TuiRunHistory }
            '5'  { Invoke-TuiClearRuns }
            '6'  { Invoke-TuiFeedback }
            '7'  { Invoke-TuiQuestions }
            '8'  { Invoke-DoctorCommand }
            '9'  { Invoke-DashboardCommand }
            '10' { Write-Host "Goodbye." -ForegroundColor Cyan; return }
            default { Write-Host "Invalid selection. Please enter 1-10." -ForegroundColor Yellow }
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

# ── TUI: Clear run history ──────────────────────────────────────────

function Invoke-TuiClearRuns {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "Clear run history:" -ForegroundColor Cyan
    Write-Host " 1) Clear a single run"
    Write-Host " 2) Clear all runs for one agent"
    Write-Host " 3) Clear all run history"
    Write-Host " 0) Back"

    $pick = Read-Host "Select [0-3]"

    switch ($pick) {
        '1' {
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

            $runPick = Read-Host "Select run to delete"
            if ($runPick -eq '0' -or [string]::IsNullOrWhiteSpace($runPick)) { return }

            $idx = 0
            if (-not [int]::TryParse($runPick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $runs.Count) {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                return
            }

            $selected = $runs[$idx - 1]
            $runId = Split-Path $selected.RunDirectory -Leaf
            $confirm = Read-Host "Delete run '$runId'? [y/N]"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                return
            }

            $result = Clear-RunHistory -RunsRoot $RunsRoot -RunId $runId
            Write-Host "  Deleted $($result.DeletedCount) run." -ForegroundColor Green
        }
        '2' {
            $agents = Get-Agents
            if ($agents.Count -eq 0) {
                Write-Host "  No agents discovered." -ForegroundColor Yellow
                return
            }

            Write-Host ""
            Write-Host "Select agent:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $agents.Count; $i++) {
                $name = if ($agents[$i].Config.name) { $agents[$i].Config.name } else { $agents[$i].Id }
                Write-Host "  $($i + 1)) $name ($($agents[$i].Id))"
            }
            Write-Host "  0) Back"

            $agentPick = Read-Host "Select"
            if ($agentPick -eq '0' -or [string]::IsNullOrWhiteSpace($agentPick)) { return }

            $idx = 0
            if (-not [int]::TryParse($agentPick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $agents.Count) {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                return
            }

            $agentId = $agents[$idx - 1].Id
            $runs = @(Get-RunHistory -RunsRoot $RunsRoot -AgentId $agentId)
            if ($runs.Count -eq 0) {
                Write-Host "  No run history for agent '$agentId'." -ForegroundColor Yellow
                return
            }

            $confirm = Read-Host "Delete $($runs.Count) run(s) for '$agentId'? [y/N]"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                return
            }

            $result = Clear-RunHistory -RunsRoot $RunsRoot -AgentId $agentId
            Write-Host "  Deleted $($result.DeletedCount) run(s)." -ForegroundColor Green
        }
        '3' {
            $runs = @(Get-RunHistory -RunsRoot $RunsRoot)
            if ($runs.Count -eq 0) {
                Write-Host "  No run history found." -ForegroundColor Yellow
                return
            }

            Write-Host "This will delete ALL $($runs.Count) run(s) across every agent." -ForegroundColor Yellow
            $confirm = Read-Host "Confirm? [y/N]"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                return
            }

            $result = Clear-RunHistory -RunsRoot $RunsRoot -All
            Write-Host "  Deleted $($result.DeletedCount) run(s)." -ForegroundColor Green
        }
        default { return }
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

# ── TUI: Pending questions ──────────────────────────────────────────

function Invoke-TuiQuestions {
    [CmdletBinding()]
    param()

    $stateRoot = Join-Path $PersonalRepoPath '.cronstate'
    $pending = Get-PendingQuestions -StateRoot $stateRoot

    if ($pending.Count -eq 0) {
        Write-Host "  No pending questions." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Pending questions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $q = $pending[$i]
        $agentLabel = if ($q.agentId) { "[$($q.agentId)]" } else { '' }
        Write-Host "  $($i + 1)) $agentLabel $($q.question)"
    }
    Write-Host "  0) Back"

    $pick = Read-Host "Select a question to answer"
    if ($pick -eq '0' -or [string]::IsNullOrWhiteSpace($pick)) { return }

    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $pending.Count) {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        return
    }

    $selected = $pending[$idx - 1]
    Invoke-AnswerQuestion -Question $selected -StateRoot $stateRoot
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
        'questions' { Invoke-QuestionsCommand -AgentId $Argument }
        'clear'     { Invoke-ClearCommand -AgentId $Argument }
        'dashboard' { Invoke-DashboardCommand }
        'doctor'    { Invoke-DoctorCommand }
        'install'   { Invoke-InstallCommand }
        'uninstall' { Invoke-UninstallCommand }
        'migrate'   { Invoke-MigrateCommand }
        default {
            Write-Host "Unknown command: '$Command'" -ForegroundColor Red
            Show-Usage
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}
