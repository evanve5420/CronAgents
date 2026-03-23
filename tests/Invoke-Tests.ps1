<#
.SYNOPSIS
    CronAgents test runner — runs all Pester tests with process isolation.
.DESCRIPTION
    Pester 5 can hang when 15+ test containers import the same module in a single
    process (FileStream exclusive locks + module reimport contention). This runner
    executes each test file in its own pwsh subprocess for reliable results.
.PARAMETER ExcludeTag
    Tags to exclude. Defaults to 'E2E'.
.PARAMETER Filter
    Optional wildcard filter for test file names (e.g. 'Config*').
.EXAMPLE
    ./tests/Invoke-Tests.ps1
    ./tests/Invoke-Tests.ps1 -Filter 'Schedule*'
    ./tests/Invoke-Tests.ps1 -ExcludeTag 'E2E','Slow'
#>
[CmdletBinding()]
param(
    [string[]]$ExcludeTag = @('E2E'),
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir = $PSScriptRoot
$resultFile = Join-Path ([System.IO.Path]::GetTempPath()) "cronagents-test-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"

$files = Get-ChildItem -Path $testDir -Filter "$Filter.Tests.ps1" | Sort-Object Name
if ($files.Count -eq 0) {
    Write-Host "No test files matching '$Filter.Tests.ps1' in $testDir" -ForegroundColor Yellow
    exit 1
}

$excludeArg = ($ExcludeTag | ForEach-Object { "'$_'" }) -join ','
$totalPassed = 0; $totalFailed = 0; $totalSkipped = 0
$failures = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "CronAgents Test Runner" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "Files: $($files.Count)  Exclude: $($ExcludeTag -join ', ')`n"

foreach ($file in $files) {
    $label = $file.Name.Replace('.Tests.ps1', '')
    Write-Host -NoNewline "  $($label.PadRight(30))"

    # Run in subprocess and write results to temp file
    $cmd = @"
        Set-Location '$repoRoot'
        `$r = Invoke-Pester '$($file.FullName)' -ExcludeTag $excludeArg -Output None -PassThru 2>`$null
        "`$(`$r.PassedCount)|`$(`$r.FailedCount)|`$(`$r.SkippedCount)" | Set-Content '$resultFile'
        if (`$r.FailedCount -gt 0) {
            `$r.Failed | ForEach-Object { `$_.Name } | Add-Content '$resultFile'
        }
"@
    pwsh -NoProfile -Command $cmd 2>$null | Out-Null

    if (Test-Path $resultFile) {
        $lines = @(Get-Content $resultFile)
        $parts = $lines[0].Split('|')
        $p = [int]$parts[0]; $f = [int]$parts[1]; $s = [int]$parts[2]
        $totalPassed += $p; $totalFailed += $f; $totalSkipped += $s

        if ($f -gt 0) {
            Write-Host "FAIL  ($p passed, $f failed)" -ForegroundColor Red
            $failedNames = $lines[1..($lines.Count - 1)]
            $failures += @{ File = $label; Names = $failedNames }
            $failedNames | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
        elseif ($p -eq 0 -and $s -eq 0) {
            Write-Host "SKIP  (excluded)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "OK    ($p passed$(if ($s) { ", $s skipped" }))" -ForegroundColor Green
        }
        Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "ERROR (no result)" -ForegroundColor Red
        $totalFailed++
        $failures += @{ File = $label; Names = @('Subprocess produced no result') }
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
