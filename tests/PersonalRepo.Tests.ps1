<#
.SYNOPSIS
    Pester 5 tests for PersonalRepo.ps1 — personal repo management,
    path resolution, validation, initialization, config merging,
    slug helpers, username resolution, and feedback commits
    for CronAgents.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

# ===== Get-PersonalRepoPath =====

Describe 'Get-PersonalRepoPath' {
    It 'Returns default path when no config' {
        $result = Get-PersonalRepoPath
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Expands tilde to HOME' {
        $result = Get-PersonalRepoPath -ConfigPath '~/.my-agents'
        $expected = Join-Path $HOME '.my-agents'
        $result | Should -Be $expected
    }

    It 'Returns absolute path for relative input' {
        $result = Get-PersonalRepoPath -ConfigPath './agents'
        [System.IO.Path]::IsPathRooted($result) | Should -Be $true
    }

    It 'Handles empty string same as null' {
        $result = Get-PersonalRepoPath -ConfigPath ''
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Handles whitespace-only same as null' {
        $result = Get-PersonalRepoPath -ConfigPath '   '
        $expected = Join-Path $HOME '.cronagents'
        $result | Should -Be $expected
    }

    It 'Handles explicit absolute path' {
        $absPath = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\my\agents' } else { '/opt/my/agents' }
        $result = Get-PersonalRepoPath -ConfigPath $absPath
        $result | Should -Be $absPath
    }
}

# ===== Test-PersonalRepoValid =====

