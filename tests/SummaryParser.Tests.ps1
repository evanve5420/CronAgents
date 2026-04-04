<#
.SYNOPSIS
    Pester 5 tests for SummaryParser.ps1 — YAML frontmatter parsing from summary.md files.
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scheduler/lib/CronAgents.psd1') -Force
}

Describe 'Read-SummaryFrontmatter' {

    Context 'With full YAML frontmatter' {
        It 'Parses attention=true and headline' {
            $content = "---`nattention: true`nheadline: `"New song detected!`"`n---`nFull summary body here."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $true
            $result.Headline  | Should -Be 'New song detected!'
            $result.Body      | Should -Be 'Full summary body here.'
        }

        It 'Parses attention=false' {
            $content = "---`nattention: false`nheadline: `"Routine check`"`n---`nNothing happened."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $false
            $result.Headline  | Should -Be 'Routine check'
            $result.Body      | Should -Be 'Nothing happened.'
        }

        It 'Handles single-quoted headline' {
            $content = "---`nattention: true`nheadline: 'Alert raised'`n---`nBody text."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Headline | Should -Be 'Alert raised'
        }

        It 'Handles unquoted headline' {
            $content = "---`nattention: false`nheadline: No changes detected`n---`nBody."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Headline | Should -Be 'No changes detected'
        }

        It 'Accepts yes as truthy for attention' {
            $content = "---`nattention: yes`nheadline: Something`n---`nBody."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $true
        }
    }

    Context 'Without frontmatter (backwards compatibility)' {
        It 'Treats entire content as body' {
            $content = 'Just a plain summary without any frontmatter.'
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $false
            $result.Headline  | Should -BeNullOrEmpty
            $result.Body      | Should -Be $content
        }

        It 'Handles markdown content that starts with heading' {
            $content = "# Summary`nReviewed 5 files."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $false
            $result.Body      | Should -Match 'Reviewed 5 files'
        }
    }

    Context 'Edge cases' {
        It 'Handles empty content' {
            $result = Read-SummaryFrontmatter -Content ''
            $result.Attention | Should -Be $false
            $result.Headline  | Should -BeNullOrEmpty
            $result.Body      | Should -Be ''
        }

        It 'Handles whitespace-only content' {
            $result = Read-SummaryFrontmatter -Content '   '
            $result.Attention | Should -Be $false
            $result.Body      | Should -Be ''
        }

        It 'Handles frontmatter with only attention field' {
            $content = "---`nattention: true`n---`nImportant information."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $true
            $result.Headline  | Should -BeNullOrEmpty
            $result.Body      | Should -Be 'Important information.'
        }

        It 'Handles missing file path gracefully' {
            $result = Read-SummaryFrontmatter -Path (Join-Path $TestDrive 'nonexistent-summary.md')
            $result.Attention | Should -Be $false
            $result.Body      | Should -Be ''
            $result.ReadError | Should -Not -BeNullOrEmpty
        }

        It 'Reads from file path' {
            $summaryPath = Join-Path $TestDrive 'test-summary.md'
            $content = "---`nattention: true`nheadline: `"From file`"`n---`nBody from file."
            Set-Content -Path $summaryPath -Value $content -Encoding UTF8 -NoNewline
            $result = Read-SummaryFrontmatter -Path $summaryPath
            $result.Attention | Should -Be $true
            $result.Headline  | Should -Be 'From file'
            $result.Body      | Should -Be 'Body from file.'
            $result.ReadError | Should -BeNullOrEmpty
        }

        It 'Handles multiline body after frontmatter' {
            $content = "---`nattention: false`nheadline: `"Quick check`"`n---`nLine 1`nLine 2`nLine 3"
            $result = Read-SummaryFrontmatter -Content $content
            $result.Body | Should -Match 'Line 1'
            $result.Body | Should -Match 'Line 3'
        }

        It 'Preserves Raw field with original content' {
            $content = "---`nattention: true`nheadline: `"Test`"`n---`nBody."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Raw | Should -Be $content
        }

        It 'Handles unclosed frontmatter gracefully' {
            $content = "---`nattention: true`nheadline: Oops`nNo closing delimiter here."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Attention | Should -Be $false
            $result.Body      | Should -Match 'No closing delimiter'
        }

        It 'Trims leading newlines from body after frontmatter' {
            $content = "---`nattention: false`nheadline: Test`n---`n`n`nActual body starts here."
            $result = Read-SummaryFrontmatter -Content $content
            $result.Body | Should -Be 'Actual body starts here.'
        }

        It 'MetadataOnly returns frontmatter without full file read' {
            $summaryPath = Join-Path $TestDrive 'metadata-only.md'
            $longBody = 'X' * 5000
            $content = "---`nattention: true`nheadline: `"Quick check`"`n---`nFirst line.`n$longBody"
            Set-Content -Path $summaryPath -Value $content -Encoding UTF8 -NoNewline
            $result = Read-SummaryFrontmatter -Path $summaryPath -MetadataOnly
            $result.Attention | Should -Be $true
            $result.Headline  | Should -Be 'Quick check'
            $result.Body      | Should -Match 'First line'
        }
    }
}
