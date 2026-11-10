[CmdletBinding()]
param(
    # Folder to create. Default: steam-deck in the repository root.
    [string]$OutputDirectory,
    # Native Release build that provides skate2.exe and its DLLs.
    [string]$BuildDirectory,
    # Folder with the x64 Microsoft Visual C++ runtime DLLs. Default: the
    # newest Visual Studio 2022 x64 CRT redist folder, else the Windows
    # system folder, whichever first meets the launcher's minimum version.
    [string]$CrtDirectory,
    # Leave out the game files (about 6.75 GB).
    [switch]$NoGameData,
    # Also copy the saves from skate2\userdata. The source is only read.
    [switch]$IncludeSaves,
    # Compare the SHA-256 of every copied game file, not only the sizes and
    # default.xex.
    [switch]$VerifyAllHashes,
    # Replace an existing output folder, but only one this script created.
    [switch]$Force,
    # Check the inputs and show what would be created, without writing.
    [switch]$CheckOnly
)

# Builds a self-contained folder for running Skate 2 PC on a Steam Deck under
# Proton, as a non-Steam game that starts skate2.exe directly (the PowerShell
# launcher cannot run there). The folder holds the current Release build, the
# Microsoft C++ runtime DLLs, the third-party notices, the Steam Deck settings
# in skate2.toml, instructions, and by default a copy of your own game folder.
# It never launches, uploads or changes its sources.
#
# The folder is built in a temporary sibling and renamed into place at the
# end, so a failed run leaves no half-written output. An existing output is
# never replaced unless -Force is given and the folder carries the marker
# file that this script writes.
#
# Relative paths are resolved from the repository root, like the other
# packaging scripts.
$ErrorActionPreference = 'Stop'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$culture = [Globalization.CultureInfo]::InvariantCulture
$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\', '/')
$markerName = '.skate2-steam-deck-build'
$markerTool = 'Build-Skate2SteamDeck.ps1'
$expectedGameHash = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'
$gameRoot = Join-Path $workspace 'game'
# A source checkout keeps its saves here (docs/INSTALL.md, Saves and updates).
$saveRoot = Join-Path $workspace 'skate2\userdata'
$buildRoot = Join-Path $workspace 'skate2\out\build\win-amd64-release'
$packageScript = Join-Path $PSScriptRoot 'Package-Skate2.ps1'

# Steam Deck profile, written in the format of rex::cvar::SaveConfig: one
# flat "name = value" line per setting, strings quoted. The first five match
# the "Steam Deck" preset of the in-game settings panel
# (skate2/src/settings_panel.cpp, three keys for its scale and render path);
# the last two are the synchronization settings of the earlier hand-made
# Deck folder. Values saved later from F1 or F4 replace this file.
$deckSettings = [ordered]@{
    skate2_frame_rate = '"60"'
    draw_resolution_scale_x = '1'
    draw_resolution_scale_y = '1'
    render_target_path_d3d12 = '"rtv"'
    d3d12_submit_draw_interval = '1024'
    d3d12_async_submission = 'true'
    d3d12_present_idleclean_sync = 'true'
    async_shader_compilation = 'true'
}

