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
param([string]$FrameRate, [int]$RenderScale, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $root 'fixture-config.json') -Raw | ConvertFrom-Json
$observation = [ordered]@{
    frameRate = $FrameRate
    renderScale = $RenderScale
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
    Assert-True ($result.frameRate -eq 'unlimited' -and $result.renderScale -eq 2) 'default profile is unlimited and 2x'
    Assert-True ($observed.frameRate -eq 'unlimited' -and $observed.renderScale -eq 2 -and $observed.checkOnly) 'helper receives exact default settings and CheckOnly'
    Assert-True ($result.workingDirectory -eq $fixture -and $observed.cwd -eq $fixture) 'native and helper working directories use executable location'
    Assert-True ($result.script -eq $scriptPath -and $observed.scriptRoot -eq $scripts) 'Unicode and shell-special paths arrive intact'
    Assert-True ($result.powerShell -eq (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe')) 'uses absolute native Windows PowerShell independent of PATH'
    Assert-True ($observed.psVersion.StartsWith('5.1.')) 'helper runs Windows PowerShell 5.1'
    Assert-True ($observed.hash -eq $expectedHash) 'native module defaults resolve Get-FileHash and correct bytes'
    Assert-True ($observed.executionPolicy -eq 'Bypass') 'download-marked helper works under inherited Restricted process policy'
    Assert-True (-not $observed.modulePath.Contains('nonexistent-module-path')) 'child removes contaminated inherited module path'
    Assert-True ($result.output.Contains('HOST-OUTPUT-MARKER') -and $result.output.Contains('STDOUT-MARKER') -and $result.output.Contains('STDERR-MARKER')) 'captures Write-Host, stdout and stderr'

    Set-Fixture
    $null = Invoke-Fixture 'overrides' @('--render-scale', '1', '--frame-rate', '60')
    $observed = Read-Observation
    Assert-True ($observed.frameRate -eq '60' -and $observed.renderScale -eq 1) 'handheld overrides reach helper'

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
    Assert-True (-not $observed.checkOnly -and $observed.renderScale -eq 2 -and $observed.frameRate -eq 'unlimited') 'normal double-click profile reaches harmless helper without CheckOnly'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture 'completed.txt')) 'normal launcher waits for helper completion'

    Set-Fixture
    $invalid = Invoke-Fixture 'invalid-rate' @('--frame-rate', '120;exit') -ExpectedExit 1
    Assert-True ($invalid.launcherError.Contains('Frame rate must be')) 'rejects invalid frame-rate input without invoking PowerShell'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'observation.json'))) 'invalid arguments do not run helper'
    $invalid = Invoke-Fixture 'invalid-scale' @('--render-scale', '0') -ExpectedExit 1
    Assert-True ($invalid.launcherError.Contains('Render scale must be')) 'rejects invalid render scale'
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
