<#
.SYNOPSIS
    Pester 5 tests for QuestionsManager.ps1 — agent question/answer queue.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

# ===== Save-AgentQuestions =====

Describe 'Save-AgentQuestions' {
    It 'Creates questions file with metadata' {
        $stateRoot = Join-Path $TestDrive 'save-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        $questions = @(
            @{ id = 'q1'; question = 'Move items to Acme?'; choices = @('Yes', 'No'); recommended = 'Yes'; context = 'Found 7 emails' }
        )

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'inbox-mgr' `
            -RunId 'run-001' -Questions $questions -ExpirationDays 7

        $path = Join-Path $stateRoot 'pending-questions' 'inbox-mgr.json'
        Test-Path $path | Should -Be $true

        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        @($saved).Count | Should -Be 1
        $saved[0].id | Should -Be 'q1'
        $saved[0].question | Should -Be 'Move items to Acme?'
        $saved[0].agentId | Should -Be 'inbox-mgr'
        $saved[0].runId | Should -Be 'run-001'
        $saved[0].answer | Should -BeNullOrEmpty
        $saved[0].askedAt | Should -Not -BeNullOrEmpty
        $saved[0].expiresAt | Should -Not -BeNullOrEmpty
        $saved[0].choices.Count | Should -Be 2
        $saved[0].recommended | Should -Be 'Yes'
    }

    It 'Merges with existing questions by id' {
        $stateRoot = Join-Path $TestDrive 'merge-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        # First save
        $q1 = @(@{ id = 'q1'; question = 'Original?'; choices = @() })
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'test-agent' `
            -RunId 'run-001' -Questions $q1

        # Second save with same id (updated text) + new question
        $q2 = @(
            @{ id = 'q1'; question = 'Updated?'; choices = @('A', 'B') }
            @{ id = 'q2'; question = 'New question?'; choices = @() }
        )
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'test-agent' `
            -RunId 'run-002' -Questions $q2

        $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'test-agent'
        $pending.Count | Should -Be 2
        ($pending | Where-Object { $_.id -eq 'q1' }).question | Should -Be 'Updated?'
        ($pending | Where-Object { $_.id -eq 'q2' }).question | Should -Be 'New question?'
    }

    It 'Sets expiresAt to null when ExpirationDays is 0' {
        $stateRoot = Join-Path $TestDrive 'no-expire\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        $questions = @(@{ id = 'q1'; question = 'Permanent?' })
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'perm-agent' `
            -RunId 'run-001' -Questions $questions -ExpirationDays 0

        $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'perm-agent'
        $pending[0].expiresAt | Should -BeNullOrEmpty
    }
}

# ===== Get-Questions =====

