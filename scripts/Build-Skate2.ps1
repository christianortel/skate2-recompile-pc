[CmdletBinding()]
param(
    # SdkPatches only verifies or applies the SDK source patches (no CMake).
    [ValidateSet('All', 'SDK', 'SdkPatches', 'Generate', 'Build', 'Launcher')]
    [string]$Stage = 'All',
    [ValidateRange(1, 32)]
    [int]$Jobs = 4,
    [switch]$PerformanceCounters,
    # Optional extracted source to import. The authored manifest always uses game/.
    [string]$GameDirectory,
    # Test hook for -Stage SdkPatches: use another checkout of the pinned SDK.
    [Parameter(DontShow)]
    [string]$SdkSourceDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$sdkSource = Join-Path $workspace 'tools\rexglue-sdk-source'
if ($SdkSourceDirectory) {
    if ($Stage -ne 'SdkPatches') { throw '-SdkSourceDirectory is only supported with -Stage SdkPatches.' }
    $sdkSource = (Resolve-Path -LiteralPath $SdkSourceDirectory).Path
}
$sdkInstall = Join-Path $sdkSource 'out\install\win-amd64'
$sdkPinnedCommit = 'f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
# Applied in this order on top of $sdkPinnedCommit. Later patches may modify
# lines added by earlier ones, so a per-patch reverse-apply check cannot tell
# whether a tree is already patched; Initialize-SdkPatches compares whole states.
$sdkPatchNames = @(
    'rexglue-0.10.0-windows-build.patch',
    'rexglue-0.10.0-float16-pack.patch',
    'rexglue-0.10.0-input-diagnostics.patch',
    'rexglue-0.10.0-input-synchronization.patch',
    'rexglue-0.10.0-audio-output.patch',
    'rexglue-0.10.0-cvar-toml-escaping.patch',
    'rexglue-0.10.0-release-perf-counters.patch',
    'rexglue-0.10.0-live-frame-capture.patch',
    'rexglue-0.10.0-cvar-validator.patch',
    'rexglue-0.10.0-vertex-buffer-coherency.patch',
    'rexglue-0.10.0-present-idleclean-diagnostic.patch',
    'rexglue-0.10.0-idle-ui-repaint.patch',
    'rexglue-0.10.0-unclipped-draw-extent.patch',
    'rexglue-0.10.0-command-processor-overhead.patch',
    'rexglue-0.10.0-d3d12-submission-and-queries.patch',
    'rexglue-0.10.0-placed-textures.patch',
    'rexglue-0.10.0-gpu-trace-recorder.patch')
$projectRoot = Join-Path $workspace 'skate2'
$gameRoot = Join-Path $workspace 'game'
$manifest = Join-Path $projectRoot 'skate2_manifest.toml'
$expectedXexSha256 = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'

if ($Stage -eq 'Launcher') {
    & (Join-Path $PSScriptRoot 'Build-Skate2Launcher.ps1') -Jobs $Jobs
    return
}

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    # Match ordinary PATH lookup when multiple installations are visible.
    $command = Get-Command $Program -CommandType Application -ErrorAction Stop | Select-Object -First 1
    # Windows PowerShell represents redirected native stderr as error records,
    # including ordinary compiler progress/warnings. Judge success by exit code.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $command.Source @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-Host
        $nativeExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($nativeExitCode -ne 0) {
        throw "$Program failed with exit code $nativeExitCode"
    }
}

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-GitCapture {
    # Runs git without PowerShell's native pipeline so NUL-separated (-z)
    # output and stderr are captured intact. Read-only commands take no
    # optional locks, so status does not rewrite the index.
    param([string]$Directory, [string[]]$Arguments, [switch]$AllowFailure)
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $git.Source
    $startInfo.Arguments = ((@('--no-optional-locks', '-C', $Directory) + $Arguments) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Error = $errorTask.Result.Trim() }
    } finally { $process.Dispose() }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw ('git {0} failed in {1} with exit code {2}: {3}' -f ($Arguments -join ' '), $Directory, $result.ExitCode, $result.Error)
    }
    return $result
}

function Get-SdkPatchPaths {
    # Repository paths that the patches create, modify or delete.
    param([string]$SdkRoot, [string[]]$PatchFiles)
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($patchFile in $PatchFiles) {
        $numstat = (Invoke-GitCapture $SdkRoot @('apply', '--numstat', '-z', $patchFile)).Output
        foreach ($record in $numstat.Split([char]0)) {
            if ($record -match '^(?:-|\d+)\t(?:-|\d+)\t(.+)$') { [void]$paths.Add($Matches[1]) }
        }
    }
    return [string[]]@($paths)
}

