# -----------------------------------------------------------------------
# QuestionsManager.ps1 — Persisted question/answer queue for agents
#
# Agents write questions to .cronstate/pending-questions/<agent-id>.json.
# The scheduler discovers them post-run, and the CLI/TUI presents them
# for the user to answer. Answered questions are injected into the next
# agent run via --share, then cleared.
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QuestionsDir {
    <#
    .SYNOPSIS
        Returns the pending-questions directory path, creating it if needed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateRoot
    )

    $dir = Join-Path $StateRoot 'pending-questions'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-AgentQuestionsPath {
    <#
    .SYNOPSIS
        Returns the path to an agent's questions file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId
    )

    $dir = Get-QuestionsDir -StateRoot $StateRoot
    return Join-Path $dir "$AgentId.json"
}

function Read-QuestionsFile {
    <#
    .SYNOPSIS
        Reads and parses an agent's questions JSON file. Returns empty array
        if the file does not exist or is invalid.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) { return @() }

        $parsed = $content | ConvertFrom-Json
        $questions = @()
        foreach ($q in @($parsed)) {
            $ht = @{
                id          = $q.id
                question    = $q.question
                choices     = if ($q.PSObject.Properties['choices'] -and $null -ne $q.choices) { @($q.choices) } else { @() }
                recommended = if ($q.PSObject.Properties['recommended']) { $q.recommended } else { $null }
                context     = if ($q.PSObject.Properties['context']) { $q.context } else { $null }
                agentId     = if ($q.PSObject.Properties['agentId']) { $q.agentId } else { $null }
                runId       = if ($q.PSObject.Properties['runId']) { $q.runId } else { $null }
                askedAt     = if ($q.PSObject.Properties['askedAt']) { $q.askedAt } else { $null }
                expiresAt   = if ($q.PSObject.Properties['expiresAt']) { $q.expiresAt } else { $null }
                answer      = if ($q.PSObject.Properties['answer']) { $q.answer } else { $null }
            }
            $questions += $ht
        }
        return $questions
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "Failed to read questions file '$Path': $_"
        return @()
    }
}

