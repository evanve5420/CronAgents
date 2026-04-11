# -----------------------------------------------------------------------
# Notifier.ps1 — Windows toast notifications for agent failures, successes,
# and scheduler errors.
#
# Provides Send-AgentFailureNotification (fires a toast when an agent
# errors), Send-AgentSuccessNotification (fires a toast when an agent
# succeeds), Send-SchedulerErrorNotification (fires a toast for scheduler
# infrastructure errors with per-tick batching and cooldown), and
# Test-NotificationAvailable (probes whether any notification backend
# is usable). Gracefully degrades:
#   1. BurntToast module (rich toasts)
#   2. Native Windows.UI.Notifications API
#   3. Silent no-op
#
# Scheduler-error rate limiting:
#   - Per-tick batching: Start-SchedulerErrorBatch / Complete-SchedulerErrorBatch
#     collect errors during a tick and fire a single summary toast.
#   - Cooldown: After a scheduler-error toast fires, subsequent toasts are
#     suppressed for 5 minutes (configurable via CooldownSeconds).
# -----------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cache the detected backend so we only probe once per session.
# Values: 'BurntToast', 'Native', 'None', or $null (not yet probed).
$script:NotificationBackend = $null

# --- Scheduler-error batching & cooldown state ---
# When a batch is active, Send-SchedulerErrorNotification collects
# errors here instead of firing individual toasts.
$script:SchedulerErrorBatch  = $null   # $null = no active batch; [List] = active
$script:LastSchedulerToastTime = [datetime]::MinValue
$script:DefaultCooldownSeconds = 300   # 5 minutes

# Known Windows system sound presets (BurntToast -Sound values / WinRT URIs).
# Dictionary maps case-insensitive lookup → canonical PascalCase name.
$script:SoundPresets = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    'Default', 'IM', 'Mail', 'Reminder', 'SMS',
    'Alarm', 'Alarm2', 'Alarm3', 'Alarm4', 'Alarm5',
    'Alarm6', 'Alarm7', 'Alarm8', 'Alarm9', 'Alarm10',
    'Call', 'Call2', 'Call3', 'Call4', 'Call5',
    'Call6', 'Call7', 'Call8', 'Call9', 'Call10',
    'None'
) | ForEach-Object { $script:SoundPresets[$_] = $_ }

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

function Resolve-SoundFileUri {
    <#
    .SYNOPSIS
        Resolves a custom sound file path to a file:// URI. Returns $null
        and logs a warning if the path is a UNC/network path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if ($resolvedPath.StartsWith('\\')) {
        Write-CronAgentsLog -Level 'warn' -Message "Notification sound path rejected (UNC/network path): $Path"
        return $null
    }
    return ([System.Uri]::new($resolvedPath)).AbsoluteUri
}

function Send-BurntToastNotification {
    <#
    .SYNOPSIS
        Sends a toast via the BurntToast PowerShell module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$Sound
    )

    Import-Module BurntToast -ErrorAction Stop
    $params = @{ Text = @($Title, $Body); ErrorAction = 'Stop' }
    if ($Sound) {
        if ($Sound -eq 'None') {
            $params['Silent'] = $true
        } elseif ($script:SoundPresets.ContainsKey($Sound)) {
            $params['Sound'] = $script:SoundPresets[$Sound]
        } else {
            $fileUri = Resolve-SoundFileUri -Path $Sound
            if ($fileUri) {
                $params['Audio'] = New-BTAudio -Source $fileUri
            }
        }
    }
    New-BurntToastNotification @params
}

function Test-LoopingSound {
    <#
    .SYNOPSIS
        Returns $true if the sound name is a looping Alarm or Call preset.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SoundName)
    return ($SoundName -match '^(Alarm|Call)\d*$')
}

function ConvertTo-NativeAudioUri {
    <#
    .SYNOPSIS
        Maps a preset sound name to the ms-winsoundevent URI for native toasts.
        Normalizes casing to the canonical PascalCase form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SoundName)

    $canonical = $script:SoundPresets[$SoundName]
    if (-not $canonical) { $canonical = $SoundName }

    if (Test-LoopingSound -SoundName $canonical) {
        return "ms-winsoundevent:Notification.Looping.$canonical"
    }
    return "ms-winsoundevent:Notification.$canonical"
}

