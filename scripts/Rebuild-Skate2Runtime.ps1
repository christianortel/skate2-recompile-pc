# Rebuild the distributed runtime from its corresponding source. Never changes a game installation.
[CmdletBinding()]
param(
    [string]$CompanionRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory,
    [ValidateRange(1,32)][int]$Jobs = 4,
    [switch]$VerifyOriginal,
    [string]$VisualStudioPath,
    [string]$LLVMDirectory,
    [string]$CMakeDirectory,
    [string]$NinjaDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$CompanionRoot = (Resolve-Path -LiteralPath $CompanionRoot).Path
$manifest = Get-Content -LiteralPath (Join-Path $CompanionRoot 'SOURCE-MANIFEST.json') -Raw | ConvertFrom-Json
$checkedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Get-SafeFile([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[/\\])\.\.([/\\]|$)' -or $Relative.Contains(':')) { throw "Unsafe relative path: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped root.' }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Expected ordinary file: $Relative" }
    $parent = $item.Directory
    while ($parent.FullName.Length -ge $Root.Length) {
        if ($checkedDirectories.Contains($parent.FullName)) { break }
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse directories are not supported.' }
        $checkedDirectories.Add($parent.FullName) | Out-Null
        $parent = $parent.Parent
        if (-not $parent) { break }
    }
    return $full
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $CompanionRoot ('rebuild-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory must be a fresh path; existing directories are never overwritten.' }
$outputParent = Get-Item -LiteralPath (Split-Path -Parent $OutputDirectory) -Force
if (-not $outputParent.PSIsContainer) { throw 'Output parent must exist.' }
while ($outputParent) {
    if ($outputParent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse output directories are not supported.' }
    $outputParent = $outputParent.Parent
}
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$buildSource = Join-Path $OutputDirectory 'sdk-source'
[IO.Directory]::CreateDirectory($buildSource) | Out-Null
$copied = 0
foreach ($entry in $manifest.Files) {
    if (-not $entry.Path.StartsWith('sdk-source/')) { continue }
    $source = Get-SafeFile $CompanionRoot $entry.Path
    if ($VerifyOriginal -and (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Original source hash mismatch: $($entry.Path)" }
    $destination = Join-Path $OutputDirectory $entry.Path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::Copy($source, $destination, $false)
    $copied++
}
# Minimal archive-only preparation; original archived source remains byte-exact.
$thirdparty = Join-Path $buildSource 'thirdparty/CMakeLists.txt'
$cmake = [IO.File]::ReadAllText($thirdparty)
$old = 'if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${submodule}/.git")'
$new = 'if(NOT REXGLUE_SOURCE_ARCHIVE AND NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${submodule}/.git")'
if (($cmake.Split(@($old),[StringSplitOptions]::None)).Count -ne 2) { throw 'Unexpected submodule initialization check.' }
[IO.File]::WriteAllText($thirdparty, $cmake.Replace($old,$new), [Text.UTF8Encoding]::new($false))
$version = Join-Path $buildSource 'cmake/rex_version.cmake'
$cmake = [IO.File]::ReadAllText($version)
$old = 'function(rex_resolve_version out_var)'
$new = @'
function(rex_resolve_version out_var)
    # Source archive has no Git metadata; retain the shipped SDK version.
    if(DEFINED REXGLUE_SOURCE_ARCHIVE_VERSION)
        set(${out_var} "${REXGLUE_SOURCE_ARCHIVE_VERSION}" PARENT_SCOPE)
        return()
    endif()
'@
if (($cmake.Split(@($old),[StringSplitOptions]::None)).Count -ne 2) { throw 'Unexpected version resolver.' }
[IO.File]::WriteAllText($version, $cmake.Replace($old,$new), [Text.UTF8Encoding]::new($false))
$environmentArguments = @{}
foreach ($name in @('VisualStudioPath','LLVMDirectory','CMakeDirectory','NinjaDirectory')) {
    if (Get-Variable -Name $name -ValueOnly) { $environmentArguments[$name] = Get-Variable -Name $name -ValueOnly }
}
. (Get-SafeFile $CompanionRoot 'tools/Enter-BuildEnvironment.ps1') @environmentArguments
$configureArguments = @('--preset','win-amd64','-DREXGLUE_SOURCE_ARCHIVE=ON','-DREXGLUE_SOURCE_ARCHIVE_VERSION=0.10.0',
    '-DREXGLUE_USE_D3D12=ON','-DREXGLUE_USE_VULKAN=OFF','-DREXGLUE_ENABLE_FIDELITYFX=OFF',
    '-DREXGLUE_ENABLE_TRACY=OFF','-DREXGLUE_BUILD_TESTS=OFF','-DREXGLUE_ENABLE_PERF_COUNTERS=ON',
    '-DREXGLUE_ENABLE_RELEASE_PERF_COUNTERS=ON')
$buildArguments = @('--build','out/build/win-amd64','--config','Release','--target','rexruntime','rexgpu-xenos','--parallel',"$Jobs")
Push-Location $buildSource
try {
    & cmake @configureArguments 2>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'configure.log') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed: $LASTEXITCODE" }
    & cmake @buildArguments 2>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'build.log') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Runtime build failed: $LASTEXITCODE" }
} finally { Pop-Location }
$runtimeOutput = Join-Path $OutputDirectory 'runtime-output'
[IO.Directory]::CreateDirectory($runtimeOutput) | Out-Null
$outputs = @()
foreach ($name in @('rexruntime.dll','rexgpu-xenos.dll')) {
    $source = Join-Path $buildSource "out/win-amd64/Release/$name"
    [IO.File]::Copy($source, (Join-Path $runtimeOutput $name), $false)
    $outputs += [ordered]@{ Path = "runtime-output/$name"; SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash; Bytes = (Get-Item -LiteralPath $source).Length }
}
[ordered]@{
    SchemaVersion = 1; Status = 'built'; OriginalHashesVerified = [bool]$VerifyOriginal; SourceFilesCopied = $copied
    ConfigureArguments = $configureArguments; BuildArguments = $buildArguments; Outputs = $outputs
    Scope = 'Runtime DLLs only; no game executable, game data, generated game code, or save data required.'
    Limitations = @('No game launched.','Build outputs are not expected to be byte-identical: timestamps, toolchain and paths can differ.','Use the release ABI comparison before replacing DLLs in a separate installation.')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'rebuild-result.json') -Encoding UTF8
Write-Host "Runtime DLLs ready in $runtimeOutput"