function Write-QuestionsFile {
    <#
    .SYNOPSIS
        Writes an array of question hashtables to the agent's questions file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Questions
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($Questions.Count -eq 0) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        return
    }

    $ordered = @()
    foreach ($q in $Questions) {
        $obj = [ordered]@{
            id          = $q.id
            question    = $q.question
            choices     = $q.choices
            recommended = $q.recommended
            context     = $q.context
            agentId     = $q.agentId
            runId       = $q.runId
            askedAt     = $q.askedAt
            expiresAt   = $q.expiresAt
            answer      = $q.answer
        }
        $ordered += $obj
    }

    $json = $ordered | ConvertTo-Json -Depth 10
    # ConvertTo-Json returns a bare object when there's exactly one item; wrap it
    if ($Questions.Count -eq 1 -and -not $json.StartsWith('[')) {
        $json = "[$json]"
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

# -----------------------------------------------------------------------
# Public functions
# -----------------------------------------------------------------------

function Save-AgentQuestions {
    <#
    .SYNOPSIS
        Persists questions from an agent run. Merges with any existing
        unanswered questions (by id), adding metadata.
    .PARAMETER StateRoot
        Path to .cronstate directory.
    .PARAMETER AgentId
        The agent that asked the questions.
    .PARAMETER RunId
        The run directory name for traceability.
    .PARAMETER Questions
        Array of question objects from the agent (each with id, question,
        choices, recommended, context).
    .PARAMETER ExpirationDays
        Days until questions expire. 0 = never expire.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][object[]]$Questions,
        [int]$ExpirationDays = 7
    )

    $path = Get-AgentQuestionsPath -StateRoot $StateRoot -AgentId $AgentId
    $existing = @(Read-QuestionsFile -Path $path)

    $now = [datetime]::UtcNow.ToString('o')
    $expiresAt = if ($ExpirationDays -gt 0) {
        [datetime]::UtcNow.AddDays($ExpirationDays).ToString('o')
    } else { $null }

    foreach ($q in $Questions) {
        $qId = if ($q -is [hashtable]) { $q.id } else { $q.id }
        $qQuestion = if ($q -is [hashtable]) { $q.question } else { $q.question }
        $qChoices = if ($q -is [hashtable] -and $q.ContainsKey('choices')) { @($q.choices) }
                    elseif ($q -is [PSCustomObject] -and $q.PSObject.Properties['choices']) { @($q.choices) }
                    else { @() }
        $qRecommended = if ($q -is [hashtable] -and $q.ContainsKey('recommended')) { $q.recommended }
                        elseif ($q -is [PSCustomObject] -and $q.PSObject.Properties['recommended']) { $q.recommended }
                        else { $null }
        $qContext = if ($q -is [hashtable] -and $q.ContainsKey('context')) { $q.context }
                    elseif ($q -is [PSCustomObject] -and $q.PSObject.Properties['context']) { $q.context }
                    else { $null }

        # Check if this question ID already exists (unanswered) — update it
        $found = $false
        for ($i = 0; $i -lt $existing.Count; $i++) {
            if ($existing[$i].id -eq $qId -and $null -eq $existing[$i].answer) {
                $existing[$i].question    = $qQuestion
                $existing[$i].choices     = $qChoices
                $existing[$i].recommended = $qRecommended
                $existing[$i].context     = $qContext
                $existing[$i].agentId     = $AgentId
                $existing[$i].runId       = $RunId
                $existing[$i].askedAt     = $now
                $existing[$i].expiresAt   = $expiresAt
                $found = $true
                break
            }
        }

        if (-not $found) {
            $existing += @{
                id          = $qId
                question    = $qQuestion
                choices     = $qChoices
                recommended = $qRecommended
                context     = $qContext
                agentId     = $AgentId
                runId       = $RunId
                askedAt     = $now
                expiresAt   = $expiresAt
                answer      = $null
            }
        }
    }

    Write-QuestionsFile -Path $path -Questions $existing
    Write-CronAgentsLog -Level 'info' -Message "Saved $($Questions.Count) question(s) for agent '$AgentId'"
}

function Get-PendingQuestions {
    <#
    .SYNOPSIS
        Returns unanswered questions, optionally filtered by agent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AgentId
    )

    $params = @{ StateRoot = $StateRoot }
    if ($AgentId) { $params['AgentId'] = $AgentId }
    $questions = Get-Questions @params
    $results = @($questions | Where-Object { $null -eq $_.answer })

    Write-Output -NoEnumerate $results
}

function Get-Questions {
    <#
    .SYNOPSIS
        Returns all questions, optionally filtered by agent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AgentId
    )

    $dir = Get-QuestionsDir -StateRoot $StateRoot
    $results = @()

    if ($AgentId) {
        $path = Get-AgentQuestionsPath -StateRoot $StateRoot -AgentId $AgentId
        $results = @(Read-QuestionsFile -Path $path)
    }
    else {
        $files = Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $results += @(Read-QuestionsFile -Path $file.FullName)
        }
    }

    Write-Output -NoEnumerate $results
}

function Get-AnsweredQuestions {
    <#
    .SYNOPSIS
        Returns answered questions, optionally filtered by agent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AgentId
    )

    $params = @{ StateRoot = $StateRoot }
    if ($AgentId) { $params['AgentId'] = $AgentId }
    $questions = Get-Questions @params
    $results = @($questions | Where-Object { $null -ne $_.answer })

    Write-Output -NoEnumerate $results
}

function Set-QuestionAnswer {
    <#
    .SYNOPSIS
        Records the user's answer for a specific question.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$QuestionId,
        [Parameter(Mandatory)][string]$Answer
    )

    $path = Get-AgentQuestionsPath -StateRoot $StateRoot -AgentId $AgentId
    $questions = @(Read-QuestionsFile -Path $path)

    $found = $false
    for ($i = 0; $i -lt $questions.Count; $i++) {
        if ($questions[$i].id -eq $QuestionId) {
            $questions[$i].answer = $Answer
            $found = $true
            break
        }
    }

    if (-not $found) {
        Write-CronAgentsLog -Level 'warn' -Message "Question '$QuestionId' not found for agent '$AgentId'"
        return
    }

    Write-QuestionsFile -Path $path -Questions $questions
    Write-CronAgentsLog -Level 'info' -Message "Answered question '$QuestionId' for agent '$AgentId'"
}

