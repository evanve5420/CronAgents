# -----------------------------------------------------------------------
# Notifier.ps1 — Windows toast notifications for agent failures
#
# Provides Send-AgentFailureNotification (fires a toast when an agent
# errors) and Test-NotificationAvailable (probes whether any notification
# backend is usable). Gracefully degrades:
#   1. BurntToast module (rich toasts)
#   2. Native Windows.UI.Notifications API
#   3. Silent no-op
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cache the detected backend so we only probe once per session.
# Values: 'BurntToast', 'Native', 'None', or $null (not yet probed).
$script:NotificationBackend = $null

function Resolve-NotificationBackend {
    <#
    .SYNOPSIS
        Detects the best available notification backend. Result is cached
        in $script:NotificationBackend for the lifetime of the module.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -ne $script:NotificationBackend) {
        return $script:NotificationBackend
    }

    # 1. Try BurntToast
    try {
        $mod = Get-Module -ListAvailable -Name 'BurntToast' -ErrorAction SilentlyContinue
        if ($mod) {
            $script:NotificationBackend = 'BurntToast'
            return 'BurntToast'
        }
    }
    catch { <# ignore #> }

    # 2. Try native Windows.UI.Notifications
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $script:NotificationBackend = 'Native'
        return 'Native'
    }
    catch { <# ignore #> }

    $script:NotificationBackend = 'None'
    return 'None'
}

function Test-NotificationAvailable {
    <#
    .SYNOPSIS
        Returns $true if at least one notification backend is usable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $backend = Resolve-NotificationBackend
    return ($backend -ne 'None')
}

function Send-BurntToastNotification {
    <#
    .SYNOPSIS
        Sends a toast via the BurntToast PowerShell module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )

    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text $Title, $Body -ErrorAction Stop
}

function Send-NativeToastNotification {
    <#
    .SYNOPSIS
        Sends a toast via the Windows.UI.Notifications WinRT API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )

    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
      <text>$([System.Security.SecurityElement]::Escape($Body))</text>
    </binding>
  </visual>
</toast>
"@
    $xml.LoadXml($template)

    $appId = 'CronAgents'
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Send-AgentFailureNotification {
    <#
    .SYNOPSIS
        Shows a Windows toast notification for an agent failure. Respects
        both the global notifications toggle and per-agent notifyOnFailure.
        Silently degrades if no backend is available.

    .PARAMETER AgentId
        The agent identifier (e.g. 'daily-review').

    .PARAMETER AgentName
        Human-friendly display name.

    .PARAMETER ExitCode
        The exit code from the failed run.

    .PARAMETER TimedOut
        Whether the failure was a timeout.

    .PARAMETER GlobalConfig
        The parsed global config object. Must have a 'notifications' property.

    .PARAMETER AgentConfig
        The parsed per-agent config object. Must have a 'notifyOnFailure' property.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][bool]$TimedOut,
        [Parameter(Mandatory)][PSCustomObject]$GlobalConfig,
        [Parameter(Mandatory)][PSCustomObject]$AgentConfig
    )

    # Gate 1: global toggle
    if ($GlobalConfig.PSObject.Properties['notifications'] -and
        $GlobalConfig.notifications -eq $false) {
        Write-CronAgentsLog -Level 'debug' -Message "Notifications disabled globally — skipping toast for '$AgentId'."
        return
    }

    # Gate 2: per-agent opt-in
    if (-not $AgentConfig.PSObject.Properties['notifyOnFailure'] -or
        -not $AgentConfig.notifyOnFailure) {
        Write-CronAgentsLog -Level 'debug' -Message "notifyOnFailure not enabled for '$AgentId' — skipping toast."
        return
    }

    # Build message
    $reason = if ($TimedOut) { 'timed out' } else { "failed (exit code $ExitCode)" }
    $title  = "CronAgents: $AgentName $reason"
    $body   = "Agent '$AgentId' $reason. Check the dashboard or run directory for details."

    $backend = Resolve-NotificationBackend

    switch ($backend) {
        'BurntToast' {
            try {
                Send-BurntToastNotification -Title $title -Body $body
                Write-CronAgentsLog -Level 'info' -Message "Toast notification sent for '$AgentId' via BurntToast."
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "BurntToast notification failed for '$AgentId': $_ — trying native fallback."
                # Fall through to native
                try {
                    Send-NativeToastNotification -Title $title -Body $body
                    Write-CronAgentsLog -Level 'info' -Message "Toast notification sent for '$AgentId' via native API."
                }
                catch {
                    Write-CronAgentsLog -Level 'warn' -Message "Native toast also failed for '$AgentId': $_ — notification skipped."
                }
            }
        }
        'Native' {
            try {
                Send-NativeToastNotification -Title $title -Body $body
                Write-CronAgentsLog -Level 'info' -Message "Toast notification sent for '$AgentId' via native API."
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Native toast failed for '$AgentId': $_ — notification skipped."
            }
        }
        default {
            Write-CronAgentsLog -Level 'debug' -Message "No notification backend available — toast skipped for '$AgentId'."
        }
    }
}

function Send-SchedulerErrorNotification {
    <#
    .SYNOPSIS
        Shows a Windows toast notification for a scheduler infrastructure error.
        Gated only by the global notifications toggle. Silently degrades if no
        backend is available.

    .PARAMETER Operation
        Short label for what failed (e.g. 'Dashboard update', 'Retention cleanup').

    .PARAMETER ErrorMessage
        The error details to include in the toast body.

    .PARAMETER GlobalConfig
        The parsed global config object. Must have a 'notifications' property.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [Parameter(Mandatory)][PSCustomObject]$GlobalConfig
    )

    # Gate: global toggle
    if ($GlobalConfig.PSObject.Properties['notifications'] -and
        $GlobalConfig.notifications -eq $false) {
        Write-CronAgentsLog -Level 'debug' -Message "Notifications disabled globally — skipping scheduler error toast."
        return
    }

    $title = "CronAgents: $Operation failed"
    $body  = "$ErrorMessage"

    $backend = Resolve-NotificationBackend

    switch ($backend) {
        'BurntToast' {
            try {
                Send-BurntToastNotification -Title $title -Body $body
                Write-CronAgentsLog -Level 'info' -Message "Scheduler error toast sent via BurntToast: $Operation"
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "BurntToast failed for scheduler error — trying native fallback."
                try {
                    Send-NativeToastNotification -Title $title -Body $body
                    Write-CronAgentsLog -Level 'info' -Message "Scheduler error toast sent via native API: $Operation"
                }
                catch {
                    Write-CronAgentsLog -Level 'warn' -Message "Native toast also failed for scheduler error: $_ — skipped."
                }
            }
        }
        'Native' {
            try {
                Send-NativeToastNotification -Title $title -Body $body
                Write-CronAgentsLog -Level 'info' -Message "Scheduler error toast sent via native API: $Operation"
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Native toast failed for scheduler error: $_ — skipped."
            }
        }
        default {
            Write-CronAgentsLog -Level 'debug' -Message "No notification backend available — scheduler error toast skipped."
        }
    }
}
