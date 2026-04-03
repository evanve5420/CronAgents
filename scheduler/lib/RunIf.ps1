Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunIfFileChangedPrefix = 'file-changed:'
$script:RunIfMissingItemSentinel = '__missing__'
$script:RunIfNoCommitsSentinel = '__no_commits__'

function Test-RunIfRelativePathValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PathValue
    )

    $trimmed = $PathValue.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return 'path must not be empty'
    }

    if ([System.IO.Path]::IsPathRooted($trimmed)) {
        return 'path must be relative'
    }

    return $null
}

function ConvertTo-AgentRunIfDefinition {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowNull()]
        $RunIf
    )

    if ($null -eq $RunIf) {
        return $null
    }

    if ($RunIf -is [string]) {
        $value = $RunIf.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'runIf must not be empty.'
        }

        if ($value -eq 'git-dirty') {
            return [PSCustomObject]@{ type = 'git-dirty' }
        }

        if ($value.StartsWith($script:RunIfFileChangedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $pathValue = $value.Substring($script:RunIfFileChangedPrefix.Length)
            $pathError = Test-RunIfRelativePathValue -PathValue $pathValue
            if ($pathError) {
                throw "runIf file-changed path $pathError."
            }

            return [PSCustomObject]@{
                type = 'file-changed'
                path = $pathValue.Trim()
            }
        }

        throw "Unsupported runIf value '$value'."
    }

    $runIfObject = if ($RunIf -is [hashtable]) { [PSCustomObject]$RunIf } else { $RunIf }
    if (-not ($runIfObject -is [PSCustomObject])) {
        throw 'runIf must be a string or an object.'
    }

    $propertyNames = @($runIfObject.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 1 -or $propertyNames[0] -ne 'script') {
        throw 'runIf object form only supports the property "script".'
    }

    $scriptPath = [string]$runIfObject.script
    $scriptError = Test-RunIfRelativePathValue -PathValue $scriptPath
    if ($scriptError) {
        throw "runIf.script $scriptError."
    }

    return [PSCustomObject]@{
        type   = 'script'
        script = $scriptPath.Trim()
    }
}

function Get-AgentRunIfExecutionRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$AgentConfig,

        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$PersonalRepoPath
    )

    $defaultRoot = if ($PersonalRepoPath -and $PersonalRepoPath.Trim()) { $PersonalRepoPath } else { $RepoRoot }
    $defaultRoot = [System.IO.Path]::GetFullPath($defaultRoot)

    if ($AgentConfig.PSObject.Properties['workingDirectory'] -and
        -not [string]::IsNullOrWhiteSpace($AgentConfig.workingDirectory)) {
        $workingDirectory = [string]$AgentConfig.workingDirectory
        if ([System.IO.Path]::IsPathRooted($workingDirectory)) {
            return [System.IO.Path]::GetFullPath($workingDirectory)
        }

        return [System.IO.Path]::GetFullPath((Join-Path $defaultRoot $workingDirectory))
    }

    return $defaultRoot
}

function Get-RunIfPathStringComparison {
    [CmdletBinding()]
    [OutputType([System.StringComparison])]
    param()

    if ($IsWindows) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }

    return [System.StringComparison]::Ordinal
}

function Resolve-RunIfPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $rootPath = [System.IO.Path]::GetFullPath($ExecutionRoot)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    $comparison = Get-RunIfPathStringComparison
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSeparator = if ($rootPath.EndsWith($separator) -or $rootPath.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        $rootPath
    }
    else {
        "$rootPath$separator"
    }

    if ($fullPath -ne $rootPath -and -not $fullPath.StartsWith($rootWithSeparator, $comparison)) {
        throw "Path '$RelativePath' escapes execution root '$rootPath'."
    }

    return $fullPath
}

function Get-RunIfFileStateKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$AbsolutePath
    )

    $relativePath = [System.IO.Path]::GetRelativePath(
        [System.IO.Path]::GetFullPath($ExecutionRoot),
        [System.IO.Path]::GetFullPath($AbsolutePath)
    )

    return ($relativePath -replace '\\', '/')
}