function Clear-AnsweredQuestions {
    <#
    .SYNOPSIS
        Removes all answered questions for an agent (called after injecting
        answers into a run).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId
    )

    $path = Get-AgentQuestionsPath -StateRoot $StateRoot -AgentId $AgentId
    $questions = @(Read-QuestionsFile -Path $path)
    $remaining = @($questions | Where-Object { $null -eq $_.answer })

    Write-QuestionsFile -Path $path -Questions $remaining
    $cleared = $questions.Count - $remaining.Count
    if ($cleared -gt 0) {
        Write-CronAgentsLog -Level 'info' -Message "Cleared $cleared answered question(s) for agent '$AgentId'"
    }
}

function Remove-ExpiredQuestions {
    <#
    .SYNOPSIS
        Removes questions past their expiresAt timestamp.
        If AgentId is specified, only processes that agent's file; otherwise sweeps all agents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AgentId
    )

    $dir = Get-QuestionsDir -StateRoot $StateRoot

    if ($AgentId) {
        $targetPath = Get-AgentQuestionsPath -StateRoot $StateRoot -AgentId $AgentId
        if (-not (Test-Path -LiteralPath $targetPath)) { return }
        $files = @(Get-Item -LiteralPath $targetPath)
    }
    else {
        $files = Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue
    }

    $now = [datetime]::UtcNow
    $totalExpired = 0

    foreach ($file in $files) {
        $questions = @(Read-QuestionsFile -Path $file.FullName)
        $remaining = @()
        foreach ($q in $questions) {
            if ($null -ne $q.expiresAt -and $null -eq $q.answer) {
                try {
                    $expiry = [datetime]::Parse($q.expiresAt)
                    if ($expiry -lt $now) {
                        $totalExpired++
                        Write-CronAgentsLog -Level 'info' -Message "Expired question '$($q.id)' for agent '$($q.agentId)'"
                        continue
                    }
                }
                catch {
                    # Can't parse expiry — keep the question
                }
            }
            $remaining += $q
        }

        Write-QuestionsFile -Path $file.FullName -Questions $remaining
    }

    if ($totalExpired -gt 0) {
        Write-CronAgentsLog -Level 'info' -Message "Expired $totalExpired question(s) total"
    }
}

function Test-AgentHasPendingQuestions {
    <#
    .SYNOPSIS
        Returns $true if the agent has unanswered questions.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId
    )

    $pending = Get-PendingQuestions -StateRoot $StateRoot -AgentId $AgentId
    return ($pending.Count -gt 0)
}

function Write-AnswersFile {
    <#
    .SYNOPSIS
        Writes answered questions to a JSON file suitable for --share injection.
        Returns the path to the answers file, or $null if no answers exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    $answered = Get-AnsweredQuestions -StateRoot $StateRoot -AgentId $AgentId
    if ($answered.Count -eq 0) { return $null }

    $answersForAgent = @()
    foreach ($q in $answered) {
        $answersForAgent += [ordered]@{
            id       = $q.id
            question = $q.question
            answer   = $q.answer
            context  = $q.context
        }
    }

    $answersPath = Join-Path $RunDirectory 'answers.json'
    $json = $answersForAgent | ConvertTo-Json -Depth 10
    if ($answered.Count -eq 1 -and -not $json.StartsWith('[')) {
        $json = "[$json]"
    }
    [System.IO.File]::WriteAllText($answersPath, $json, [System.Text.Encoding]::UTF8)

    Write-CronAgentsLog -Level 'info' -Message "Wrote $($answered.Count) answer(s) to: $answersPath"
    return $answersPath
}
