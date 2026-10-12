# Dot-source this file to update only the current PowerShell process.
[CmdletBinding()]
param(
    [string]$VisualStudioPath,
    [string]$LLVMDirectory,
    [string]$CMakeDirectory,
    [string]$NinjaDirectory
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use a 64-bit PowerShell process.' }
if (-not $VisualStudioPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $VisualStudioPath = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
    }
    if (-not $VisualStudioPath -and $env:VSINSTALLDIR) { $VisualStudioPath = $env:VSINSTALLDIR }
}
if (-not $VisualStudioPath) { throw 'Install Visual Studio 2022 Desktop development with C++ and a Windows SDK, or supply -VisualStudioPath.' }
$vcvarsPath = Join-Path $VisualStudioPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvarsPath -PathType Leaf)) { throw 'The selected Visual Studio installation lacks vcvars64.bat.' }
if ($vcvarsPath -match '["%\r\n]') { throw 'Visual Studio path cannot contain quotes, percent signs, or line breaks.' }
$environmentLines = & $env:ComSpec /d /s /c ('"{0}" >nul && set' -f $vcvarsPath)
if ($LASTEXITCODE -ne 0) { throw "Visual Studio environment setup failed with exit code $LASTEXITCODE" }
foreach ($environmentLine in $environmentLines) {
    if ($environmentLine -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
# Prefer the optional workspace tool layout used during development, otherwise PATH.
$localToolBins = @()
foreach ($toolSpec in @(
    @{ Explicit = $LLVMDirectory; Local = 'llvm-20.1.8\bin' },
    @{ Explicit = $CMakeDirectory; Local = 'cmake-4.4.4-windows-x86_64\bin' },
    @{ Explicit = $NinjaDirectory; Local = 'ninja' }
)) {
    if ($toolSpec.Explicit) {
        if (-not (Test-Path -LiteralPath $toolSpec.Explicit -PathType Container)) { throw "Missing tool directory: $($toolSpec.Explicit)" }
        $localToolBins += (Resolve-Path -LiteralPath $toolSpec.Explicit).Path
    } else {
        $localBin = Join-Path $PSScriptRoot $toolSpec.Local
        if (Test-Path -LiteralPath $localBin -PathType Container) { $localToolBins += $localBin }
    }
}
if ($localToolBins.Count) { $env:PATH = ($localToolBins -join ';') + ';' + $env:PATH }
foreach ($toolName in @('clang', 'clang++', 'cmake', 'ninja', 'git')) {
    if (-not (Get-Command $toolName -CommandType Application -ErrorAction SilentlyContinue)) { throw "Missing $toolName. Install the documented toolchain and add it to PATH." }
}
$clangVersion = (& clang --version | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or $clangVersion -notmatch 'clang version (\d+)\.' -or [int]$Matches[1] -lt 20) { throw 'LLVM Clang 20 or later is required.' }
$cmakeVersion = (& cmake --version | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or $cmakeVersion -notmatch 'cmake version (\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'3.25.0') { throw 'CMake 3.25 or later is required.' }
$env:CC = 'clang'
$env:CXX = 'clang++'
Write-Host 'Skate 2 x64 C++ build environment loaded. Toolchain discovery does not validate a clean-machine build.'
