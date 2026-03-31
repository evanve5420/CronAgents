<#
.SYNOPSIS
    Pester 5 tests for the CronAgents HTML Dashboard server.
    Tests the HTTP server lifecycle, all API endpoints (GET + POST),
    HTML serving, error handling, and data integrity.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:dashboardScript = Join-Path $repoRoot 'scheduler/Start-DashboardServer.ps1'
    $script:dashboardHtml   = Join-Path $repoRoot 'scheduler/dashboard.html'
}

# ── Unit Tests: Data Payload Functions ────────────────────────────────
# These tests exercise the data layer without starting the HTTP server.

Describe 'Dashboard — Data Layer' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'DashData'
        $null = New-TestAgentConfig -TestEnv $testEnv -AgentId 'test-agent' `
            -Schedule @{ type = 'daily'; time = '09:00' } `
            -Prompt 'Test prompt' -Name 'Test Agent'
        $script:stateFile = Join-Path $testEnv.StatePath 'state.json'
        $script:runsRoot  = $testEnv.RunsRoot
        $script:stateRoot = $testEnv.StatePath
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Agent discovery returns registered agents' {
        $agents = Get-AgentConfigs -RepoRoot $testEnv.Root
        $agents.Count | Should -BeGreaterOrEqual 1
        $agents[0].Id | Should -Be 'test-agent'
        $agents[0].Config.name | Should -Be 'Test Agent'
    }

    It 'State returns default values for new environment' {
        $state = Get-AgentState -StateFile $script:stateFile
        $state.schedulerPaused | Should -Be $false
    }

    It 'Run history returns empty for new environment' {
        $runs = Get-RunHistory -RunsRoot $script:runsRoot
        $runs.Count | Should -Be 0
    }

    It 'Run history returns runs with meta after creating a run directory' {
        $runDir = New-RunDirectory -RunsRoot $script:runsRoot -AgentId 'test-agent'
        Write-RunMetadata -RunDirectory $runDir -AgentId 'test-agent' -AgentName 'Test Agent' `
            -Prompt 'Test prompt' -StartTime ([datetime]::UtcNow.AddMinutes(-5)) `
            -EndTime ([datetime]::UtcNow) -ExitCode 0

        $runs = Get-RunHistory -RunsRoot $script:runsRoot
        $runs.Count | Should -Be 1
        $runs[0].AgentId | Should -Be 'test-agent'
        $runs[0].Meta.exitCode | Should -Be 0
    }

    It 'Pending questions returns empty for new environment' {
        $questions = Get-PendingQuestions -StateRoot $script:stateRoot
        $questions.Count | Should -Be 0
    }

    It 'Saved questions appear in pending list' {
        Save-AgentQuestions -StateRoot $script:stateRoot -AgentId 'test-agent' -RunId 'test-run' `
            -Questions @(@{ id = 'q1'; question = 'What color?'; choices = @('red','blue'); recommended = 'blue'; context = $null })
        $pending = Get-PendingQuestions -StateRoot $script:stateRoot
        $pending.Count | Should -Be 1
        $pending[0].question | Should -Be 'What color?'
    }

    It 'Answering a question removes it from pending' {
        Save-AgentQuestions -StateRoot $script:stateRoot -AgentId 'test-agent' -RunId 'test-run' `
            -Questions @(@{ id = 'q1'; question = 'What color?'; choices = @(); recommended = $null; context = $null })
        Set-QuestionAnswer -StateRoot $script:stateRoot -AgentId 'test-agent' -QuestionId 'q1' -Answer 'green'
        $pending = Get-PendingQuestions -StateRoot $script:stateRoot
        $pending.Count | Should -Be 0
    }
}

# ── Integration Tests: HTTP Server ────────────────────────────────────