function Test-ReparsePoint($Item) {
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Resolve-RepoPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $workspace $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SameOrInside([string]$Path, [string]$Root) {
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    return ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Assert-OrdinaryAncestors([string]$Path) {
    for ($current = $Path; $current; $current = Split-Path -Parent $current) {
        if ((Test-Path -LiteralPath $current) -and (Test-ReparsePoint (Get-Item -LiteralPath $current -Force))) {
            throw "Links and other reparse points are not accepted in this path: $current"
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
    }
}

function Assert-RegularFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or (Test-ReparsePoint $item)) { throw "Expected an ordinary file: $Path" }
    return $item
}

# All files below a source folder. Links are refused rather than followed.
function Get-OrdinaryTree([string]$Root, [string]$Label) {
    Assert-OrdinaryAncestors $Root
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    $linked = @($items | Where-Object { Test-ReparsePoint $_ })
    if ($linked.Count) { throw "$Label contains links or other reparse points, for example $($linked[0].FullName). Resolve them first." }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    foreach ($file in $files) {
        if (-not $file.FullName.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected path below ${Root}: $($file.FullName)"
        }
    }
    return $files
}

function Get-FileVersion([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

# The file name as stored on disk; import tables use their own spelling.
function Get-DiskName([string]$Path) {
    $name = [IO.Path]::GetFileName($Path)
    foreach ($candidate in [IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($Path), $name)) {
        $candidateName = [IO.Path]::GetFileName($candidate)
        if ($candidateName -ieq $name) { return $candidateName }
    }
    return $name
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1e9) { return [string]::Format($culture, '{0:0.00} GB', $Bytes / 1e9) }
    if ($Bytes -ge 1e6) { return [string]::Format($culture, '{0:0.0} MB', $Bytes / 1e6) }
    return [string]::Format($culture, '{0:0} KB', [math]::Ceiling($Bytes / 1e3))
}

function Read-BuildMarker([string]$Folder) {
    $path = Join-Path $Folder $markerName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $path -Force
    if ((Test-ReparsePoint $item) -or $item.Length -gt 1MB) { return $null }
    try { $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
    if (-not $data -or $data.tool -ne $markerTool -or $data.schemaVersion -ne 1) { return $null }
    return $data
}

# Deletes a folder that this script created. The whole tree is checked first
# and any link or other reparse point stops the removal, so it never
# follows a junction. Each folder is removed non-recursively, deepest first.
function Remove-OwnedTree([string]$Path) {
    $top = Get-Item -LiteralPath $Path -Force
    if (-not $top.PSIsContainer -or (Test-ReparsePoint $top)) { throw "Refusing to remove: $Path" }
    $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    if (@($entries | Where-Object { Test-ReparsePoint $_ }).Count) {
        throw "Refusing to remove a folder that contains links or other reparse points: $Path"
    }
    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer })) {
        $directoryAttributes = [IO.File]::GetAttributes([IO.Path]::GetDirectoryName($file.FullName))
        $attributes = [IO.File]::GetAttributes($file.FullName)
        if (($attributes -bor $directoryAttributes) -band [IO.FileAttributes]::ReparsePoint) {
            throw "A link appeared while removing $Path; stopped at $($file.FullName)"
        }
        if ($attributes -band [IO.FileAttributes]::ReadOnly) {
            [IO.File]::SetAttributes($file.FullName, $attributes -band (-bnot [IO.FileAttributes]::ReadOnly))
        }
        [IO.File]::Delete($file.FullName)
    }
    foreach ($directory in @($entries | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) {
        [IO.Directory]::Delete($directory.FullName, $false)
    }
    [IO.Directory]::Delete($top.FullName, $false)
}

# An existing output may be replaced only with -Force, only when this script
# wrote it, and never when its userdata holds saves this script did not copy.
function Assert-ReplaceableOutput([string]$Folder) {
    $item = Get-Item -LiteralPath $Folder -Force
    if (-not $item.PSIsContainer -or (Test-ReparsePoint $item)) {
        throw "Refusing to replace ${Folder}: it is not an ordinary folder. Nothing was changed."
    }
    $marker = Read-BuildMarker $Folder
    if (-not $marker) {
        throw ("Refusing to replace ${Folder}: it has no valid $markerName marker, so this script did not " +
            "create it. Nothing was changed. Choose another -OutputDirectory.")
    }
    $entries = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force)
    if (@($entries | Where-Object { Test-ReparsePoint $_ }).Count) {
        throw "Refusing to replace ${Folder}: it contains links or other reparse points. Nothing was changed."
    }
    $written = @{}
    foreach ($record in @($marker.files)) { $written[([string]$record.path).ToLowerInvariant()] = $record }
    $userdata = Join-Path $Folder 'userdata'
    $unknown = @()
    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer -and (Test-SameOrInside $_.FullName $userdata) })) {
        $relative = $file.FullName.Substring($Folder.Length + 1).Replace('\', '/')
        $record = $written[$relative.ToLowerInvariant()]
        if (-not $record -or -not $record.sha256 -or [int64]$record.bytes -ne $file.Length -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $record.sha256) {
            $unknown += $relative
        }
    }
    if ($unknown.Count) {
        throw ("Refusing to replace ${Folder}: its userdata folder holds $($unknown.Count) save file(s) that this " +
            "script did not write, for example $($unknown[0]). Copy them somewhere safe and remove them " +
            "first. Nothing was changed.")
    }
    return $marker
}

# ---- Output location ---------------------------------------------------------

