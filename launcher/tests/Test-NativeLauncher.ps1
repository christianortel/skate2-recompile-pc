# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$launcher = (Resolve-Path -LiteralPath $LauncherPath).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) ('out\tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$fixtureName = "fixture space & percent% apostrophe' bang! [brackets] " + [char]0x96EA
$fixture = Join-Path $outputRoot $fixtureName
$null = New-Item -ItemType Directory -Force -Path $fixture
$scripts = Join-Path $fixture 'scripts'
$null = New-Item -ItemType Directory -Force -Path $scripts
$exe = Join-Path $fixture 'Launch Skate 2.exe'
Copy-Item -LiteralPath $launcher -Destination $exe
$payload = Join-Path $fixture 'fixture-payload.txt'
[IO.File]::WriteAllText($payload, 'Native launcher fixture payload.', [Text.UTF8Encoding]::new($false))
$expectedHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
$scriptPath = Join-Path $scripts 'Launch-Skate2.ps1'
$stub = @'
param([string]$FrameRate, [int]$RenderScale, [string]$FrameLimit, [string]$NvidiaMaxPerformance,
      [string]$DrawDistanceScale, [string]$LodDistanceScale, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $root 'fixture-config.json') -Raw | ConvertFrom-Json
$observation = [ordered]@{
    boundNames = @($PSBoundParameters.Keys | Sort-Object)
    frameRatePassed = $PSBoundParameters.ContainsKey('FrameRate')
    frameRate = $FrameRate
    renderScalePassed = $PSBoundParameters.ContainsKey('RenderScale')
    renderScale = $RenderScale
    frameLimitPassed = $PSBoundParameters.ContainsKey('FrameLimit')
    frameLimit = $FrameLimit
    nvidiaMaxPerformancePassed = $PSBoundParameters.ContainsKey('NvidiaMaxPerformance')
    nvidiaMaxPerformance = $NvidiaMaxPerformance
    drawDistanceScalePassed = $PSBoundParameters.ContainsKey('DrawDistanceScale')
    drawDistanceScale = $DrawDistanceScale
    lodDistanceScalePassed = $PSBoundParameters.ContainsKey('LodDistanceScale')
    lodDistanceScale = $LodDistanceScale
    checkOnly = [bool]$CheckOnly
    cwd = [Environment]::CurrentDirectory
    scriptRoot = $PSScriptRoot
    psVersion = $PSVersionTable.PSVersion.ToString()
    modulePath = $env:PSModulePath
    executionPolicy = (Get-ExecutionPolicy).ToString()
    hash = (Get-FileHash -LiteralPath (Join-Path $root 'fixture-payload.txt') -Algorithm SHA256).Hash
}
$observation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'observation.json') -Encoding UTF8
if ($config.DelayMs -gt 0) { Start-Sleep -Milliseconds $config.DelayMs }
if ($config.LargeOutput) {
    $line = 'x' * 4096
    for ($i = 0; $i -lt 40; $i++) { [Console]::Out.WriteLine($line); [Console]::Error.WriteLine($line) }
}
if (-not $config.EmptyOutput) {
    Write-Host 'HOST-OUTPUT-MARKER'
    [Console]::Out.WriteLine('STDOUT-MARKER')
    [Console]::Error.WriteLine('STDERR-MARKER')
}
[IO.File]::WriteAllText((Join-Path $root 'completed.txt'), 'complete')
exit ([int]$config.ExitCode)
'@
[IO.File]::WriteAllText($scriptPath, $stub, [Text.UTF8Encoding]::new($false))
Set-Content -LiteralPath $scriptPath -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$checks = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $checks.Add($Message)
}
function Set-Fixture([int]$ExitCode = 0, [int]$DelayMs = 0, [bool]$LargeOutput = $false, [bool]$EmptyOutput = $false) {
    @{ ExitCode = $ExitCode; DelayMs = $DelayMs; LargeOutput = $LargeOutput; EmptyOutput = $EmptyOutput } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'fixture-config.json') -Encoding UTF8
    foreach ($name in @('observation.json', 'completed.txt')) {
        $path = Join-Path $fixture $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
function Invoke-Fixture([string]$Name, [string[]]$Options = @(), [bool]$CheckOnly = $true, [int]$ExpectedExit = 0, [bool]$CheckLifetime = $false) {
    $report = Join-Path $outputRoot ($Name + '.json')
    $arguments = @($Options)
    if ($CheckOnly) { $arguments += @('--check-only', '--report', ('"' + $report + '"')) }
    $start = @{ FilePath = $exe; WorkingDirectory = $outputRoot; PassThru = $true; WindowStyle = 'Hidden' }
    if ($arguments.Count) { $start.ArgumentList = $arguments }
    $process = Start-Process @start
    if ($CheckLifetime) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json')) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (-not $process.HasExited) "$Name stays alive while helper is running"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'completed.txt'))) "$Name has not returned before helper completion"
    }
    if (-not $process.WaitForExit(30000)) {
        # Only terminate the executable copied into this harmless fixture.
        $process.Kill()
        throw "Fixture timed out: $Name"
    }
    $process.Refresh()
    Assert-True ($process.ExitCode -eq $ExpectedExit) "$Name propagates expected exit $ExpectedExit (actual $($process.ExitCode))"
    if ($CheckOnly) {
        Assert-True (Test-Path -LiteralPath $report) "$Name writes a native report"
        $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($result.exitCode -eq $ExpectedExit) "$Name report preserves exit status"
        return $result
    }
}
function Read-Observation { Get-Content -LiteralPath (Join-Path $fixture 'observation.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
$originalModulePath = $env:PSModulePath
$originalPolicy = $env:PSExecutionPolicyPreference
$originalPath = $env:PATH
$contaminatedModulePath = Join-Path $outputRoot 'nonexistent-module-path'
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$ps7Modules = Join-Path $programFiles 'PowerShell\7\Modules'
if (Test-Path -LiteralPath $ps7Modules) { $contaminatedModulePath = $ps7Modules + ';' + $contaminatedModulePath }
try {
    $env:PSModulePath = $contaminatedModulePath
    $env:PSExecutionPolicyPreference = 'Restricted'
    $env:PATH = [Environment]::GetFolderPath('System')

    Set-Fixture
    $result = Invoke-Fixture 'defaults'
    $observed = Read-Observation
    Assert-True ($result.frameRate -eq '' -and $null -eq $result.renderScale) 'default profile reports no frame rate or render scale, so saved settings apply'
    Assert-True (-not $observed.frameRatePassed -and -not $observed.renderScalePassed -and $observed.checkOnly) 'helper receives no frame rate or render scale, and CheckOnly'
    Assert-True ((@($observed.boundNames) -join ',') -eq 'CheckOnly') 'default profile passes no helper option besides CheckOnly'
    Assert-True (-not $observed.frameLimitPassed -and $result.frameLimit -eq '') 'default profile leaves the frame limit to saved settings'
    Assert-True (-not $observed.nvidiaMaxPerformancePassed -and $result.nvidiaMaxPerformance -eq '') 'default profile leaves NVIDIA driver settings to saved settings'
    Assert-True (-not $observed.drawDistanceScalePassed -and -not $observed.lodDistanceScalePassed -and $result.drawDistanceScale -eq '' -and $result.lodDistanceScale -eq '') 'default profile leaves draw and LOD distance to saved settings'
    Assert-True ($result.workingDirectory -eq $fixture -and $observed.cwd -eq $fixture) 'native and helper working directories use executable location'
    Assert-True ($result.script -eq $scriptPath -and $observed.scriptRoot -eq $scripts) 'Unicode and shell-special paths arrive intact'
    Assert-True ($result.powerShell -eq (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe')) 'uses absolute native Windows PowerShell independent of PATH'
    Assert-True ($observed.psVersion.StartsWith('5.1.')) 'helper runs Windows PowerShell 5.1'
    Assert-True ($observed.hash -eq $expectedHash) 'native module defaults resolve Get-FileHash and correct bytes'
    Assert-True ($observed.executionPolicy -eq 'Bypass') 'download-marked helper works under inherited Restricted process policy'
    Assert-True (-not $observed.modulePath.Contains('nonexistent-module-path')) 'child removes contaminated inherited module path'
    Assert-True ($result.output.Contains('HOST-OUTPUT-MARKER') -and $result.output.Contains('STDOUT-MARKER') -and $result.output.Contains('STDERR-MARKER')) 'captures Write-Host, stdout and stderr'

    Set-Fixture
    $result = Invoke-Fixture 'overrides' @('--render-scale', '1', '--frame-rate', '60')
    $observed = Read-Observation
    Assert-True ($observed.frameRatePassed -and $observed.frameRate -eq '60' -and $observed.renderScalePassed -and $observed.renderScale -eq 1) 'handheld overrides reach helper'
    Assert-True ($result.frameRate -eq '60' -and $result.renderScale -eq 1) 'handheld overrides appear in the report'

    # The former built-in defaults, now only when asked for explicitly.
    Set-Fixture
    $result = Invoke-Fixture 'explicit-unlimited-2x' @('--frame-rate', 'unlimited', '--render-scale', '2')
    $observed = Read-Observation
    Assert-True ($observed.frameRatePassed -and $observed.frameRate -eq 'unlimited' -and $observed.renderScalePassed -and $observed.renderScale -eq 2) 'explicit unlimited and 2x still reach helper'
    Assert-True ($result.frameRate -eq 'unlimited' -and $result.renderScale -eq 2) 'explicit unlimited and 2x appear in the report'

    foreach ($rate in @('original', '60', '120', '144', '165', '200', '240', 'unlimited')) {
        Set-Fixture
        $result = Invoke-Fixture ('frame-rate-' + $rate) @('--frame-rate', $rate)
        $observed = Read-Observation
        Assert-True ($observed.frameRatePassed -and $observed.frameRate -eq $rate -and $result.frameRate -eq $rate) "frame rate $rate reaches helper"
        Assert-True (-not $observed.renderScalePassed -and $null -eq $result.renderScale) "frame rate $rate alone leaves render scale to saved settings"
    }

    foreach ($scale in @(1, 2, 3, 4)) {
        Set-Fixture
        $result = Invoke-Fixture ('render-scale-' + $scale) @('--render-scale', [string]$scale)
        $observed = Read-Observation
        Assert-True ($observed.renderScalePassed -and $observed.renderScale -eq $scale -and $result.renderScale -eq $scale) "render scale $scale reaches helper"
        Assert-True (-not $observed.frameRatePassed -and $result.frameRate -eq '') "render scale $scale alone leaves frame rate to saved settings"
    }

    foreach ($limit in @('auto', '57', 'off')) {
        Set-Fixture
        $result = Invoke-Fixture ('frame-limit-' + $limit) @('--frame-limit', $limit)
        $observed = Read-Observation
        Assert-True ($observed.frameLimitPassed -and $observed.frameLimit -eq $limit -and $result.frameLimit -eq $limit) "frame limit $limit reaches helper"
    }

    foreach ($mode in @('on', 'off', 'restore')) {
        Set-Fixture
        $result = Invoke-Fixture ('nvidia-max-performance-' + $mode) @('--nvidia-max-performance', $mode)
        $observed = Read-Observation
        Assert-True ($observed.nvidiaMaxPerformancePassed -and $observed.nvidiaMaxPerformance -eq $mode -and $result.nvidiaMaxPerformance -eq $mode) "NVIDIA max performance $mode reaches helper"
    }

    # Different values in each pair also show the two options are not swapped.
    foreach ($pair in @(@('1', '8'), @('2.5', '0.5'), @('0.5', '2.5'), @('8', '1'))) {
        $draw, $lod = $pair
        Set-Fixture
        $result = Invoke-Fixture ('distance-' + $draw + '-' + $lod) @('--draw-distance', $draw, '--lod-distance', $lod)
        $observed = Read-Observation
        Assert-True ($observed.drawDistanceScalePassed -and $observed.drawDistanceScale -eq $draw -and $result.drawDistanceScale -eq $draw) "draw distance $draw reaches helper"
        Assert-True ($observed.lodDistanceScalePassed -and $observed.lodDistanceScale -eq $lod -and $result.lodDistanceScale -eq $lod) "LOD distance $lod reaches helper"
    }
    Set-Fixture
    $result = Invoke-Fixture 'draw-distance-only' @('--draw-distance', '2')
    $observed = Read-Observation
    Assert-True ($observed.drawDistanceScale -eq '2' -and -not $observed.lodDistanceScalePassed -and $result.lodDistanceScale -eq '') 'draw distance alone leaves LOD distance to saved settings'
    Set-Fixture
    $result = Invoke-Fixture 'lod-distance-only' @('--lod-distance', '2')
    $observed = Read-Observation
    Assert-True ($observed.lodDistanceScale -eq '2' -and -not $observed.drawDistanceScalePassed -and $result.drawDistanceScale -eq '') 'LOD distance alone leaves draw distance to saved settings'

    Set-Fixture -ExitCode 23
    $failure = Invoke-Fixture 'failure' -ExpectedExit 23
    Assert-True ($failure.output.Contains('STDERR-MARKER')) 'failed helper retains useful error output without a dialog'

    Set-Fixture -ExitCode 17 -EmptyOutput $true
    $empty = Invoke-Fixture 'empty-failure' -ExpectedExit 17
    Assert-True ([string]::IsNullOrEmpty($empty.output)) 'empty-output failure still preserves nonzero exit'

    Set-Fixture -LargeOutput $true
    $large = Invoke-Fixture 'large-output'
    Assert-True ($large.outputTruncated -and $large.output.Length -le 65536) 'large stdout and stderr are drained with bounded retained output'
    Assert-True ($large.output.Contains('STDERR-MARKER')) 'bounded capture keeps final diagnostics after pipe-sized output'

    Set-Fixture -DelayMs 2000
    $null = Invoke-Fixture 'normal-launch-lifetime' -CheckOnly $false -CheckLifetime $true
    $observed = Read-Observation
    Assert-True (-not $observed.checkOnly -and -not $observed.renderScalePassed -and -not $observed.frameRatePassed) 'normal double-click reaches harmless helper without CheckOnly, frame rate or render scale'
    Assert-True (@($observed.boundNames).Count -eq 0) 'normal double-click passes no helper options, so saved settings apply'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture 'completed.txt')) 'normal launcher waits for helper completion'

    Set-Fixture
    $invalid = Invoke-Fixture 'invalid-rate' @('--frame-rate', '120;exit') -ExpectedExit 1
    Assert-True ($invalid.launcherError.Contains('Frame rate must be')) 'rejects invalid frame-rate input without invoking PowerShell'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json'))) 'invalid arguments do not run helper'
    $invalid = Invoke-Fixture 'invalid-scale' @('--render-scale', '0') -ExpectedExit 1
    Assert-True ($invalid.launcherError.Contains('Render scale must be')) 'rejects invalid render scale'
    $badIndex = 0
    foreach ($bad in @('60;exit', '19', '1001', '60.5', 'AUTO')) {
        $badIndex++
        $invalid = Invoke-Fixture ('invalid-limit-' + $badIndex) @('--frame-limit', $bad) -ExpectedExit 1
        Assert-True ($invalid.launcherError.Contains('Frame limit must be')) "rejects frame limit '$bad' without invoking PowerShell"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json'))) 'invalid frame limits do not run helper'
    $badIndex = 0
    # '""' passes an empty argument through the launcher command line.
    foreach ($bad in @('ON', 'max', 'on;exit', '""')) {
        $badIndex++
        $invalid = Invoke-Fixture ('invalid-nvidia-' + $badIndex) @('--nvidia-max-performance', $bad) -ExpectedExit 1
        Assert-True ($invalid.launcherError.Contains('NVIDIA max performance must be')) "rejects NVIDIA max performance '$bad' without invoking PowerShell"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json'))) 'invalid NVIDIA max performance values do not run helper'
    foreach ($option in @(
        @{ Name = '--draw-distance'; Slug = 'draw'; Message = 'Draw distance must be' },
        @{ Name = '--lod-distance'; Slug = 'lod'; Message = 'LOD distance must be' }
    )) {
        Set-Fixture
        $badIndex = 0
        # '""' passes an empty argument through the launcher command line.
        foreach ($bad in @('0.4', '9', '2,5', 'abc', '1;exit', '""', '1.2345')) {
            $badIndex++
            $invalid = Invoke-Fixture ('invalid-' + $option.Slug + '-distance-' + $badIndex) @($option.Name, $bad) -ExpectedExit 1
            Assert-True ($invalid.launcherError.Contains($option.Message)) "rejects $($option.Name) '$bad' without invoking PowerShell"
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json'))) "invalid $($option.Name) values do not run helper"
    }
    $invalid = Invoke-Fixture 'unknown-option' @('--arbitrary-command') -ExpectedExit 1
    Assert-True ($invalid.launcherError.Contains('Unknown launcher option')) 'rejects arbitrary forwarded arguments'

    Move-Item -LiteralPath $scriptPath -Destination ($scriptPath + '.fixture-backup')
    $missing = Invoke-Fixture 'missing-helper' -ExpectedExit 1
    Assert-True ($missing.launcherError.Contains('Extract the complete player package')) 'missing helper gives actionable extraction guidance'
    Move-Item -LiteralPath ($scriptPath + '.fixture-backup') -Destination $scriptPath

    Assert-True ($env:PSModulePath -eq $contaminatedModulePath -and $env:PSExecutionPolicyPreference -eq 'Restricted') 'child launches leave parent module path and execution policy unchanged'
} finally {
    $env:PSModulePath = $originalModulePath
    $env:PSExecutionPolicyPreference = $originalPolicy
    $env:PATH = $originalPath
}
Assert-True ($env:PSModulePath -eq $originalModulePath -and $env:PSExecutionPolicyPreference -eq $originalPolicy -and $env:PATH -eq $originalPath) 'fixture restores its caller environment'
$summary = [ordered]@{
    passed = $true
    checks = $checks.Count
    assertions = @($checks)
    launcherSha256 = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    hostPowerShell = $PSVersionTable.PSVersion.ToString()
    fixture = $fixture
    limitations = @('Controlled PowerShell scripts only; no game launched.', 'No actual Armoury Crate or Ally integration test.', 'CheckOnly reports preflight results; it does not prove gameplay or runtime readiness.')
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'verification.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