Describe 'Test-PersonalRepoValid' {
    It 'Returns Valid=false for non-existent path' {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nonexistent-$(Get-Random)"
        $result = Test-PersonalRepoValid -Path $fakePath
        $result.Valid | Should -Be $false
        $result.Errors.Count | Should -BeGreaterThan 0
    }

    It 'Returns Valid=false for non-git directory' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nogit-$(Get-Random)"
        New-Item $tempDir -ItemType Directory -Force | Out-Null
        try {
            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            $result.Errors | Should -Contain "Not a git repository (missing .git): $tempDir"
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=false when missing .github/agents/' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-noagents-$(Get-Random)"
        try {
            Initialize-TestGitRepo -Path $tempDir | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            ($result.Errors | Where-Object { $_ -like '*Missing directory: .github/agents/*' }).Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=false when missing .cronagents/agents/' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-nocrondir-$(Get-Random)"
        try {
            Initialize-TestGitRepo -Path $tempDir | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.github' 'agents') -Force | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $false
            ($result.Errors | Where-Object { $_ -like '*Missing directory: .cronagents/agents/*' }).Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Valid=true for complete structure' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-valid-$(Get-Random)"
        try {
            Initialize-TestGitRepo -Path $tempDir | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.github' 'agents') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempDir '.cronagents' 'agents') -Force | Out-Null

            $result = Test-PersonalRepoValid -Path $tempDir
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns descriptive errors' {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-descriptive-$(Get-Random)"
        $result = Test-PersonalRepoValid -Path $fakePath
        $result.Errors | Should -Not -BeNullOrEmpty
        $result.Errors[0] | Should -BeLike '*does not exist*'
    }
}

# ===== Initialize-PersonalRepo =====

Describe 'Initialize-PersonalRepo' {
    BeforeAll {
        $script:initBaseDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-init-$(Get-Random)"
    }

    AfterAll {
        Remove-Item -Path $script:initBaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates a new personal repo with correct structure' {
        $repoPath = Join-Path $script:initBaseDir 'structure-test'
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'

        (Test-Path (Join-Path $repoPath '.github' 'agents'))       | Should -Be $true
        (Test-Path (Join-Path $repoPath '.github' 'skills'))       | Should -Be $true
        (Test-Path (Join-Path $repoPath '.github' 'instructions')) | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronagents' 'agents'))   | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronstate'))             | Should -Be $true
        (Test-Path (Join-Path $repoPath '.cronstate' 'runs'))     | Should -Be $true
    }

    It 'Returns Created=true for new repo' {
        $repoPath = Join-Path $script:initBaseDir 'created-test'
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $result.Created | Should -Be $true
        $result.Path | Should -Be $repoPath
        $result.Message | Should -Not -BeNullOrEmpty
    }

    It 'Creates .gitignore with .cronstate/' {
        $repoPath = Join-Path $script:initBaseDir 'gitignore-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        $gitignore = Get-Content -LiteralPath (Join-Path $repoPath '.gitignore') -Raw
        $gitignore | Should -BeLike '*.cronstate/*'
    }

    It 'Creates minimal cronagents.json without $schema' {
        $repoPath = Join-Path $script:initBaseDir 'config-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        $configPath = Join-Path $repoPath 'cronagents.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.PSObject.Properties.Name | Should -Not -Contain '$schema'
    }

    It 'Creates .github/copilot-instructions.md with username' {
        $repoPath = Join-Path $script:initBaseDir 'instructions-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'alice' | Out-Null

        $content = Get-Content -LiteralPath (Join-Path $repoPath '.github' 'copilot-instructions.md') -Raw
        $content | Should -BeLike '*alice*'
    }

    It 'Initializes git repo' {
        $repoPath = Join-Path $script:initBaseDir 'git-test'
        Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' | Out-Null

        (Test-Path (Join-Path $repoPath '.git')) | Should -Be $true

        $log = & git -C $repoPath log --oneline 2>&1
        $commitCount = ($log | Measure-Object).Count
        $commitCount | Should -Be 1
    }

    It 'Returns Created=false for existing valid repo' {
        $repoPath = Join-Path $script:initBaseDir 'idempotent-test'
        $first = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $first.Created | Should -Be $true

        $second = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user'
        $second.Created | Should -Be $false
        $second.Path | Should -Be $repoPath
    }

    It 'Accepts optional InfraRepoRoot parameter' {
        $repoPath = Join-Path $script:initBaseDir 'infraroot-test'
        $infraDir = Join-Path $script:initBaseDir 'fake-infra'
        Initialize-TestGitRepo -Path $infraDir -UserEmail 'infra@test.com' -UserName 'Infra User' | Out-Null
        $null = New-TestGitCommit -Path $infraDir -FileName 'f.txt' -Content 'x' -Message 'init'

        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'test-user' -InfraRepoRoot $infraDir
        $result.Created | Should -Be $true

        $userName = & git -C $repoPath config user.name
        $userName | Should -Be 'Infra User'
    }

    It 'Repairs partially initialized repo' {
        $repoPath = Join-Path $script:initBaseDir 'repair-test'
        # Create a partial structure — directory exists but missing required dirs
        Initialize-TestGitRepo -Path $repoPath | Out-Null
        $null = New-TestGitCommit -Path $repoPath -FileName 'placeholder.txt' -Content 'temp' -Message 'partial'

        # Validation should fail — missing required dirs
        $validation = Test-PersonalRepoValid -Path $repoPath
        $validation.Valid | Should -Be $false

        # Initialize should repair
        $result = Initialize-PersonalRepo -Path $repoPath -UserName 'repair-user'
        $result.Created | Should -Be $true

        # Now it should be valid
        $validation = Test-PersonalRepoValid -Path $repoPath
        $validation.Valid | Should -Be $true
    }
}

# ===== Import-PersonalRepoConfig =====

Describe 'Import-PersonalRepoConfig' {
    BeforeAll {
        $script:configBaseDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-importcfg-$(Get-Random)"
        New-Item $script:configBaseDir -ItemType Directory -Force | Out-Null

        $script:baseConfig = [PSCustomObject]@{
            logLevel     = 'info'
            autoFeedback = $false
            personalRepo = [PSCustomObject]@{
                path                   = '~/.cronagents'
                userName               = $null
                autoCommitFeedback     = $true
                defaultWorkingDirectory = $null
            }
        }
    }

    AfterAll {
        Remove-Item -Path $script:configBaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns BaseConfig when no personal config file exists' {
        $fakePath = Join-Path $script:configBaseDir 'nonexistent-repo'
        $result = Import-PersonalRepoConfig -PersonalRepoPath $fakePath -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
        $result.autoFeedback | Should -Be $false
    }

    It 'Returns BaseConfig when personal config is empty' {
        $emptyDir = Join-Path $script:configBaseDir 'empty-config'
        New-Item $emptyDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $emptyDir 'cronagents.json') -Value '' -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $emptyDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
    }

    It 'Overrides top-level string properties' {
        $overrideDir = Join-Path $script:configBaseDir 'override-string'
        New-Item $overrideDir -ItemType Directory -Force | Out-Null
        $json = '{ "logLevel": "debug" }'
        Set-Content -Path (Join-Path $overrideDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $overrideDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'debug'
    }

    It 'Overrides top-level boolean properties' {
        $overrideDir = Join-Path $script:configBaseDir 'override-bool'
        New-Item $overrideDir -ItemType Directory -Force | Out-Null
        $json = '{ "autoFeedback": true }'
        Set-Content -Path (Join-Path $overrideDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $overrideDir -BaseConfig $script:baseConfig
        $result.autoFeedback | Should -Be $true
    }

    It 'Does not override with null values' {
        $nullDir = Join-Path $script:configBaseDir 'null-override'
        New-Item $nullDir -ItemType Directory -Force | Out-Null
        $json = '{ "logLevel": null }'
        Set-Content -Path (Join-Path $nullDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $nullDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
    }

    It 'Applies explicit quietHours null to disable inherited quiet hours' {
        $quietDir = Join-Path $script:configBaseDir 'quiet-null-override'
        New-Item $quietDir -ItemType Directory -Force | Out-Null
        $json = '{ "quietHours": null }'
        Set-Content -Path (Join-Path $quietDir 'cronagents.json') -Value $json -Encoding UTF8

        $baseWithQuiet = [PSCustomObject]@{
            logLevel   = 'info'
            quietHours = [PSCustomObject]@{ start = '17:00'; end = '08:00' }
        }

        $result = Import-PersonalRepoConfig -PersonalRepoPath $quietDir -BaseConfig $baseWithQuiet
        # The override is explicit: the property remains but its value is null.
        $result.PSObject.Properties['quietHours'] | Should -Not -BeNullOrEmpty
        $result.quietHours | Should -BeNullOrEmpty
        # Unrelated inherited settings are untouched.
        $result.logLevel | Should -Be 'info'
    }

    It 'Adds explicit quietHours null override when base omits quietHours' {
        $quietDir = Join-Path $script:configBaseDir 'quiet-null-add'
        New-Item $quietDir -ItemType Directory -Force | Out-Null
        $json = '{ "quietHours": null }'
        Set-Content -Path (Join-Path $quietDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $quietDir -BaseConfig $script:baseConfig
        $result.quietHours | Should -BeNullOrEmpty
        $result.logLevel | Should -Be 'info'
    }

    It 'Overrides inherited quietHours object with a personal object' {
        $quietDir = Join-Path $script:configBaseDir 'quiet-object-override'
        New-Item $quietDir -ItemType Directory -Force | Out-Null
        $json = '{ "quietHours": { "start": "22:00", "end": "06:00" } }'
        Set-Content -Path (Join-Path $quietDir 'cronagents.json') -Value $json -Encoding UTF8

        $baseWithQuiet = [PSCustomObject]@{
            quietHours = [PSCustomObject]@{ start = '17:00'; end = '08:00' }
        }

        $result = Import-PersonalRepoConfig -PersonalRepoPath $quietDir -BaseConfig $baseWithQuiet
        $result.quietHours.start | Should -Be '22:00'
        $result.quietHours.end   | Should -Be '06:00'
    }

    It 'Merges personalRepo sub-object at property level' {
        $mergeDir = Join-Path $script:configBaseDir 'merge-subrepo'
        New-Item $mergeDir -ItemType Directory -Force | Out-Null
        $json = '{ "personalRepo": { "userName": "alice" } }'
        Set-Content -Path (Join-Path $mergeDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $mergeDir -BaseConfig $script:baseConfig
        $result.personalRepo.userName | Should -Be 'alice'
        $result.personalRepo.path | Should -Be '~/.cronagents'
        $result.personalRepo.autoCommitFeedback | Should -Be $true
    }

    It 'Ignores $schema property' {
        $schemaDir = Join-Path $script:configBaseDir 'schema-ignore'
        New-Item $schemaDir -ItemType Directory -Force | Out-Null
        $json = '{ "$schema": "https://example.com/schema.json", "logLevel": "warn" }'
        Set-Content -Path (Join-Path $schemaDir 'cronagents.json') -Value $json -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $schemaDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'warn'
        # Base config should not gain a $schema property from personal config
        $result.PSObject.Properties['$schema'] | Should -BeNullOrEmpty
    }

    It 'Handles malformed JSON gracefully' {
        $badDir = Join-Path $script:configBaseDir 'bad-json'
        New-Item $badDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $badDir 'cronagents.json') -Value '{ invalid json }}}' -Encoding UTF8

        $result = Import-PersonalRepoConfig -PersonalRepoPath $badDir -BaseConfig $script:baseConfig
        $result.logLevel | Should -Be 'info'
        $result.autoFeedback | Should -Be $false
    }
}

# ===== ConvertTo-Slug =====

Describe 'ConvertTo-Slug' {
    It 'Lowercases input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'Alice' } | Should -Be 'alice'
    }

    It 'Replaces spaces with hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'John Doe' } | Should -Be 'john-doe'
    }

    It 'Strips non-alphanumeric characters except hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'user@name!' } | Should -Be 'username'
    }

    It 'Collapses multiple hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'a - - b' } | Should -Be 'a-b'
    }

    It 'Trims leading and trailing hyphens' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '-hello-' } | Should -Be 'hello'
    }

    It 'Handles complex real-world names' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "O'Brien, Jane (Admin)" } | Should -Be 'obrien-jane-admin'
    }

    It 'Handles tab characters as whitespace' {
        InModuleScope CronAgents { ConvertTo-Slug -Value "first`tsecond" } | Should -Be 'first-second'
    }

    It 'Handles purely numeric input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '12345' } | Should -Be '12345'
    }

    It 'Handles single character' {
        InModuleScope CronAgents { ConvertTo-Slug -Value 'A' } | Should -Be 'a'
    }

    It 'Handles empty-after-strip input' {
        InModuleScope CronAgents { ConvertTo-Slug -Value '!!!' } | Should -Be ''
    }
}

