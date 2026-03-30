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
.EXAMPLE
    ./tests/Invoke-Tests.ps1
    ./tests/Invoke-Tests.ps1 -Filter 'Schedule*'
    ./tests/Invoke-Tests.ps1 -ExcludeTag 'E2E','Slow'
    ./tests/Invoke-Tests.ps1 -MaxWorkers 8
#>
[CmdletBinding()]
param(
    [string[]]$ExcludeTag = @('E2E'),
    [string]$Filter = '*',
    [ValidateRange(1, 64)]
    [int]$MaxWorkers = 8
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir = $PSScriptRoot

$files = Get-ChildItem -Path $testDir -Filter "$Filter.Tests.ps1" | Sort-Object Name
if ($files.Count -eq 0) {
    Write-Host "No test files matching '$Filter.Tests.ps1' in $testDir" -ForegroundColor Yellow
    exit 1
}

$excludeArg = ($ExcludeTag | ForEach-Object { "'$_'" }) -join ','
$totalPassed = 0; $totalFailed = 0; $totalSkipped = 0
$failures = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Start-TestProcess {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ExcludeArg
    )

    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-test-$([guid]::NewGuid().ToString('N')).txt"
    $cmd = @"
Set-Location '$RepoRoot'
`$r = Invoke-Pester '$($File.FullName)' -ExcludeTag $ExcludeArg -Output None -PassThru 2>`$null
"`$(`$r.PassedCount)|`$(`$r.FailedCount)|`$(`$r.SkippedCount)" | Set-Content '$resultFile'
if (`$r.FailedCount -gt 0) {
    `$r.Failed | ForEach-Object { `$_.Name } | Add-Content '$resultFile'
}
"@
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    $startArgs = @{
        FilePath     = 'pwsh'
        ArgumentList = @('-NoProfile', '-EncodedCommand', $encodedCommand)
        PassThru     = $true
    }
    if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }

    [PSCustomObject]@{
        File       = $File
        Label      = $File.Name.Replace('.Tests.ps1', '')
        ResultFile = $resultFile
        Process    = Start-Process @startArgs
    }
}

function Complete-TestProcess {
    param(
        [Parameter(Mandatory)][pscustomobject]$RunningTest
    )

    $label = $RunningTest.Label
    Write-Host -NoNewline "  $($label.PadRight(30))"

    if (Test-Path $RunningTest.ResultFile) {
        $lines = @(Get-Content $RunningTest.ResultFile)
        $parts = $lines[0].Split('|')
        $passed = [int]$parts[0]
        $failed = [int]$parts[1]
        $skipped = [int]$parts[2]
        $failedNames = if ($lines.Count -gt 1) { $lines[1..($lines.Count - 1)] } else { @() }
        Remove-Item $RunningTest.ResultFile -Force -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            Label        = $label
            PassedCount  = $passed
            FailedCount  = $failed
            SkippedCount = $skipped
            FailedNames  = $failedNames
            HadResult    = $true
        }
    }

    return [PSCustomObject]@{
        Label        = $label
        PassedCount  = 0
        FailedCount  = 1
        SkippedCount = 0
        FailedNames  = @('Subprocess produced no result')
        HadResult    = $false
    }
}

Write-Host "CronAgents Test Runner" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "Files: $($files.Count)  Exclude: $($ExcludeTag -join ', ')  Workers: $MaxWorkers"
Write-Host

$pendingFiles = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()
foreach ($file in $files) {
    $pendingFiles.Enqueue($file)
}

$runningTests = [System.Collections.ArrayList]::new()

while ($pendingFiles.Count -gt 0 -or $runningTests.Count -gt 0) {
    while ($pendingFiles.Count -gt 0 -and $runningTests.Count -lt $MaxWorkers) {
        $null = $runningTests.Add((Start-TestProcess -File $pendingFiles.Dequeue() -RepoRoot $repoRoot -ExcludeArg $excludeArg))
    }

    $completedTests = @($runningTests | Where-Object { $_.Process.HasExited })
    if ($completedTests.Count -eq 0) {
        Start-Sleep -Milliseconds 200
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
            $failures += @{ File = $result.Label; Names = $result.FailedNames }
            $result.FailedNames | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
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
    }
    exit 1
}

exit 0
