<#
.SYNOPSIS
    Pester 5 tests for the Notifier module (Send-AgentFailureNotification,
    Send-AgentSuccessNotification, Test-NotificationAvailable,
    Resolve-NotificationBackend).
    All tests mock the notification backends to avoid actual toast popups.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    function New-MockGlobalConfig {
        param([bool]$Notifications = $true)
        [PSCustomObject]@{ notifications = $Notifications }
    }

    function New-MockAgentConfig {
        param(
            [bool]$NotifyOnFailure = $false,
            [bool]$NotifyOnSuccess = $false,
            [string]$NotificationSound
        )
        $config = [PSCustomObject]@{
            name            = 'Test Agent'
            notifyOnFailure = $NotifyOnFailure
            notifyOnSuccess = $NotifyOnSuccess
        }
        if ($NotificationSound) {
            $config | Add-Member -NotePropertyName 'notificationSound' -NotePropertyValue $NotificationSound
        }
        $config
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertTo-NativeAudioUri' {
    It 'Maps Default to Notification.Default' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Default' | Should -Be 'ms-winsoundevent:Notification.Default'
        }
    }

    It 'Maps IM to Notification.IM' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'IM' | Should -Be 'ms-winsoundevent:Notification.IM'
        }
    }

    It 'Maps Alarm to Notification.Looping.Alarm' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Alarm' | Should -Be 'ms-winsoundevent:Notification.Looping.Alarm'
        }
    }

    It 'Maps Alarm3 to Notification.Looping.Alarm3' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Alarm3' | Should -Be 'ms-winsoundevent:Notification.Looping.Alarm3'
        }
    }

    It 'Maps Call to Notification.Looping.Call' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Call' | Should -Be 'ms-winsoundevent:Notification.Looping.Call'
        }
    }

    It 'Maps Call7 to Notification.Looping.Call7' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Call7' | Should -Be 'ms-winsoundevent:Notification.Looping.Call7'
        }
    }

    It 'Maps Mail to Notification.Mail (not Looping)' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'Mail' | Should -Be 'ms-winsoundevent:Notification.Mail'
        }
    }

    It 'Normalizes lowercase input to canonical PascalCase in URI' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'alarm3' | Should -Be 'ms-winsoundevent:Notification.Looping.Alarm3'
            ConvertTo-NativeAudioUri -SoundName 'mail' | Should -Be 'ms-winsoundevent:Notification.Mail'
        }
    }

    It 'Passes through unknown sound names without throwing' {
        InModuleScope CronAgents {
            ConvertTo-NativeAudioUri -SoundName 'FutureBell' | Should -Be 'ms-winsoundevent:Notification.FutureBell'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Resolve-SoundFileUri' -Tag 'WindowsOnly' {
    It 'Converts a local path to a file:// URI' {
        InModuleScope CronAgents {
            $result = Resolve-SoundFileUri -Path 'C:\Sounds\alert.wav'
            $result | Should -Be 'file:///C:/Sounds/alert.wav'
        }
    }

    It 'URL-encodes spaces in file paths' {
        InModuleScope CronAgents {
            $result = Resolve-SoundFileUri -Path 'C:\My Sounds\alert.wav'
            $result | Should -Match 'My%20Sounds'
        }
    }

    It 'Returns $null for UNC paths' {
        InModuleScope CronAgents {
            $result = Resolve-SoundFileUri -Path '\\server\share\sound.wav'
            $result | Should -BeNullOrEmpty
        }
    }

    It 'Allows extended-length local paths (\\?\C:\...)' {
        InModuleScope CronAgents {
            $result = Resolve-SoundFileUri -Path '\\?\C:\Sounds\alert.wav'
            $result | Should -BeLike 'file:///*'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Resolve-NotificationBackend' {
    It 'Returns a string value (BurntToast, Native, or None)' {
        # We cannot control what's installed on the test machine, but we
        # can verify the function returns one of the known values.
        InModuleScope CronAgents {
            $script:NotificationBackend = $null   # force re-probe
            $result = Resolve-NotificationBackend
            $result | Should -BeIn @('BurntToast', 'Native', 'None')
        }
    }

    It 'Caches the result on subsequent calls' {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'BurntToast'
            $result = Resolve-NotificationBackend
            $result | Should -Be 'BurntToast'
            $script:NotificationBackend = $null   # reset
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-NotificationAvailable' {
    It 'Returns bool' {
        $result = Test-NotificationAvailable
        $result | Should -BeOfType [bool]
    }

    It 'Returns $false when backend is None' {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'None'
        }
        Test-NotificationAvailable | Should -BeFalse
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Returns $true when backend is BurntToast' {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'BurntToast'
        }
        Test-NotificationAvailable | Should -BeTrue
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Returns $true when backend is Native' {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'Native'
        }
        Test-NotificationAvailable | Should -BeTrue
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentFailureNotification — gating logic' {
    BeforeEach {
        # Force backend to None so we never actually try to show a toast
        InModuleScope CronAgents { $script:NotificationBackend = 'None' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Does nothing when global notifications = false' {
        $global = New-MockGlobalConfig -Notifications $false
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        # Should not throw — just silently skip
        { Send-AgentFailureNotification -AgentId 'test' -AgentName 'Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Does nothing when per-agent notifyOnFailure = false' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $false

        { Send-AgentFailureNotification -AgentId 'test' -AgentName 'Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Does nothing when notifyOnFailure property is absent' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = [PSCustomObject]@{ name = 'Test Agent' }

        { Send-AgentFailureNotification -AgentId 'test' -AgentName 'Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Proceeds past gates when both toggles are true (backend=None → silent)' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        { Send-AgentFailureNotification -AgentId 'test' -AgentName 'Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentFailureNotification — BurntToast mock' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Calls Send-BurntToastNotification when backend is BurntToast' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        # Mock the internal BurntToast sender to avoid Import-Module
        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        Send-AgentFailureNotification -AgentId 'bt-test' -AgentName 'BT Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }

    It 'Falls back to native when BurntToast throws' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        Mock -ModuleName CronAgents Send-BurntToastNotification { throw 'BurntToast unavailable' }
        Mock -ModuleName CronAgents Send-NativeToastNotification {}

        Send-AgentFailureNotification -AgentId 'fb-test' -AgentName 'Fallback Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        Should -Invoke -ModuleName CronAgents Send-NativeToastNotification -Times 1
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentFailureNotification — Native mock' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'Native' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Calls Send-NativeToastNotification when backend is Native' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        Mock -ModuleName CronAgents Send-NativeToastNotification {}

        Send-AgentFailureNotification -AgentId 'native-test' -AgentName 'Native Test' `
            -ExitCode 2 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-NativeToastNotification -Times 1
    }

    It 'Silently degrades when native throws' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        Mock -ModuleName CronAgents Send-NativeToastNotification { throw 'WinRT unavailable' }

        { Send-AgentFailureNotification -AgentId 'native-fail' -AgentName 'Native Fail' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentFailureNotification — timeout message' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Includes "timed out" in the title when TimedOut is true' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Send-AgentFailureNotification -AgentId 'timeout-test' -AgentName 'Timeout Test' `
            -ExitCode -1 -TimedOut $true -GlobalConfig $global -AgentConfig $agent

        $capturedTitle | Should -Match 'timed out'
    }

    It 'Includes "failed (exit code N)" in the title when TimedOut is false' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Send-AgentFailureNotification -AgentId 'exitcode-test' -AgentName 'ExitCode Test' `
            -ExitCode 42 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        $capturedTitle | Should -Match 'failed \(exit code 42\)'
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentFailureNotification — notificationSound' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Passes Sound to Send-BurntToastNotification when notificationSound is set' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true -NotificationSound 'Alarm3'

        $capturedSound = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentFailureNotification -AgentId 'sound-test' -AgentName 'Sound Test' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -Be 'Alarm3'
    }

    It 'Does not pass Sound when notificationSound is absent' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true

        $capturedSound = 'sentinel'
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentFailureNotification -AgentId 'no-sound-test' -AgentName 'No Sound' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -BeNullOrEmpty
    }

    It 'Passes custom file path as Sound to Send-BurntToastNotification' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnFailure $true -NotificationSound 'C:\Sounds\alert.wav'

        $capturedSound = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentFailureNotification -AgentId 'custom-sound' -AgentName 'Custom Sound' `
            -ExitCode 1 -TimedOut $false -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -Be 'C:\Sounds\alert.wav'
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentSuccessNotification — gating logic' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'None' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Does nothing when global notifications = false' {
        $global = New-MockGlobalConfig -Notifications $false
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        { Send-AgentSuccessNotification -AgentId 'test' -AgentName 'Test' `
            -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Does nothing when per-agent notifyOnSuccess = false' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $false

        { Send-AgentSuccessNotification -AgentId 'test' -AgentName 'Test' `
            -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Does nothing when notifyOnSuccess property is absent' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = [PSCustomObject]@{ name = 'Test Agent' }

        { Send-AgentSuccessNotification -AgentId 'test' -AgentName 'Test' `
            -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }

    It 'Proceeds past gates when both toggles are true (backend=None → silent)' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        { Send-AgentSuccessNotification -AgentId 'test' -AgentName 'Test' `
            -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentSuccessNotification — BurntToast mock' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Calls Send-BurntToastNotification when backend is BurntToast' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        Send-AgentSuccessNotification -AgentId 'bt-test' -AgentName 'BT Test' `
            -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }

    It 'Falls back to native when BurntToast throws' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        Mock -ModuleName CronAgents Send-BurntToastNotification { throw 'BurntToast unavailable' }
        Mock -ModuleName CronAgents Send-NativeToastNotification {}

        Send-AgentSuccessNotification -AgentId 'fb-test' -AgentName 'Fallback Test' `
            -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        Should -Invoke -ModuleName CronAgents Send-NativeToastNotification -Times 1
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentSuccessNotification — Native mock' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'Native' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Calls Send-NativeToastNotification when backend is Native' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        Mock -ModuleName CronAgents Send-NativeToastNotification {}

        Send-AgentSuccessNotification -AgentId 'native-test' -AgentName 'Native Test' `
            -GlobalConfig $global -AgentConfig $agent

        Should -Invoke -ModuleName CronAgents Send-NativeToastNotification -Times 1
    }

    It 'Silently degrades when native throws' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        Mock -ModuleName CronAgents Send-NativeToastNotification { throw 'WinRT unavailable' }

        { Send-AgentSuccessNotification -AgentId 'native-fail' -AgentName 'Native Fail' `
            -GlobalConfig $global -AgentConfig $agent } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentSuccessNotification — message content' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Includes "completed successfully" in the title' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'success-test' -AgentName 'Success Test' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedTitle | Should -Match 'completed successfully'
    }

    It 'Includes agent name in the title' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'name-test' -AgentName 'My Agent' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedTitle | Should -Match 'My Agent'
    }

    It 'Includes agent ID in the body' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        $capturedBody = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedBody -Value $Body -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'body-test' -AgentName 'Body Test' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedBody | Should -Match 'body-test'
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-AgentSuccessNotification — notificationSound' {
    BeforeEach {
        InModuleScope CronAgents { $script:NotificationBackend = 'BurntToast' }
    }
    AfterEach {
        InModuleScope CronAgents { $script:NotificationBackend = $null }
    }

    It 'Passes Sound to Send-BurntToastNotification when notificationSound is set' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true -NotificationSound 'Mail'

        $capturedSound = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'sound-test' -AgentName 'Sound Test' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -Be 'Mail'
    }

    It 'Does not pass Sound when notificationSound is absent' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true

        $capturedSound = 'sentinel'
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'no-sound-test' -AgentName 'No Sound' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -BeNullOrEmpty
    }

    It 'Passes custom file path as Sound to Send-BurntToastNotification' {
        $global = New-MockGlobalConfig -Notifications $true
        $agent  = New-MockAgentConfig  -NotifyOnSuccess $true -NotificationSound 'D:\Music\chime.wav'

        $capturedSound = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body, $Sound)
            Set-Variable -Name capturedSound -Value $Sound -Scope 2
        }

        Send-AgentSuccessNotification -AgentId 'custom-sound' -AgentName 'Custom Sound' `
            -GlobalConfig $global -AgentConfig $agent

        $capturedSound | Should -Be 'D:\Music\chime.wav'
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-SchedulerErrorNotification — gating logic' {
    BeforeEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'None'
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }
    AfterEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = $null
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }

    It 'Does nothing when global notifications = false' {
        $global = New-MockGlobalConfig -Notifications $false

        { Send-SchedulerErrorNotification -Operation 'Test op' -ErrorMessage 'boom' -GlobalConfig $global } |
            Should -Not -Throw
    }

    It 'Proceeds when global notifications = true (backend=None → silent)' {
        $global = New-MockGlobalConfig -Notifications $true

        { Send-SchedulerErrorNotification -Operation 'Test op' -ErrorMessage 'boom' -GlobalConfig $global } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-SchedulerErrorNotification — toast content' {
    BeforeEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'BurntToast'
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }
    AfterEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = $null
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }

    It 'Includes operation name in the title' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Send-SchedulerErrorNotification -Operation 'Dashboard update' -ErrorMessage 'file locked' -GlobalConfig $global

        $capturedTitle | Should -Match 'Dashboard update'
        $capturedTitle | Should -Match 'failed'
    }

    It 'Includes error message in the body' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedBody = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedBody -Value $Body -Scope 2
        }

        Send-SchedulerErrorNotification -Operation 'Retention cleanup' -ErrorMessage 'disk full' -GlobalConfig $global

        $capturedBody | Should -Match 'disk full'
    }

    It 'Falls back to native when BurntToast throws' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification { throw 'BurntToast unavailable' }
        Mock -ModuleName CronAgents Send-NativeToastNotification {}

        Send-SchedulerErrorNotification -Operation 'Test fallback' -ErrorMessage 'error' -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        Should -Invoke -ModuleName CronAgents Send-NativeToastNotification -Times 1
    }
}

# ---------------------------------------------------------------------------
Describe 'ConfigLoader — notifyOnFailure parsing' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'NotifierConfig'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Defaults notifyOnFailure to false when absent' {
        $configContent = [ordered]@{
            prompt   = 'Do something'
            schedule = @{ type = 'daily'; time = '09:00' }
        }
        $filePath = Join-Path $testEnv.AgentsDir 'no-notify.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'no-notify' }
        $agent.Config.notifyOnFailure | Should -Be $false
    }

    It 'Parses notifyOnFailure = true' {
        $configContent = [ordered]@{
            prompt          = 'Do something'
            schedule        = @{ type = 'daily'; time = '09:00' }
            notifyOnFailure = $true
        }
        $filePath = Join-Path $testEnv.AgentsDir 'yes-notify.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'yes-notify' }
        $agent.Config.notifyOnFailure | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
Describe 'ConfigLoader — notifyOnSuccess parsing' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'NotifierSuccessConfig'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Defaults notifyOnSuccess to false when absent' {
        $configContent = [ordered]@{
            prompt   = 'Do something'
            schedule = @{ type = 'daily'; time = '09:00' }
        }
        $filePath = Join-Path $testEnv.AgentsDir 'no-success-notify.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'no-success-notify' }
        $agent.Config.notifyOnSuccess | Should -Be $false
    }

    It 'Parses notifyOnSuccess = true' {
        $configContent = [ordered]@{
            prompt          = 'Do something'
            schedule        = @{ type = 'daily'; time = '09:00' }
            notifyOnSuccess = $true
        }
        $filePath = Join-Path $testEnv.AgentsDir 'yes-success-notify.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'yes-success-notify' }
        $agent.Config.notifyOnSuccess | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
Describe 'ConfigLoader — notificationSound parsing' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'NotifSoundConfig'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Has no notificationSound property when absent from config' {
        $configContent = [ordered]@{
            prompt   = 'Do something'
            schedule = @{ type = 'daily'; time = '09:00' }
        }
        $filePath = Join-Path $testEnv.AgentsDir 'no-sound.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'no-sound' }
        $agent.Config.PSObject.Properties['notificationSound'] | Should -BeNullOrEmpty
    }

    It 'Parses notificationSound = "Alarm3"' {
        $configContent = [ordered]@{
            prompt            = 'Do something'
            schedule          = @{ type = 'daily'; time = '09:00' }
            notificationSound = 'Alarm3'
        }
        $filePath = Join-Path $testEnv.AgentsDir 'with-sound.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'with-sound' }
        $agent.Config.notificationSound | Should -Be 'Alarm3'
    }

    It 'Parses notificationSound with a custom file path' {
        $configContent = [ordered]@{
            prompt            = 'Do something'
            schedule          = @{ type = 'daily'; time = '09:00' }
            notificationSound = 'C:\Sounds\alert.wav'
        }
        $filePath = Join-Path $testEnv.AgentsDir 'custom-sound.agent-registration.json'
        $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8

        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agent = $agents | Where-Object { $_.Id -eq 'custom-sound' }
        $agent.Config.notificationSound | Should -Be 'C:\Sounds\alert.wav'
    }
}

# ---------------------------------------------------------------------------
Describe 'SoundPresets dictionary' {
    It 'Contains all 26 known preset names' {
        InModuleScope CronAgents {
            $script:SoundPresets.Count | Should -Be 26
            $script:SoundPresets.ContainsKey('Default') | Should -BeTrue
            $script:SoundPresets.ContainsKey('None') | Should -BeTrue
            $script:SoundPresets.ContainsKey('Alarm') | Should -BeTrue
            $script:SoundPresets.ContainsKey('Alarm10') | Should -BeTrue
            $script:SoundPresets.ContainsKey('Call10') | Should -BeTrue
        }
    }

    It 'Does not contain arbitrary strings' {
        InModuleScope CronAgents {
            $script:SoundPresets.ContainsKey('C:\Sounds\alert.wav') | Should -BeFalse
            $script:SoundPresets.ContainsKey('custom') | Should -BeFalse
        }
    }

    It 'Is case-insensitive' {
        InModuleScope CronAgents {
            $script:SoundPresets.ContainsKey('alarm') | Should -BeTrue
            $script:SoundPresets.ContainsKey('MAIL') | Should -BeTrue
        }
    }

    It 'Returns canonical PascalCase for case-insensitive lookups' {
        InModuleScope CronAgents {
            $script:SoundPresets['alarm3'] | Should -Be 'Alarm3'
            $script:SoundPresets['mail'] | Should -Be 'Mail'
            $script:SoundPresets['IM'] | Should -Be 'IM'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'ConfigLoader — global notifications parsing' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'NotifGlobal'
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Defaults notifications to true when absent' {
        $configContent = [ordered]@{
            '$schema' = './cronagents.schema.json'
            logLevel  = 'info'
        }
        $configContent | ConvertTo-Json -Depth 5 |
            Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        $config = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $config.notifications | Should -Be $true
    }

    It 'Parses notifications = false' {
        $configContent = [ordered]@{
            '$schema'      = './cronagents.schema.json'
            logLevel       = 'info'
            notifications  = $false
        }
        $configContent | ConvertTo-Json -Depth 5 |
            Out-File -FilePath $testEnv.ConfigPath -Encoding utf8

        $config = Import-CronAgentsConfig -ConfigPath $testEnv.ConfigPath
        $config.notifications | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Scheduler error batching — Start / Complete lifecycle' {
    BeforeEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'BurntToast'
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }
    AfterEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = $null
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }

    It 'Fires no toast when batch contains zero errors' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        Start-SchedulerErrorBatch
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 0
    }

    It 'Fires a single toast when batch contains one error — preserves error message' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedTitle = $null
        $capturedBody  = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
            Set-Variable -Name capturedBody  -Value $Body  -Scope 2
        }

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Dashboard update' -ErrorMessage 'disk full' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        $capturedTitle | Should -Match 'Dashboard update'
        $capturedTitle | Should -Match 'failed'
        $capturedBody  | Should -Match 'disk full'
    }

    It 'Fires a single summary toast when batch contains multiple errors' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedTitle = $null
        $capturedBody  = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
            Set-Variable -Name capturedBody  -Value $Body  -Scope 2
        }

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Dashboard update' -ErrorMessage 'disk full' -GlobalConfig $global
        Send-SchedulerErrorNotification -Operation 'Retention cleanup' -ErrorMessage 'access denied' -GlobalConfig $global
        Send-SchedulerErrorNotification -Operation 'Feedback sweep' -ErrorMessage 'timeout' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        $capturedTitle | Should -Match '3 errors this tick'
        $capturedBody  | Should -Match 'Dashboard update'
        $capturedBody  | Should -Match 'Retention cleanup'
        $capturedBody  | Should -Match 'Feedback sweep'
    }

    It 'Truncates operation list in body when batch has more than 3 errors' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedBody = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedBody -Value $Body -Scope 2
        }

        Start-SchedulerErrorBatch
        1..5 | ForEach-Object {
            Send-SchedulerErrorNotification -Operation "Op$_" -ErrorMessage 'err' -GlobalConfig $global
        }
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        $capturedBody | Should -Match '\+2 more'
    }

    It 'Does not fire individual toasts while batch is active' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' -GlobalConfig $global
        Send-SchedulerErrorNotification -Operation 'Op2' -ErrorMessage 'err' -GlobalConfig $global

        # Before Complete, no toasts should have fired
        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 0

        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }

    It 'Respects global notifications = false when completing batch' {
        $global = New-MockGlobalConfig -Notifications $false

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Scheduler error cooldown' {
    BeforeEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = 'BurntToast'
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }
    AfterEach {
        InModuleScope CronAgents {
            $script:NotificationBackend = $null
            $script:SchedulerErrorBatch = $null
            $script:LastSchedulerToastTime = [datetime]::MinValue
        }
    }

    It 'Suppresses batched toast when within cooldown window' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        # Simulate a recent toast
        InModuleScope CronAgents {
            $script:LastSchedulerToastTime = Get-Date
        }

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global -CooldownSeconds 300

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 0
    }

    It 'Allows batched toast after cooldown expires' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        # Simulate an old toast (10 minutes ago)
        InModuleScope CronAgents {
            $script:LastSchedulerToastTime = (Get-Date).AddSeconds(-600)
        }

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global -CooldownSeconds 300

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }

    It 'Suppresses unbatched toast when within cooldown window' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        # Simulate a recent toast
        InModuleScope CronAgents {
            $script:LastSchedulerToastTime = Get-Date
        }

        # No batch active — direct call
        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' `
            -GlobalConfig $global -CooldownSeconds 300

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 0
    }

    It 'Allows unbatched toast after cooldown expires' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        InModuleScope CronAgents {
            $script:LastSchedulerToastTime = (Get-Date).AddSeconds(-600)
        }

        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' `
            -GlobalConfig $global -CooldownSeconds 300

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }

    It 'Respects custom CooldownSeconds parameter' {
        $global = New-MockGlobalConfig -Notifications $true

        Mock -ModuleName CronAgents Send-BurntToastNotification {}

        # Toast 2 seconds ago, cooldown 1 second → should pass
        InModuleScope CronAgents {
            $script:LastSchedulerToastTime = (Get-Date).AddSeconds(-2)
        }

        Send-SchedulerErrorNotification -Operation 'Op1' -ErrorMessage 'err' `
            -GlobalConfig $global -CooldownSeconds 1

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
    }
}

# ---------------------------------------------------------------------------
Describe 'Reset-SchedulerErrorState' {
    It 'Clears batch and cooldown state' {
        InModuleScope CronAgents {
            $script:NotificationBackend     = 'BurntToast'
            $script:SchedulerErrorBatch     = [System.Collections.Generic.List[string]]::new()
            $script:LastSchedulerToastTime  = Get-Date
        }

        Reset-SchedulerErrorState

        InModuleScope CronAgents {
            $script:SchedulerErrorBatch    | Should -BeNullOrEmpty
            $script:LastSchedulerToastTime | Should -Be ([datetime]::MinValue)
        }

        InModuleScope CronAgents {
            $script:NotificationBackend = $null
        }
    }
}
