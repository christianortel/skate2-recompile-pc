[CmdletBinding()]
param(
    [string]$SdkSource,
    [switch]$CheckOnly
)

# Collect only reviewed notice files/comment blocks. This is an inventory aid,
# not a declaration that a binary distribution meets every license obligation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $SdkSource) { $SdkSource = Join-Path $workspace 'tools/rexglue-sdk-source' }
$sdk = [IO.Path]::GetFullPath($SdkSource)
$licenseRoot = Join-Path $workspace 'licenses'
$reportPath = Join-Path $workspace 'reports/runtime-notice-audit.json'
$byteEncoding = [Text.Encoding]::GetEncoding(28591)
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-OrdinaryPath([string]$Path, [string]$Root, [switch]$File) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($absolute -ne $base -and -not $absolute.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its permitted root: $Path"
    }
    $cursor = $absolute
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not permitted: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($File -and -not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Missing ordinary source file: $absolute" }
    return $absolute
}

function Get-BytesHash([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($Bytes))).Replace('-', '') }
    finally { $hasher.Dispose() }
}

$firstComment = '\A/\*[\s\S]*?\*/'
$commentPrefix = '\A(?:(?://[^\r\n]*(?:\r\n|\n|\r|$))|(?:/\*[\s\S]*?\*/)|\s)+'
$stbLicense = '/\*\s*-+\s*This software is available under 2 licenses[\s\S]*?\*/'
$specs = New-Object 'System.Collections.Generic.List[object]'
function Add-Notice($Component, $Source, $Output, $Terms, $Integration, $Pattern = '') {
    $specs.Add([pscustomobject]@{ Component=$Component; Source=$Source; Output=$Output; Terms=$Terms; Integration=$Integration; Pattern=$Pattern })
}

