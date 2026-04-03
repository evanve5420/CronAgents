<#
.SYNOPSIS
    CronAgents test runner - runs all Pester tests with process isolation.
.DESCRIPTION
    Pester 5 can hang when 15+ test containers import the same module in a single
    process (FileStream exclusive locks + module reimport contention). This runner
    executes each test file in its own pwsh subprocess for reliable results.
.PARAMETER ExcludeTag
    Tags to exclude. Defaults to 'E2E'.
.PARAMETER Filter
    Optional wildcard filter for test file names (e.g. 'Config*').
.PARAMETER MaxWorkers
    Maximum number of test-file subprocesses to run at once.
.PARAMETER PollIntervalMs
    Milliseconds to wait before checking for completed subprocesses again.
.EXAMPLE
    ./tests/Invoke-Tests.ps1
    ./tests/Invoke-Tests.ps1 -Filter 'Schedule*'
    ./tests/Invoke-Tests.ps1 -ExcludeTag 'E2E','Slow'
    ./tests/Invoke-Tests.ps1 -MaxWorkers 8
    ./tests/Invoke-Tests.ps1 -PollIntervalMs 100
#>
[CmdletBinding()]
param(
    [string[]]$ExcludeTag = @('E2E'),
    [string]$Filter = '*',
    [ValidateRange(1, 64)]
    [int]$MaxWorkers = 8,
    [ValidateRange(25, 2000)]
    [int]$PollIntervalMs = 100,
    [switch]$ChildRun,
    [string]$TestFile,
    [string]$ResultFile,
    [string]$ExcludeTagSerialized
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir = $PSScriptRoot
$runnerScriptPath = $PSCommandPath
$hostExecutablePath = (Get-Process -Id $PID -ErrorAction Stop).Path
if (-not $hostExecutablePath) {
    $hostExecutablePath = (Get-Command pwsh -ErrorAction Stop).Source
}

if ($ChildRun) {
    Set-Location $repoRoot
    $childExcludeTag = if ($PSBoundParameters.ContainsKey('ExcludeTagSerialized')) {
        @($ExcludeTagSerialized -split "`n" | Where-Object { $_ -ne '' })
    }
    else {
        $ExcludeTag
    }

    try {
        $result = Invoke-Pester $TestFile -ExcludeTag $childExcludeTag -Output None -PassThru
        [PSCustomObject]@{
            PassedCount   = $result.PassedCount
            FailedCount   = $result.FailedCount
            SkippedCount  = $result.SkippedCount
            FailedNames   = @($result.Failed | ForEach-Object { $_.Name })
            FailedDetails = @($result.Failed | ForEach-Object {
                $msg = $_.ErrorRecord.Exception.Message
                if ($msg.Length -gt 400) { $msg.Substring(0, 400) + '...' } else { $msg }
            })
        } | ConvertTo-Json -Compress | Set-Content -Path $ResultFile -Encoding utf8
        exit 0
    }
    catch {
        Write-Error $_
        exit 1
    }
}

$files = Get-ChildItem -Path $testDir -Filter "$Filter.Tests.ps1" | Sort-Object Name
if ($files.Count -eq 0) {
    Write-Host "No test files matching '$Filter.Tests.ps1' in $testDir" -ForegroundColor Yellow
    exit 1
}

$totalPassed = 0; $totalFailed = 0; $totalSkipped = 0
$failures = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-TestProcessDiagnostics {
    param(
        [Parameter(Mandatory)][pscustomobject]$RunningTest,
        [int]$MaxLines = 20
    )

    $diagnostics = @()
    $streams = @(
        @{ Label = 'stderr'; Path = $RunningTest.StdErrFile }
        @{ Label = 'stdout'; Path = $RunningTest.StdOutFile }
    )

    foreach ($stream in $streams) {
        if (-not (Test-Path $stream.Path)) {
            continue
        }

        $content = Get-Content -Path $stream.Path -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            continue
        }

        $diagnostics += "$($stream.Label):"
        $lines = @($content -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        if ($lines.Count -le $MaxLines) {
            $diagnostics += $lines
        }
        else {
            $diagnostics += $lines[0..($MaxLines - 1)]
            $diagnostics += "... ($($lines.Count - $MaxLines) more lines)"
        }
    }

    return $diagnostics
}

function Remove-TestProcessArtifacts {
    param(
        [Parameter(Mandatory)][pscustomobject]$RunningTest
    )

    @($RunningTest.ResultFile, $RunningTest.StdOutFile, $RunningTest.StdErrFile) |
        Where-Object { $_ } |
        ForEach-Object {
            Remove-Item $_ -Force -ErrorAction SilentlyContinue
        }
}

function Start-TestProcess {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$RunnerScriptPath,
        [Parameter(Mandatory)][string]$HostExecutablePath,
        [Parameter(Mandatory)][string[]]$ExcludeTag
    )

    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-test-$([guid]::NewGuid().ToString('N')).txt"
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-test-$([guid]::NewGuid().ToString('N')).stdout.txt"
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-test-$([guid]::NewGuid().ToString('N')).stderr.txt"

    $argumentList = @(
        '-NoProfile'
        '-File'
        $RunnerScriptPath
        '-ChildRun'
        '-TestFile'
        $File.FullName
        '-ResultFile'
        $resultFile
        '-ExcludeTagSerialized'
        ($ExcludeTag -join "`n")
    )

    $startArgs = @{
        FilePath               = $HostExecutablePath
        ArgumentList           = $argumentList
        RedirectStandardOutput = $stdoutFile
        RedirectStandardError  = $stderrFile
        PassThru               = $true
    }
    if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }

    [PSCustomObject]@{
        File       = $File
        Label      = $File.Name.Replace('.Tests.ps1', '')
        ResultFile = $resultFile
        StdOutFile = $stdoutFile
        StdErrFile = $stderrFile
        Process    = Start-Process @startArgs
    }
}

