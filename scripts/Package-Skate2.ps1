[CmdletBinding()]
param(
    [string]$Destination,
    [string]$BuildDirectory,
    [switch]$IncludeGameData,
    [switch]$SkipGameData,
    [string]$CrtDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')][string]$ReleaseVersion,
    [switch]$CheckOnly
)

# Stages a fresh player folder. It does not launch, install, upload,
# download, archive, or remove anything. Existing destinations are refused.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$packageRoot = Join-Path $workspace 'packages'
$buildRoot = Join-Path $workspace 'skate2\out\build\win-amd64-release'
if ($BuildDirectory) {
    $buildRoot = if ([IO.Path]::IsPathRooted($BuildDirectory)) { $BuildDirectory } else { Join-Path $workspace $BuildDirectory }
    $buildRoot = [IO.Path]::GetFullPath($buildRoot)
}
$sdkRoot = Join-Path $workspace 'tools\rexglue-sdk-source'
$sdkBin = Join-Path $sdkRoot 'out\install\win-amd64\bin'
$readobj = Join-Path $workspace 'tools\llvm-20.1.8\bin\llvm-readobj.exe'
$gameRoot = Join-Path $workspace 'game'
$expectedGameHash = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'
$includeGame = [bool]$IncludeGameData -and -not [bool]$SkipGameData
if ($IncludeGameData -and $SkipGameData) { throw 'Choose either -IncludeGameData or -SkipGameData, not both.' }
if ($ReleaseVersion -and $IncludeGameData) { throw 'Release packages cannot contain original game files.' }
$packageStatus = if ($ReleaseVersion) { 'release-staged' } else { 'development-staged' }
if (-not $CrtDirectory -and -not $ReleaseVersion) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vsPath = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsPath) {
            $CrtDirectory = Get-ChildItem -Path (Join-Path $vsPath 'VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT') -Directory |
                Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
    }
}
$crtRoot = $CrtDirectory
if (-not (Test-Path -LiteralPath $readobj)) {
    $readobj = (Get-Command llvm-readobj -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Assert-RegularFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected an ordinary file: $Path"
    }
    return $item
}

function Assert-OrdinaryAncestors([string]$Path) {
    for ($current = $Path; $current; $current = Split-Path -Parent $current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse-point paths are not accepted for packaging: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
    }
}

if (-not $Destination) {
    $prefix = if ($ReleaseVersion) { "Skate2-PC-v$ReleaseVersion-Windows-x64" } else { 'Skate2-Development' }
    $name = '{0}-{1}-{2}' -f $prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $Destination = Join-Path $packageRoot $name
} elseif (-not [IO.Path]::IsPathRooted($Destination)) {
    $Destination = Join-Path $workspace $Destination
}
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
$allowedPrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\', '/') + '\'
if (-not $Destination.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Choose a fresh destination below $packageRoot."
}
Assert-OrdinaryAncestors $Destination
Assert-OrdinaryAncestors $buildRoot
if (Test-Path -LiteralPath $Destination) { throw "Destination already exists; choose a fresh folder: $Destination" }
[void](Assert-RegularFile $readobj)

# Windows owns these DLLs. API-set contracts are also supplied by Windows.
# Resolve other imports only from the native build, SDK install, or official
# local VC redist directory; never silently copy files from System32 or PATH.
$windowsDlls = @{}
@('advapi32.dll','avrt.dll','bcrypt.dll','cfgmgr32.dll','combase.dll','comctl32.dll',
  'comdlg32.dll','crypt32.dll','d3d12.dll','d3dcompiler_47.dll','dbghelp.dll','dinput8.dll',
  'dwmapi.dll','dxgi.dll','gdi32.dll','hid.dll','imm32.dll','iphlpapi.dll','kernel32.dll',
  'msacm32.dll','msimg32.dll','netapi32.dll','normaliz.dll','ntdll.dll','ole32.dll',
  'oleaut32.dll','powrprof.dll','propsys.dll','psapi.dll','rpcrt4.dll','secur32.dll',
  'setupapi.dll','shell32.dll','shlwapi.dll','ucrtbase.dll','user32.dll','userenv.dll',
  'usp10.dll','uxtheme.dll','version.dll','winhttp.dll','wininet.dll','winmm.dll',
  'winspool.drv','wintrust.dll','wldap32.dll','ws2_32.dll','wtsapi32.dll','xinput1_4.dll') |
    ForEach-Object { $windowsDlls[$_] = $true }

