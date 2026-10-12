[CmdletBinding()]
param(
    # Always a fresh child of source-exports/. Existing folders are never replaced.
    [string]$Destination,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$exportRoot = Join-Path $workspace 'source-exports'

# This is the complete inclusion policy. Do not replace it with recursive copy,
# git ls-files, or a wildcard: this workspace also contains private game data.
$allowlist = @(
    '.gitignore', '.gitattributes', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    '.github/ISSUE_TEMPLATE/bug_report.yml', '.github/ISSUE_TEMPLATE/config.yml',
    'Import Game Files.cmd', 'Launch Skate 2.cmd', 'Launch Skate 2 - 60 FPS.cmd',
    'Launch Skate 2 - Unlocked FPS.cmd', 'Launch Skate 2 - 2x Quality.cmd', 'Launch Skate 2 - 4x Quality.cmd',
    'Launch Skate 2 - 1x Performance.cmd',
    'docs/INSTALL.md', 'docs/BUILD.md', 'docs/KNOWN_ISSUES.md', 'docs/HOW_IT_WORKS.md',
    'docs/DISPLAY.md', 'docs/RELEASE_CHECKLIST.md', 'docs/RELEASE_NOTES.md', 'docs/RUNTIME_REBUILD.md',
    'scripts/Export-Skate2Source.ps1', 'scripts/Bootstrap-Skate2Sdk.ps1',
    'scripts/Build-Skate2.ps1', 'scripts/Build-Skate2Launcher.ps1', 'scripts/Import-Skate2Data.ps1',
    'scripts/Launch-Skate2.ps1', 'scripts/Check-Skate2Runtime.ps1', 'scripts/Package-Skate2.ps1',
    'scripts/Capture-Skate2Load.ps1', 'scripts/analyze_frame_times.py',
    'scripts/tests/Test-FrameAnalysis.py', 'tools/Enter-BuildEnvironment.ps1',
    'scripts/tests/Test-BuildInvocation.ps1',
    'scripts/tests/Test-PlayerLaunchers.ps1',
    'launcher/.gitignore', 'launcher/CMakeLists.txt', 'launcher/src/main.cpp',
    'launcher/src/launcher.rc', 'launcher/tests/Test-NativeLauncher.ps1',
    'scripts/tests/Test-CvarInit.ps1', 'scripts/tests/cvar_init_main.cpp',
    'scripts/Collect-Skate2Notices.ps1',
    'scripts/Package-Skate2RuntimeSource.ps1', 'scripts/Rebuild-Skate2Runtime.ps1', 'scripts/Test-Skate2RuntimeABI.ps1',
    'skate2/CMakeLists.txt', 'skate2/CMakePresets.json', 'skate2/skate2_manifest.toml',
    'skate2/src/main.cpp', 'skate2/src/skate2_app.h',
    'skate2/src/crash_diagnostics.cpp', 'skate2/src/crash_diagnostics.h',
    'skate2/src/automatic_gpu_selection.cpp', 'skate2/src/automatic_gpu_selection.h',
    'skate2/src/frame_rate.cpp', 'skate2/src/frame_rate.h',
    'skate2/config/constructed-callbacks.toml', 'skate2/config/indirect-additional.toml',
    'skate2/config/indirect-lower.toml', 'skate2/config/indirect-runtime.toml',
    'skate2/config/indirect-upper.toml', 'skate2/config/reconciled-switch-methods.toml',
    'patches/rexglue-0.10.0-windows-build.patch',
    'patches/rexglue-0.10.0-float16-pack.patch',
    'patches/rexglue-0.10.0-input-diagnostics.patch',
    'patches/rexglue-0.10.0-input-synchronization.patch',
    'patches/rexglue-0.10.0-audio-output.patch',
    'patches/rexglue-0.10.0-cvar-toml-escaping.patch',
    'patches/rexglue-0.10.0-release-perf-counters.patch',
    'patches/rexglue-0.10.0-live-frame-capture.patch',
    'patches/rexglue-0.10.0-cvar-validator.patch',
    'patches/rexglue-0.10.0-vertex-buffer-coherency.patch',
    'patches/rexglue-0.10.0-present-idleclean-diagnostic.patch',
    'licenses/ReXGlue-LICENSE.txt', 'licenses/NOTICE-INDEX.json',
    'licenses/SDL3-LICENSE.txt', 'licenses/HIDAPI-license-options.txt',
    'licenses/HIDAPI-BSD-LICENSE.txt', 'licenses/HIDAPI-Windows-NOTICE.txt',
    'licenses/fmt-LICENSE.txt', 'licenses/spdlog-LICENSE.txt', 'licenses/xxHash-LICENSE.txt',
    'licenses/aes128-LICENSE.txt', 'licenses/o1heap-LICENSE.txt', 'licenses/SIMDe-COPYING.txt',
    'licenses/tomlplusplus-LICENSE.txt', 'licenses/CLI11-LICENSE.txt', 'licenses/UTF8CPP-LICENSE.txt',
    'licenses/ImGui-LICENSE.txt', 'licenses/ImGui-stb_rectpack-LICENSE.txt',
    'licenses/ImGui-stb_truetype-LICENSE.txt', 'licenses/ImGui-stb_textedit-LICENSE.txt',
    'licenses/stb_image-LICENSE.txt', 'licenses/RenderDoc-API-LICENSE.txt',
    'licenses/DXC-dxcapi-NOTICE.txt', 'licenses/DXC-DxbcConverter-NOTICE.txt',
    'licenses/DXC-LICENSE.txt', 'licenses/disruptorplus-LICENSE.txt',
    'licenses/libmspack-COPYING.LIB.txt', 'licenses/libmspack-LZX-NOTICE.txt',
    'licenses/FFmpeg-COPYING.LGPLv2.1.txt', 'licenses/FFmpeg-LICENSE.md',
    'licenses/FFmpeg-IJG-jfdctfst-NOTICE.txt', 'licenses/FFmpeg-IJG-jfdctint-NOTICE.txt',
    'licenses/FFmpeg-IJG-jrevdct-NOTICE.txt', 'licenses/Crypto-DES-LICENSE.txt',
    'licenses/TinySHA1-LICENSE.txt', 'licenses/Rijndael-NOTICE.txt',
    'licenses/SHA256-NOTICE.txt', 'licenses/DXBC-Checksum-NOTICE.txt',
    'licenses/SHA256-LICENSE.txt', 'licenses/PE-format-NOTICE.txt',
    'licenses/aes128-NOTICE.txt', 'licenses/FFmpeg-avsscanf-LICENSE.txt',
    'licenses/FFmpeg-Selected-Source-NOTICES.txt', 'licenses/ProggyFonts-LICENSE.txt',
    'licenses/SDL3-yuv2rgb-LICENSE.txt', 'licenses/SDL3-Selected-Source-NOTICES.txt',
    'licenses/SIMDe-Selected-Header-NOTICES.txt'
)
function Assert-OrdinaryPath([string]$Path) {
    for ($current = [IO.Path]::GetFullPath($Path); $current;) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Source export refuses linked paths: $current"
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}
Assert-OrdinaryPath $workspace
$problems = [Collections.Generic.List[string]]::new()
$snapshot = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    foreach ($relative in $allowlist) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or
            $relative -match '(^|/)(?:\.git|\.local|game|reports|generated|out|cache|userdata)(/|$)' -or
            $relative -match '\.(?:xex|iso|rar|zip|exe|dll|pdb|dmp|obj|png|jpg|mp3|bk2|dat)$') {
            throw "Forbidden allowlist entry: $relative"
        }
        $source = Join-Path $workspace $relative
        # An exported tree can export itself without downloading the SDK.
        if ($relative -eq 'licenses/ReXGlue-LICENSE.txt' -and -not (Test-Path -LiteralPath $source)) {
            $source = Join-Path $workspace 'tools/rexglue-sdk-source/LICENSE'
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $problems.Add("Required source file is missing: $relative")
            continue
        }
        Assert-OrdinaryPath $source
        $item = Get-Item -LiteralPath $source -Force
        if ($item.Length -gt 2MB) { $problems.Add("Unexpectedly large source file: $relative"); continue }
        $bytes = [IO.File]::ReadAllBytes($source)
        try { $content = $utf8.GetString($bytes) } catch { $problems.Add("Not UTF-8 source text: $relative"); continue }
        if ($content.IndexOf([char]0) -ge 0) { $problems.Add("Binary content detected: $relative"); continue }
        # Stop rather than silently redact build inputs. These are bounded
        # signatures, not a guarantee that arbitrary secrets cannot exist.
        $checks = [ordered]@{
            AbsoluteMachinePath = '(?i)(?<![\w\\])[a-z]:[\\/][^\s"''<>]+|/(?:Users|home)/[^\s"''<>]+'
            PrivateKey = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
            GitHubToken = '(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'
            AwsAccessKey = '(?:AKIA|ASIA)[A-Z0-9]{16}'
            SlackToken = 'xox[baprs]-[A-Za-z0-9-]{20,}'
            BearerSecret = '(?i)Bearer\s+[A-Za-z0-9_.-]{32,}'
            GeneratedPpc = '(?m)^\s*(?:PPC_FUNC_IMPL\(|PPC_FUNC\(sub_|__attribute__\(\(alias\("__imp__sub_)'
        }
        foreach ($check in $checks.GetEnumerator()) {
            if ([regex]::IsMatch($content, $check.Value)) { $problems.Add("$($check.Key) detected in $relative") }
        }
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        $snapshot.Add([pscustomobject]@{ Path = $relative; Bytes = $bytes; Length = $bytes.Length; SHA256 = $hash })
    }
} finally { $sha.Dispose() }
if ($problems.Count) { throw ("Source export preflight failed. No staging performed:`n" + ($problems -join "`n")) }
$manifest = [ordered]@{
    SchemaVersion = 1
    Kind = 'source-only-local-export'
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    Status = 'review-before-publication; clean-machine-build-unverified'
    IncludesGameData = $false
    IncludesGeneratedGameCode = $false
    IncludesRuntimeBinaries = $false
    GitInitialized = $false
    Published = $false
    Scan = 'Explicit path allowlist; ordinary-file/ancestor checks; UTF-8/no-NUL; bounded path, credential and generated-PPC signatures. Not an exhaustive secret or license audit.'
    Files = @($snapshot | ForEach-Object { [ordered]@{ Path=$_.Path; Bytes=$_.Length; SHA256=$_.SHA256 } })
}
if ($CheckOnly) { return [pscustomobject]$manifest }
if (-not $Destination) { $Destination = Join-Path $exportRoot ('Skate2-Source-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 6)) }
elseif (-not [IO.Path]::IsPathRooted($Destination)) { $Destination = Join-Path $workspace $Destination }
$Destination = [IO.Path]::GetFullPath($Destination)
if (-not $Destination.StartsWith(([IO.Path]::GetFullPath($exportRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination must be a fresh child of source-exports/.' }
Assert-OrdinaryPath $Destination
if (Test-Path -LiteralPath $Destination) { throw 'Export destination already exists. Choose a new folder; nothing was removed.' }
[IO.Directory]::CreateDirectory($Destination) | Out-Null
foreach ($file in $snapshot) {
    $target = Join-Path $Destination $file.Path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($file.Bytes, 0, $file.Bytes.Length) } finally { $stream.Dispose() }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Staged hash mismatch: $($file.Path)" }
}
[IO.File]::WriteAllText((Join-Path $Destination 'SOURCE-EXPORT-MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Destination=$Destination; SourceFiles=$snapshot.Count; FileBytes=($snapshot | Measure-Object Length -Sum).Sum; Published=$false; GitInitialized=$false }