Add-Notice 'ReXGlue and Xenia' 'LICENSE' 'ReXGlue-LICENSE.txt' 'BSD-3-Clause' 'Runtime DLL and GPU plugin'
Add-Notice 'SDL3' 'thirdparty/sdl3/LICENSE.txt' 'SDL3-LICENSE.txt' 'Zlib' 'Static library linked into rexruntime and the application'
Add-Notice 'HIDAPI' 'thirdparty/sdl3/src/hidapi/LICENSE.txt' 'HIDAPI-license-options.txt' 'Upstream alternative-license explanation' 'SDL3 HID controller support'
Add-Notice 'HIDAPI' 'thirdparty/sdl3/src/hidapi/LICENSE-bsd.txt' 'HIDAPI-BSD-LICENSE.txt' 'BSD-style option retained' 'SDL3 HID controller support'
Add-Notice 'HIDAPI Windows' 'thirdparty/sdl3/src/hidapi/windows/hid.c' 'HIDAPI-Windows-NOTICE.txt' 'Copyright and alternative-license notice' 'SDL3 HID controller support' $firstComment
Add-Notice 'fmt' 'thirdparty/fmt/LICENSE' 'fmt-LICENSE.txt' 'MIT' 'Static formatting library'
Add-Notice 'spdlog' 'thirdparty/spdlog/LICENSE' 'spdlog-LICENSE.txt' 'MIT and included third-party notices' 'Static logging library'
Add-Notice 'xxHash' 'thirdparty/xxHash/LICENSE' 'xxHash-LICENSE.txt' 'BSD-2-Clause' 'Static hash library'
Add-Notice 'aes_128' 'thirdparty/aes_128/LICENSE' 'aes128-LICENSE.txt' 'MIT' 'Static library for kernel crypto routines'
Add-Notice 'o1heap' 'thirdparty/o1heap/LICENSE' 'o1heap-LICENSE.txt' 'MIT' 'Static kernel heap allocator'
Add-Notice 'SIMDe' 'thirdparty/simde/COPYING' 'SIMDe-COPYING.txt' 'MIT and included notices' 'SIMD headers used by runtime and generated application'
Add-Notice 'toml++' 'thirdparty/tomlplusplus/LICENSE' 'tomlplusplus-LICENSE.txt' 'MIT' 'Configuration parsing headers'
Add-Notice 'CLI11' 'thirdparty/cli11/LICENSE' 'CLI11-LICENSE.txt' 'BSD-3-Clause' 'Runtime cvar argument parsing headers'
Add-Notice 'UTF8-CPP' 'thirdparty/utfcpp/LICENSE' 'UTF8CPP-LICENSE.txt' 'Boost-1.0' 'Runtime text conversion headers'
Add-Notice 'Dear ImGui' 'thirdparty/imgui/LICENSE.txt' 'ImGui-LICENSE.txt' 'MIT' 'UI object files linked into rexruntime'
Add-Notice 'ImGui stb_rectpack' 'thirdparty/imgui/imstb_rectpack.h' 'ImGui-stb_rectpack-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui internal font packing' $stbLicense
Add-Notice 'ImGui stb_truetype' 'thirdparty/imgui/imstb_truetype.h' 'ImGui-stb_truetype-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui font rasterization' $stbLicense
Add-Notice 'ImGui stb_textedit' 'thirdparty/imgui/imstb_textedit.h' 'ImGui-stb_textedit-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui text editing' $stbLicense
Add-Notice 'stb_image' 'thirdparty/stb/stb_image.h' 'stb_image-LICENSE.txt' 'MIT or public-domain alternatives' 'Runtime image_decode.cpp' $stbLicense
Add-Notice 'RenderDoc API' 'thirdparty/renderdoc/renderdoc_app.h' 'RenderDoc-API-LICENSE.txt' 'MIT' 'API header; RenderDoc DLL is not bundled' $firstComment
Add-Notice 'DXC API headers' 'thirdparty/dxc/include/dxcapi.h' 'DXC-dxcapi-NOTICE.txt' 'Notice only; referenced full license missing locally' 'D3D12 runtime API declarations' $commentPrefix
Add-Notice 'DXC converter header' 'thirdparty/dxc/include/DxbcConverter.h' 'DXC-DxbcConverter-NOTICE.txt' 'Notice only; referenced full license missing locally' 'D3D12 runtime API declarations' $commentPrefix
Add-Notice 'libmspack' 'thirdparty/libmspack/libmspack/COPYING.LIB' 'libmspack-COPYING.LIB.txt' 'LGPL-2.1' 'lzxd.c static library linked into rexruntime'
Add-Notice 'libmspack LZX' 'thirdparty/libmspack/libmspack/mspack/lzxd.c' 'libmspack-LZX-NOTICE.txt' 'LGPL-2.1 copyright notice' 'lzxd.c static library linked into rexruntime' $firstComment
Add-Notice 'FFmpeg' 'thirdparty/FFmpeg/COPYING.LGPLv2.1' 'FFmpeg-COPYING.LGPLv2.1.txt' 'LGPL-2.1-or-later under inspected configuration' 'libavcodec and libavutil static libraries'
Add-Notice 'FFmpeg' 'thirdparty/FFmpeg/LICENSE.md' 'FFmpeg-LICENSE.md' 'Upstream licensing overview; optional licenses are not all enabled' 'libavcodec and libavutil static libraries'
Add-Notice 'FFmpeg IJG fast DCT' 'thirdparty/FFmpeg/libavcodec/jfdctfst.c' 'FFmpeg-IJG-jfdctfst-NOTICE.txt' 'Independent JPEG Group terms' 'Selected FFmpeg codec source' $firstComment
Add-Notice 'FFmpeg IJG integer DCT' 'thirdparty/FFmpeg/libavcodec/jfdctint_template.c' 'FFmpeg-IJG-jfdctint-NOTICE.txt' 'Independent JPEG Group terms' 'Included by selected jfdctint.c source' $firstComment
Add-Notice 'FFmpeg IJG inverse DCT' 'thirdparty/FFmpeg/libavcodec/jrevdct.c' 'FFmpeg-IJG-jrevdct-NOTICE.txt' 'Independent JPEG Group terms' 'Selected FFmpeg codec source' $firstComment
Add-Notice 'Crypto DES' 'thirdparty/crypto/des/LICENSE' 'Crypto-DES-LICENSE.txt' 'MIT' 'Included directly by xboxkrnl_crypt.cpp'
Add-Notice 'TinySHA1' 'thirdparty/crypto/TinySHA1.hpp' 'TinySHA1-LICENSE.txt' 'ISC-style notice' 'Included by kernel crypto and XEX loader' $firstComment
Add-Notice 'Rijndael AES' 'thirdparty/crypto/rijndael-alg-fst.c' 'Rijndael-NOTICE.txt' 'Public-domain dedication and warranty disclaimer' 'Included directly by xex_module.cpp' $firstComment
Add-Notice 'Crypto SHA256' 'thirdparty/crypto/sha256.cpp' 'SHA256-NOTICE.txt' 'Notice states zlib when acquired; full historical terms need verification' 'Included directly by xboxkrnl_crypt.cpp' $commentPrefix
Add-Notice 'DXBC checksum' 'thirdparty/dxbc/DXBCChecksum.cpp' 'DXBC-Checksum-NOTICE.txt' 'AMD attribution and RSA-MD5 derivative notice' 'Compiled into GPU plugin' $commentPrefix