$nativeFiles = [ordered]@{}
$pending = New-Object 'System.Collections.Generic.Queue[string]'
$windowsImports = @{}
$externalRuntimeImports = @{}
$dependencyGraph = New-Object 'System.Collections.Generic.List[object]'

function Add-NativeFile([string]$Path, [string]$Origin) {
    $item = Assert-RegularFile $Path
    $key = $item.Name.ToLowerInvariant()
    if ($nativeFiles.Contains($key)) {
        if ($nativeFiles[$key].source -ne $item.FullName) {
            throw "Conflicting source files for $($item.Name). Rebuild and restage a consistent native build."
        }
        return
    }
    $nativeFiles[$key] = [pscustomobject]@{ source = $item.FullName; name = $item.Name; origin = $Origin; bytes = $item.Length }
    $pending.Enqueue($key)
}

function Resolve-NativeDependency([string]$Name) {
    if ($Name -match '^(?i:msvcp|vcruntime|concrt|vccorlib)[0-9].*\.dll$') {
        if (-not $crtRoot) { throw 'Supply -CrtDirectory pointing to the official x64 Microsoft.VC143.CRT redist directory.' }
        $path = Join-Path $crtRoot $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required Visual C++ runtime $Name is missing from the official local redist folder $crtRoot"
        }
        return [pscustomobject]@{ path = $path; origin = 'Visual Studio x64 CRT redist' }
    }
    foreach ($dir in @($buildRoot, $sdkBin)) {
        $path = Join-Path $dir $Name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [pscustomobject]@{ path = $path; origin = 'Native build or installed SDK' }
        }
    }
    throw "Unresolved native dependency $Name. Finish the build or provide its known local runtime dependency before packaging."
}

