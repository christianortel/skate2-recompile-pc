[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$IncludeGameData,
    [switch]$SkipGameData,
    [string]$CrtDirectory,
    [switch]$CheckOnly
)

# Stages a fresh local development folder. It does not launch, install, upload,
# download, archive, or remove anything. Existing destinations are refused.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$packageRoot = Join-Path $workspace 'packages'
$buildRoot = Join-Path $workspace 'skate2\out\build\win-amd64-release'
$sdkRoot = Join-Path $workspace 'tools\rexglue-sdk-source'
$sdkBin = Join-Path $sdkRoot 'out\install\win-amd64\bin'
$readobj = Join-Path $workspace 'tools\llvm-20.1.8\bin\llvm-readobj.exe'
$gameRoot = Join-Path $workspace 'game'
$expectedGameHash = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'
$includeGame = [bool]$IncludeGameData -and -not [bool]$SkipGameData
if ($IncludeGameData -and $SkipGameData) { throw 'Choose either -IncludeGameData or -SkipGameData, not both.' }
if (-not $CrtDirectory) {
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
    $readobj = (Get-Command llvm-readobj -ErrorAction Stop).Source
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
    $name = 'Skate2-Development-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $Destination = Join-Path $packageRoot $name
} elseif (-not [IO.Path]::IsPathRooted($Destination)) {
    $Destination = Join-Path $workspace $Destination
}
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
$allowedPrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\', '/') + '\'
if (-not $Destination.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Choose a fresh destination below $packageRoot. Packages remain local to this workspace."
}
Assert-OrdinaryAncestors $Destination
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
    [pscustomobject]@{ source = Join-Path $PSScriptRoot 'Import-Skate2Data.ps1'; relative = 'scripts\Import-Skate2Data.ps1' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\INSTALL.md'; relative = 'docs\INSTALL.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\KNOWN_ISSUES.md'; relative = 'docs\KNOWN_ISSUES.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\DISPLAY.md'; relative = 'docs\DISPLAY.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\BUILD.md'; relative = 'docs\BUILD.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'docs\RELEASE_CHECKLIST.md'; relative = 'docs\RELEASE_CHECKLIST.md' },
    [pscustomobject]@{ source = Join-Path $workspace 'THIRD_PARTY_NOTICES.md'; relative = 'THIRD_PARTY_NOTICES.md' },
    [pscustomobject]@{ source = Join-Path $sdkRoot 'LICENSE'; relative = 'licenses\ReXGlue-LICENSE.txt' }
)
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
    status = 'development-unverified'
    gameDataIncluded = $includeGame
    nativeFiles = @($nativeFiles.Values)
    gameFileCount = $gameFiles.Count
    approximateBytes = $bytes
    operatingSystemImports = @($windowsImports.Keys | Sort-Object)
    importInspection = 'PE imports plus explicitly seeded runtime-loaded Xenos GPU plugin; gameplay not validated'
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
    $gameNote = if (-not $includeGame) { 'Game data is not included. Use Import Game Files.cmd with your own supported extracted game before launching.' } else { 'The game directory contains a local copy of the original user-provided game files. This folder is for local use only.' }
    @"
Skate 2 local development build

Status: development / unverified. This package is not evidence of playability.
Start with Launch Skate 2.cmd. Controller behavior, audio, graphics, career
progression, saves, stability, and operation without developer tools require
actual gameplay verification. Windows 10/11 x64 and a compatible Direct3D 12
GPU are expected; system and graphics-driver requirements remain unverified.

$gameNote

Saves and caches are created locally in userdata and cache. Original source
files and existing saves were not moved. Build tools, generated C++ source,
debug PDBs, and previous user data are not included.

This staging folder remains local. No files have been uploaded or published.
The file inventory and SHA-256 hashes are recorded in package-manifest.json;
the manifest itself is excluded from its own hash list.
"@ | Set-Content -LiteralPath (Join-Path $Destination 'DEVELOPMENT-STATUS.txt') -Encoding utf8

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
        status = 'development-unverified'
        packageScope = 'local-only'
        gameDataIncluded = $includeGame
        expectedGameExecutableSha256 = $expectedGameHash.ToLowerInvariant()
        validation = [ordered]@{ nativeImportClosureInspected = $true; x64ArchitectureChecked = $true; gameplayVerified = $false; controllerVerified = $false; saveVerified = $false; cleanMachineVerified = $false }
        runtimeSources = @($nativeFiles.Values | ForEach-Object { [pscustomobject]@{ name=$_.name; origin=$_.origin; bytes=$_.bytes } })
        nativeDependencies = @($dependencyGraph.ToArray())
        windowsProvidedImports = @($windowsImports.Keys | Sort-Object)
        dynamicDependencies = @('rexgpu-xenos.dll is explicitly staged', 'D3D12.dll and dxgi.dll are supplied by Windows', 'Optional shader debugging DLLs dxcompiler.dll and dxilconv.dll are not included')
        crtDeployment = 'Required DLLs copied from the installed Visual Studio x64 CRT Redist folder; Windows supplies UCRT/API sets.'
        excluded = @('generated C++ source','PDB debug symbols','development tools','existing saves and caches')
        files = $inventory
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Destination 'package-manifest.json') -Encoding utf8
    Write-Output ([pscustomobject]@{ Package = $Destination; Status = 'development-unverified'; Files = $inventory.Count; GameDataIncluded = $includeGame })
} catch {
    [ordered]@{ status = 'packaging-failed'; error = $_.Exception.Message; createdUtc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'package-failed.json') -Encoding utf8
    throw
}