Describe 'Get-Questions' {
    It 'Returns pending and answered questions across agents' {
        $stateRoot = Join-Path $TestDrive 'all-questions-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'agent-a' `
            -RunId 'run-a' -Questions @(@{ id = 'q1'; question = 'Pending?' })
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'agent-b' `
            -RunId 'run-b' -Questions @(@{ id = 'q2'; question = 'Answered?' })
        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'agent-b' -QuestionId 'q2' -Answer 'Done'

        $questions = Get-Questions -StateRoot $stateRoot
        $questions.Count | Should -Be 2
        ($questions | Where-Object { $_.id -eq 'q1' }).answer | Should -BeNullOrEmpty
        ($questions | Where-Object { $_.id -eq 'q2' }).answer | Should -Be 'Done'
    }
}

# ===== Get-PendingQuestions =====

Describe 'Get-PendingQuestions' {
    It 'Returns only unanswered questions' {
        $stateRoot = Join-Path $TestDrive 'pending-test\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $data = @(
            [ordered]@{ id = 'q1'; question = 'Unanswered'; agentId = 'a1'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
            [ordered]@{ id = 'q2'; question = 'Answered'; agentId = 'a1'; answer = 'Yes'; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'a1'
        $pending.Count | Should -Be 1
        $pending[0].id | Should -Be 'q1'
    }

    It 'Returns questions across all agents when no AgentId specified' {
        $stateRoot = Join-Path $TestDrive 'all-agents\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $a1 = @([ordered]@{ id = 'q1'; question = 'Q1'; agentId = 'agent-a'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null })
        $a2 = @([ordered]@{ id = 'q2'; question = 'Q2'; agentId = 'agent-b'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null })
        $a1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'agent-a.json') -Encoding UTF8
        $a2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'agent-b.json') -Encoding UTF8

        $pending = Get-PendingQuestions -StateRoot $stateRoot
        $pending.Count | Should -Be 2
    }

    It 'Returns empty array when no questions exist' {
        $stateRoot = Join-Path $TestDrive 'empty-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'nonexistent'
        $pending.Count | Should -Be 0
    }
}

# ===== Set-QuestionAnswer =====

Describe 'Set-QuestionAnswer' {
    It 'Records answer for a specific question' {
        $stateRoot = Join-Path $TestDrive 'answer-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        $questions = @(@{ id = 'q1'; question = 'Move items?' })
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'test-agent' `
            -RunId 'run-001' -Questions $questions

        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'test-agent' `
            -QuestionId 'q1' -Answer 'Yes, move them'

        $answered = Get-AnsweredQuestions -StateRoot $stateRoot -AgentId 'test-agent'
        $answered.Count | Should -Be 1
        $answered[0].answer | Should -Be 'Yes, move them'

        $pending = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'test-agent'
        $pending.Count | Should -Be 0
    }

    It 'Returns answered questions across agents when no AgentId is specified' {
        $stateRoot = Join-Path $TestDrive 'answer-all-test\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'agent-a' `
            -RunId 'run-a' -Questions @(@{ id = 'q1'; question = 'A?' })
        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'agent-b' `
            -RunId 'run-b' -Questions @(@{ id = 'q2'; question = 'B?' })

        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'agent-a' -QuestionId 'q1' -Answer 'Answer A'
        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'agent-b' -QuestionId 'q2' -Answer 'Answer B'

        $answered = Get-AnsweredQuestions -StateRoot $stateRoot
        $answered.Count | Should -Be 2
        @($answered | ForEach-Object { $_.answer }) | Should -Contain 'Answer A'
        @($answered | ForEach-Object { $_.answer }) | Should -Contain 'Answer B'
    }
}

# ===== Clear-AnsweredQuestions =====

Describe 'Clear-AnsweredQuestions' {
    It 'Removes answered questions and keeps unanswered' {
        $stateRoot = Join-Path $TestDrive 'clear-test\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $data = @(
            [ordered]@{ id = 'q1'; question = 'Answered'; agentId = 'a1'; answer = 'Yes'; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
            [ordered]@{ id = 'q2'; question = 'Pending'; agentId = 'a1'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        Clear-AnsweredQuestions -StateRoot $stateRoot -AgentId 'a1'

        $path = Join-Path $dir 'a1.json'
        $remaining = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        @($remaining).Count | Should -Be 1
        $remaining[0].id | Should -Be 'q2'
    }

    It 'Removes file when all questions are answered' {
        $stateRoot = Join-Path $TestDrive 'clear-all\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $data = @(
            [ordered]@{ id = 'q1'; question = 'Done'; agentId = 'a1'; answer = 'Yes'; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        Clear-AnsweredQuestions -StateRoot $stateRoot -AgentId 'a1'

        Test-Path (Join-Path $dir 'a1.json') | Should -Be $false
    }
}

# ===== Remove-ExpiredQuestions =====

Describe 'Remove-ExpiredQuestions' {
    It 'Removes expired unanswered questions' {
        $stateRoot = Join-Path $TestDrive 'expire-test\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $past = [datetime]::UtcNow.AddDays(-1).ToString('o')
        $future = [datetime]::UtcNow.AddDays(7).ToString('o')

        $data = @(
            [ordered]@{ id = 'expired'; question = 'Old'; agentId = 'a1'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $past }
            [ordered]@{ id = 'valid'; question = 'Fresh'; agentId = 'a1'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $future }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        Remove-ExpiredQuestions -StateRoot $stateRoot

        $remaining = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'a1'
        $remaining.Count | Should -Be 1
        $remaining[0].id | Should -Be 'valid'
    }

    It 'Keeps answered questions regardless of expiration' {
        $stateRoot = Join-Path $TestDrive 'expire-answered\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $past = [datetime]::UtcNow.AddDays(-1).ToString('o')

        $data = @(
            [ordered]@{ id = 'answered-expired'; question = 'Old but answered'; agentId = 'a1'; answer = 'Done'; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $past }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        Remove-ExpiredQuestions -StateRoot $stateRoot

        $all = Get-AnsweredQuestions -StateRoot $stateRoot -AgentId 'a1'
        $all.Count | Should -Be 1
    }

    It 'Keeps questions with null expiresAt' {
        $stateRoot = Join-Path $TestDrive 'no-expire-test\.cronstate'
        $dir = Join-Path $stateRoot 'pending-questions'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $data = @(
            [ordered]@{ id = 'permanent'; question = 'Never expires'; agentId = 'a1'; answer = $null; choices = @(); recommended = $null; context = $null; runId = 'r1'; askedAt = '2025-01-01'; expiresAt = $null }
        )
        $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'a1.json') -Encoding UTF8

        Remove-ExpiredQuestions -StateRoot $stateRoot

        $remaining = Get-PendingQuestions -StateRoot $stateRoot -AgentId 'a1'
        $remaining.Count | Should -Be 1
    }
}

# ===== Test-AgentHasPendingQuestions =====

Describe 'Test-AgentHasPendingQuestions' {
    It 'Returns true when agent has unanswered questions' {
        $stateRoot = Join-Path $TestDrive 'has-q\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'blocked-agent' `
            -RunId 'run-001' -Questions @(@{ id = 'q1'; question = 'Pending?' })

        $result = Test-AgentHasPendingQuestions -StateRoot $stateRoot -AgentId 'blocked-agent'
        $result | Should -Be $true
    }

    It 'Returns false when agent has no questions' {
        $stateRoot = Join-Path $TestDrive 'no-q\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        $result = Test-AgentHasPendingQuestions -StateRoot $stateRoot -AgentId 'free-agent'
        $result | Should -Be $false
    }

    It 'Returns false when all questions are answered' {
        $stateRoot = Join-Path $TestDrive 'all-answered\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'done-agent' `
            -RunId 'run-001' -Questions @(@{ id = 'q1'; question = 'Done?' })
        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'done-agent' `
            -QuestionId 'q1' -Answer 'Yes'

        $result = Test-AgentHasPendingQuestions -StateRoot $stateRoot -AgentId 'done-agent'
        $result | Should -Be $false
    }
}

# ===== Write-AnswersFile =====

Describe 'Write-AnswersFile' {
    It 'Writes answers.json with answered questions' {
        $stateRoot = Join-Path $TestDrive 'write-answers\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null
        $runDir = Join-Path $TestDrive 'write-answers-run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        Save-AgentQuestions -StateRoot $stateRoot -AgentId 'test-agent' `
            -RunId 'run-001' -Questions @(
                @{ id = 'q1'; question = 'Archive?'; context = '7 emails' }
                @{ id = 'q2'; question = 'Move?'; context = '3 items' }
            )

        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'test-agent' `
            -QuestionId 'q1' -Answer 'Yes'
        Set-QuestionAnswer -StateRoot $stateRoot -AgentId 'test-agent' `
            -QuestionId 'q2' -Answer 'No'

        $result = Write-AnswersFile -StateRoot $stateRoot -AgentId 'test-agent' -RunDirectory $runDir
        $result | Should -Not -BeNullOrEmpty

        $answersPath = Join-Path $runDir 'answers.json'
        Test-Path $answersPath | Should -Be $true

        $answers = Get-Content -LiteralPath $answersPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($answers).Count | Should -Be 2
        ($answers | Where-Object { $_.id -eq 'q1' }).answer | Should -Be 'Yes'
        ($answers | Where-Object { $_.id -eq 'q2' }).answer | Should -Be 'No'
    }

    It 'Returns null when no answered questions exist' {
        $stateRoot = Join-Path $TestDrive 'no-answers\.cronstate'
        New-Item -ItemType Directory -Path (Join-Path $stateRoot 'pending-questions') -Force | Out-Null
        $runDir = Join-Path $TestDrive 'no-answers-run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $result = Write-AnswersFile -StateRoot $stateRoot -AgentId 'empty-agent' -RunDirectory $runDir
        $result | Should -BeNullOrEmpty
    }
}
