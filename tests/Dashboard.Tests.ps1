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

    It 'Get-RunHistory returns runs for unregistered agents (low-level, unfiltered)' {
        # Create a run for an agent that is NOT registered
        $unregRunDir = New-RunDirectory -RunsRoot $script:runsRoot -AgentId 'ghost-agent'
        Write-RunMetadata -RunDirectory $unregRunDir -AgentId 'ghost-agent' -AgentName 'Ghost' `
            -Prompt 'boo' -StartTime ([datetime]::UtcNow.AddMinutes(-1)) `
            -EndTime ([datetime]::UtcNow) -ExitCode 0

        $runs = Get-RunHistory -RunsRoot $script:runsRoot
        $ghostRuns = $runs | Where-Object { $_.AgentId -eq 'ghost-agent' }
        $ghostRuns.Count | Should -BeGreaterOrEqual 1
    }

    It 'Filtering run history by registered agents excludes unregistered agents (issue #90)' {
        # Create a run for an unregistered agent
        $unregRunDir = New-RunDirectory -RunsRoot $script:runsRoot -AgentId 'deleted-agent'
        Write-RunMetadata -RunDirectory $unregRunDir -AgentId 'deleted-agent' -AgentName 'Deleted' `
            -Prompt 'gone' -StartTime ([datetime]::UtcNow.AddMinutes(-1)) `
            -EndTime ([datetime]::UtcNow) -ExitCode 0

        # Create a run for the registered agent
        $regRunDir = New-RunDirectory -RunsRoot $script:runsRoot -AgentId 'test-agent'
        Write-RunMetadata -RunDirectory $regRunDir -AgentId 'test-agent' -AgentName 'Test Agent' `
            -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-1)) `
            -EndTime ([datetime]::UtcNow) -ExitCode 0

        $allRuns = Get-RunHistory -RunsRoot $script:runsRoot
        $registeredIds = @(Get-AgentConfigs -RepoRoot $testEnv.Root | ForEach-Object { $_.Id })
        $filteredRuns = @($allRuns | Where-Object { $_.AgentId -in $registeredIds })

        # Filtered results should contain only registered agents
        $filteredRuns.Count | Should -BeGreaterOrEqual 1
        $filteredRuns | ForEach-Object { $_.AgentId | Should -Be 'test-agent' }
        ($filteredRuns | Where-Object { $_.AgentId -eq 'deleted-agent' }).Count | Should -Be 0
    }
}

# ── Integration Tests: HTTP Server ────────────────────────────────────

