# Mock script for CronAgents script-mode testing
# Outputs env vars and exits with configurable code
[CmdletBinding()]
param()

# Output env vars for test assertions
$output = [ordered]@{
    CRONAGENTS_RUN_DIR      = $env:CRONAGENTS_RUN_DIR
    CRONAGENTS_AGENT_NAME   = $env:CRONAGENTS_AGENT_NAME
    CRONAGENTS_CONFIG       = $env:CRONAGENTS_CONFIG
    CRONAGENTS_COPILOT_PATH = $env:CRONAGENTS_COPILOT_PATH
}

$output | ConvertTo-Json -Compress | Write-Output

$code = if ($env:CRONAGENTS_MOCK_SCRIPT_EXIT_CODE) { [int]$env:CRONAGENTS_MOCK_SCRIPT_EXIT_CODE } else { 0 }
exit $code