function Get-AgentRunIfSnapshot {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowNull()]
        [PSCustomObject]$RunIf,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot
    )

    if ($null -eq $RunIf) {
        return [PSCustomObject]@{
            Success  = $true
            Snapshot = @{}
        }
    }

    switch ($RunIf.type) {
        'git-dirty' {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                return [PSCustomObject]@{
                    Success = $false
                    Snapshot = @{}
                    Reason = 'git was not found on PATH.'
                }
            }

            $insideWorkTree = & git -C $ExecutionRoot rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -ne 0 -or ($insideWorkTree | Select-Object -First 1).ToString().Trim() -ne 'true') {
                return [PSCustomObject]@{
                    Success = $false
                    Snapshot = @{}
                    Reason = "Execution root '$ExecutionRoot' is not a git work tree."
                }
            }

            $commitHash = & git -C $ExecutionRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0) {
                return [PSCustomObject]@{
                    Success  = $true
                    Snapshot = @{
                        gitDirty = @{
                            head = ($commitHash | Select-Object -First 1).ToString().Trim()
                        }
                    }
                }
            }

            $verifyHead = & git -C $ExecutionRoot rev-parse --verify HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                return [PSCustomObject]@{
                    Success  = $true
                    Snapshot = @{
                        gitDirty = @{
                            head = $script:RunIfNoCommitsSentinel
                        }
                    }
                }
            }

            return [PSCustomObject]@{
                Success = $false
                Snapshot = @{}
                Reason = 'Unable to determine git HEAD.'
            }
        }
        'file-changed' {
            try {
                $absolutePath = Resolve-RunIfPath -ExecutionRoot $ExecutionRoot -RelativePath $RunIf.path
            }
            catch {
                return [PSCustomObject]@{
                    Success = $false
                    Snapshot = @{}
                    Reason = $_.Exception.Message
                }
            }

            $stateKey = Get-RunIfFileStateKey -ExecutionRoot $ExecutionRoot -AbsolutePath $absolutePath
            $item = Get-Item -LiteralPath $absolutePath -ErrorAction SilentlyContinue
            $value = if ($null -eq $item) {
                $script:RunIfMissingItemSentinel
            }
            else {
                $item.LastWriteTimeUtc.ToString('o')
            }

            return [PSCustomObject]@{
                Success  = $true
                Snapshot = @{
                    fileChanged = @{
                        $stateKey = $value
                    }
                }
            }
        }
        'script' {
            return [PSCustomObject]@{
                Success  = $true
                Snapshot = @{}
            }
        }
        default {
            throw "Unsupported runIf type '$($RunIf.type)'."
        }
    }
}

function Invoke-RunIfScriptCondition {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$StateFile
    )

    try {
        $resolvedScriptPath = Resolve-RunIfPath -ExecutionRoot $ExecutionRoot -RelativePath $ScriptPath
    }
    catch {
        Write-CronAgentsLog -Level 'warn' -Message "runIf script for '$AgentId' is invalid: $($_.Exception.Message). Allowing run."
        return $true
    }

    if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
        Write-CronAgentsLog -Level 'warn' -Message "runIf script for '$AgentId' was not found at '$resolvedScriptPath'. Allowing run."
        return $true
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.WorkingDirectory = $ExecutionRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($resolvedScriptPath)
    $psi.ArgumentList.Add('-RepoRoot')
    $psi.ArgumentList.Add($ExecutionRoot)
    $psi.ArgumentList.Add('-AgentId')
    $psi.ArgumentList.Add($AgentId)
    $psi.ArgumentList.Add('-StateFile')
    $psi.ArgumentList.Add($StateFile)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $proc.StandardInput.Close()

    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    [void]$stdout.Wait(5000)
    [void]$stderr.Wait(5000)

    $stdoutText = if ($stdout.IsCompleted) { $stdout.Result } else { '' }
    $stderrText = if ($stderr.IsCompleted) { $stderr.Result } else { '' }
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if ($exitCode -ne 0) {
        Write-CronAgentsLog -Level 'warn' -Message "runIf script for '$AgentId' exited with code $exitCode. stderr: $stderrText Allowing run."
        return $true
    }

    $decisionLine = @(
        $stdoutText -split "(`r`n|`n|`r)"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1

    $parsedDecision = $false
    if (-not [bool]::TryParse([string]$decisionLine, [ref]$parsedDecision)) {
        Write-CronAgentsLog -Level 'warn' -Message "runIf script for '$AgentId' did not emit 'true' or 'false'. Output: $stdoutText Allowing run."
        return $true
    }

    return $parsedDecision
}

function Test-AgentRunIf {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [PSCustomObject]$RunIf,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$StateFile,

        [hashtable]$RunIfState
    )

    if ($null -eq $RunIf) {
        return $true
    }

    if ($RunIf.type -eq 'script') {
        return Invoke-RunIfScriptCondition -ScriptPath $RunIf.script -ExecutionRoot $ExecutionRoot -AgentId $AgentId -StateFile $StateFile
    }

    $snapshotResult = Get-AgentRunIfSnapshot -RunIf $RunIf -ExecutionRoot $ExecutionRoot
    if (-not $snapshotResult.Success) {
        Write-CronAgentsLog -Level 'warn' -Message "Unable to evaluate runIf for '$AgentId': $($snapshotResult.Reason) Allowing run."
        return $true
    }

    switch ($RunIf.type) {
        'git-dirty' {
            if ($null -eq $RunIfState -or
                -not $RunIfState.ContainsKey('gitDirty') -or
                -not $RunIfState.gitDirty.ContainsKey('head')) {
                return $true
            }

            return ($RunIfState.gitDirty.head -ne $snapshotResult.Snapshot.gitDirty.head)
        }
        'file-changed' {
            $fileState = $snapshotResult.Snapshot.fileChanged
            $stateKey = @($fileState.Keys)[0]
            if ($null -eq $RunIfState -or
                -not $RunIfState.ContainsKey('fileChanged') -or
                -not $RunIfState.fileChanged.ContainsKey($stateKey)) {
                return $true
            }

            return ($RunIfState.fileChanged[$stateKey] -ne $fileState[$stateKey])
        }
        default {
            throw "Unsupported runIf type '$($RunIf.type)'."
        }
    }
}
