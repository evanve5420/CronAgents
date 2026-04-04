<#
.SYNOPSIS
    CronAgents HTML Dashboard — lightweight HTTP server.
.DESCRIPTION
    Starts a System.Net.HttpListener on localhost serving the HTML dashboard
    and a JSON API that mirrors the CLI commands. All API handlers call the
    same shared lib functions used by cronagents.ps1 and the scheduler.

    Designed to run standalone (not embedded in the scheduler loop).
.PARAMETER RepoRoot
    Path to the CronAgents repository root. Defaults to the parent of the
    scheduler/ directory.
.PARAMETER Port
    Port to listen on. Defaults to 9077.
.PARAMETER NoBrowser
    If set, does not auto-open the browser on startup.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$Port = 9077,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Bootstrap ────────────────────────────────────────────────────────
if (-not $RepoRoot) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

$ModulePath = Join-Path $PSScriptRoot 'lib/CronAgents.psd1'
Import-Module $ModulePath -Force

$ConfigPath = Join-Path $RepoRoot 'cronagents.json'
$GlobalConfig = Import-CronAgentsConfig -ConfigPath $ConfigPath
$PersonalRepoPath = Get-PersonalRepoPath -ConfigPath $GlobalConfig.personalRepo.path
$StateFile = Join-Path $PersonalRepoPath '.cronstate/state.json'
$RunsRoot  = Join-Path $PersonalRepoPath '.cronstate/runs'
$StateRoot = Join-Path $PersonalRepoPath '.cronstate'

$InvokeScriptPath = Join-Path $PSScriptRoot 'Invoke-ScheduledAgent.ps1'
$DashboardHtmlPath = Join-Path $PSScriptRoot 'dashboard.html'

# ── Helpers ──────────────────────────────────────────────────────────

function script:Normalize-IsoTimestamp {
    [OutputType([string])]
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString('o')
    }

    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        }
        return $dt.ToUniversalTime().ToString('o')
    }

    try {
        $text = [string]$Value
        if ($text -match 'Z$|[+\-]\d{2}:\d{2}$') {
            $parsed = [datetimeoffset]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
            return $parsed.ToUniversalTime().ToString('o')
        }

        $parsed = [datetime]::ParseExact($text, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        return ([datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)).ToString('o')
    }
    catch {
        return [string]$Value
    }
}

function script:Get-AgentsList {
    [OutputType([object[]])]
    param()
    $agents = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
    $state  = Get-AgentState -StateFile $StateFile
    $now    = [datetime]::UtcNow

    $result = @()
    foreach ($a in $agents) {
        $agentState = if ($state.agents.ContainsKey($a.Id)) { $state.agents[$a.Id] } else { $null }
        $enabled    = if ($agentState -and $null -ne $agentState.enabled) { $agentState.enabled } else { $true }

        $lastRunStr = $null
        $lastRunDt  = $null
        if ($agentState -and $agentState.lastRun) {
            try {
                $lastRunDt  = [datetime]::Parse($agentState.lastRun)
                $lastRunStr = $lastRunDt.ToString('o')
            } catch { }
        }

        $nextRunStr = $null
        try {
            $schedHt = @{ type = $a.Config.schedule.type }
            if ($a.Config.schedule.PSObject.Properties['every']) { $schedHt['every'] = $a.Config.schedule.every }
            if ($a.Config.schedule.PSObject.Properties['time'])  { $schedHt['time']  = $a.Config.schedule.time }
            if ($a.Config.schedule.PSObject.Properties['day'])   { $schedHt['day']   = $a.Config.schedule.day }
            $nextRun = Get-NextRunTime -Schedule $schedHt -LastRun $lastRunDt -Now $now
            $nextRunStr = $nextRun.ToString('o')
        } catch { }

        $result += [ordered]@{
            id       = $a.Id
            name     = $a.Config.name
            schedule = [ordered]@{
                type  = $a.Config.schedule.type
                every = if ($a.Config.schedule.PSObject.Properties['every']) { $a.Config.schedule.every } else { $null }
                time  = if ($a.Config.schedule.PSObject.Properties['time'])  { $a.Config.schedule.time }  else { $null }
                day   = if ($a.Config.schedule.PSObject.Properties['day'])   { $a.Config.schedule.day }   else { $null }
            }
            enabled  = $enabled
            lastRun  = $lastRunStr
            nextRun  = $nextRunStr
        }
    }
    return $result
}