function Send-NativeToastNotification {
    <#
    .SYNOPSIS
        Sends a toast via the Windows.UI.Notifications WinRT API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$Sound
    )

    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $audioXml = ''
    $scenarioAttr = ''
    if ($Sound) {
        if ($Sound -eq 'None') {
            $audioXml = "`n  <audio silent=`"true`" />"
        } elseif ($script:SoundPresets.ContainsKey($Sound)) {
            $canonical = $script:SoundPresets[$Sound]
            $uri = [System.Security.SecurityElement]::Escape((ConvertTo-NativeAudioUri -SoundName $canonical))
            if (Test-LoopingSound -SoundName $canonical) {
                $audioXml = "`n  <audio src=`"$uri`" loop=`"true`" />"
                $scenarioAttr = ' scenario="alarm"'
            } else {
                $audioXml = "`n  <audio src=`"$uri`" />"
            }
        } else {
            $fileUri = Resolve-SoundFileUri -Path $Sound
            if ($fileUri) {
                $audioXml = "`n  <audio src=`"$([System.Security.SecurityElement]::Escape($fileUri))`" />"
            }
        }
    }

    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $template = @"
<toast$scenarioAttr>
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
      <text>$([System.Security.SecurityElement]::Escape($Body))</text>
    </binding>
  </visual>$audioXml
</toast>
"@
    $xml.LoadXml($template)

    $appId = 'CronAgents'
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Send-ToastWithFallback {
    <#
    .SYNOPSIS
        Private helper — dispatches a toast through the BurntToast → Native
        fallback chain. Caller is responsible for gating logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$LogContext = 'notification',
        [string]$Sound
    )

    $backend = Resolve-NotificationBackend
    $soundArgs = @{}
    if ($Sound) { $soundArgs['Sound'] = $Sound }

    switch ($backend) {
        'BurntToast' {
            try {
                Send-BurntToastNotification -Title $Title -Body $Body @soundArgs
                Write-CronAgentsLog -Level 'info' -Message "Toast sent for $LogContext via BurntToast."
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "BurntToast failed for $LogContext`: $_ — trying native fallback."
                try {
                    Send-NativeToastNotification -Title $Title -Body $Body @soundArgs
                    Write-CronAgentsLog -Level 'info' -Message "Toast sent for $LogContext via native API."
                }
                catch {
                    Write-CronAgentsLog -Level 'warn' -Message "Native toast also failed for $LogContext`: $_ — skipped."
                }
            }
        }
        'Native' {
            try {
                Send-NativeToastNotification -Title $Title -Body $Body @soundArgs
                Write-CronAgentsLog -Level 'info' -Message "Toast sent for $LogContext via native API."
            }
            catch {
                Write-CronAgentsLog -Level 'warn' -Message "Native toast failed for $LogContext`: $_ — skipped."
            }
        }
        default {
            Write-CronAgentsLog -Level 'debug' -Message "No notification backend available — toast skipped for $LogContext."
        }
    }
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
        The parsed per-agent config object. If 'notifyOnFailure' is missing or $false, the failure toast is skipped.
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

    $soundArgs = @{}
    if ($AgentConfig.PSObject.Properties['notificationSound'] -and $AgentConfig.notificationSound) {
        $soundArgs['Sound'] = $AgentConfig.notificationSound
    }

    Send-ToastWithFallback -Title $title -Body $body -LogContext "agent '$AgentId'" @soundArgs
}

function Send-AgentSuccessNotification {
    <#
    .SYNOPSIS
        Shows a Windows toast notification for a successful agent run. Respects
        both the global notifications toggle and per-agent notifyOnSuccess.
        Silently degrades if no backend is available.

    .PARAMETER AgentId
        The agent identifier (e.g. 'daily-review').

    .PARAMETER AgentName
        Human-friendly display name.

    .PARAMETER GlobalConfig
        The parsed global config object. Must have a 'notifications' property.

    .PARAMETER AgentConfig
        The parsed per-agent config object. If 'notifyOnSuccess' is missing or $false, the success toast is skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][PSCustomObject]$GlobalConfig,
        [Parameter(Mandatory)][PSCustomObject]$AgentConfig
    )

    # Gate 1: global toggle
    if ($GlobalConfig.PSObject.Properties['notifications'] -and
        $GlobalConfig.notifications -eq $false) {
        Write-CronAgentsLog -Level 'debug' -Message "Notifications disabled globally — skipping success toast for '$AgentId'."
        return
    }

    # Gate 2: per-agent opt-in
    if (-not $AgentConfig.PSObject.Properties['notifyOnSuccess'] -or
        -not $AgentConfig.notifyOnSuccess) {
        Write-CronAgentsLog -Level 'debug' -Message "notifyOnSuccess not enabled for '$AgentId' — skipping toast."
        return
    }

    # Build message
    $title = "CronAgents: $AgentName completed successfully"
    $body  = "Agent '$AgentId' finished without errors."

    $soundArgs = @{}
    if ($AgentConfig.PSObject.Properties['notificationSound'] -and $AgentConfig.notificationSound) {
        $soundArgs['Sound'] = $AgentConfig.notificationSound
    }

    Send-ToastWithFallback -Title $title -Body $body -LogContext "agent '$AgentId' success" @soundArgs
}

function Start-SchedulerErrorBatch {
    <#
    .SYNOPSIS
        Begins collecting scheduler-error notifications for the current tick.
        While a batch is active, Send-SchedulerErrorNotification queues errors
        instead of firing individual toasts.
    #>
    [CmdletBinding()]
    param()

    $script:SchedulerErrorBatch = [System.Collections.Generic.List[hashtable]]::new()
    Write-CronAgentsLog -Level 'debug' -Message 'Scheduler error notification batch started.'
}

