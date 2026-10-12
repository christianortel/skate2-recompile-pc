[CmdletBinding()]
param([ValidateRange(1, 32)][int]$Jobs = 4)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. (Join-Path $workspace 'tools\Enter-BuildEnvironment.ps1')
$source = Join-Path $workspace 'launcher'
$build = Join-Path $source 'out\win-amd64-release'

function Invoke-LauncherBuild([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & cmake @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-Host
        $result = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($result -ne 0) { throw "Launcher CMake command failed with exit code $result." }
}

# This small launcher has no dependency on the game data or the ReXGlue SDK.
Invoke-LauncherBuild @('-S', $source, '-B', $build, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=cl.exe')
Invoke-LauncherBuild @('--build', $build, '--config', 'Release', '--parallel', "$Jobs")
$executable = Join-Path $build 'Launch Skate 2.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'The launcher build did not produce Launch Skate 2.exe.'
}
$destination = Join-Path $workspace 'Launch Skate 2.exe'
Copy-Item -LiteralPath $executable -Destination $destination
if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $executable).Hash) {
    throw 'The launcher copy failed verification.'
}
[pscustomobject]@{ Launcher = $destination; SHA256 = (Get-FileHash -LiteralPath $destination).Hash }
