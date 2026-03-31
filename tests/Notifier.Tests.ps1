<#
.SYNOPSIS
    Pester 5 tests for the Notifier module (Send-AgentFailureNotification,
    Test-NotificationAvailable, Resolve-NotificationBackend).
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
        param([bool]$NotifyOnFailure = $false)
        [PSCustomObject]@{
            name            = 'Test Agent'
            notifyOnFailure = $NotifyOnFailure
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

    It 'Fires a single toast when batch contains one error' {
        $global = New-MockGlobalConfig -Notifications $true

        $capturedTitle = $null
        Mock -ModuleName CronAgents Send-BurntToastNotification {
            param($Title, $Body)
            Set-Variable -Name capturedTitle -Value $Title -Scope 2
        }

        Start-SchedulerErrorBatch
        Send-SchedulerErrorNotification -Operation 'Dashboard update' -ErrorMessage 'disk full' -GlobalConfig $global
        Complete-SchedulerErrorBatch -GlobalConfig $global

        Should -Invoke -ModuleName CronAgents Send-BurntToastNotification -Times 1
        $capturedTitle | Should -Match 'Dashboard update'
        $capturedTitle | Should -Match 'failed'
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