function Complete-TestProcess {
    param(
        [Parameter(Mandatory)][pscustomobject]$RunningTest
    )

    $label = $RunningTest.Label
    Write-Host -NoNewline "  $($label.PadRight(30))"
    $diagnostics = Get-TestProcessDiagnostics -RunningTest $RunningTest

    if (Test-Path $RunningTest.ResultFile) {
        try {
            $payload = Get-Content $RunningTest.ResultFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $passed = [int]$payload.PassedCount
            $failed = [int]$payload.FailedCount
            $skipped = [int]$payload.SkippedCount
            $failedNames = @($payload.FailedNames)
            $failedDetails = @($payload.FailedDetails)

            Remove-TestProcessArtifacts -RunningTest $RunningTest

            return [PSCustomObject]@{
                Label        = $label
                PassedCount  = $passed
                FailedCount  = $failed
                SkippedCount = $skipped
                FailedNames  = $failedNames
                Diagnostics  = $failedDetails
                HadResult    = $true
            }
        }
        catch {
            $diagnostics = @("Invalid result payload: $($_.Exception.Message)") + $diagnostics
        }
    }

    Remove-TestProcessArtifacts -RunningTest $RunningTest

    return [PSCustomObject]@{
        Label        = $label
        PassedCount  = 0
        FailedCount  = 1
        SkippedCount = 0
        FailedNames  = @("Subprocess failed before reporting results (exit code $($RunningTest.Process.ExitCode))")
        Diagnostics  = $diagnostics
        HadResult    = $false
    }
}

Write-Host "CronAgents Test Runner" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "Files: $($files.Count)  Exclude: $($ExcludeTag -join ', ')  Workers: $MaxWorkers  Poll: ${PollIntervalMs}ms"
Write-Host

$pendingFiles = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()
foreach ($file in $files) {
    $pendingFiles.Enqueue($file)
}

$runningTests = [System.Collections.ArrayList]::new()

while ($pendingFiles.Count -gt 0 -or $runningTests.Count -gt 0) {
    while ($pendingFiles.Count -gt 0 -and $runningTests.Count -lt $MaxWorkers) {
        $null = $runningTests.Add((Start-TestProcess -File $pendingFiles.Dequeue() -RunnerScriptPath $runnerScriptPath -HostExecutablePath $hostExecutablePath -ExcludeTag $ExcludeTag))
    }

    $completedTests = @($runningTests | Where-Object { $_.Process.HasExited })
    if ($completedTests.Count -eq 0) {
        Start-Sleep -Milliseconds $PollIntervalMs
        continue
    }

    foreach ($completedTest in $completedTests) {
        $null = $completedTest.Process.WaitForExit()
        $result = Complete-TestProcess -RunningTest $completedTest
        $totalPassed += $result.PassedCount
        $totalFailed += $result.FailedCount
        $totalSkipped += $result.SkippedCount

        if ($result.FailedCount -gt 0) {
            Write-Host "FAIL  ($($result.PassedCount) passed, $($result.FailedCount) failed)" -ForegroundColor Red
            $failures += @{ File = $result.Label; Names = $result.FailedNames; Diagnostics = $result.Diagnostics }
            $result.FailedNames | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            if ($result.Diagnostics.Count -gt 0) {
                $result.Diagnostics | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
            }
        }
        elseif ($result.PassedCount -eq 0 -and $result.SkippedCount -eq 0) {
            Write-Host "SKIP  (excluded)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "OK    ($($result.PassedCount) passed$(if ($result.SkippedCount) { ", $($result.SkippedCount) skipped" }))" -ForegroundColor Green
        }

        [void]$runningTests.Remove($completedTest)
    }
}

$sw.Stop()
Write-Host "`n$("=" * 50)" -ForegroundColor Cyan
$color = if ($totalFailed -gt 0) { 'Red' } else { 'Green' }
Write-Host "Total: $totalPassed passed, $totalFailed failed, $totalSkipped skipped  ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor $color

if ($failures.Count -gt 0) {
    Write-Host "`nFailure Summary:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  $($f.File):" -ForegroundColor Red
        $f.Names | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        if ($f.Diagnostics.Count -gt 0) {
            $f.Diagnostics | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
        }
    }
    exit 1
}

exit 0