Add-NativeFile (Join-Path $buildRoot 'skate2.exe') 'Native Release build'
# Runtime-loaded GPU plugins are absent from the executable import table.
foreach ($name in @('rexruntime.dll', 'rexgpu-xenos.dll')) {
    $builtPath = Join-Path $buildRoot $name
    $installedPath = Join-Path $sdkBin $name
    if ((Test-Path -LiteralPath $builtPath) -and (Test-Path -LiteralPath $installedPath)) {
        if ((Get-FileHash -LiteralPath $builtPath -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash) {
            throw "$name beside the executable differs from the installed SDK. Rebuild the game before packaging."
        }
    }
    $resolved = Resolve-NativeDependency $name
    Add-NativeFile $resolved.path $resolved.origin
}

while ($pending.Count -gt 0) {
    $key = $pending.Dequeue()
    $binary = $nativeFiles[$key]
    $inspection = & $readobj --file-header --coff-imports $binary.source
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect native imports: $($binary.source)" }
    if (-not ($inspection -match 'Format: COFF-x86-64')) { throw "Not a Windows x64 binary: $($binary.source)" }
    $imports = @($inspection | ForEach-Object {
        if ($_ -match '^\s+Name:\s+([^\s]+\.(?:dll|drv))\s*$') { $Matches[1] }
    } | Sort-Object -Unique)
    $dependencyGraph.Add([pscustomobject]@{ binary = $binary.name; imports = $imports })
    foreach ($import in $imports) {
        $dependencyKey = $import.ToLowerInvariant()
        if ($windowsDlls.ContainsKey($dependencyKey) -or $dependencyKey -match '^(api-ms-win-|ext-ms-win-)') {
            $windowsImports[$dependencyKey] = $true
        } elseif ($ReleaseVersion -and $dependencyKey -match '^(msvcp|vcruntime|concrt|vccorlib)[0-9].*\.dll$') {
            if ($dependencyKey -notin @('msvcp140.dll', 'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
                throw "Unrecognized Visual C++ prerequisite $import. Update and validate the launcher prerequisite check before releasing this build."
            }
            $externalRuntimeImports[$dependencyKey] = $true
        } elseif (-not $nativeFiles.Contains($dependencyKey)) {
            $resolved = Resolve-NativeDependency $import
            Add-NativeFile $resolved.path $resolved.origin
        }
    }
}

$supportFiles = @(
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2.cmd'; relative = 'Launch Skate 2.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2 - Unlocked FPS.cmd'; relative = 'Launch Skate 2 - Unlocked FPS.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2 - 60 FPS.cmd'; relative = 'Launch Skate 2 - 60 FPS.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Import Game Files.cmd'; relative = 'Import Game Files.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2 - 2x Quality.cmd'; relative = 'Launch Skate 2 - 2x Quality.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2 - 1x Performance.cmd'; relative = 'Launch Skate 2 - 1x Performance.cmd' },
    [pscustomobject]@{ source = Join-Path $workspace 'Launch Skate 2 - 4x Quality.cmd'; relative = 'Launch Skate 2 - 4x Quality.cmd' },
    [pscustomobject]@{ source = Join-Path $PSScriptRoot 'Launch-Skate2.ps1'; relative = 'scripts\Launch-Skate2.ps1' },
    [pscustomobject]@{ source = Join-Path $PSScriptRoot 'Check-Skate2Runtime.ps1'; relative = 'scripts\Check-Skate2Runtime.ps1' },
    [pscustomobject]@{ source = Join-Path $PSScriptRoot 'Import-Skate2Data.ps1'; relative = 'scripts\Import-Skate2Data.ps1' },
    [pscustomobject]@{ source = Join-Path $workspace 'README.md'; relative = 'README.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\INSTALL.md'; relative = 'docs\INSTALL.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\KNOWN_ISSUES.md'; relative = 'docs\KNOWN_ISSUES.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\DISPLAY.md'; relative = 'docs\DISPLAY.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\BUILD.md'; relative = 'docs\BUILD.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\HOW_IT_WORKS.md'; relative = 'docs\HOW_IT_WORKS.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\RELEASE_CHECKLIST.md'; relative = 'docs\RELEASE_CHECKLIST.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\RELEASE_NOTES.md'; relative = 'docs\RELEASE_NOTES.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\RUNTIME_REBUILD.md'; relative = 'docs\RUNTIME_REBUILD.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'THIRD_PARTY_NOTICES.md'; relative = 'THIRD_PARTY_NOTICES.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'LICENSE'; relative = 'LICENSE' }
)
$noticeIndexPath = Join-Path $workspace 'licenses/NOTICE-INDEX.json'
Assert-OrdinaryAncestors $noticeIndexPath
[void](Assert-RegularFile $noticeIndexPath)
$noticeIndex = Get-Content -LiteralPath $noticeIndexPath -Raw | ConvertFrom-Json
if ($noticeIndex.SchemaVersion -ne 1 -or -not $noticeIndex.Files.Count -or
    $noticeIndex.NoticeCount -ne $noticeIndex.Files.Count) { throw 'Invalid notice inventory. Run Collect-Skate2Notices.ps1 and review its output.' }
$noticePaths = @{}
foreach ($notice in $noticeIndex.Files) {
    if ($notice.Path -notmatch '^licenses/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.(txt|md)$' -or
        $noticePaths.ContainsKey($notice.Path)) { throw 'Invalid or duplicate path in notice inventory.' }
    $noticePaths[$notice.Path] = $true
    $noticeSource = Join-Path $workspace $notice.Path
    Assert-OrdinaryAncestors $noticeSource
    $noticeFile = Assert-RegularFile $noticeSource
    if ($noticeFile.Length -gt 2MB -or $noticeFile.Length -ne $notice.Bytes -or
        (Get-FileHash -LiteralPath $noticeSource -Algorithm SHA256).Hash -ne $notice.SHA256) { throw "Notice differs from reviewed inventory: $($notice.Path)" }
    $supportFiles += [pscustomobject]@{ source=$noticeSource; relative=$notice.Path }
}
$supportFiles += [pscustomobject]@{ source=$noticeIndexPath; relative='licenses/NOTICE-INDEX.json' }
foreach ($file in $supportFiles) { [void](Assert-RegularFile $file.source) }
$gameFiles = @()
if ($includeGame) {
    Assert-OrdinaryAncestors $gameRoot
    [void](Assert-RegularFile (Join-Path $gameRoot 'default.xex'))
    if ((Get-FileHash -LiteralPath (Join-Path $gameRoot 'default.xex') -Algorithm SHA256).Hash -ne $expectedGameHash) {
        throw 'Original game executable does not match the audited build revision.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'data') -PathType Container)) {
        throw 'Original game data directory is missing.'
    }
    $gameItems = @(Get-ChildItem -LiteralPath $gameRoot -Recurse -Force)
    if ($gameItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
        throw 'Game source contains reparse points; resolve them before packaging.'
    }
    $gameFiles = @($gameItems | Where-Object { -not $_.PSIsContainer })
}

$bytes = ($nativeFiles.Values | Measure-Object -Property bytes -Sum).Sum
if ($gameFiles.Count) { $bytes += ($gameFiles | Measure-Object -Property Length -Sum).Sum }
$plan = [pscustomobject]@{
    destination = $Destination
    status = $packageStatus
    version = $ReleaseVersion
    gameDataIncluded = $includeGame
    nativeFiles = @($nativeFiles.Values)
    gameFileCount = $gameFiles.Count
    approximateBytes = $bytes
    operatingSystemImports = @($windowsImports.Keys | Sort-Object)
    separatelyInstalledRuntimeImports = @($externalRuntimeImports.Keys | Sort-Object)
    importInspection = 'PE imports plus explicitly seeded runtime-loaded Xenos GPU plugin'
}
if ($CheckOnly) { return $plan }

New-Item -ItemType Directory -Path $Destination | Out-Null
try {
    foreach ($file in $nativeFiles.Values) {
        $sourceHash = (Get-FileHash -LiteralPath $file.source -Algorithm SHA256).Hash
        $target = Join-Path $Destination $file.name
        Copy-Item -LiteralPath $file.source -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $sourceHash) {
            throw "Source changed while packaging: $($file.source)"
        }
    }
    foreach ($file in $supportFiles) {
        $target = Join-Path $Destination $file.relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.source -Destination $target
    }
    if ($includeGame) { New-Item -ItemType Directory -Path (Join-Path $Destination 'game') | Out-Null }
    foreach ($file in $gameFiles) {
        $relative = $file.FullName.Substring($gameRoot.Length).TrimStart('\', '/')
        $target = Join-Path (Join-Path $Destination 'game') $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
    $gameNote = if (-not $includeGame) { 'Game files are not included. Run Import Game Files.cmd and select your own extracted folder containing default.xex and data.' } else { 'Game files are already included in this local test folder. Do not distribute it.' }
    $packageHeading = if ($ReleaseVersion) { "Skate 2 PC v$ReleaseVersion - Windows x64" } else { 'Skate 2 PC - local preview' }
    $packageIntro = if ($ReleaseVersion) { 'Ready to run after importing your supported Xbox 360 game files. No build tools are required.' } else { 'This package is for local testing. It is not a public release.' }
    @"
$packageHeading

$packageIntro

1. Keep all package files together in a writable folder.
2. $gameNote
3. Connect your controller, then run Launch Skate 2.cmd.

If the launcher asks for the Microsoft Visual C++ x64 Runtime, open
Install Visual C++ Runtime.url, run Microsoft's installer, then launch again.

The default profile uses 2x rendering and unlimited FPS. For lower GPU load,
use Launch Skate 2 - 1x Performance.cmd. USB DualSense can connect directly;
close DS4Windows when using direct input. Press F4 for PC settings.

Read docs/INSTALL.md for requirements, the supported game revision, controls,
audio, saves, and troubleshooting. See docs/KNOWN_ISSUES.md for limitations.
Keep the userdata folder when updating; it contains your saves.

If you encounter a bug, open Report a Bug.url or visit:
https://github.com/christianortel/skate2-recompile-pc/issues/new/choose

Package contents and hashes are listed in package-manifest.json.
"@ | Set-Content -LiteralPath (Join-Path $Destination 'START-HERE.txt') -Encoding utf8
    "[InternetShortcut]`r`nURL=https://github.com/christianortel/skate2-recompile-pc/issues/new/choose`r`n" |
        Set-Content -LiteralPath (Join-Path $Destination 'Report a Bug.url') -Encoding ascii
    "[InternetShortcut]`r`nURL=https://aka.ms/vc14/vc_redist.x64.exe`r`n" |
        Set-Content -LiteralPath (Join-Path $Destination 'Install Visual C++ Runtime.url') -Encoding ascii

    $inventory = @(Get-ChildItem -LiteralPath $Destination -Recurse -File | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($Destination.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{
        schemaVersion = 1
        createdUtc = [DateTime]::UtcNow.ToString('o')
        status = $packageStatus
        version = $ReleaseVersion
        packageScope = $(if ($ReleaseVersion) { 'player-package' } else { 'local-only' })
        gameDataIncluded = $includeGame
        expectedGameExecutableSha256 = $expectedGameHash.ToLowerInvariant()
        validation = [ordered]@{ nativeImportClosureInspected = $true; x64ArchitectureChecked = $true; scope = 'Packaging checks; gameplay coverage and compatibility limits are documented in docs/RELEASE_NOTES.md and docs/KNOWN_ISSUES.md.' }
        runtimeSources = @($nativeFiles.Values | ForEach-Object { [pscustomobject]@{ name=$_.name; origin=$_.origin; bytes=$_.bytes } })
        nativeDependencies = @($dependencyGraph.ToArray())
        windowsProvidedImports = @($windowsImports.Keys | Sort-Object)
        dynamicDependencies = @('rexgpu-xenos.dll is explicitly staged', 'D3D12.dll and dxgi.dll are supplied by Windows', 'Optional shader debugging DLLs dxcompiler.dll and dxilconv.dll are not included')
        crtDeployment = $(if ($ReleaseVersion) { 'Microsoft Visual C++ x64 v14 runtime 14.44.35211.0 or later is a separately installed prerequisite. No Microsoft CRT DLLs are distributed in this release.' } else { 'Required DLLs copied from the installed Visual Studio x64 CRT Redist folder for local testing; Windows supplies UCRT/API sets.' })
        separatelyInstalledRuntimeImports = @($externalRuntimeImports.Keys | Sort-Object)
        excluded = @('generated C++ source','PDB debug symbols','development tools','existing saves and caches')
        files = $inventory
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Destination 'package-manifest.json') -Encoding utf8
    Write-Output ([pscustomobject]@{ Package = $Destination; Status = $packageStatus; Version = $ReleaseVersion; Files = $inventory.Count; GameDataIncluded = $includeGame })
} catch {
    [ordered]@{ status = 'packaging-failed'; error = $_.Exception.Message; createdUtc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'package-failed.json') -Encoding utf8
    throw
}
