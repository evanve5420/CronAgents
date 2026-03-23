<#
.SYNOPSIS
    Pester 5 integration tests for pre-edit snapshot creation.
    Tests that run directories capture file state and nested paths
    are preserved in backup structures.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

Describe 'Backup — Snapshot Creation' {
    BeforeEach {
        $testEnv = New-TestEnvironment -Name 'Backup'

        # Create some source files in the test repo to snapshot
        $srcDir = Join-Path $testEnv.Root 'src'
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        Set-Content -Path (Join-Path $srcDir 'main.ps1') -Value 'Write-Host "Hello"' -Encoding UTF8

        $nestedDir = Join-Path $srcDir 'lib' 'helpers'
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
        Set-Content -Path (Join-Path $nestedDir 'util.ps1') -Value 'function Get-Help {}' -Encoding UTF8

        Set-Content -Path (Join-Path $testEnv.Root 'config.json') -Value '{"key":"value"}' -Encoding UTF8
    }
    AfterEach {
        Remove-TestEnvironment -TestEnv $testEnv
    }

    It 'Snapshot creation: backup/ dir exists with file copies' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'backup-test'
        $backupDir = Join-Path $runDir 'backup'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        # Snapshot key files into the backup dir
        $filesToBackup = @(
            (Join-Path $testEnv.Root 'config.json'),
            (Join-Path $testEnv.Root 'src' 'main.ps1')
        )
        foreach ($file in $filesToBackup) {
            $relativePath = $file.Substring($testEnv.Root.Length).TrimStart('\', '/')
            $destPath = Join-Path $backupDir $relativePath
            $destDir  = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $file -Destination $destPath
        }

        Test-Path $backupDir | Should -Be $true
        Test-Path (Join-Path $backupDir 'config.json') | Should -Be $true
        Test-Path (Join-Path $backupDir 'src' 'main.ps1') | Should -Be $true

        # Verify content matches
        Get-Content (Join-Path $backupDir 'config.json') -Raw |
            Should -Match '"key"'
    }

    It 'Snapshot path mirroring: nested paths preserved' {
        $runDir = New-RunDirectory -RunsRoot $testEnv.RunsRoot -AgentId 'backup-nested'
        $backupDir = Join-Path $runDir 'backup'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        $nestedFile = Join-Path $testEnv.Root 'src' 'lib' 'helpers' 'util.ps1'
        $relativePath = $nestedFile.Substring($testEnv.Root.Length).TrimStart('\', '/')
        $destPath = Join-Path $backupDir $relativePath
        $destDir  = Split-Path $destPath -Parent
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $nestedFile -Destination $destPath

        Test-Path $destPath | Should -Be $true
        # Verify the nested directory structure is mirrored
        $destPath | Should -BeLike "*backup*src*lib*helpers*util.ps1"
    }
}
