[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$sdkSource = Join-Path $workspace 'tools\rexglue-sdk-source'
$revision = 'f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
$repository = 'https://github.com/rexglue/rexglue-sdk.git'
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows and add git to PATH first.' }
function Invoke-GitChecked {
    param([string[]]$GitArguments)
    & git @GitArguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed with exit code $LASTEXITCODE; no automatic cleanup/reset was attempted." }
}
foreach ($candidate in @($workspace, (Join-Path $workspace 'tools'), $sdkSource)) {
    if ((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'SDK workspace paths must not be links or junctions.'
    }
}
if (Test-Path -LiteralPath $sdkSource) {
    $sdkTop = & git -C $sdkSource rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($sdkTop).TrimEnd('\') -ne [IO.Path]::GetFullPath($sdkSource).TrimEnd('\')) { throw 'Existing SDK directory is not its own Git checkout. It was not changed.' }
    $actual = & git -C $sdkSource rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw 'Existing SDK checkout is not the pinned revision. It was not reset.' }
    Write-Host 'Pinned SDK source is already present; local patches are preserved.'
} elseif (-not $CheckOnly) {
    New-Item -ItemType Directory -Path (Join-Path $workspace 'tools') -Force | Out-Null
    # Fetch source only. Never download or execute an SDK binary release.
    Invoke-GitChecked @('clone', '--branch', 'v0.10.0', '--depth', '1', '--no-checkout', $repository, $sdkSource)
    $actual = & git -C $sdkSource rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw 'Upstream tag does not match the pinned revision. Checkout was left for inspection.' }
    Invoke-GitChecked @('-C', $sdkSource, 'checkout', '--detach', $revision)
}
if ($CheckOnly) {
    Write-Host 'Check only: no downloads or changes. Normal execution clones the official pinned SDK and its pinned submodules.'
} else {
    # This project's build selects Windows D3D12 with tests/Tracy/FidelityFX
    # disabled. Fetch only its runtime and codegen dependencies, at their
    # exact superproject revisions, without unrelated Vulkan/test histories.
    $submodules = @('cli11', 'libmspack', 'FFmpeg', 'tomlplusplus', 'simde',
        'xxHash', 'spdlog', 'fmt', 'utfcpp', 'imgui', 'sdl3', 'o1heap', 'inja') |
        ForEach-Object { "thirdparty/$_" }
    Invoke-GitChecked (@('-C', $sdkSource, 'submodule', 'update', '--init',
        '--recursive', '--depth', '1', '--jobs', '4', '--') + $submodules)
    Write-Host 'SDK source is ready. Install the documented build tools, then run scripts/Build-Skate2.ps1.'
}