function Get-SdkTreeState {
    # One line per path that differs from HEAD (tracked or untracked; ignored
    # files and submodules excluded) or that a patch touches: the SHA-256 of
    # the working-tree bytes, or 'missing'. Equal lines mean equal patched source.
    param([string]$Root, [string[]]$TouchedPaths)
    $status = (Invoke-GitCapture $Root @('status', '--porcelain=v1', '-z', '--untracked-files=all',
        '--ignore-submodules=all', '--no-renames')).Output
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($record in $status.Split([char]0)) {
        if ($record.Length -gt 3) { [void]$paths.Add($record.Substring(3)) }
    }
    $changedCount = $paths.Count
    foreach ($path in $TouchedPaths) { [void]$paths.Add($path) }
    $sortedPaths = [string[]]@($paths)
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $sortedPaths) {
        $file = Join-Path $Root $path
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $lines.Add(('{0} {1}' -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash, $path))
        } else {
            $lines.Add(('missing {0}' -f $path))
        }
    }
    return [pscustomobject]@{ ChangedCount = $changedCount; Lines = $lines.ToArray() }
}

function Get-SdkPatchMarkerText {
    param([string]$Commit, [string[]]$PatchFiles, [string[]]$StateLines)
    $lines = @(
        '# SDK patch state written by scripts/Build-Skate2.ps1 after the patches below',
        '# were applied to, or verified in, this checkout. It is only a cache: delete',
        '# it to force a full comparison on the next SDK stage.',
        "base $Commit")
    foreach ($patchFile in $PatchFiles) {
        $lines += ('patch {0} {1}' -f (Get-FileHash -LiteralPath $patchFile -Algorithm SHA256).Hash, (Split-Path -Leaf $patchFile))
    }
    foreach ($line in $StateLines) { $lines += "file $line" }
    return ($lines -join "`n") + "`n"
}

function Get-SdkExpectedPatchedState {
    # Applies the patches to a temporary detached worktree of the pinned commit
    # and returns that tree's state. The worktree is always removed.
    param([string]$SdkRoot, [string]$Commit, [string[]]$PatchFiles, [string[]]$TouchedPaths)
    $tempTree = Join-Path ([System.IO.Path]::GetTempPath()) ('skate2-sdk-patchcheck-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    try {
        Invoke-GitCapture $SdkRoot @('worktree', 'add', '--detach', $tempTree, $Commit) | Out-Null
        foreach ($patchFile in $PatchFiles) {
            $applied = Invoke-GitCapture $tempTree @('apply', $patchFile) -AllowFailure
            if ($applied.ExitCode -ne 0) {
                throw ('{0} does not apply in order to a clean checkout of {1}; fix the patches\ set first. git apply: {2}' -f (Split-Path -Leaf $patchFile), $Commit, $applied.Error)
            }
        }
        return Get-SdkTreeState $tempTree $TouchedPaths
    } finally {
        Invoke-GitCapture $SdkRoot @('worktree', 'remove', '--force', $tempTree) -AllowFailure | Out-Null
        if (Test-Path -LiteralPath $tempTree) { Remove-Item -LiteralPath $tempTree -Recurse -Force -ErrorAction SilentlyContinue }
        Invoke-GitCapture $SdkRoot @('worktree', 'prune') -AllowFailure | Out-Null
    }
}

function Get-SdkStateDifferences {
    param([string[]]$Expected, [string[]]$Actual, [int]$Limit = 15)
    $maps = foreach ($lines in @(, $Expected) + @(, $Actual)) {
        $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach ($line in $lines) {
            $separator = $line.IndexOf(' ')
            $map[$line.Substring($separator + 1)] = $line.Substring(0, $separator)
        }
        , $map
    }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($map in $maps) { foreach ($key in $map.Keys) { [void]$paths.Add($key) } }
    $sortedPaths = [string[]]@($paths)
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $differences = @()
    foreach ($path in $sortedPaths) {
        $values = foreach ($map in $maps) {
            if (-not $map.ContainsKey($path)) { 'as pinned' }
            elseif ($map[$path] -ceq 'missing') { 'absent' }
            else { 'sha256 ' + $map[$path].Substring(0, 12).ToLowerInvariant() }
        }
        if ($values[0] -cne $values[1]) { $differences += ('  {0}: expected {1}, found {2}' -f $path, $values[0], $values[1]) }
    }
    if ($differences.Count -gt $Limit) {
        $differences = $differences[0..($Limit - 1)] + @(('  ... and {0} more' -f ($differences.Count - $Limit)))
    }
    return $differences
}

function Get-SdkResetInstructions {
    param([string]$SdkRoot)
    return @(
        'Save any SDK edits you want to keep, then reset the checkout to the pinned revision.',
        'This discards tracked edits and removes untracked, non-ignored files; ignored',
        'build output such as out\ is kept (preview the removal with clean -nd):',
        ('  git -C "{0}" checkout -- .' -f $SdkRoot),
        ('  git -C "{0}" clean -fd' -f $SdkRoot),
        'Then re-run this script (for example -Stage SDK); it applies all patches in order.')
}