Describe 'Dashboard — HTTP Server' -Tag 'Slow' {
    BeforeAll {
        $script:testEnv = New-TestEnvironment -Name 'DashHTTP'
        $null = New-TestAgentConfig -TestEnv $script:testEnv -AgentId 'http-agent' `
            -Schedule @{ type = 'daily'; time = '10:00' } `
            -Prompt 'HTTP test prompt' -Name 'HTTP Agent'
        @{
            name             = 'HTTP Working Dir Agent'
            agent            = 'http-working-dir'
            prompt           = 'HTTP working directory test prompt'
            schedule         = @{ type = 'daily'; time = '11:00' }
            workingDirectory = $script:testEnv.Root
        } | ConvertTo-Json -Depth 5 | Set-Content `
            -LiteralPath (Join-Path $script:testEnv.AgentsDir 'http-working-dir.agent-registration.json') `
            -Encoding UTF8

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
        Set-Content -LiteralPath (Join-Path $script:runDir 'output.md') `
            -Value "Primary output line`n`n---`n**stderr:**`nMock stderr line" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:runDir 'scheduler.log') `
            -Value "[2026-01-01T00:00:00Z] [ERROR] Mock scheduler failure detail" -Encoding UTF8

        # Save a pending question
        $qStateRoot = $script:testEnv.StatePath
        Save-AgentQuestions -StateRoot $qStateRoot -AgentId 'http-agent' -RunId $script:runId `
            -Questions @(@{
                id = 'test-q1'; question = 'Pick a color?'
                choices = @('red','green','blue'); recommended = 'green'; context = 'For the UI theme'
            })

        # Ask the OS for a free loopback port to avoid collisions with other test workers.
        $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $portProbe.Start()
            $script:port = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        }
        finally {
            $portProbe.Stop()
        }

        $script:baseUrl = "http://127.0.0.1:$($script:port)"

        # Start dashboard server in a background job
        $dashScript = $script:dashboardScript
        $script:job = Start-Job -ScriptBlock {
            param($s, $r, $p)
            & $s -RepoRoot $r -Port $p -NoBrowser
        } -ArgumentList $dashScript, $script:testEnv.Root, $script:port

        # Wait for the server to become responsive. Under the multi-worker test runner,
        # the dashboard process can take longer to start on busy CI hosts.
        $deadline = (Get-Date).AddSeconds(60)
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
            throw "Dashboard server did not become ready within 60 seconds. Output: $output"
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

        It 'Agent includes pendingQuestions count' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $data.agents | Where-Object { $_.id -eq 'http-agent' }
            $agent.pendingQuestions | Should -BeGreaterOrEqual 1
        }

        It 'Agent with no questions has pendingQuestions zero' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/status" -ErrorAction Stop
            $agent = $data.agents | Where-Object { $_.id -eq 'http-working-dir' }
            $agent.pendingQuestions | Should -Be 0
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

        It 'Excludes runs for unregistered/deleted agents (issue #90)' {
            # Create a run for an agent that is NOT registered
            $unregDir = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'ghost-agent'
            Write-RunMetadata -RunDirectory $unregDir -AgentId 'ghost-agent' -AgentName 'Ghost' `
                -Prompt 'boo' -StartTime ([datetime]::UtcNow.AddMinutes(-1)) `
                -EndTime ([datetime]::UtcNow) -ExitCode 0
            Set-Content -LiteralPath (Join-Path $unregDir 'summary.md') `
                -Value "---`nattention: true`nheadline: `"Ghost alert`"`n---`nShould not appear." -Encoding UTF8

            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" -ErrorAction Stop
            $ghostRuns = @($data | Where-Object { $_.agentId -eq 'ghost-agent' })
            $ghostRuns.Count | Should -Be 0
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

        It 'Returns output, scheduler log, and run directory for run detail' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$($script:runId)" -ErrorAction Stop
            $data.runDirectory | Should -Be $script:runDir
            $data.output | Should -Match 'Primary output line'
            $data.schedulerLog | Should -Match 'Mock scheduler failure detail'
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

        It 'Returns 400 for invalid run ID format' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/not-a-run-id" -ErrorAction Stop
            } catch {
                $err = $_
            }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
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

    Context 'GET /api/activity' {
        It 'Returns activity payload with commits array' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/activity" -ErrorAction Stop
            $data | Should -Not -BeNullOrEmpty
            # Test env has no .git, so commits should be empty
            @($data.commits).Count | Should -Be 0
        }

        It 'Returns null vsCodeLink when personal repo has no .git' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/activity" -ErrorAction Stop
            $data.vsCodeLink | Should -BeNullOrEmpty
        }

        It 'Returns vsCodeLink with correct vscode://file/ prefix when .git exists' {
            # Temporarily init a git repo so the server builds the deeplink
            & git init $script:testEnv.Root --quiet 2>$null
            try {
                $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/activity" -ErrorAction Stop
                $data.vsCodeLink | Should -Not -BeNullOrEmpty
                $data.vsCodeLink | Should -Match '^vscode://file/'
                # Authority must be exactly "file" — no path chars glued to it
                $data.vsCodeLink | Should -Not -Match '^vscode://file[^/]'
            }
            finally {
                Remove-Item -LiteralPath (Join-Path $script:testEnv.Root '.git') -Recurse -Force -ErrorAction SilentlyContinue
            }
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

        It 'Runs a working-directory agent through the dashboard job path' {
            $existingRunNames = @(
                Get-ChildItem -LiteralPath $script:testEnv.RunsRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*http-working-dir*' } |
                    Select-Object -ExpandProperty Name
            )
            $beforeRuns = $existingRunNames.Count

            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/run/http-working-dir" `
                -Method Post -ErrorAction Stop
            $data.ok | Should -Be $true

            # Poll for the run to complete. The background job chain is:
            # dashboard Start-Job → agent runner Start-Job → copilot process → summarizer process
            # On CI with parallel workers this can take significant time.
            $deadline = (Get-Date).AddSeconds(60)
            $newRunDir = $null
            while ((Get-Date) -lt $deadline -and -not $newRunDir) {
                Start-Sleep -Milliseconds 500
                $newRunDir = Get-ChildItem -LiteralPath $script:testEnv.RunsRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name -like '*http-working-dir*' -and
                        $_.Name -notin $existingRunNames
                    } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1

                if ($newRunDir) {
                    $metaPath = Join-Path $newRunDir.FullName 'meta.json'
                    if (-not (Test-Path -LiteralPath $metaPath)) {
                        $newRunDir = $null
                    }
                    else {
                        # Wait for the run to finish — exitCode is set by Write-RunMetadata
                        # ConvertFrom-Json can throw a terminating error on partial writes,
                        # so wrap in try/catch rather than relying on -ErrorAction.
                        $meta = $null
                        try {
                            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        } catch { }
                        if ($null -eq $meta -or $null -eq $meta.exitCode) {
                            $newRunDir = $null
                        }
                    }
                }
            }

            $newRunDir | Should -Not -BeNullOrEmpty
            @(
                Get-ChildItem -LiteralPath $script:testEnv.RunsRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*http-working-dir*' }
            ).Count | Should -BeGreaterThan $beforeRuns

            # Mock invocations should already exist since the copilot finished before
            # exitCode was written to meta.json. Give a generous window anyway.
            $invocations = @()
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and $invocations.Count -eq 0) {
                Start-Sleep -Milliseconds 500
                $invocations = @(Get-MockInvocations -LogPath $script:testEnv.MockLogPath |
                    Where-Object { $_.agent -eq 'http-working-dir' })
            }

            $invocations.Count | Should -BeGreaterOrEqual 1
            @($invocations[-1].addDir) | Should -Contain $script:testEnv.Root
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

    # ── DELETE /api/runs ─────────────────────────────────────────

    Context 'DELETE /api/runs/:id' {
        It 'Deletes a completed run and returns success' {
            # Create a new completed run to delete
            $delRunDir = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $delRunDir -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-1)) `
                -EndTime ([datetime]::UtcNow) -ExitCode 0
            $delRunId = Split-Path $delRunDir -Leaf

            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$delRunId" `
                -Method Delete -ErrorAction Stop
            $result.ok | Should -Be $true
            $result.deleted | Should -Be 1
            Test-Path $delRunDir | Should -Be $false
        }

        It 'Returns 404 for non-existent run ID' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/20260101T120000_noagent_abcd" `
                    -Method Delete -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 404
        }

        It 'Returns 400 for invalid run ID format' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/../traversal" `
                    -Method Delete -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $status = $err.Exception.Response.StatusCode.value__
            # May be 400 (invalid format) or 404 (path normalization)
            $status | Should -BeIn @(400, 404)
        }

        It 'Returns 409 when trying to delete an active run' {
            # Create an active (in-progress) run
            $activeDir = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Initialize-RunMetadata -RunDirectory $activeDir -AgentId 'http-agent' `
                -AgentName 'HTTP Agent' -Prompt 'running test'
            $activeRunId = Split-Path $activeDir -Leaf

            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$activeRunId" `
                    -Method Delete -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 409

            # Run should still exist
            Test-Path $activeDir | Should -Be $true
            # Clean up
            Remove-Item -LiteralPath $activeDir -Recurse -Force
        }

        It 'Allows deleting an incomplete run (no final metadata but output.md exists)' {
            # Create a run with active metadata but an output.md file (incomplete)
            $incompleteDir = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Initialize-RunMetadata -RunDirectory $incompleteDir -AgentId 'http-agent' `
                -AgentName 'HTTP Agent' -Prompt 'incomplete test'
            Set-Content -LiteralPath (Join-Path $incompleteDir 'output.md') -Value 'agent output' -Encoding UTF8
            $incompleteRunId = Split-Path $incompleteDir -Leaf

            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/$incompleteRunId" `
                -Method Delete -ErrorAction Stop
            $result.ok | Should -Be $true
            $result.deleted | Should -Be 1
            Test-Path $incompleteDir | Should -Be $false
        }
    }

    Context 'DELETE /api/runs (bulk)' {
        It 'Clears all completed runs' {
            # Create two completed runs
            $d1 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d1 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-3)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-2)) -ExitCode 0
            $d2 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d2 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-2)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-1)) -ExitCode 0

            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs" `
                -Method Delete -ErrorAction Stop
            $result.ok | Should -Be $true
            $result.deleted | Should -BeGreaterOrEqual 2
        }

        It 'Filters by agent query parameter' {
            # Create runs for two agents
            $d1 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d1 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-3)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-2)) -ExitCode 0

            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs?agent=http-agent" `
                -Method Delete -ErrorAction Stop
            $result.ok | Should -Be $true
            $result.deleted | Should -BeGreaterOrEqual 1
        }

        It 'Returns 400 for invalid agent query parameter' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs?agent=../bad" `
                    -Method Delete -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }
    }

    Context 'POST /api/runs/batch-delete' {
        It 'Deletes multiple runs by ID' {
            $d1 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d1 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-3)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-2)) -ExitCode 0
            $d2 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d2 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-2)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-1)) -ExitCode 1

            $ids = @((Split-Path $d1 -Leaf), (Split-Path $d2 -Leaf))
            $body = @{ ids = $ids } | ConvertTo-Json
            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop

            $result.ok | Should -Be $true
            $result.deleted | Should -Be 2
            Test-Path $d1 | Should -Be $false
            Test-Path $d2 | Should -Be $false
        }

        It 'Skips active runs and deletes the rest' {
            $dCompleted = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $dCompleted -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-2)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-1)) -ExitCode 0
            $dActive = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Initialize-RunMetadata -RunDirectory $dActive -AgentId 'http-agent' `
                -AgentName 'HTTP Agent' -Prompt 'running'

            $ids = @((Split-Path $dCompleted -Leaf), (Split-Path $dActive -Leaf))
            $body = @{ ids = $ids } | ConvertTo-Json
            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop

            $result.ok | Should -Be $true
            $result.deleted | Should -Be 1
            $result.skipped | Should -BeGreaterOrEqual 1
            Test-Path $dCompleted | Should -Be $false
            Test-Path $dActive | Should -Be $true

            # Clean up active run
            Remove-Item -LiteralPath $dActive -Recurse -Force
        }

        It 'Returns 400 when ids array is empty' {
            $err = $null
            try {
                $body = @{ ids = @() } | ConvertTo-Json
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Returns 400 when body is missing' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                    -Method Post -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Skips non-existent run IDs gracefully' {
            $d1 = New-RunDirectory -RunsRoot $script:testEnv.RunsRoot -AgentId 'http-agent'
            Write-RunMetadata -RunDirectory $d1 -AgentId 'http-agent' -AgentName 'HTTP Agent' `
                -Prompt 'test' -StartTime ([datetime]::UtcNow.AddMinutes(-2)) `
                -EndTime ([datetime]::UtcNow.AddMinutes(-1)) -ExitCode 0

            $ids = @((Split-Path $d1 -Leaf), '20260101T120000_noagent_abcd')
            $body = @{ ids = $ids } | ConvertTo-Json
            $result = Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop

            $result.ok | Should -Be $true
            $result.deleted | Should -Be 1
            $result.skipped | Should -BeGreaterOrEqual 1
            Test-Path $d1 | Should -Be $false
        }

        It 'Returns 400 when more than 200 IDs are provided' {
            $ids = 1..201 | ForEach-Object { "20260101T000000_fake_$($_.ToString('x4'))" }
            $body = @{ ids = $ids } | ConvertTo-Json
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                    -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }

        It 'Returns 400 for malformed JSON body' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/runs/batch-delete" `
                    -Method Post -Body 'not-json' -ContentType 'application/json' -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 400
        }
    }

    # ── Error Handling ───────────────────────────────────────────

    # ── GET /api/freshness ──────────────────────────────────────

    Context 'GET /api/freshness' {
        It 'Returns freshness payload with server info' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/freshness" -ErrorAction Stop
            $data.server | Should -Not -BeNullOrEmpty
            $data.server.pid | Should -BeGreaterThan 0
            $data.server.startedAt | Should -Not -BeNullOrEmpty
        }

        It 'Server reports not stale on a fresh start' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/freshness" -ErrorAction Stop
            $data.server.stale | Should -Be $false
        }

        It 'Includes page section with lastModified' {
            $data = Invoke-RestMethod -Uri "$($script:baseUrl)/api/freshness" -ErrorAction Stop
            $data.page | Should -Not -BeNullOrEmpty
            $data.page.lastModified | Should -Not -BeNullOrEmpty
        }
    }

    # ── POST /api/server/restart ────────────────────────────────

    Context 'POST /api/server/restart' {
        It 'Returns 403 when no Origin or Referer header is provided' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/server/restart" `
                    -Method Post -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 403
        }

        It 'Returns 403 for untrusted origin' {
            $err = $null
            try {
                Invoke-RestMethod -Uri "$($script:baseUrl)/api/server/restart" `
                    -Method Post -Headers @{ Origin = 'http://evil.example.com:9999' } -ErrorAction Stop
            } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Response.StatusCode.value__ | Should -Be 403
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

# ── Restart Endpoint (dedicated server instance) ─────────────────────
# The happy-path restart test triggers a real server shutdown, so it runs
# against its own short-lived server to avoid killing the main test instance.

Describe 'Dashboard — Restart Endpoint' -Tag 'Slow' {
    BeforeAll {
        $script:restartEnv = New-TestEnvironment -Name 'DashRestart'
        $null = New-TestAgentConfig -TestEnv $script:restartEnv -AgentId 'restart-agent' `
            -Schedule @{ type = 'daily'; time = '10:00' } `
            -Prompt 'Restart test prompt' -Name 'Restart Agent'

        $configPath = $script:restartEnv.ConfigPath
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.personalRepo.path = $script:restartEnv.Root
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $portProbe.Start()
            $script:restartPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        } finally {
            $portProbe.Stop()
        }

        $script:restartBaseUrl = "http://127.0.0.1:$($script:restartPort)"

        $dashScript = $script:dashboardScript
        $script:restartJob = Start-Job -ScriptBlock {
            param($s, $r, $p)
            & $s -RepoRoot $r -Port $p -NoBrowser
        } -ArgumentList $dashScript, $script:restartEnv.Root, $script:restartPort

        $deadline = (Get-Date).AddSeconds(60)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            try {
                $null = Invoke-RestMethod -Uri "$($script:restartBaseUrl)/api/status" -TimeoutSec 2 -ErrorAction Stop
                $ready = $true
                break
            } catch { }
        }

        if (-not $ready) {
            $output = Receive-Job $script:restartJob 2>&1 | Out-String
            Stop-Job $script:restartJob -ErrorAction SilentlyContinue
            Remove-Job $script:restartJob -Force -ErrorAction SilentlyContinue
            throw "Restart-test dashboard server did not become ready within 60 seconds. Output: $output"
        }
    }

    AfterAll {
        if ($script:restartJob) {
            Stop-Job $script:restartJob -ErrorAction SilentlyContinue
            Remove-Job $script:restartJob -Force -ErrorAction SilentlyContinue
        }
        # The restart happy-path spawns an independent pwsh process.
        # Clean up via the dashboard PID file that the new server writes.
        $pidFile = Join-Path $script:restartEnv.StatePath 'dashboard.pid'
        if (Test-Path -LiteralPath $pidFile) {
            try {
                $pidData = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
                $orphan = Get-Process -Id ([int]$pidData.pid) -ErrorAction SilentlyContinue
                if ($orphan -and -not $orphan.HasExited) {
                    Stop-Process -Id $orphan.Id -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        Remove-TestEnvironment -TestEnv $script:restartEnv
    }

    It 'Returns 200 with ok:true for trusted Referer' {
        $data = Invoke-RestMethod -Uri "$($script:restartBaseUrl)/api/server/restart" `
            -Method Post -Headers @{ Referer = "$($script:restartBaseUrl)/" } -ErrorAction Stop
        $data.ok | Should -Be $true
        $data.message | Should -Be 'Server restarting'
    }
}