Describe 'Dashboard — HTTP Server' {
    BeforeAll {
        $script:testEnv = New-TestEnvironment -Name 'DashHTTP'
        $null = New-TestAgentConfig -TestEnv $script:testEnv -AgentId 'http-agent' `
            -Schedule @{ type = 'daily'; time = '10:00' } `
            -Prompt 'HTTP test prompt' -Name 'HTTP Agent'

        # Rewrite config to point personalRepo.path at the test root
        # so the server finds .cronstate/ in the temp directory
        $configPath = $script:testEnv.ConfigPath
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.personalRepo.path = $script:testEnv.Root
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

        # Create a run with metadata
        $script:runDir = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
        Write-RunMetadata -RunDirectory $script:runDir -AgentId 'http-agent' -AgentName 'HTTP Agent' `
            -Prompt 'HTTP test prompt' -StartTime ([datetime]::UtcNow.AddMinutes(-2)) `
            -EndTime ([datetime]::UtcNow) -ExitCode 0
        $script:runId = Split-Path $script:runDir -Leaf

        # Create a multi-line summary to test excerpt vs full content
        Set-Content -LiteralPath (Join-Path $script:runDir 'summary.md') `
            -Value "# Run Summary`nDetailed line two`nLine three with more info" -Encoding UTF8

        # Save a pending question
        $qStateRoot = $script:testEnv.StatePath
        Save-AgentQuestions -StateRoot $qStateRoot -AgentId 'http-agent' -RunId $script:runId `
            -Questions @(@{
                id = 'test-q1'; question = 'Pick a color?'
                choices = @('red','green','blue'); recommended = 'green'; context = 'For the UI theme'
            })

        # Find an open port
        $script:port = 19077
        for ($p = 19077; $p -lt 19100; $p++) {
            try {
                $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
                $tcp.Start()
                $tcp.Stop()
                $script:port = $p
                break
            } catch { continue }
        }

        $script:baseUrl = "http://127.0.0.1:$($script:port)"

        # Start dashboard server in a background job
        $dashScript = $script:dashboardScript
        $script:job = Start-Job -ScriptBlock {
            param($s, $r, $p)
            & $s -RepoRoot $r -Port $p -NoBrowser
        } -ArgumentList $dashScript, $script:testEnv.Root, $script:port

        # Wait for the server to become responsive (up to 15 seconds)
        $deadline = (Get-Date).AddSeconds(15)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            try {
                $null = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -TimeoutSec 2 -ErrorAction Stop
                $ready = $true
                break
            } catch { }
        }

        if (-not $ready) {
            $output = Receive-Job $script:job 2>&1 | Out-String
            Stop-Job $script:job -ErrorAction SilentlyContinue
            Remove-Job $script:job -Force -ErrorAction SilentlyContinue
            throw "Dashboard server did not become ready within 15 seconds. Output: $output"
        }
    }

    AfterAll {
        if ($script:job) {
            Stop-Job $script:job -ErrorAction SilentlyContinue
            Remove-Job $script:job -Force -ErrorAction SilentlyContinue
        }
        Remove-TestEnvironment -TestEnv $script:testEnv
    }

    # ── HTML Serving ─────────────────────────────────────────────

    Context 'Static file serving' {
        It 'GET / returns HTML' {
            $response = Invoke-WebRequest -Uri "$($script:baseUrl)/" -ErrorAction Stop
            $response.StatusCode | Should -Be 200
            $response.Headers['Content-Type'] | Should -Match 'text/html'
            $response.Content | Should -Match 'CronAgents Dashboard'
        }

        It 'GET /dashboard.html returns HTML' {
            $response = Invoke-WebRequest -Uri "$($script:baseUrl)/dashboard.html" -ErrorAction Stop
            $response.StatusCode | Should -Be 200
            $response.Content | Should -Match 'CronAgents Dashboard'
        }
    }

    # ── GET Endpoints ────────────────────────────────────────────

    Context 'GET /api/status' {
        It 'Returns status payload with agents' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $data.schedulerPaused | Should -Be $false
            $data.agents | Should -Not -BeNullOrEmpty
            $data.timestamp | Should -Not -BeNullOrEmpty
        }

        It 'Contains the registered agent' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $data.agents | Where-Object { $_.id -eq 'http-agent' }
            $agent | Should -Not -BeNullOrEmpty
            $agent.name | Should -Be 'HTTP Agent'
            $agent.enabled | Should -Be $true
        }

        It 'Agent has schedule information' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $data.agents | Where-Object { $_.id -eq 'http-agent' }
            $agent.schedule.type | Should -Be 'daily'
            $agent.schedule.time | Should -Be '10:00'
        }
    }

    Context 'GET /api/agents' {
        It 'Returns agent list' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/agents" -ErrorAction Stop
            $data.Count | Should -BeGreaterOrEqual 1
        }

        It 'Agent has id, name, schedule, enabled fields' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/agents" -ErrorAction Stop
            $agent = $data | Where-Object { $_.id -eq 'http-agent' }
            $agent.id | Should -Be 'http-agent'
            $agent.name | Should -Be 'HTTP Agent'
            $agent.enabled | Should -Be $true
        }
    }

    Context 'GET /api/runs' {
        It 'Returns run history' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" -ErrorAction Stop
            $data.Count | Should -BeGreaterOrEqual 1
        }

        It 'Run has expected fields' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" -ErrorAction Stop
            $run = $data | Where-Object { $_.agentId -eq 'http-agent' } | Select-Object -First 1
            $run.agentId | Should -Be 'http-agent'
            $run.id | Should -Not -BeNullOrEmpty
            $run.timestamp | Should -Not -BeNullOrEmpty
            $run.meta | Should -Not -BeNullOrEmpty
            $run.meta.exitCode | Should -Be 0
        }

        It 'Run includes summary content' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" -ErrorAction Stop
            $run = $data | Where-Object { $_.agentId -eq 'http-agent' } | Select-Object -First 1
            $run.hasSummary | Should -Be $true
            $run.summary | Should -Match 'Run Summary'
        }

        It 'Run list returns only first line of summary (not full content)' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" -ErrorAction Stop
            $run = $data | Where-Object { $_.agentId -eq 'http-agent' } | Select-Object -First 1
            $run.summary | Should -Be '# Run Summary'
            $run.summary | Should -Not -Match 'Detailed line two'
        }

        It 'Filters by agent query parameter' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs?agent=http-agent" -ErrorAction Stop
            @($data).Count | Should -BeGreaterOrEqual 1
            @($data) | ForEach-Object { $_.agentId | Should -Be 'http-agent' }
        }

        It 'Returns empty array for non-existent agent filter' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs?agent=nonexistent" -ErrorAction Stop
            @($data).Count | Should -Be 0
        }
    }

    Context 'GET /api/runs/:id' {
        It 'Returns run detail for valid ID' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$($script:runId)" -ErrorAction Stop
            $data.id | Should -Be $script:runId
            $data.meta | Should -Not -BeNullOrEmpty
            $data.summary | Should -Match 'Run Summary'
        }

        It 'Returns full multi-line summary (not truncated)' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$($script:runId)" -ErrorAction Stop
            $data.summary | Should -Match 'Run Summary'
            $data.summary | Should -Match 'Detailed line two'
            $data.summary | Should -Match 'Line three with more info'
        }

        It 'Returns 404 for non-existent run' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/99990101T000000_fake_0000" -ErrorAction Stop
            } catch {
                $err = $_
            }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }

        It 'Returns 404 for invalid run ID format' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/../../etc/passwd" -ErrorAction Stop
            } catch {
                $err = $_
            }
            $err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'GET /api/questions' {
        It 'Returns pending questions' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions" -ErrorAction Stop
            @($data).Count | Should -BeGreaterOrEqual 1
        }

        It 'Question has expected fields' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions" -ErrorAction Stop
            $q = @($data) | Where-Object { $_.id -eq 'test-q1' } | Select-Object -First 1
            $q | Should -Not -BeNullOrEmpty
            $q.question | Should -Be 'Pick a color?'
            $q.agentId | Should -Be 'http-agent'
            @($q.choices).Count | Should -Be 3
        }
    }

    # ── POST Endpoints ───────────────────────────────────────────

    Context 'POST /api/pause and /api/resume' {
        It 'Global pause sets schedulerPaused=true' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/pause" -Method Post -ErrorAction Stop
            $data.ok | Should -Be $true

            $status = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $status.schedulerPaused | Should -Be $true
        }

        It 'Global resume clears schedulerPaused' {
            Invoke-RestMethod -Uri "$($script:baseUrl)/api/resume" -Method Post -ErrorAction Stop

            $status = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $status.schedulerPaused | Should -Be $false
        }

        It 'Per-agent pause disables agent' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/pause/http-agent" -Method Post -ErrorAction Stop
            $data.ok | Should -Be $true

            $status = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $status.agents | Where-Object { $_.id -eq 'http-agent' }
            $agent.enabled | Should -Be $false
        }

        It 'Per-agent resume enables agent' {
            Invoke-RestMethod -Uri "$($script:baseUrl)/api/resume/http-agent" -Method Post -ErrorAction Stop

            $status = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $status.agents | Where-Object { $_.id -eq 'http-agent' }
            $agent.enabled | Should -Be $true
        }

        It 'Per-agent pause returns 404 for unknown agent' {
            $threw = $false
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/pause/nonexistent-agent" `
                    -Method Post -ErrorAction Stop
            } catch {
                $threw = $true
                $_.Exception.Response.StatusCode.Value__ | Should -Be 404
            }
            $threw | Should -Be $true
        }

        It 'Per-agent resume returns 404 for unknown agent' {
            $threw = $false
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/resume/nonexistent-agent" `
                    -Method Post -ErrorAction Stop
            } catch {
                $threw = $true
                $_.Exception.Response.StatusCode.Value__ | Should -Be 404
            }
            $threw | Should -Be $true
        }
    }

    Context 'POST /api/feedback/:runId' {
        It 'Saves feedback for valid run' {
            $body = @{ feedback = 'Great job on this run!' } | ConvertTo-Json
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/feedback/$($script:runId)" `
                -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            $data.ok | Should -Be $true

            # Verify it was written
            $fbPath = Join-Path $script:runDir 'feedback.md'
            $content = Get-Content -LiteralPath $fbPath -Raw
            $content | Should -Match 'Great job'
        }

        It 'Returns 404 for non-existent run' {
            $body = @{ feedback = 'test' } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/feedback/99990101T000000_fake_0000" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }

        It 'Returns 400 for missing feedback field' {
            $body = @{ text = 'wrong field' } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/feedback/$($script:runId)" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Returns 400 for invalid JSON body' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/feedback/$($script:runId)" `
                    -Method Post -Body 'not json' -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Returns error for path traversal attempt in run ID' {
            $body = @{ feedback = 'test' } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/feedback/invalid..path" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            # Invalid format returns 400; path resolution may return 404
            $err.Exception.Response.StatusCode.value__ | Should -BeIn @(400, 404)
        }
    }

    Context 'POST /api/questions/:agent/:questionId' {
        BeforeAll {
            # Save a fresh question so the test doesn't depend on previous contexts
            Save-AgentQuestions -StateRoot $script:testEnv.StatePath -AgentId 'http-agent' -RunId 'q-test-run' `
                -Questions @(@{
                    id = 'answer-q1'; question = 'Favorite number?'
                    choices = @('1','2','3'); recommended = '2'; context = 'Just a test'
                })
        }

        It 'Answers a pending question' {
            $body = @{ answer = '42' } | ConvertTo-Json
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions/http-agent/answer-q1" `
                -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            $data.ok | Should -Be $true

            # Verify the question is no longer pending
            $questions = Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions" -ErrorAction Stop
            $remaining = @($questions) | Where-Object { $_.id -eq 'answer-q1' }
            $remaining.Count | Should -Be 0
        }

        It 'Returns 400 for missing answer field' {
            $body = @{ response = 'wrong field' } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions/http-agent/test-q1" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Returns 400 for path-traversal agent ID' {
            $body = @{ answer = 'test' } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/questions/../etc/test-q1" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'POST /api/run/:agent' {
        It 'Returns success for known agent' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/run/http-agent" `
                -Method Post -ErrorAction Stop
            $data.ok | Should -Be $true
            $data.message | Should -Match 'http-agent'
        }

        It 'Returns 404 for unknown agent' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/run/nonexistent-agent" `
                    -Method Post -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }
    }

    # ── Error Handling ───────────────────────────────────────────

    Context '404 handling' {
        It 'Returns 404 for unknown routes' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/nonexistent" -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }

        It 'Returns 404 for unknown static paths' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/nonexistent.html" -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }
    }
}

# ── HTML File Existence ──────────────────────────────────────────────

Describe 'Dashboard — File Integrity' {
    It 'dashboard.html exists in scheduler directory' {
        Test-Path -LiteralPath $script:dashboardHtml | Should -Be $true
    }

    It 'dashboard.html contains essential elements' {
        $content = Get-Content -LiteralPath $script:dashboardHtml -Raw
        $content | Should -Match 'CronAgents Dashboard'
        $content | Should -Match '/api/status'
        $content | Should -Match '/api/runs'
        $content | Should -Match '/api/questions'
        $content | Should -Match '/api/pause'
        $content | Should -Match '/api/resume'
        $content | Should -Match '/api/feedback'
    }

    It 'Start-DashboardServer.ps1 exists' {
        Test-Path -LiteralPath $script:dashboardScript | Should -Be $true
    }
}

# ── CLI Integration ──────────────────────────────────────────────────

Describe 'Dashboard — CLI Integration' {
    BeforeAll {
        $cliScript = Join-Path $repoRoot 'cronagents.ps1'
    }

    It 'help text includes dashboard command' {
        $output = & $cliScript 'help' 6>&1 2>&1
        $text = ($output | Out-String)
        $text | Should -Match 'dashboard'
    }
}