function Initialize-SdkPatches {
    # Case 1: pristine pinned checkout -> apply every patch in order.
    # Case 2: checkout equals pinned commit plus every patch -> nothing to do.
    # Case 3: anything else -> stop without changing the checkout.
    param([string]$SdkRoot, [string]$Commit, [string]$PatchDirectory, [string[]]$PatchNames)
    $patchFiles = foreach ($patchName in $PatchNames) {
        $patchFile = Join-Path $PatchDirectory $patchName
        if (-not (Test-Path -LiteralPath $patchFile -PathType Leaf)) { throw "SDK patch is missing: $patchFile" }
        (Resolve-Path -LiteralPath $patchFile).Path
    }
    $head = (Invoke-GitCapture $SdkRoot @('rev-parse', 'HEAD') -AllowFailure).Output.Trim()
    if ($head -ne $Commit) {
        throw 'SDK source revision differs from the pinned, audited version.'
    }
    $touchedPaths = @(Get-SdkPatchPaths $SdkRoot $patchFiles)
    # The patches must stay in the main SDK repository: submodule working
    # trees are separate repositories and are excluded from the state check.
    $treeListing = (Invoke-GitCapture $SdkRoot @('ls-tree', '-r', '-z', $Commit)).Output
    foreach ($record in $treeListing.Split([char]0)) {
        if ($record -notmatch '^160000 commit [0-9a-f]+\t(.+)$') { continue }
        $submodulePath = $Matches[1]
        foreach ($path in $touchedPaths) {
            if ($path -ceq $submodulePath -or $path.StartsWith($submodulePath + '/', [StringComparison]::Ordinal)) {
                throw "SDK patch set touches $path inside submodule $submodulePath; this script only patches the main SDK repository."
            }
        }
    }
    $markerPath = Join-Path $SdkRoot 'out\skate2-applied-patches.txt'
    $liveState = Get-SdkTreeState $SdkRoot $touchedPaths

    if ($liveState.ChangedCount -eq 0) {
        Write-Host ('SDK checkout is the pristine pinned revision; applying {0} patches.' -f $patchFiles.Count)
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
        foreach ($patchFile in $patchFiles) {
            $applied = Invoke-GitCapture $SdkRoot @('apply', $patchFile) -AllowFailure
            if ($applied.Error) { Write-Host $applied.Error }
            if ($applied.ExitCode -ne 0) {
                Get-SdkResetInstructions $SdkRoot | ForEach-Object { Write-Host $_ }
                throw ('{0} did not apply, so the SDK checkout is now partially patched. Reset it as described above, fix the patch, and re-run.' -f (Split-Path -Leaf $patchFile))
            }
            Write-Host ('  applied {0}' -f (Split-Path -Leaf $patchFile))
        }
        $liveState = Get-SdkTreeState $SdkRoot $touchedPaths
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $markerPath) | Out-Null
        [System.IO.File]::WriteAllText($markerPath, (Get-SdkPatchMarkerText $Commit $patchFiles $liveState.Lines), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "SDK patches applied; recorded the patched state in $markerPath"
        return
    }

    $markerText = Get-SdkPatchMarkerText $Commit $patchFiles $liveState.Lines
    if ((Test-Path -LiteralPath $markerPath -PathType Leaf) -and ([System.IO.File]::ReadAllText($markerPath) -ceq $markerText)) {
        Write-Host "SDK patches already applied; the checkout matches $markerPath"
        return
    }
    Write-Host 'SDK checkout has local changes but no matching patch marker; comparing it with a clean patched checkout...'
    $expectedState = Get-SdkExpectedPatchedState $SdkRoot $Commit $patchFiles $touchedPaths
    if (($expectedState.Lines -join "`n") -ceq ($liveState.Lines -join "`n")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $markerPath) | Out-Null
        [System.IO.File]::WriteAllText($markerPath, $markerText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "SDK patches already applied; verified against a clean patched checkout and recorded $markerPath"
        return
    }
    Write-Host ('The SDK checkout at {0} is neither the pristine pinned revision nor the pinned revision plus the current patches\ set.' -f $SdkRoot)
    Write-Host 'It may be partially patched, patched with older patch versions, or locally edited. Differences from the expected patched source:'
    Get-SdkStateDifferences $expectedState.Lines $liveState.Lines | ForEach-Object { Write-Host $_ }
    Get-SdkResetInstructions $SdkRoot | ForEach-Object { Write-Host $_ }
    throw 'SDK checkout does not match the pinned revision plus the current patch set; no patches were applied. Reset it as described above and re-run.'
}