# ===== Resolve-CronAgentsUserName =====

Describe 'Resolve-CronAgentsUserName' {
    It 'Prefers ConfigUserName when provided' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Test User'
        $result | Should -Be 'test-user'
    }

    It 'Falls back to env:USERNAME when no config and no RepoRoot' {
        $result = Resolve-CronAgentsUserName
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Slugifies ConfigUserName with special characters' {
        $result = Resolve-CronAgentsUserName -ConfigUserName 'Jane O Smith'
        $result | Should -Be 'jane-o-smith'
    }

    It 'Prefers git config github.user when given a RepoRoot' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-ghuser-$(Get-Random)"
        try {
            Initialize-TestGitRepo -Path $tempDir -UserName 'Git Config User' -GitHubUser 'octocat-user' | Out-Null
            $null = New-TestGitCommit -Path $tempDir -FileName 'f.txt' -Content 'x' -Message 'init'

            $result = Resolve-CronAgentsUserName -RepoRoot $tempDir
            $result | Should -Be 'octocat-user'
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Reads git config user.name when no GitHub handle is available' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-username-$(Get-Random)"
        $stubDir = Join-Path $tempDir 'bin'
        $originalPath = $env:PATH
        try {
            Initialize-TestGitRepo -Path $tempDir -UserName 'Git Config User' | Out-Null
            New-Item $stubDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $stubDir 'gh.cmd') -Value "@echo off`r`nexit /b 1" -Encoding ASCII
            $env:PATH = "$stubDir;$originalPath"
            $null = New-TestGitCommit -Path $tempDir -FileName 'f.txt' -Content 'x' -Message 'init'

            $result = Resolve-CronAgentsUserName -RepoRoot $tempDir
            $result | Should -Be 'git-config-user'
        }
        finally {
            $env:PATH = $originalPath
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ConfigUserName takes precedence over git config' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-username-$(Get-Random)"
        try {
            Initialize-TestGitRepo -Path $tempDir -UserName 'Git User' | Out-Null
            $null = New-TestGitCommit -Path $tempDir -FileName 'f.txt' -Content 'x' -Message 'init'

            $result = Resolve-CronAgentsUserName -ConfigUserName 'Override User' -RepoRoot $tempDir
            $result | Should -Be 'override-user'
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===== New-FeedbackCommit =====

Describe 'New-FeedbackCommit' {
    BeforeAll {
        $script:feedbackRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-feedback-$(Get-Random)"
        Initialize-TestGitRepo -Path $script:feedbackRepoDir -InitialBranch 'main' | Out-Null
        $null = New-TestGitCommit -Path $script:feedbackRepoDir -FileName 'file.txt' -Content 'initial' -Message 'init'
    }

    AfterAll {
        Remove-Item -Path $script:feedbackRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Creates a feedback commit with correct message format' {
        Set-Content -Path (Join-Path $script:feedbackRepoDir 'feedback.md') -Value 'good work'
        $result = New-FeedbackCommit -RepoRoot $script:feedbackRepoDir -AgentId 'daily-review' -Summary 'Looks good' -ChangedFiles @('feedback.md')
        $result.Success | Should -Be $true
        $result.CommitHash | Should -Not -BeNullOrEmpty
        $result.CommitHash.Length | Should -BeGreaterOrEqual 7

        $msg = & git -C $script:feedbackRepoDir log -1 --format=%s
        $msg | Should -BeLike 'feedback: daily-review*Looks good'
    }

    It 'Returns failure when file does not exist' {
        $result = New-FeedbackCommit -RepoRoot $script:feedbackRepoDir -AgentId 'test' -Summary 'no-op' -ChangedFiles @('nonexistent.txt')
        $result.Success | Should -Be $false
        $result.CommitHash | Should -BeNullOrEmpty
        $result.Message | Should -Not -BeNullOrEmpty
    }
}
