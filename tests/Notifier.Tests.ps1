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
    It 'Defaults notifications to true when absent' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-NotifGlobal-$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $configContent = [ordered]@{
                '$schema' = './cronagents.schema.json'
                logLevel  = 'info'
            }
            $configPath = Join-Path $tmpDir 'cronagents.json'
            $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $configPath -Encoding utf8

            # Touch a .git dir so Find-RepoRoot finds it
            New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null

            $config = Import-CronAgentsConfig -ConfigPath $configPath
            $config.notifications | Should -Be $true
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Parses notifications = false' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "CronAgents-NotifGlobal-$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $configContent = [ordered]@{
                '$schema'      = './cronagents.schema.json'
                logLevel       = 'info'
                notifications  = $false
            }
            $configPath = Join-Path $tmpDir 'cronagents.json'
            $configContent | ConvertTo-Json -Depth 5 | Out-File -FilePath $configPath -Encoding utf8
            New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null

            $config = Import-CronAgentsConfig -ConfigPath $configPath
            $config.notifications | Should -Be $false
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