if (-not (Test-Path -LiteralPath $sdkSource -PathType Container)) {
    throw 'SDK source is missing. Run scripts/Bootstrap-Skate2Sdk.ps1 first, then install the documented build tools.'
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw 'The authored skate2/skate2_manifest.toml is missing. Restore the source export; do not replace it with an empty generated project.'
}
if ($Stage -eq 'SdkPatches') {
    # Patch-only stage: git is the only tool needed.
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Missing git. Install Git for Windows and add it to PATH.' }
} else {
    . (Join-Path $workspace 'tools\Enter-BuildEnvironment.ps1')
}
$reportRoot = Join-Path $workspace 'reports'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$logPath = Join-Path $reportRoot ('build-{0}-{1}.log' -f $Stage.ToLowerInvariant(), (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -LiteralPath $logPath | Out-Null
try {
    if ($Stage -in @('All', 'Generate', 'Build')) {
        if (-not (Test-Path -LiteralPath $gameRoot -PathType Container)) {
            if ($GameDirectory -and $Stage -in @('All', 'Generate')) {
                & (Join-Path $PSScriptRoot 'Import-Skate2Data.ps1') -SourceDirectory $GameDirectory
            } else {
                throw 'Import your extracted game with scripts/Import-Skate2Data.ps1 -SourceDirectory <folder>, or use -GameDirectory with -Stage All/Generate.'
            }
        } elseif ($GameDirectory) {
            $providedGame = (Resolve-Path -LiteralPath $GameDirectory).Path.TrimEnd('\', '/')
            if ($providedGame -ne (Resolve-Path -LiteralPath $gameRoot).Path.TrimEnd('\', '/')) {
                throw 'game/ already exists. Build uses that canonical imported copy; omit -GameDirectory or verify it separately. No files were replaced.'
            }
        }
        $xexPath = Join-Path $gameRoot 'default.xex'
        if ((Get-FileHash -LiteralPath $xexPath -Algorithm SHA256).Hash -ne $expectedXexSha256) {
            throw 'Game executable differs from the audited revision. Revalidate its addresses before generating or building.'
        }
    }
    if ($Stage -in @('All', 'SDK', 'SdkPatches')) {
        Initialize-SdkPatches -SdkRoot $sdkSource -Commit $sdkPinnedCommit -PatchDirectory (Join-Path $workspace 'patches') -PatchNames $sdkPatchNames
    }
    if ($Stage -in @('All', 'SDK')) {
        Push-Location $sdkSource
        try {
            $releaseCounters = if ($PerformanceCounters) { 'ON' } else { 'OFF' }
            Invoke-Checked cmake @('--preset', 'win-amd64',
                '-DREXGLUE_ENABLE_FIDELITYFX=OFF', '-DREXGLUE_USE_VULKAN=OFF',
                '-DREXGLUE_ENABLE_PERF_COUNTERS=ON', "-DREXGLUE_ENABLE_RELEASE_PERF_COUNTERS=$releaseCounters",
                '-DREXGLUE_ENABLE_TRACY=OFF', '-DREXGLUE_BUILD_TESTS=OFF')
            Invoke-Checked cmake @('--build', 'out/build/win-amd64', '--config', 'Release',
                '--target', 'install', '--parallel', "$Jobs")
        } finally { Pop-Location }
    }

    if ($Stage -in @('All', 'Generate', 'Build')) {
        $rexglue = Join-Path $sdkInstall 'bin\rexglue.exe'
        if (-not (Test-Path -LiteralPath $rexglue)) {
            throw 'Local SDK has not been built. Run this script with -Stage SDK first.'
        }
        Push-Location $projectRoot
        try {
            if ($Stage -in @('All', 'Generate')) {
                # Revalidate after local generator patches, even if the upstream
                # SDK version string has not changed.
                Invoke-Checked $rexglue @('codegen', $manifest, '--ignore-stamp')
            }
            if ($Stage -in @('All', 'Build')) {
                if (-not (Test-Path -LiteralPath 'generated\default\sources.cmake')) {
                    throw 'Code generation has not completed. Run -Stage Generate and resolve its errors first.'
                }
                Invoke-Checked cmake @('--preset', 'win-amd64-release', "-DCMAKE_PREFIX_PATH=$sdkInstall")
                Invoke-Checked cmake @('--build', 'out/build/win-amd64-release', '--config', 'Release',
                    '--parallel', "$Jobs")
            }
        } finally { Pop-Location }
    }
    if ($Stage -in @('All', 'Build')) {
        & (Join-Path $PSScriptRoot 'Build-Skate2Launcher.ps1') -Jobs $Jobs
    }
} finally {
    Stop-Transcript | Out-Null
}