function script:Get-StatusPayload {
    [OutputType([hashtable])]
    param()
    $state = Get-AgentState -StateFile $StateFile
    return [ordered]@{
        schedulerPaused = $state.schedulerPaused
        agents          = @(script:Get-AgentsList)
        timestamp       = [datetime]::UtcNow.ToString('o')
    }
}

function script:Get-RunsPayload {
    [OutputType([object[]])]
    param([string]$AgentId)
    $maxRunHistory = if ($GlobalConfig.PSObject.Properties['maxRunHistory'] -and $null -ne $GlobalConfig.maxRunHistory) {
        [int]$GlobalConfig.maxRunHistory
    } else {
        50
    }
    $params = @{ RunsRoot = $RunsRoot; MaxResults = $maxRunHistory }
    if ($AgentId) { $params['AgentId'] = $AgentId }
    $runs = @(Get-RunHistory @params)

    $result = @()
    foreach ($r in $runs) {
        $dirName = Split-Path $r.RunDirectory -Leaf
        $meta = $null
        $hasOutput = Test-Path -LiteralPath (Join-Path $r.RunDirectory 'output.md')
        $isIncomplete = $false
        if ($r.Meta) {
            $meta = [ordered]@{
                agentId           = $r.Meta.agentId
                agentName         = if ($r.Meta.PSObject.Properties['agentName']) { $r.Meta.agentName } else { $null }
                prompt            = if ($r.Meta.PSObject.Properties['prompt']) { $r.Meta.prompt } else { $null }
                startTime         = if ($r.Meta.PSObject.Properties['startTime']) { script:Normalize-IsoTimestamp -Value $r.Meta.startTime } else { $null }
                endTime           = if ($r.Meta.PSObject.Properties['endTime']) { script:Normalize-IsoTimestamp -Value $r.Meta.endTime } else { $null }
                exitCode          = if ($r.Meta.PSObject.Properties['exitCode']) { $r.Meta.exitCode } else { $null }
                timedOut          = if ($r.Meta.PSObject.Properties['timedOut']) { $r.Meta.timedOut } else { $false }
                retryAttempt      = if ($r.Meta.PSObject.Properties['retryAttempt']) { $r.Meta.retryAttempt } else { 0 }
                feedbackProcessed = if ($r.Meta.PSObject.Properties['feedbackProcessed']) { $r.Meta.feedbackProcessed } else { $false }
            }

            if (($null -eq $meta.exitCode) -and [string]::IsNullOrEmpty($meta.endTime) -and $hasOutput) {
                $isIncomplete = $true
            }
        }

        # Read summary with frontmatter parsing (full content available via GET /api/runs/:id)
        $summaryExcerpt = $null
        $attention = $false
        $headline = $null
        if ($r.HasSummary) {
            $summaryPath = Join-Path $r.RunDirectory 'summary.md'
            try {
                $parsed = Read-SummaryFrontmatter -Path $summaryPath
                $attention = $parsed.Attention
                $headline  = $parsed.Headline
                # Use headline for the excerpt; fall back to first line of body
                if ($headline) {
                    $summaryExcerpt = $headline
                } elseif ($parsed.Body) {
                    $firstLine = ($parsed.Body -split '\r?\n', 2)[0].TrimEnd()
                    if ($null -ne $firstLine) { $summaryExcerpt = $firstLine }
                }
            } catch {
                Write-CronAgentsLog -Level 'debug' -Message "Failed to parse summary for run list: $summaryPath — $_"
            }
        }

        $result += [ordered]@{
            id                = $dirName
            agentId           = $r.AgentId
            timestamp         = $r.Timestamp.ToUniversalTime().ToString('o')
            meta              = $meta
            hasOutput         = $hasOutput
            isIncomplete      = $isIncomplete
            hasFeedback       = $r.HasFeedback
            feedbackProcessed = $r.FeedbackProcessed
            hasSummary        = $r.HasSummary
            summary           = $summaryExcerpt
            attention         = $attention
            headline          = $headline
        }
    }
    return $result
}

function script:Test-SafeIdentifier {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Value)
    return (Test-CronAgentsSafeIdentifier -Value $Value)
}