if ($BuildDirectory) { $buildRoot = Resolve-RepoPath $BuildDirectory }
if (-not $OutputDirectory) { $OutputDirectory = 'steam-deck' }
$output = Resolve-RepoPath $OutputDirectory
$pathRoot = [IO.Path]::GetPathRoot($output)
if (-not $pathRoot -or $output.Length -le $pathRoot.TrimEnd('\', '/').Length) {
    throw "Choose a folder, not a drive root, for -OutputDirectory: $output"
}
$parent = [IO.Path]::GetDirectoryName($output)
$leaf = [IO.Path]::GetFileName($output)
$sources = @($gameRoot, $buildRoot, $saveRoot, (Join-Path $workspace 'skate2'), (Join-Path $workspace 'licenses'),
    (Join-Path $workspace 'scripts'), (Join-Path $workspace 'tools'), (Join-Path $workspace '.git'))
foreach ($protected in @($workspace) + $sources) {
    if (Test-SameOrInside $protected $output) { throw "The output folder must not be or contain ${protected}: $output" }
}
foreach ($source in $sources) {
    if (Test-SameOrInside $output $source) { throw "The output folder must not be inside ${source}: $output" }
}
Assert-OrdinaryAncestors $output
if ((Test-Path -LiteralPath $parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "The parent of the output folder is not a folder: $parent"
}

$replace = $false
$previousMarker = $null
if (Test-Path -LiteralPath $output) {
    if (-not $Force) {
        throw ("The output folder already exists: $output. Nothing was changed. Use -Force to replace a " +
            "folder this script created, or choose another -OutputDirectory.")
    }
    $previousMarker = Assert-ReplaceableOutput $output
    $replace = $true
}
if (Test-Path -LiteralPath $parent -PathType Container) {
    $leftoverPattern = '^\.' + [regex]::Escape($leaf) + '\.(partial|replaced)-'
    foreach ($leftover in @(Get-ChildItem -LiteralPath $parent -Directory -Force | Where-Object { $_.Name -match $leftoverPattern })) {
        Write-Warning "An earlier run left $($leftover.FullName). It is not used; delete it when it is no longer needed."
    }
}

foreach ($process in @(Get-Process -Name skate2 -ErrorAction SilentlyContinue)) {
    $processPath = $null
    try { $processPath = $process.Path } catch { }
    if ($processPath -and (Test-SameOrInside $processPath $output)) {
        throw "skate2.exe is running from $output (process $($process.Id)). Close it first. Nothing was changed."
    }
    if ($IncludeSaves) {
        throw "Close Skate 2 (process $($process.Id)) before copying saves, so they are complete. Nothing was changed."
    }
}

# ---- Inputs ------------------------------------------------------------------

$entries = New-Object 'System.Collections.Generic.List[object]'
function Add-Entry([string]$Kind, [string]$Source, [string]$Relative, [int64]$Bytes, [string]$Sha256) {
    $entries.Add([pscustomobject]@{ Kind = $Kind; Source = $Source; Relative = $Relative; Bytes = $Bytes; Sha256 = $Sha256 })
}

Write-Host 'Checking the game files, build, runtime and notices...'
$gameFileCount = 0
if (-not $NoGameData) {
    $xex = Join-Path $gameRoot 'default.xex'
    if (-not (Test-Path -LiteralPath $xex -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $gameRoot 'data') -PathType Container)) {
        throw "Game files are missing: expected default.xex and data in $gameRoot. Import your game first (Import Game Files.cmd), or use -NoGameData."
    }
    [void](Assert-RegularFile $xex)
    $xexHash = (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash
    if ($xexHash -ne $expectedGameHash) {
        throw "game\default.xex is not the supported revision (SHA-256 $($xexHash.ToLowerInvariant())). See docs/INSTALL.md, Supported game version."
    }
    foreach ($file in (Get-OrdinaryTree $gameRoot 'The game folder')) {
        $relative = 'game\' + $file.FullName.Substring($gameRoot.Length + 1)
        $hash = $null
        if ($relative -ieq 'game\default.xex') { $hash = $xexHash }
        Add-Entry 'game' $file.FullName $relative $file.Length $hash
        $gameFileCount++
    }
}

$saveFileCount = 0
if ($IncludeSaves) {
    if (-not (Test-Path -LiteralPath $saveRoot -PathType Container)) { throw "No saves were found in $saveRoot." }
    foreach ($file in (Get-OrdinaryTree $saveRoot 'The save folder')) {
        Add-Entry 'save' $file.FullName ('userdata\' + $file.FullName.Substring($saveRoot.Length + 1)) $file.Length (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $saveFileCount++
    }
    if (-not $saveFileCount) { throw "The save folder is empty: $saveRoot" }
}

# Proton may not provide a current Microsoft C++ runtime, so the DLLs are
# bundled beside skate2.exe. The minimum is the launcher's own check.
. (Join-Path $PSScriptRoot 'Check-Skate2Runtime.ps1')
$runtimeRequirement = Get-Skate2RuntimeStatus
$minimumCrt = [version]$runtimeRequirement.MinimumVersion
$crtNames = @($runtimeRequirement.Files | ForEach-Object { $_.Name })
$crtCandidates = @()
if ($CrtDirectory) {
    $crtCandidates += [pscustomobject]@{ Directory = (Resolve-RepoPath $CrtDirectory); Origin = 'folder given with -CrtDirectory' }
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $vsPath = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsPath) {
            $redists = @(Get-ChildItem -Path (Join-Path $vsPath 'VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT') -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $version = $null; [void][version]::TryParse($_.Parent.Parent.Name, [ref]$version); $version } -Descending)
            foreach ($redist in $redists) {
                $crtCandidates += [pscustomobject]@{ Directory = $redist.FullName; Origin = 'Visual Studio x64 CRT redist' }
            }
        }
    }
    $systemDirectory = [Environment]::SystemDirectory
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory = Join-Path $env:SystemRoot 'Sysnative' }
    $crtCandidates += [pscustomobject]@{ Directory = $systemDirectory; Origin = 'installed runtime in the Windows system folder' }
}
$crtSource = $null
$crtRejected = @()
foreach ($candidate in $crtCandidates) {
    $problems = @(foreach ($name in $crtNames) {
        $path = Join-Path $candidate.Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "$name missing"; continue }
        $version = Get-FileVersion $path
        if ($version -lt $minimumCrt) { "$name $version" }
    })
    if (-not $problems.Count) { $crtSource = $candidate; break }
    $crtRejected += "$($candidate.Directory) ($($problems -join ', '))"
}
if (-not $crtSource) {
    throw ("No x64 Microsoft Visual C++ runtime $minimumCrt or later was found. Install or update it, or pass " +
        "-CrtDirectory. Checked: " + ($crtRejected -join '; '))
}

