[CmdletBinding()]
param([string]$SourceDirectory, [switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $workspace 'game'
$expectedHash = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'

function Assert-OrdinaryPath([string]$Path) {
    for ($current = $Path; $current;) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked paths are not supported: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

if (-not $SourceDirectory) {
    if ($CheckOnly) { throw 'Supply -SourceDirectory when using -CheckOnly.' }
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Select your extracted Skate 2 folder containing default.xex and data.'
    $picker.ShowNewFolderButton = $false
    try {
        if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $SourceDirectory = $picker.SelectedPath
    } finally { $picker.Dispose() }
}
$SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath.TrimEnd('\', '/')
Assert-OrdinaryPath $SourceDirectory
Assert-OrdinaryPath $destination
if (Test-Path -LiteralPath $destination) { throw 'The game folder already exists. Import uses a fresh folder and never overwrites an existing installation.' }
$sourceXex = Join-Path $SourceDirectory 'default.xex'
$sourceData = Join-Path $SourceDirectory 'data'
if (-not (Test-Path -LiteralPath $sourceXex -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceData -PathType Container)) {
    throw 'Select the extracted folder containing default.xex and data, not its parent or an ISO/archive.'
}
Assert-OrdinaryPath $sourceXex
if ((Get-FileHash -LiteralPath $sourceXex -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'Unsupported executable revision. No files were copied. See docs/INSTALL.md for the supported SHA-256.'
}
$items = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force)
if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw 'The source contains links. Import requires ordinary extracted files.'
}
$files = @($items | Where-Object { -not $_.PSIsContainer })
$bytes = ($files | Measure-Object Length -Sum).Sum
if ($CheckOnly) { return [pscustomobject]@{ Source=$SourceDirectory; Destination=$destination; Files=$files.Count; Bytes=$bytes; ExecutableVerified=$true; CopiesPerformed=$false } }

# Stage beside the destination. Interrupted imports never look like a complete game.
$staging = Join-Path $workspace ('game-import-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($SourceDirectory.Length).TrimStart('\', '/')
        $target = Join-Path $staging $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
            throw "Copy verification failed: $relative"
        }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $staging 'default.xex')).Hash -ne $expectedHash) { throw 'Executable changed during import.' }
    # Both absolute paths were constructed directly inside this workspace.
    $workspacePrefix = [IO.Path]::GetFullPath($workspace).TrimEnd('\', '/') + '\'
    foreach ($path in @($staging, $destination)) {
        if (-not [IO.Path]::GetFullPath($path).StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Import path escaped workspace.' }
        Assert-OrdinaryPath $path
    }
    if (Test-Path -LiteralPath $destination) { throw 'Another import created game while this import was running.' }
    # Fail atomically if another process created game; never nest inside it.
    [IO.Directory]::Move($staging, $destination)
    Write-Host 'Game files imported and verified. Open Launch Skate 2.cmd.'
} catch {
    Write-Warning "Import incomplete. The partial copy is preserved at $staging. Original files were not changed."
    throw
}