function script:Get-RunDetailPayload {
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$RunId)

    $resolvedRun = Resolve-CronAgentsRunPath -RunId $RunId -RunsRoot $RunsRoot
    if (-not $resolvedRun.IsValid) {
        return [PSCustomObject]@{
            IsValid = $false
            Exists  = $false
            Payload = $null
        }
    }
    if (-not $resolvedRun.Exists) {
        return [PSCustomObject]@{
            IsValid = $true
            Exists  = $false
            Payload = $null
        }
    }

    $runDir = $resolvedRun.Path

    $meta = $null
    $metaPath = Join-Path $runDir 'meta.json'
    if (Test-Path -LiteralPath $metaPath) {
        try { $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }

    $hasOutput = Test-Path -LiteralPath (Join-Path $runDir 'output.md')
    $isIncomplete = $false
    if ($meta -and
        ($null -eq $meta.PSObject.Properties['exitCode'] -or $null -eq $meta.exitCode) -and
        ($null -eq $meta.PSObject.Properties['endTime'] -or [string]::IsNullOrEmpty($meta.endTime)) -and
        $hasOutput) {
        $isIncomplete = $true
    }

    $summary = $null
    $attention = $false
    $headline = $null
    $summaryPath = Join-Path $runDir 'summary.md'
    if (Test-Path -LiteralPath $summaryPath) {
        $parsed = Read-SummaryFrontmatter -Path $summaryPath
        $summary   = $parsed.Body
        $attention = $parsed.Attention
        $headline  = $parsed.Headline
    }

    $output = $null
    $outputPath = Join-Path $runDir 'output.md'
    if (Test-Path -LiteralPath $outputPath) {
        try { $output = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 } catch { }
    }

    $schedulerLog = $null
    $logPath = Join-Path $runDir 'scheduler.log'
    if (Test-Path -LiteralPath $logPath) {
        try { $schedulerLog = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } catch { }
    }

    $feedback = $null
    $feedbackPath = Join-Path $runDir 'feedback.md'
    if (Test-Path -LiteralPath $feedbackPath) {
        try { $feedback = Get-Content -LiteralPath $feedbackPath -Raw -Encoding UTF8 } catch { }
    }

    $feedbackResult = $null
    $frPath = Join-Path $runDir 'feedback-result.md'
    if (Test-Path -LiteralPath $frPath) {
        try { $feedbackResult = Get-Content -LiteralPath $frPath -Raw -Encoding UTF8 } catch { }
    }

    if ($meta) {
        if ($meta.PSObject.Properties['startTime']) {
            $meta.startTime = script:Normalize-IsoTimestamp -Value $meta.startTime
        }
        if ($meta.PSObject.Properties['endTime']) {
            $meta.endTime = script:Normalize-IsoTimestamp -Value $meta.endTime
        }
    }

    return [PSCustomObject]@{
        IsValid = $true
        Exists  = $true
        Payload = [ordered]@{
            id             = $RunId
            runDirectory   = $runDir
            meta           = $meta
            hasOutput      = $hasOutput
            isIncomplete   = $isIncomplete
            summary        = $summary
            attention      = $attention
            headline       = $headline
            output         = $output
            schedulerLog   = $schedulerLog
            feedback       = $feedback
            feedbackResult = $feedbackResult
        }
    }
}

function script:Get-QuestionsPayload {
    [OutputType([object[]])]
    param([string]$AgentId)
    $params = @{ StateRoot = $StateRoot }
    if ($AgentId) { $params['AgentId'] = $AgentId }
    $pending = Get-PendingQuestions @params
    return @($pending)
}

# ── HTTP Response Helpers ────────────────────────────────────────────

function script:Send-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [AllowNull()]
        $Body,
        [int]$StatusCode = 200
    )
    # Handle empty arrays explicitly — ConvertTo-Json produces '' for @()
    if ($Body -is [System.Array] -and $Body.Count -eq 0) {
        $json = '[]'
    } else {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        if ([string]::IsNullOrEmpty($json)) { $json = 'null' }
    }
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function script:Send-TextResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Text,
        [string]$ContentType = 'text/plain',
        [int]$StatusCode = 200
    )
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "$ContentType; charset=utf-8"
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function script:Send-ErrorResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Message,
        [int]$StatusCode = 400
    )
    script:Send-JsonResponse -Response $Response -Body ([ordered]@{ error = $Message }) -StatusCode $StatusCode
}

