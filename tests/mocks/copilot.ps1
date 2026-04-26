# Mock Copilot CLI for CronAgents testing
# Accepts same flags as real CLI, logs invocations, returns deterministic output
[CmdletBinding()]
param(
    [Alias('p')][string]$Prompt,
    [string]$Agent,
    [switch]$Silent,
    [string]$Share,
    [string]$Model,
    [string[]]$DenyTool,
    [string]$OutputFormat,
    [switch]$AllowAllTools,
    [string]$AddDir,
    [switch]$NoAskUser,
    [Parameter(ValueFromRemainingArguments)][string[]]$ExtraArgs
)

# --- Parse --key=value arguments from ExtraArgs ---
# The real Copilot CLI accepts --key=value; PowerShell doesn't bind them to
# named parameters, so they end up in $ExtraArgs. Extract the ones we care about.
# Additionally, PowerShell splits Windows paths at the ':' (e.g. C:\Users → 'C'
# and '\Users\...') when they appear inline with --key=, so we rejoin them.
if ($ExtraArgs) {
    # First pass: reassemble split Windows drive-letter paths.
    # e.g. ('--add-dir=C', '\Users\path') → ('--add-dir=C:\Users\path')
    $merged = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $cur = $ExtraArgs[$i]
        if ($i + 1 -lt $ExtraArgs.Count -and
            $cur -match '^(--[a-z-]+=)[A-Za-z]$' -and
            $ExtraArgs[$i + 1] -match '^\\') {
            $merged.Add($cur + ':' + $ExtraArgs[$i + 1])
            $i++   # skip next
        } else {
            $merged.Add($cur)
        }
    }

    $remaining = [System.Collections.Generic.List[string]]::new()
    $addDirs   = [System.Collections.Generic.List[string]]::new()
    if ($AddDir) { $addDirs.Add($AddDir) }
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $arg = $merged[$i]
        if ($arg -match '^--agent=(.+)$' -and -not $Agent)        { $Agent     = $Matches[1] }
        elseif ($arg -match '^--share=(.+)$' -and -not $Share)    { $Share     = $Matches[1] }
        elseif ($arg -match '^--model=(.+)$' -and -not $Model)    { $Model     = $Matches[1] }
        elseif ($arg -match '^--add-dir=(.+)$')                   { $addDirs.Add($Matches[1]) }
        elseif ($arg -match '^--deny-tool=(.+)$')                 { $DenyTool  = @($DenyTool) + $Matches[1] }
        elseif ($arg -eq '--allow-all-tools')                      { $AllowAllTools = [switch]$true }
        elseif ($arg -eq '--allow-all')                            { <# scope flag, ignore #> }
        elseif ($arg -eq '--silent')                               { $Silent = [switch]$true }
        elseif ($arg -eq '--no-ask-user')                          { $NoAskUser = [switch]$true }
        else { $remaining.Add($arg) }
    }
    $ExtraArgs = if ($remaining.Count) { $remaining.ToArray() } else { @() }
    $addDirResolved = if ($addDirs.Count) {
        $addDirs.ToArray()
    } else {
        @()
    }
}

# --- Invocation logging ---
$logPath = if ($env:CRONAGENTS_MOCK_LOG) { $env:CRONAGENTS_MOCK_LOG }
           else { Join-Path $PSScriptRoot 'mock-invocations.jsonl' }

$entry = [ordered]@{
    timestamp   = (Get-Date -Format 'o')
    prompt      = $Prompt
    agent       = $Agent
    silent      = $Silent.IsPresent
    share       = $Share
    model       = $Model
    denyTool    = $DenyTool
    outputFormat = $OutputFormat
    allowAllTools = $AllowAllTools.IsPresent
    addDir      = if ($addDirResolved) { @($addDirResolved) } else { $AddDir }
    noAskUser   = $NoAskUser.IsPresent
    extraArgs   = $ExtraArgs
}

$entry | ConvertTo-Json -Compress | Out-File -FilePath $logPath -Append -Encoding utf8

# --- Session file ---
if ($Share) {
    $sessionContent = @"
# Mock Copilot Session
Agent: $Agent
Prompt: $Prompt
Timestamp: $(Get-Date -Format 'o')
Status: completed
"@
    $sessionDir = Split-Path $Share -Parent
    if ($sessionDir -and -not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }
    $sessionContent | Out-File -FilePath $Share -Encoding utf8
}

# --- Deterministic output ---
$mockOutputOverride = [System.Environment]::GetEnvironmentVariable('CRONAGENTS_MOCK_OUTPUT')
if ($null -ne $mockOutputOverride) {
    $output = $mockOutputOverride
}
else {
    $output = switch ($Agent) {
        'run-summarizer' {
            @"
---
attention: false
result: success
headline: "No changes detected"
---
✓ no changes
"@
        }
        'feedback-evaluator' {
            @"
## Changes Made

- No changes required.

## Summary

Feedback acknowledged, no edits needed.
"@
        }
        default {
            $label = if ($Agent) { $Agent } else { 'prompt-only' }
            "Mock agent output for: $label`n`nAll checks passed. No issues found."
        }
    }
}

# --- Output format ---
if ($OutputFormat -eq 'json') {
    $output = @{ output = $output; exitCode = 0; agent = $Agent } | ConvertTo-Json -Compress
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Output $output

# --- Exit code ---
$code = if ($env:CRONAGENTS_MOCK_EXIT_CODE) { [int]$env:CRONAGENTS_MOCK_EXIT_CODE } else { 0 }
exit $code
