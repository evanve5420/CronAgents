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
    addDir      = $AddDir
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
$output = switch ($Agent) {
    'run-summarizer' {
        "✓ no changes"
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

# --- Output format ---
if ($OutputFormat -eq 'json') {
    $output = @{ output = $output; exitCode = 0; agent = $Agent } | ConvertTo-Json -Compress
}

Write-Output $output

# --- Exit code ---
$code = if ($env:CRONAGENTS_MOCK_EXIT_CODE) { [int]$env:CRONAGENTS_MOCK_EXIT_CODE } else { 0 }
exit $code