# The packager resolves and checks the native import closure (x64, build and
# installed SDK consistency, CRT files from the chosen folder). Its plan is
# reused here; the Windows launcher it also inspects is not needed on Proton.
try {
    $nativePlan = @(& $packageScript -CheckOnly -BuildDirectory $buildRoot -CrtDirectory $crtSource.Directory) |
        Where-Object { $null -ne $_ -and $_.PSObject.Properties['nativeFiles'] } | Select-Object -Last 1
} catch {
    throw "The native build check (Package-Skate2.ps1 -CheckOnly) failed: $($_.Exception.Message)"
}
if (-not $nativePlan) { throw 'Package-Skate2.ps1 -CheckOnly returned no native file plan.' }
$crtFiles = @()
foreach ($native in @($nativePlan.nativeFiles)) {
    if ($native.name -ieq 'Launch Skate 2.exe') { continue }
    $name = Get-DiskName $native.source
    [void](Assert-RegularFile $native.source)
    if ($name -match '^(?i:msvcp|vcruntime|concrt|vccorlib)[0-9].*\.dll$') {
        $version = Get-FileVersion $native.source
        if ($version -lt $minimumCrt) { throw "$name is version $version; $minimumCrt or later is required." }
        $signature = Get-AuthenticodeSignature -LiteralPath $native.source
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "$name does not carry a valid Microsoft signature: $($native.source)"
        }
        $crtFiles += [pscustomobject]@{ name = $name; version = $version.ToString(); origin = $crtSource.Origin }
        Add-Entry 'runtime' $native.source $name $native.bytes (Get-FileHash -LiteralPath $native.source -Algorithm SHA256).Hash
    } else {
        Add-Entry 'program' $native.source $name $native.bytes (Get-FileHash -LiteralPath $native.source -Algorithm SHA256).Hash
    }
}
foreach ($required in @('skate2.exe', 'rexruntime.dll', 'rexgpu-xenos.dll')) {
    if (-not @($entries | Where-Object { $_.Kind -eq 'program' -and $_.Relative -ieq $required }).Count) {
        throw "$required is missing from the native build plan."
    }
}