[void](Assert-OrdinaryPath $sdk $sdk)
[void](Assert-OrdinaryPath $licenseRoot $workspace)
[void](Assert-OrdinaryPath $reportPath $workspace)
$prepared = New-Object 'System.Collections.Generic.List[object]'
$seen = @{}
foreach ($spec in $specs) {
    if ($spec.Output -notmatch '\A[A-Za-z0-9_.-]+\z' -or $seen.ContainsKey($spec.Output)) { throw "Invalid or duplicate notice output: $($spec.Output)" }
    $seen[$spec.Output] = $true
    $source = Assert-OrdinaryPath (Join-Path $sdk $spec.Source) $sdk -File
    $destination = Assert-OrdinaryPath (Join-Path $licenseRoot $spec.Output) $licenseRoot
    [byte[]]$original = [IO.File]::ReadAllBytes($source)
    if ($original.Length -gt 2MB -or $original -contains 0) { throw "Notice input is unexpectedly large or binary: $($spec.Source)" }
    [byte[]]$selected = $original
    $start = 0
    if ($spec.Pattern) {
        # Latin-1 has a one-to-one byte mapping: extraction retains CRLF, spaces,
        # and original encoding bytes without reformatting or appending a newline.
        $matches = [regex]::Matches($byteEncoding.GetString($original), $spec.Pattern)
        if ($matches.Count -ne 1 -or $matches[0].Length -eq 0) { throw "Expected one reviewed notice block: $($spec.Source)" }
        $start = $matches[0].Index
        $selected = $byteEncoding.GetBytes($matches[0].Value)
        if ($byteEncoding.GetString($selected) -notmatch '(?i)copyright|license|public domain') { throw "Selected block lacks license markers: $($spec.Source)" }
    }
    $hash = Get-BytesHash $selected
    if (Test-Path -LiteralPath $destination) {
        [void](Assert-OrdinaryPath $destination $licenseRoot -File)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
            throw "Existing notice differs; review it before replacing: $destination"
        }
    }
    $record = [pscustomobject][ordered]@{
        Component=$spec.Component; Path=('licenses/' + $spec.Output); Terms=$spec.Terms
        Integration=$spec.Integration; Source=$spec.Source
        SourceSHA256=(Get-BytesHash $original); SourceByteOffset=$start
        Extraction=$(if ($spec.Pattern) { 'Exact comment block bytes' } else { 'Entire upstream notice file bytes' })
        Bytes=$selected.Length; SHA256=$hash
    }
    $prepared.Add([pscustomobject]@{ Record=$record; Bytes=$selected; Destination=$destination })
}

