[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$workspace = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $workspace 'tools/rexglue-sdk-source'
# Keep the pin explicit; this is the source of the tested 0.10.0 runtime.
$expectedCommit = 'f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
$actualCommit = (& git -C $sdk rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) { throw 'SDK commit does not match the tested runtime.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $workspace ('packages/Skate2-Runtime-Source-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$packagesRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'packages'))
if (-not $OutputDirectory.StartsWith($packagesRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Companion must be a fresh directory under packages.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Destination already exists.' }
$ancestor = Get-Item -LiteralPath (Split-Path -Parent $OutputDirectory) -Force
while ($ancestor) { if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse output directory.' }; $ancestor = $ancestor.Parent }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$files = [Collections.Generic.List[object]]::new()
$omitted = [Collections.Generic.List[object]]::new()
$checkedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Copy-Ordinary([string]$Root, [string]$Relative, [string]$Target, [string]$GitMode = '') {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[/\\])\.\.([/\\]|$)' -or $Relative.Contains(':') -or $Target -match '(^|/)\.git(/|$)') { throw "Unsafe path: $Relative" }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $path.StartsWith($Root.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source escaped root.' }
    $item = Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Expected ordinary file: $Relative" }
    $ancestor = $item.Directory
    while ($ancestor.FullName.Length -ge $Root.Length) {
        if ($checkedDirectories.Contains($ancestor.FullName)) { break }
        if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse source directory.' }
        $checkedDirectories.Add($ancestor.FullName) | Out-Null
        $ancestor = $ancestor.Parent; if(-not $ancestor) { break }
    }
    $dest = Join-Path $OutputDirectory $Target
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
    [IO.File]::Copy($path,$dest,$false)
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $hash) { throw 'Copy hash mismatch.' }
    $files.Add([ordered]@{Path=$Target; Bytes=$item.Length; SHA256=$hash; GitMode=$GitMode})
}
$selected = @('FFmpeg','cli11','fmt','imgui','inja','libmspack','o1heap','sdl3','simde','spdlog','tomlplusplus','utfcpp','xxHash')
$gitlinks = @{}
$entries = @(& git -C $sdk -c core.quotepath=false ls-files --stage)
if($LASTEXITCODE -ne 0) { throw 'SDK inventory failed.' }
foreach ($entry in $entries) {
    if($entry -notmatch '^(\d+) ([a-f0-9]+) 0\t(.+)$') { throw "Unrecognized Git inventory: $entry" }
    $mode=$Matches[1]; $blob=$Matches[2]; $relative=$Matches[3]
    if($mode -eq '160000') { $gitlinks[$relative]=$blob; continue }
    if($relative -match '^(tools/|tests/|\.github/)') { $omitted.Add([ordered]@{Path=$relative; Reason='Upstream development/test tools; not needed for selected runtime targets.'}); continue }
    Copy-Ordinary $sdk $relative "sdk-source/$relative" $mode
}
# This reviewed port header is new rather than tracked in the pinned SDK.
Copy-Ordinary $sdk 'include/rex/cvar_validation.h' 'sdk-source/include/rex/cvar_validation.h'
$submodules = @()
foreach ($name in $selected) {
    $relativeRoot="thirdparty/$name"; $subroot=Join-Path $sdk $relativeRoot
    $commit=(& git -C $subroot rev-parse HEAD).Trim()
    if($LASTEXITCODE -ne 0 -or $commit -ne $gitlinks[$relativeRoot]) { throw "Submodule pin mismatch: $name" }
    $dirty=@(& git -C $subroot status --porcelain)
    if($LASTEXITCODE -ne 0 -or $dirty.Count) { throw "Unexpected submodule changes: $name" }
    $submodules += [ordered]@{Path=$relativeRoot; Commit=$commit; Modified=$false}
    $entries=@(& git -C $subroot -c core.quotepath=false ls-files --stage)
    if($LASTEXITCODE -ne 0) { throw "Submodule inventory failed: $name" }
    foreach($entry in $entries) {
        if($entry -notmatch '^(\d+) ([a-f0-9]+) 0\t(.+)$') { throw "Unrecognized Git inventory: $entry" }
        $mode=$Matches[1]; $relative=$Matches[3]
        if($mode -eq '160000') {
            if($name -ne 'simde' -or $relative -ne 'test/munit') { throw "Unreviewed nested submodule: $name/$relative" }
            $omitted.Add([ordered]@{Path="$relativeRoot/$relative";Reason='SIMDe unit-test harness; no runtime dependency.'}); continue
        }
        if($name -eq 'imgui' -and $relative -match '^examples/libs/glfw/lib-vc2010-\d+/glfw3\.lib$') { $omitted.Add([ordered]@{Path="$relativeRoot/$relative";Reason='Unused prebuilt GLFW example library.'}); continue }
        Copy-Ordinary $subroot $relative "sdk-source/$relativeRoot/$relative" $mode
    }
    Write-Host "Collected $name at $commit"
}
foreach($relative in @('scripts/Rebuild-Skate2Runtime.ps1','scripts/Test-Skate2RuntimeABI.ps1','tools/Enter-BuildEnvironment.ps1','docs/RUNTIME_REBUILD.md','LICENSE')) { Copy-Ordinary $workspace $relative $relative }
$patches=@('windows-build','float16-pack','input-diagnostics','input-synchronization','audio-output','cvar-toml-escaping','release-perf-counters','live-frame-capture','cvar-validator','vertex-buffer-coherency','present-idleclean-diagnostic')
foreach($name in $patches) { $relative="patches/rexglue-0.10.0-$name.patch"; Copy-Ordinary $workspace $relative $relative }
$noticeIndex = Get-Content -LiteralPath (Join-Path $workspace 'licenses/NOTICE-INDEX.json') -Raw | ConvertFrom-Json
foreach($notice in $noticeIndex.Files) { Copy-Ordinary $workspace $notice.Path $notice.Path }
Copy-Ordinary $workspace 'licenses/NOTICE-INDEX.json' 'licenses/NOTICE-INDEX.json'
$baseline=@()
$expectedRuntime=@{
    'rexruntime.dll'='258D10678E0CA0F4B961A7BDCD96154711B063B0BC8557D5652C18FFFE06AA0A'
    'rexgpu-xenos.dll'='93F73CAED68E80508174668B9F5F06A7D7CDA9AE724C48143B39B4EF5AE14F02'
}
foreach($name in @('rexruntime.dll','rexgpu-xenos.dll')) {
    $path=Join-Path $sdk "out/win-amd64/Release/$name"
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if($hash -ne $expectedRuntime[$name]) { throw "Tested runtime changed: $name" }
    $baseline += [ordered]@{Path=$name;SHA256=$hash;Bytes=(Get-Item -LiteralPath $path).Length}
}
$changes = @(& git -C $sdk diff --name-only)
if($LASTEXITCODE -ne 0) { throw 'SDK change inventory failed.' }
$manifest=[ordered]@{
    SchemaVersion=1; Scope='Corresponding source and runtime-only relink recipe for Windows x64 D3D12'; SDKCommit=$actualCommit; SDKVersion='0.10.0'
    BaselineRuntime=$baseline; Submodules=$submodules; SDKModifiedFiles=@($changes)+@('include/rex/cvar_validation.h')
    SourceNotes=@('SDK files preserve exact local working-tree bytes. Port modifications are already applied; included patches explain them.', 'Full selected dependency source trees are included. Disabled Vulkan/Tracy/test submodules are omitted.', 'Windows Git checks out upstream symbolic links as small ordinary text files. GitMode records them; selected runtime build uses real source paths.', 'Upstream embedded SDK shaders and fonts are included. No game data, generated game functions, build outputs, Git metadata, saves or personal configuration are collected.')
    Files=@($files.ToArray() | Sort-Object Path); Omitted=@($omitted.ToArray()); NoticeCount=$noticeIndex.NoticeCount
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SOURCE-MANIFEST.json') -Encoding UTF8
@'
Skate 2 PC runtime corresponding source

Open docs/RUNTIME_REBUILD.md for the exact rebuild and DLL replacement procedure.
The SDK and selected dependencies are included in sdk-source/. Game files are not required.
SOURCE-MANIFEST.json identifies the released runtime DLLs and hashes every included source file.
'@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'START-HERE.txt') -Encoding UTF8
Write-Host "Runtime source companion collected: $OutputDirectory"
Write-Output $OutputDirectory
