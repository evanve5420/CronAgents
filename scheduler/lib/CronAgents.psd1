@{
    ModuleVersion     = '0.1.0'
    GUID              = 'bc7b4a10-ede2-40ea-85ad-4a48d7bce2ca'
    Author            = 'CronAgents Contributors'
    Description       = 'Shared module for CronAgents scheduler, CLI, and health check'
    RootModule        = ''
    NestedModules     = @(
        'Logger.ps1',
        'RunIf.ps1',
        'ConfigLoader.ps1',
        'StateManager.ps1',
        'ScheduleParser.ps1',
        'RunManager.ps1',
        'PersonalRepo.ps1',
        'PowerHelpers.ps1',
        'RetentionCleanup.ps1',
        'Notifier.ps1',
        'QuestionsManager.ps1',
        'CopilotHome.ps1'
    )
    FunctionsToExport = @(
        # Logger
        'Write-CronAgentsLog',
        'Initialize-RunLog',
        'Set-CronAgentsLogLevel',
        'Get-CronAgentsLogLevel',
        'Set-CronAgentsLogFile',
        # ConfigLoader
        'Import-CronAgentsConfig',
        'Test-CronAgentsConfig',
        'Get-AgentConfigs',
        # RunIf
        'ConvertTo-AgentRunIfDefinition',
        'Get-AgentRunIfExecutionRoot',
        'Get-AgentRunIfSnapshot',
        'Test-AgentRunIf',
        # StateManager
        'Get-AgentState',
        'Set-AgentState',
        'Reset-AgentState',
        # ScheduleParser
        'Test-AgentDue',
        'Get-NextRunTime',
        'ConvertTo-Minutes',
        'ConvertTo-Seconds',
        # RunManager
        'New-RunDirectory',
        'Initialize-RunMetadata',
        'Write-RunMetadata',
        'Get-RunHistory',
        'Test-FeedbackPresent',
        # PersonalRepo
        'ConvertTo-Slug',
        'Resolve-GitHubHandle',
        'Resolve-CronAgentsUserName',
        'New-FeedbackCommit',
        'Get-PersonalRepoPath',
        'Test-PersonalRepoValid',
        'Initialize-PersonalRepo',
        'Import-PersonalRepoConfig',
        # PowerHelpers
        'Test-OnBatteryPower',
        # RetentionCleanup
        'Invoke-RetentionCleanup',
        # Notifier
        'Send-AgentFailureNotification',
        'Send-AgentSuccessNotification',
        'Send-SchedulerErrorNotification',
        'Start-SchedulerErrorBatch',
        'Complete-SchedulerErrorBatch',
        'Reset-SchedulerErrorState',
        'Test-NotificationAvailable',
        'Resolve-NotificationBackend',
        # QuestionsManager
        'Save-AgentQuestions',
        'Get-PendingQuestions',
        'Get-AnsweredQuestions',
        'Set-QuestionAnswer',
        'Clear-AnsweredQuestions',
        'Remove-ExpiredQuestions',
        'Test-AgentHasPendingQuestions',
        'Write-AnswersFile',
        # CopilotHome
        'Initialize-SchedulerCopilotHome',
        'Get-CopilotAuthToken'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('CronAgents', 'Copilot', 'Scheduler')
            ProjectUri = 'https://github.com/cronagents/cronagents'
        }
    }
}
