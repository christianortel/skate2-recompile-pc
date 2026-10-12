[CmdletBinding()]
param(
    [ValidateSet('All', 'SDK', 'Generate', 'Build')]
    [string]$Stage = 'All',
    [ValidateRange(1, 32)]
    [int]$Jobs = 4,
    [switch]$PerformanceCounters,
    # Optional extracted source to import. The authored manifest always uses game/.
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$sdkSource = Join-Path $workspace 'tools\rexglue-sdk-source'
$sdkInstall = Join-Path $sdkSource 'out\install\win-amd64'
$projectRoot = Join-Path $workspace 'skate2'
$gameRoot = Join-Path $workspace 'game'
$manifest = Join-Path $projectRoot 'skate2_manifest.toml'
$expectedXexSha256 = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'

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

if (-not (Test-Path -LiteralPath $sdkSource -PathType Container)) {
    throw 'SDK source is missing. Run scripts/Bootstrap-Skate2Sdk.ps1 first, then install the documented build tools.'
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw 'The authored skate2/skate2_manifest.toml is missing. Restore the source export; do not replace it with an empty generated project.'
}
. (Join-Path $workspace 'tools\Enter-BuildEnvironment.ps1')
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
    if ($Stage -in @('All', 'SDK')) {
        Push-Location $sdkSource
        try {
            $sdkCommit = (& git rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $sdkCommit -ne 'f5337cdc947ff6d4c4196737e2c807a48f2a1fc2') {
                throw 'SDK source revision differs from the pinned, audited version.'
            }
            foreach ($patchName in @('rexglue-0.10.0-windows-build.patch', 'rexglue-0.10.0-float16-pack.patch', 'rexglue-0.10.0-input-diagnostics.patch', 'rexglue-0.10.0-input-synchronization.patch', 'rexglue-0.10.0-audio-output.patch', 'rexglue-0.10.0-cvar-toml-escaping.patch', 'rexglue-0.10.0-release-perf-counters.patch', 'rexglue-0.10.0-live-frame-capture.patch', 'rexglue-0.10.0-cvar-validator.patch', 'rexglue-0.10.0-vertex-buffer-coherency.patch', 'rexglue-0.10.0-present-idleclean-diagnostic.patch')) {
                $sdkPatch = Join-Path $workspace "patches\$patchName"
                $previousPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & git apply --reverse --check $sdkPatch 2>$null
                    $alreadyApplied = $LASTEXITCODE -eq 0
                } finally { $ErrorActionPreference = $previousPreference }
                if (-not $alreadyApplied) {
                    Invoke-Checked git @('apply', '--check', $sdkPatch)
                    Invoke-Checked git @('apply', $sdkPatch)
                }
            }
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
} finally {
    Stop-Transcript | Out-Null
}