function script:Read-RequestBody {
    [OutputType([string])]
    param([System.Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -le 0) { return '' }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

# ── Route Handler ────────────────────────────────────────────────────

function script:Invoke-Route {
    param([System.Net.HttpListenerContext]$Context)

    $request  = $Context.Request
    $response = $Context.Response
    $method   = $request.HttpMethod
    $path     = $request.Url.AbsolutePath.TrimEnd('/')

    try {
        # ── Static files ─────────────────────────────────────────
        if ($method -eq 'GET' -and ($path -eq '' -or $path -eq '/' -or $path -eq '/dashboard.html')) {
            if (-not (Test-Path -LiteralPath $DashboardHtmlPath)) {
                script:Send-ErrorResponse -Response $response -Message 'dashboard.html not found' -StatusCode 404
                return
            }
            $html = [System.IO.File]::ReadAllText($DashboardHtmlPath, [System.Text.Encoding]::UTF8)
            script:Send-TextResponse -Response $response -Text $html -ContentType 'text/html'
            return
        }

        # ── GET /api/status ──────────────────────────────────────
        if ($method -eq 'GET' -and $path -eq '/api/status') {
            $payload = script:Get-StatusPayload
            script:Send-JsonResponse -Response $response -Body $payload
            return
        }

        # ── GET /api/agents ──────────────────────────────────────
        if ($method -eq 'GET' -and $path -eq '/api/agents') {
            $payload = @(script:Get-AgentsList)
            script:Send-JsonResponse -Response $response -Body $payload
            return
        }

        # ── GET /api/runs ────────────────────────────────────────
        if ($method -eq 'GET' -and $path -eq '/api/runs') {
            $agentFilter = $request.QueryString['agent']
            $payload = @(script:Get-RunsPayload -AgentId $agentFilter)
            script:Send-JsonResponse -Response $response -Body $payload
            return
        }

        # ── GET /api/runs/:id ────────────────────────────────────
        if ($method -eq 'GET' -and $path -match '^/api/runs/(.+)$') {
            $runId = $Matches[1]
            $detail = script:Get-RunDetailPayload -RunId $runId
            if (-not $detail.IsValid) {
                script:Send-ErrorResponse -Response $response -Message 'Invalid run ID format' -StatusCode 400
                return
            }
            if (-not $detail.Exists) {
                script:Send-ErrorResponse -Response $response -Message 'Run not found' -StatusCode 404
                return
            }
            script:Send-JsonResponse -Response $response -Body $detail.Payload
            return
        }

        # ── GET /api/questions ───────────────────────────────────
        if ($method -eq 'GET' -and $path -eq '/api/questions') {
            $agentFilter = $request.QueryString['agent']
            $payload = @(script:Get-QuestionsPayload -AgentId $agentFilter)
            script:Send-JsonResponse -Response $response -Body $payload
            return
        }

        # ── POST /api/run/:agent ─────────────────────────────────
        if ($method -eq 'POST' -and $path -match '^/api/run/(.+)$') {
            $agentId = $Matches[1]
            $agents  = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
            $match   = $agents | Where-Object { $_.Id -eq $agentId } | Select-Object -First 1
            if (-not $match) {
                script:Send-ErrorResponse -Response $response -Message "Unknown agent: $agentId" -StatusCode 404
                return
            }

            # Fire and forget in a background job so we don't block the HTTP response
            # Use script-level paths (derived from $PSScriptRoot at load time) so they
            # work even when $RepoRoot points at a personal-repo or test-env directory.
            $invokeScript = $InvokeScriptPath
            $modulePath   = $ModulePath
            $job = Start-Job -ScriptBlock {
                param($script, $module, $configPath, $id, $rr, $prp, $rroot)

                Import-Module $module -Force
                $globalConfig = Import-CronAgentsConfig -ConfigPath $configPath
                $agentConfig = @(Get-AgentConfigs -RepoRoot $rr -PersonalRepoPath $prp) |
                    Where-Object { $_.Id -eq $id } |
                    Select-Object -First 1

                if (-not $agentConfig) {
                    throw "Unknown agent in dashboard background job: $id"
                }

                & $script -AgentId $id -AgentConfig $agentConfig.Config -GlobalConfig $globalConfig `
                          -RepoRoot $rr -PersonalRepoPath $prp -RunsRoot $rroot
            } -ArgumentList $invokeScript, $modulePath, $ConfigPath, $match.Id, $RepoRoot, $PersonalRepoPath, $RunsRoot
            # Auto-cleanup: remove job once it completes
            Register-ObjectEvent -InputObject $job -EventName StateChanged -Action {
                Remove-Job -Id $Sender.Id -Force -ErrorAction SilentlyContinue
                $eventSubscriber | Unregister-Event
            } | Out-Null

            script:Send-JsonResponse -Response $response -Body ([ordered]@{
                ok      = $true
                message = "Agent '$agentId' run triggered"
            })
            return
        }

        # ── POST /api/pause/:agent (or /api/pause for global) ────
        if ($method -eq 'POST' -and $path -match '^/api/pause(?:/(.+))?$') {
            $agentId = $Matches[1]
            if ($agentId) {
                $agents  = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
                $match   = $agents | Where-Object { $_.Id -eq $agentId }
                if (-not $match) {
                    script:Send-ErrorResponse -Response $response -Message "Unknown agent: $agentId" -StatusCode 404
                    return
                }
                Set-AgentState -StateFile $StateFile -AgentId $agentId -Enabled $false
                script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = "Agent '$agentId' paused" })
            } else {
                Set-AgentState -StateFile $StateFile -SchedulerPaused $true
                script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = 'Scheduler paused' })
            }
            return
        }

        # ── POST /api/resume/:agent (or /api/resume for global) ──
        if ($method -eq 'POST' -and $path -match '^/api/resume(?:/(.+))?$') {
            $agentId = $Matches[1]
            if ($agentId) {
                $agents  = @(Get-AgentConfigs -RepoRoot $RepoRoot -PersonalRepoPath $PersonalRepoPath)
                $match   = $agents | Where-Object { $_.Id -eq $agentId }
                if (-not $match) {
                    script:Send-ErrorResponse -Response $response -Message "Unknown agent: $agentId" -StatusCode 404
                    return
                }
                Set-AgentState -StateFile $StateFile -AgentId $agentId -Enabled $true
                script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = "Agent '$agentId' resumed" })
            } else {
                Set-AgentState -StateFile $StateFile -SchedulerPaused $false
                script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = 'Scheduler resumed' })
            }
            return
        }

        # ── POST /api/feedback/:runId ────────────────────────────
        if ($method -eq 'POST' -and $path -match '^/api/feedback/(.+)$') {
            $runId = $Matches[1]

            $resolvedRun = Resolve-CronAgentsRunPath -RunId $runId -RunsRoot $RunsRoot
            if (-not $resolvedRun.IsValid) {
                script:Send-ErrorResponse -Response $response -Message 'Invalid run ID format' -StatusCode 400
                return
            }

            if (-not $resolvedRun.Exists) {
                script:Send-ErrorResponse -Response $response -Message 'Run not found' -StatusCode 404
                return
            }

            $runDir = $resolvedRun.Path

            $body = script:Read-RequestBody -Request $request
            if (-not $body) {
                script:Send-ErrorResponse -Response $response -Message 'Request body required' -StatusCode 400
                return
            }

            try {
                $bodyObj = $body | ConvertFrom-Json
                $feedbackText = $bodyObj.feedback
            } catch {
                script:Send-ErrorResponse -Response $response -Message 'Invalid JSON body' -StatusCode 400
                return
            }

            if (-not $feedbackText) {
                script:Send-ErrorResponse -Response $response -Message 'feedback field required' -StatusCode 400
                return
            }

            $feedbackPath = Join-Path $runDir 'feedback.md'
            Set-Content -LiteralPath $feedbackPath -Value $feedbackText -Encoding UTF8
            script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = 'Feedback saved' })
            return
        }

        # ── POST /api/questions/:agent/:questionId ───────────────
        if ($method -eq 'POST' -and $path -match '^/api/questions/([^/]+)/(.+)$') {
            $agentId    = $Matches[1]
            $questionId = $Matches[2]

            # Validate identifiers are filename-safe
            if (-not (script:Test-SafeIdentifier -Value $agentId) -or -not (script:Test-SafeIdentifier -Value $questionId)) {
                script:Send-ErrorResponse -Response $response -Message 'Invalid agent or question ID' -StatusCode 400
                return
            }

            $body = script:Read-RequestBody -Request $request
            if (-not $body) {
                script:Send-ErrorResponse -Response $response -Message 'Request body required' -StatusCode 400
                return
            }

            try {
                $bodyObj = $body | ConvertFrom-Json
                $answer = $bodyObj.answer
            } catch {
                script:Send-ErrorResponse -Response $response -Message 'Invalid JSON body' -StatusCode 400
                return
            }

            if (-not $answer) {
                script:Send-ErrorResponse -Response $response -Message 'answer field required' -StatusCode 400
                return
            }

            Set-QuestionAnswer -StateRoot $StateRoot -AgentId $agentId -QuestionId $questionId -Answer $answer
            script:Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true; message = 'Answer recorded' })
            return
        }

        # ── DELETE /api/runs (all or per agent via ?agent=X) ─────
        if ($method -eq 'DELETE' -and $path -eq '/api/runs') {
            $agentFilter = $request.QueryString['agent']
            if ($agentFilter) {
                if (-not (script:Test-SafeIdentifier -Value $agentFilter)) {
                    script:Send-ErrorResponse -Response $response -Message 'Invalid agent ID format' -StatusCode 400
                    return
                }
                $result = Clear-RunHistory -RunsRoot $RunsRoot -AgentId $agentFilter
            }
            else {
                $result = Clear-RunHistory -RunsRoot $RunsRoot -All
            }

            $label = if ($agentFilter) { " for agent '$agentFilter'" } else { '' }
            if ($result.Errors.Count -gt 0 -and $result.DeletedCount -eq 0) {
                script:Send-JsonResponse -Response $response -Body ([ordered]@{
                    ok      = $false
                    message = "Failed to clear runs$label"
                    deleted = 0
                    skipped = $result.SkippedCount
                    errors  = $result.Errors
                }) -StatusCode 500
            }
            elseif ($result.Errors.Count -gt 0) {
                script:Send-JsonResponse -Response $response -Body ([ordered]@{
                    ok      = $true
                    message = "Cleared $($result.DeletedCount) run(s)$label (some failed)"
                    deleted = $result.DeletedCount
                    skipped = $result.SkippedCount
                    errors  = $result.Errors
                })
            }
            else {
                script:Send-JsonResponse -Response $response -Body ([ordered]@{
                    ok      = $true
                    message = "Cleared $($result.DeletedCount) run(s)$label"
                    deleted = $result.DeletedCount
                    skipped = $result.SkippedCount
                })
            }
            return
        }

        # ── DELETE /api/runs/:id ─────────────────────────────────
        if ($method -eq 'DELETE' -and $path -match '^/api/runs/(.+)$') {
            $runId = $Matches[1]

            $resolvedRun = Resolve-CronAgentsRunPath -RunId $runId -RunsRoot $RunsRoot
            if (-not $resolvedRun.IsValid) {
                script:Send-ErrorResponse -Response $response -Message 'Invalid run ID format' -StatusCode 400
                return
            }

            if (-not $resolvedRun.Exists) {
                script:Send-ErrorResponse -Response $response -Message 'Run not found' -StatusCode 404
                return
            }

            $result = Clear-RunHistory -RunsRoot $RunsRoot -RunId $runId
            if ($result.Errors.Count -gt 0) {
                script:Send-JsonResponse -Response $response -Body ([ordered]@{
                    ok      = $false
                    message = $result.Errors[0]
                    deleted = $result.DeletedCount
                }) -StatusCode 409
            }
            elseif ($result.DeletedCount -eq 0) {
                script:Send-ErrorResponse -Response $response -Message 'Run could not be deleted' -StatusCode 409
            }
            else {
                script:Send-JsonResponse -Response $response -Body ([ordered]@{
                    ok      = $true
                    message = "Deleted run '$runId'"
                    deleted = $result.DeletedCount
                })
            }
            return
        }

        # ── 404 ──────────────────────────────────────────────────
        script:Send-ErrorResponse -Response $response -Message "Not found: $path" -StatusCode 404

    } catch {
        Write-CronAgentsLog -Level 'ERROR' -Message "HTTP handler error on $method $path : $_"
        try {
            script:Send-ErrorResponse -Response $response -Message 'Internal server error' -StatusCode 500
        } catch {
            # Response may already be closed
        }
    }
}

# ── Server Loop ──────────────────────────────────────────────────────

$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "Failed to start dashboard server on port $Port`: $_" -ForegroundColor Red
    Write-Host "Is another process using port $Port?" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "CronAgents Dashboard running at $prefix" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) {
    try { Start-Process $prefix } catch { }
}

# Graceful shutdown
$shutdownRequested = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:shutdownRequested = $true
}

try {
    while ($listener.IsListening -and -not $shutdownRequested) {
        # Use async to allow Ctrl+C responsiveness
        $task = $listener.GetContextAsync()
        while (-not $task.IsCompleted) {
            Start-Sleep -Milliseconds 200
            if ($shutdownRequested) { break }
        }
        if ($task.IsCompleted -and -not $task.IsFaulted) {
            $context = $task.Result
            script:Invoke-Route -Context $context
        }
    }
} catch [System.OperationCanceledException] {
    # Expected on shutdown
} catch {
    if ($_.Exception.InnerException -isnot [System.OperationCanceledException]) {
        Write-Host "Server error: $_" -ForegroundColor Red
    }
} finally {
    Write-Host "`nStopping dashboard server..." -ForegroundColor Yellow
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