Describe 'Dashboard — File Integrity' {
    It 'dashboard.html exists in scheduler directory' {
        Test-Path -LiteralPath $script:dashboardHtml | Should -Be $true
    }

    It 'dashboard.html contains essential elements' {
        $content = Get-Content -LiteralPath $script:dashboardHtml -Raw
        $content | Should -Match 'CronAgents Dashboard'
        $content | Should -Match 'rel="icon"'
        $content | Should -Match 'image/svg\+xml'
        $content | Should -Match '/api/status'
        $content | Should -Match '/api/runs'
        $content | Should -Match '/api/questions'
        $content | Should -Match '/api/pause'
        $content | Should -Match '/api/resume'
        $content | Should -Match '/api/feedback'
        $content | Should -Match '/api/freshness'
    }

    It 'dashboard.html renders pending-question badge in agent list' {
        $content = Get-Content -LiteralPath $script:dashboardHtml -Raw
        $content | Should -Match 'badge-question'
        $content | Should -Match 'pendingQuestions'
    }

    It 'dashboard.html contains multi-select and batch-delete elements' {
        $content = Get-Content -LiteralPath $script:dashboardHtml -Raw
        $content | Should -Match 'select-all-runs'
        $content | Should -Match 'selection-toolbar'
        $content | Should -Match 'deleteSelectedRuns'
        $content | Should -Match 'clearFilteredRuns'
        $content | Should -Match 'clear-filtered-btn'
        $content | Should -Match '/api/runs/batch-delete'
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