# Notices, as reviewed in licenses/NOTICE-INDEX.json (the packager has just
# checked each file against it).
$noticeIndexPath = Join-Path $workspace 'licenses\NOTICE-INDEX.json'
$noticeIndex = Get-Content -LiteralPath $noticeIndexPath -Raw | ConvertFrom-Json
foreach ($notice in @($noticeIndex.Files)) {
    $relative = ([string]$notice.Path).Replace('/', '\')
    $source = Join-Path $workspace $relative
    $item = Assert-RegularFile $source
    Add-Entry 'notice' $source $relative $item.Length ([string]$notice.SHA256).ToUpperInvariant()
}
foreach ($relative in @('licenses\NOTICE-INDEX.json', 'THIRD_PARTY_NOTICES.md', 'LICENSE')) {
    $source = Join-Path $workspace $relative
    Assert-OrdinaryAncestors $source
    $item = Assert-RegularFile $source
    Add-Entry 'notice' $source $relative $item.Length (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
}

$seen = @{}
foreach ($entry in $entries) {
    $key = $entry.Relative.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { throw "Two inputs map to the same output file: $($entry.Relative)" }
    $seen[$key] = $true
}

# ---- Generated files ---------------------------------------------------------

$tomlLines = @('# Auto-generated cvar configuration')
foreach ($setting in $deckSettings.GetEnumerator()) { $tomlLines += "$($setting.Key) = $($setting.Value)" }
$tomlText = ($tomlLines -join "`r`n") + "`r`n"

$largest = $entries | Sort-Object Bytes -Descending | Select-Object -First 1
$largestText = [string]::Format($culture, '{0:0.0} GB', $largest.Bytes / 1e9)
$buildDate = (Get-Date).ToString('yyyy-MM-dd', $culture)
if ($NoGameData) {
    $contentsText = "and an empty game folder for your own game files"
    $privacyText = @"
   It is meant for your own Deck. Add only your own game files, and do
   not upload or share the folder once they are in it.
"@
    $gameStep = @"

   GAME FILES: this folder was built without them. Before the first
   start, copy default.xex and the data folder from your imported game
   (the game folder of your PC installation) into the game folder here.

"@
} else {
    $contentsText = "and a copy of your own game files (game folder)"
    $savesPart = ''
    if ($IncludeSaves) { $savesPart = ' and your saves (userdata folder)' }
    $privacyText = @"
   It contains your own copy of the game files (game folder)$savesPart.
   Use it on your own Deck only; do not upload or share it.
"@
    $gameStep = ''
}
if ($IncludeSaves) {
    $savesText = @"
   userdata holds a copy of your PC saves from $buildDate. Progress made
   on the Deck stays in this folder. To continue on the PC, back up the
   PC's skate2\userdata folder, then copy this userdata folder over it.
"@
} else {
    $savesText = @"
   This folder was built without saves, so the Deck starts with a new
   save. To bring your PC saves, rebuild the folder on the PC with
   scripts\Build-Skate2SteamDeck.ps1 -IncludeSaves -Force.
"@
}
$readmeText = @"
SKATE 2 ON STEAM DECK
=====================

This folder runs Skate 2 PC on a Steam Deck under Proton, as a non-Steam
game that starts skate2.exe directly. It holds skate2.exe with its runtime
(rexruntime.dll, rexgpu-xenos.dll), the Microsoft Visual C++ runtime DLLs,
the Steam Deck settings (skate2.toml), the third-party notices (LICENSE,
THIRD_PARTY_NOTICES.md, licenses folder),
$contentsText.

Built $buildDate by scripts\Build-Skate2SteamDeck.ps1. This setup has not
been tested on Steam Deck hardware.

DO NOT SHARE THIS FOLDER
$privacyText

1. COPY THIS WHOLE FOLDER TO THE DECK
   Put it on internal storage or a microSD card, for example in
   ~/Games/Skate2. A USB stick or Warpinator also work; the largest file
   is $largestText. On the Deck, switch to Desktop Mode (hold Power ->
   Switch to Desktop) and copy it with the Dolphin file manager. Keep all
   files together.
$gameStep
2. ADD IT TO STEAM (still in Desktop Mode)
   - Steam -> Games -> Add a Non-Steam Game to My Library -> Browse
   - Set the file type to "All files" and pick skate2.exe in this folder
   - Right-click the new entry -> Properties -> Compatibility:
     tick "Force the use of a specific Steam Play compatibility tool"
     and choose "Proton Experimental"
   - Leave Launch Options empty: the settings are in skate2.toml.

3. PLAY
   Return to Gaming Mode and start it from your library. The first start
   takes longer while Proton sets up and shaders compile.

SETTINGS (skate2.toml)
   skate2.toml beside skate2.exe holds the Steam Deck profile: 60 FPS
   mode, 1x render scale, RTV render path, GPU submit interval 1024 and
   the submission thread (the "Steam Deck" preset of the settings panel),
   plus GPU idle-clean synchronization and asynchronous shader
   compilation.

   Asynchronous shader compilation can shorten pauses while new shaders
   are prepared, but may show brief visual glitches; the Windows default
   is synchronous. To use synchronous compilation, change the line
     async_shader_compilation = true
   to "= false" in skate2.toml. Saving in the settings panel or in F4
   rewrites skate2.toml with the settings in effect.

LAUNCH OPTIONS (optional)
   A Steam launch option overrides skate2.toml at every start. Write
   %command% followed by --name=value, for example:
     %command% --async_shader_compilation=false
   The settings panel marks such settings (L). Remove the option again to
   return to the saved value.

CONTROLLER AND SETTINGS PANEL
   Steam Input presents the Deck's controls to the game as an Xbox
   (XInput) controller. Hold View (left of the screen) and Menu (right of
   the screen) together for about a second to open the Skate 2 settings
   panel; hold them again, or press B, to close it. In the panel the
   D-pad moves, A selects and B goes back. F1 opens it from a keyboard.
   Choose "Save to skate2.toml" to keep changes; settings marked
   "After restart" apply at the next start. The game ignores input while
   the panel is open. The shortcut has not been tested on a Deck.

SAVES, SETTINGS AND LOGS
   The game writes everything inside this folder, beside skate2.exe:
     userdata      saves (keep the whole folder, with its metadata)
     skate2.toml   settings
     cache         generated cache data
     logs          one skate2_NNN.log per start

$savesText

IF IT DOES NOT START
   Check the newest skate2_NNN.log in the logs folder. Remove personal
   paths before sharing a log, and do not share game files or saves.
"@
$readmeText = ($readmeText -replace "`r?`n", "`r`n").TrimEnd() + "`r`n"
foreach ($text in @($tomlText, $readmeText)) {
    if ($text -match '[^\x00-\x7F]') { throw 'Generated text must be ASCII.' }
}
$generated = [ordered]@{ 'skate2.toml' = $tomlText; 'README-Steam-Deck.txt' = $readmeText }

# ---- Space -------------------------------------------------------------------

$copyBytes = [int64](($entries | Measure-Object -Property Bytes -Sum).Sum)
$neededBytes = $copyBytes + 1MB
$marginBytes = 256MB
$freeBytes = $null
try { $freeBytes = [int64]([IO.DriveInfo]::new($pathRoot)).AvailableFreeSpace } catch { }
if ($null -eq $freeBytes) {
    Write-Warning "The free space on $pathRoot could not be checked; about $(Format-Size $neededBytes) is needed."
} elseif ($freeBytes -lt $neededBytes + $marginBytes) {
    throw "Not enough free space on ${pathRoot}: $(Format-Size $neededBytes) plus a reserve of $(Format-Size $marginBytes) is needed, $(Format-Size $freeBytes) is free. Nothing was written."
}

$stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$staging = Join-Path $parent ".$leaf.partial-$stamp"
$retired = Join-Path $parent ".$leaf.replaced-$stamp"
$program = @($entries | Where-Object { $_.Kind -eq 'program' })
$notices = @($entries | Where-Object { $_.Kind -eq 'notice' })
$plan = [pscustomobject]@{
    Output = $output
    ReplacesExisting = $replace
    Program = @($program | ForEach-Object { $_.Relative })
    CppRuntime = @($crtFiles | ForEach-Object { "$($_.name) $($_.version)" })
    CppRuntimeOrigin = $crtSource.Origin
    NoticeFiles = $notices.Count
    GameDataIncluded = -not $NoGameData
    GameFiles = $gameFileCount
    SavesIncluded = [bool]$IncludeSaves
    SaveFiles = $saveFileCount
    AllGameHashesVerified = [bool]$VerifyAllHashes -and -not $NoGameData
    Settings = @($tomlLines | Select-Object -Skip 1)
    Files = $entries.Count + $generated.Count + 1
    Bytes = $copyBytes
    FreeBytes = $freeBytes
}

if ($CheckOnly) {
    $existingText = 'new folder'
    if ($replace) { $existingText = "replaces the folder this script built at $($previousMarker.createdUtc) (UTC)" }
    $gameText = 'not included (-NoGameData); an empty game folder is created'
    if (-not $NoGameData) {
        $gameText = "game\ $gameFileCount files, $(Format-Size (($entries | Where-Object Kind -eq 'game' | Measure-Object Bytes -Sum).Sum)); default.xex revision verified"
    }
    $savesLine = 'not included (use -IncludeSaves)'
    if ($IncludeSaves) { $savesLine = "userdata\ $saveFileCount files, $(Format-Size (($entries | Where-Object Kind -eq 'save' | Measure-Object Bytes -Sum).Sum)) from $saveRoot" }
    $freeText = 'unknown'
    if ($null -ne $freeBytes) { $freeText = Format-Size $freeBytes }
    Write-Host ''
    Write-Host 'Steam Deck folder plan (-CheckOnly: nothing was written)'
    Write-Host "  Output        $output ($existingText)"
    Write-Host "  Program       $($plan.Program -join ', ') ($(Format-Size (($program | Measure-Object Bytes -Sum).Sum)))"
    Write-Host "  C++ runtime   $($plan.CppRuntime -join ', ') from the $($crtSource.Origin)"
    Write-Host "  Notices       LICENSE, THIRD_PARTY_NOTICES.md, licenses\ ($($notices.Count) files in all)"
    Write-Host "  Game data     $gameText"
    Write-Host "  Saves         $savesLine"
    Write-Host "  Settings      skate2.toml: $($plan.Settings -join '; ')"
    Write-Host '  Instructions  README-Steam-Deck.txt'
    Write-Host "  Marker        $markerName"
    Write-Host "  Space         $(Format-Size $neededBytes) needed on $pathRoot, $freeText free"
    Write-Host "  Built in      $staging, then renamed"
    return $plan
}

# ---- Build -------------------------------------------------------------------

if (Test-Path -LiteralPath $staging) { throw "Temporary folder already exists: $staging" }
[void][IO.Directory]::CreateDirectory($parent)
Assert-OrdinaryAncestors $parent
[void][IO.Directory]::CreateDirectory($staging)
Write-Host "Copying $($entries.Count) files ($(Format-Size $copyBytes)) into $staging"
try {
    $doneBytes = 0L
    $hashedGameFiles = 0
    foreach ($entry in $entries) {
        $percent = [int][math]::Floor(100.0 * $doneBytes / [math]::Max([double]1, [double]$copyBytes))
        Write-Progress -Activity 'Building the Steam Deck folder' -Status $entry.Relative -PercentComplete $percent
        $target = Join-Path $staging $entry.Relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $expectedHash = $entry.Sha256
        if (-not $expectedHash -and $VerifyAllHashes) {
            $expectedHash = (Get-FileHash -LiteralPath $entry.Source -Algorithm SHA256).Hash
            $entry.Sha256 = $expectedHash
        }
        [IO.File]::Copy($entry.Source, $target, $false)
        $copiedLength = ([IO.FileInfo]::new($target)).Length
        if ($copiedLength -ne $entry.Bytes) {
            throw "Copied size of $($entry.Relative) is $copiedLength bytes, expected $($entry.Bytes). Did the source change?"
        }
        if ($expectedHash) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $expectedHash) {
                throw "The copy of $($entry.Relative) differs from its source."
            }
            if ($entry.Kind -eq 'game') { $hashedGameFiles++ }
        }
        $doneBytes += $entry.Bytes
    }
    Write-Progress -Activity 'Building the Steam Deck folder' -Completed
    if ($NoGameData) { [void][IO.Directory]::CreateDirectory((Join-Path $staging 'game')) }
    foreach ($file in $generated.GetEnumerator()) {
        [IO.File]::WriteAllText((Join-Path $staging $file.Key), $file.Value, [Text.Encoding]::ASCII)
    }

    # Audit: exactly the planned files, no links, no upscaler swapper or
    # overlay files beside the program, and the generated settings rather
    # than a PC skate2.toml.
    $expected = @{}
    foreach ($entry in $entries) { $expected[$entry.Relative.ToLowerInvariant()] = $entry }
    foreach ($name in $generated.Keys) { $expected[$name.ToLowerInvariant()] = $null }
    $built = @(Get-ChildItem -LiteralPath $staging -Recurse -Force)
    if (@($built | Where-Object { Test-ReparsePoint $_ }).Count) { throw 'The new folder contains a link or other reparse point.' }
    $builtFiles = @($built | Where-Object { -not $_.PSIsContainer })
    $forbidden = '^(?i:dxgi\.dll|d3d1[12]\.dll|d3d9\.dll|dinput8\.dll|nvngx.*|.*dlss.*|.*\.addon(32|64)?|reshade.*|.*\.pdb|.*\.iso|launch skate 2\.exe)$'
    foreach ($file in $builtFiles) {
        $relative = $file.FullName.Substring($staging.Length + 1)
        if (-not $expected.ContainsKey($relative.ToLowerInvariant())) { throw "Unexpected file in the new folder: $relative" }
        if ($relative -notmatch '^(?i:game|userdata)\\' -and $file.Name -match $forbidden) { throw "Refusing to ship $relative." }
    }
    if ($builtFiles.Count -ne $expected.Count) { throw "The new folder has $($builtFiles.Count) files; $($expected.Count) were planned." }
    if ([IO.File]::ReadAllText((Join-Path $staging 'skate2.toml')) -ne $tomlText) { throw 'skate2.toml does not hold the Steam Deck settings.' }

    $inventory = @(foreach ($file in ($builtFiles | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($staging.Length + 1)
        $hash = $null
        $entry = $expected[$relative.ToLowerInvariant()]
        if ($entry) { $hash = $entry.Sha256 } else { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        $hashText = $null
        if ($hash) { $hashText = $hash.ToLowerInvariant() }
        [ordered]@{ path = $relative.Replace('\', '/'); bytes = $file.Length; sha256 = $hashText }
    })
    $marker = [ordered]@{
        tool = $markerTool
        schemaVersion = 1
        note = 'Written by scripts/Build-Skate2SteamDeck.ps1. -Force replaces only folders carrying this file. The folder holds your own game files; do not share it.'
        createdUtc = [DateTime]::UtcNow.ToString('o')
        gameDataIncluded = -not $NoGameData
        gameFilesHashed = $hashedGameFiles
        savesIncluded = [bool]$IncludeSaves
        expectedGameExecutableSha256 = $expectedGameHash.ToLowerInvariant()
        cppRuntime = $crtFiles
        settings = @($tomlLines | Select-Object -Skip 1)
        files = $inventory
    }
    [IO.File]::WriteAllText((Join-Path $staging $markerName), ($marker | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
} catch {
    Write-Progress -Activity 'Building the Steam Deck folder' -Completed
    Write-Warning "The build failed; removing the unfinished folder $staging"
    try { Remove-OwnedTree $staging } catch { Write-Warning "Could not remove ${staging}: $($_.Exception.Message)" }
    throw
}

# ---- Move into place -----------------------------------------------------------

try {
    if ($replace) {
        [void](Assert-ReplaceableOutput $output)
        [IO.Directory]::Move($output, $retired)
        try {
            [IO.Directory]::Move($staging, $output)
        } catch {
            [IO.Directory]::Move($retired, $output)
            throw
        }
    } else {
        [IO.Directory]::Move($staging, $output)
    }
} catch {
    Write-Warning "The new folder could not be moved into place; removing $staging"
    try { Remove-OwnedTree $staging } catch { Write-Warning "Could not remove ${staging}: $($_.Exception.Message)" }
    throw "Could not create ${output}: $($_.Exception.Message)"
}
if ($replace) {
    try { Remove-OwnedTree $retired } catch { Write-Warning "The replaced folder could not be removed completely: $retired. $($_.Exception.Message)" }
}

$stopwatch.Stop()
Write-Host "Created $output in $([string]::Format($culture, '{0:0.0}', $stopwatch.Elapsed.TotalSeconds)) s."
Write-Host 'Copy the whole folder to the Deck and follow README-Steam-Deck.txt. It contains your own game files: do not share it.'
$plan | Add-Member -NotePropertyName Seconds -NotePropertyValue ([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))
$plan | Add-Member -NotePropertyName GameFilesHashed -NotePropertyValue $hashedGameFiles
$plan