# Record current build evidence separately from distributed notice text.
$evidence = New-Object 'System.Collections.Generic.List[object]'
function Read-Evidence([string]$Relative) {
    $path = Assert-OrdinaryPath (Join-Path $sdk $Relative) $sdk -File
    $bytes = [IO.File]::ReadAllBytes($path)
    $evidence.Add([pscustomobject]@{ Source=$Relative; SHA256=(Get-BytesHash $bytes) })
    return $byteEncoding.GetString($bytes)
}
$config = Read-Evidence 'thirdparty/FFmpeg/config_windows_x86_64.h'
$ffmpegFlags = [ordered]@{}
foreach ($flag in @('CONFIG_GPL','CONFIG_NONFREE','CONFIG_VERSION3','CONFIG_GPLV3')) {
    $match = [regex]::Match($config, '(?m)^#define ' + $flag + ' ([01])\r?$')
    if (-not $match.Success) { throw "Cannot verify FFmpeg flag $flag" }
    $ffmpegFlags[$flag] = [int]$match.Groups[1].Value
    if ($ffmpegFlags[$flag] -ne 0) { throw "The curated notices need review for enabled FFmpeg flag $flag" }
}
foreach ($path in @('thirdparty/CMakeLists.txt','src/core/CMakeLists.txt','src/system/CMakeLists.txt','src/kernel/CMakeLists.txt','src/kernel/xboxkrnl/xboxkrnl_crypt.cpp','src/system/xex_module.cpp','src/audio/CMakeLists.txt','src/ui/CMakeLists.txt','src/graphics/CMakeLists.txt','thirdparty/dxc/README.md')) { [void](Read-Evidence $path) }
$links = New-Object 'System.Collections.Generic.List[object]'
$ninjaRelative = 'out/build/win-amd64/CMakeFiles/impl-Release.ninja'
if (Test-Path -LiteralPath (Join-Path $sdk $ninjaRelative)) {
    $ninja = Read-Evidence $ninjaRelative
    foreach ($target in @('rexruntime','rexgpu-xenos')) {
        $block = [regex]::Match($ninja, '(?ms)^build [^\r\n]*?/Release/' + [regex]::Escape($target) + '\.dll [^\r\n]*: CXX_SHARED_LIBRARY_LINKER_[^\r\n]*\r?\n(?:(?!^build ).)*')
        if (-not $block.Success) { throw "Release link evidence not found for $target" }
        $libs = [regex]::Match($block.Value, '(?m)^  LINK_LIBRARIES = ([^\r\n]*)').Groups[1].Value
        $names = @([regex]::Matches($libs, '(?:[^/\\ \x22]+)\.lib') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $links.Add([pscustomobject]@{ Target=$target; Libraries=$names })
    }
}
$buildFlags = [ordered]@{}
$cacheRelative = 'out/build/win-amd64/CMakeCache.txt'
if (Test-Path -LiteralPath (Join-Path $sdk $cacheRelative)) {
    $cache = Read-Evidence $cacheRelative
    foreach ($flag in @('REXGLUE_USE_D3D12','REXGLUE_USE_VULKAN','REXGLUE_ENABLE_FIDELITYFX','REXGLUE_ENABLE_TRACY')) {
        $match = [regex]::Match($cache, '(?m)^' + $flag + ':BOOL=(ON|OFF)\r?$')
        if (-not $match.Success) { throw "Cannot establish SDK build setting: $flag" }
        $buildFlags[$flag] = $match.Groups[1].Value
        $expected = if ($flag -eq 'REXGLUE_USE_D3D12') { 'ON' } else { 'OFF' }
        if ($buildFlags[$flag] -ne $expected) { throw "Notice allowlist needs review for $flag=$($buildFlags[$flag])" }
    }
}
$binaryEvidence = @(
    foreach ($name in @('rexruntime.dll','rexgpu-xenos.dll')) {
        $relative = 'out/win-amd64/Release/' + $name
        $path = Join-Path $sdk $relative
        if (Test-Path -LiteralPath $path) {
            [void](Assert-OrdinaryPath $path $sdk -File)
            [pscustomobject]@{ Source=$relative; Bytes=(Get-Item -LiteralPath $path).Length; SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
    }
)
$remaining = @(
    [ordered]@{ Component='FFmpeg and libmspack'; Item='Static-link LGPL obligations'; Detail='Prepare exact corresponding library source, local modifications and build instructions, plus a workable relink mechanism or another compliant distribution method. License text alone is insufficient. Validate against the final binaries.' },
    [ordered]@{ Component='DXC API headers'; Item='Full upstream license missing from vendored directory'; Detail='README identifies upstream revision 6b6f40200bea5ed99367513f53f6a28e52fd3d0e. Retrieve and verify its LICENSE.TXT; the two collected header notices are not replacements.' },
    [ordered]@{ Component='disruptorplus'; Item='Upstream license and revision not present in vendored header directory'; Detail='Runtime rexcore links this header-only queue. Establish exact provenance and preserve the applicable upstream license.' },
    [ordered]@{ Component='Crypto SHA256'; Item='Historical zlib terms'; Detail='The source says altered for Xenia and licensed under zlib when acquired, but supplies only a website reference. Preserve attribution and verify the exact historical full terms.' },
    [ordered]@{ Component='SDL3, FFmpeg and generated resources'; Item='Nested notices and source coverage'; Detail='Review additional embedded notices in selected source/header/resource inputs (including fonts and Windows HID helpers). This reviewed allowlist is not an exhaustive per-file scan or link map.' },
    [ordered]@{ Component='Microsoft redistributable DLLs'; Item='Redistribution evidence'; Detail='Record exact Visual C++ runtime versions and applicable redistribution terms for the final bundled DLLs. They are outside this SDK-source collector.' },
    [ordered]@{ Component='Skate 2 player'; Item='Game-derived distribution rights'; Detail='The newly authored project license is separate from third-party and game-derived code. This notice inventory grants no rights to the original game, assets, or generated game-derived code.' }
)
$records = @($prepared | ForEach-Object { $_.Record })
$index = [ordered]@{
    SchemaVersion=1; Scope='Available notices for the inspected Windows x64 D3D12 runtime dependency set'
    CompleteComplianceReview=$false; NoticeCount=$records.Count
    Acknowledgments=@('This software is based in part on the work of the Independent JPEG Group.', 'The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.')
    ModificationScope='The collector does not modify SDK sources. Review exact source changes and provenance with the final release source bundle.'
    Files=$records; RemainingReview=$remaining
}
$indexPath = Assert-OrdinaryPath (Join-Path $licenseRoot 'NOTICE-INDEX.json') $licenseRoot
$audit = [ordered]@{
    SchemaVersion=1; GeneratedUtc=[DateTime]::UtcNow.ToString('o'); Mode=$(if ($CheckOnly) {'CheckOnly'} else {'Collect'})
    CompleteComplianceReview=$false; NoticeCount=$records.Count; NoticeBytes=($records | Measure-Object Bytes -Sum).Sum
    CheckedOrdinaryPaths=$true; ExactBytesPreserved=$true; ExistingDifferentNoticeFilesOverwritten=$false
    FFmpegWindowsX64Flags=$ffmpegFlags; SdkBuildFlags=$buildFlags; ReleaseLinks=$links.ToArray()
    Evidence=$evidence.ToArray(); InspectedSdkBinaries=$binaryEvidence
    BinaryEvidenceLimit='Link instructions and current SDK output hashes are recorded; final player package closure and exact correspondence still require release validation.'
    Files=$records; RemainingReview=$remaining
}
if (-not $CheckOnly) {
    [void][IO.Directory]::CreateDirectory($licenseRoot)
    foreach ($entry in $prepared) {
        [void](Assert-OrdinaryPath $entry.Destination $licenseRoot)
        if (-not (Test-Path -LiteralPath $entry.Destination)) {
            $stream = [IO.File]::Open($entry.Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($entry.Bytes, 0, $entry.Bytes.Length) } finally { $stream.Dispose() }
        }
        if ((Get-FileHash -LiteralPath $entry.Destination -Algorithm SHA256).Hash -ne $entry.Record.SHA256) { throw 'Written notice failed SHA256 verification.' }
    }
    [IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 9) + "`n", $utf8)
    [void][IO.Directory]::CreateDirectory((Split-Path $reportPath -Parent))
    [IO.File]::WriteAllText($reportPath, ($audit | ConvertTo-Json -Depth 9) + "`n", $utf8)
}
[pscustomobject]@{ Mode=$audit.Mode; NoticeCount=$audit.NoticeCount; NoticeBytes=$audit.NoticeBytes; CompleteComplianceReview=$false; RemainingReviewCount=$remaining.Count }