function Complete-SchedulerErrorBatch {
    <#
    .SYNOPSIS
        Ends the current batch, firing a single summary toast if any errors
        were collected. Subject to cooldown — if the last scheduler-error
        toast was sent within the cooldown window the toast is suppressed.

    .PARAMETER GlobalConfig
        The parsed global config object (for the global notifications toggle).

    .PARAMETER CooldownSeconds
        Minimum seconds between scheduler-error toasts. Defaults to 300 (5 min).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$GlobalConfig,
        [int]$CooldownSeconds = $script:DefaultCooldownSeconds
    )

    $errors = $script:SchedulerErrorBatch
    $script:SchedulerErrorBatch = $null   # end the batch regardless

    if ($null -eq $errors -or $errors.Count -eq 0) {
        Write-CronAgentsLog -Level 'debug' -Message 'Scheduler error batch completed — no errors collected.'
        return
    }

    Write-CronAgentsLog -Level 'debug' -Message "Scheduler error batch completed — $($errors.Count) error(s) collected."

    # Gate: global toggle
    if ($GlobalConfig.PSObject.Properties['notifications'] -and
        $GlobalConfig.notifications -eq $false) {
        Write-CronAgentsLog -Level 'debug' -Message "Notifications disabled globally — skipping batched scheduler error toast."
        return
    }

    # Gate: cooldown
    $elapsed = ((Get-Date) - $script:LastSchedulerToastTime).TotalSeconds
    if ($elapsed -lt $CooldownSeconds) {
        $remaining = [int]($CooldownSeconds - $elapsed)
        Write-CronAgentsLog -Level 'debug' -Message "Scheduler error toast suppressed by cooldown ($remaining s remaining). $($errors.Count) error(s) dropped."
        return
    }

    # Build summary toast
    if ($errors.Count -eq 1) {
        $title = "CronAgents: $($errors[0].Operation) failed"
        $body  = $errors[0].ErrorMessage
    }
    else {
        $opList = ($errors | Select-Object -First 3 | ForEach-Object { $_.Operation }) -join ', '
        if ($errors.Count -gt 3) { $opList += ", +$($errors.Count - 3) more" }
        $title = "CronAgents: $($errors.Count) errors this tick"
        $body  = $opList
    }

    Send-ToastWithFallback -Title $title -Body $body -LogContext "batched scheduler errors ($($errors.Count))"
    $script:LastSchedulerToastTime = Get-Date
}

function Send-SchedulerErrorNotification {
    <#
    .SYNOPSIS
        Shows a Windows toast notification for a scheduler infrastructure error.
        When a batch is active (between Start-SchedulerErrorBatch and
        Complete-SchedulerErrorBatch) the error is queued instead of firing
        immediately. Outside a batch, the toast fires directly but is still
        subject to cooldown.

    .PARAMETER Operation
        Short label for what failed (e.g. 'Dashboard update', 'Retention cleanup').

    .PARAMETER ErrorMessage
        The error details to include in the toast body.

    .PARAMETER GlobalConfig
        The parsed global config object. Must have a 'notifications' property.

    .PARAMETER CooldownSeconds
        Minimum seconds between scheduler-error toasts (only applies outside a
        batch). Defaults to 300 (5 min).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [Parameter(Mandatory)][PSCustomObject]$GlobalConfig,
        [int]$CooldownSeconds = $script:DefaultCooldownSeconds
    )

    # If a batch is active, queue the operation name and error message, then return.
    if ($null -ne $script:SchedulerErrorBatch) {
        $script:SchedulerErrorBatch.Add(@{ Operation = $Operation; ErrorMessage = $ErrorMessage })
        Write-CronAgentsLog -Level 'debug' -Message "Scheduler error queued in batch: $Operation"
        return
    }

    # Gate: global toggle
    if ($GlobalConfig.PSObject.Properties['notifications'] -and
        $GlobalConfig.notifications -eq $false) {
        Write-CronAgentsLog -Level 'debug' -Message "Notifications disabled globally — skipping scheduler error toast."
        return
    }

    # Gate: cooldown
    $elapsed = ((Get-Date) - $script:LastSchedulerToastTime).TotalSeconds
    if ($elapsed -lt $CooldownSeconds) {
        $remaining = [int]($CooldownSeconds - $elapsed)
        Write-CronAgentsLog -Level 'debug' -Message "Scheduler error toast suppressed by cooldown ($remaining s remaining): $Operation"
        return
    }

    $title = "CronAgents: $Operation failed"
    $body  = $ErrorMessage

    Send-ToastWithFallback -Title $title -Body $body -LogContext "scheduler error ($Operation)"
    $script:LastSchedulerToastTime = Get-Date
}

function Reset-SchedulerErrorState {
    <#
    .SYNOPSIS
        Resets batch and cooldown state. Intended for tests.
    #>
    [CmdletBinding()]
    param()
    $script:SchedulerErrorBatch    = $null
    $script:LastSchedulerToastTime = [datetime]::MinValue
}
