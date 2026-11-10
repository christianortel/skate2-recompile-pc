[CmdletBinding()]
param([string]$SourceDirectory, [string]$IsoPath, [switch]$CheckOnly)

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

# Reads the Xbox 360 disc file system (XDVDFS) directly from an ISO. C# 5 so
# Windows PowerShell 5.1 can compile it with the .NET Framework compiler.
$xdvdfsSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skate2Import
{
    public sealed class XdvdfsEntry
    {
        public string Path;
        public long Offset;
        public long Size;
        public bool IsDirectory;
    }

    // The volume descriptor sits 32 sectors into the game partition; directory
    // tables are binary trees of entries addressed by sector.
    public sealed class XdvdfsImage : IDisposable
    {
        const int SectorSize = 2048;
        // Game partition starts: XGD2, XGD3, XGD1, and images rebuilt to hold
        // only the game partition.
        static readonly long[] PartitionOffsets = { 0x0FD90000L, 0x02080000L, 0x18300000L, 0L };
        static readonly byte[] Magic = Encoding.ASCII.GetBytes("MICROSOFT*XBOX*MEDIA");
        const int MaxDepth = 32;
        const uint MaxDirectoryBytes = 64u * 1024 * 1024;

        readonly FileStream stream;
        long partitionOffset = -1;

        public XdvdfsImage(string path)
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20,
                                    FileOptions.SequentialScan);
            foreach (long offset in PartitionOffsets)
            {
                long descriptor = offset + 32L * SectorSize;
                if (HasMagic(descriptor) && HasMagic(descriptor + 0x7EC))
                {
                    partitionOffset = offset;
                    break;
                }
            }
            if (partitionOffset < 0)
            {
                stream.Dispose();
                throw new InvalidDataException("This file is not an Xbox 360 disc image (no XDVDFS volume was found).");
            }
        }

        public long PartitionOffset { get { return partitionOffset; } }

        public void Dispose() { stream.Dispose(); }

        byte[] Read(long offset, int count)
        {
            if (offset < 0 || count < 0 || offset + count > stream.Length)
                throw new InvalidDataException("The disc image is truncated or corrupt.");
            byte[] buffer = new byte[count];
            stream.Position = offset;
            int done = 0;
            while (done < count)
            {
                int read = stream.Read(buffer, done, count - done);
                if (read <= 0) throw new EndOfStreamException("Unexpected end of the disc image.");
                done += read;
            }
            return buffer;
        }

        bool HasMagic(long offset)
        {
            if (offset < 0 || offset + Magic.Length > stream.Length) return false;
            byte[] bytes = Read(offset, Magic.Length);
            for (int i = 0; i < Magic.Length; ++i)
            {
                if (bytes[i] != Magic[i]) return false;
            }
            return true;
        }

        static void ValidateName(string name)
        {
            if (name == "." || name == "..") throw new InvalidDataException("Unsafe file name in the disc image: " + name);
            foreach (char c in name)
            {
                if (c < 0x20 || c > 0x7E || "\\/:*?\"<>|".IndexOf(c) >= 0)
                    throw new InvalidDataException("Unsupported file name in the disc image: " + name);
            }
        }

        public List<XdvdfsEntry> ListEntries()
        {
            byte[] descriptor = Read(partitionOffset + 32L * SectorSize, SectorSize);
            uint rootSector = BitConverter.ToUInt32(descriptor, 0x14);
            uint rootSize = BitConverter.ToUInt32(descriptor, 0x18);
            List<XdvdfsEntry> result = new List<XdvdfsEntry>();
            ReadDirectory(rootSector, rootSize, "", 0, result);
            return result;
        }

        void ReadDirectory(uint sector, uint size, string prefix, int depth, List<XdvdfsEntry> result)
        {
            if (depth > MaxDepth) throw new InvalidDataException("Directory nesting in the disc image is too deep.");
            if (size == 0) return;
            if (size > MaxDirectoryBytes) throw new InvalidDataException("A directory table in the disc image is too large.");
            byte[] table = Read(partitionOffset + (long)sector * SectorSize, (int)size);
            Stack<int> pending = new Stack<int>();
            HashSet<int> seen = new HashSet<int>();
            pending.Push(0);
            while (pending.Count > 0)
            {
                int o = pending.Pop();
                if (!seen.Add(o)) continue;
                if (o < 0 || o + 14 > table.Length) throw new InvalidDataException("Corrupt directory entry in the disc image.");
                ushort left = BitConverter.ToUInt16(table, o);
                ushort right = BitConverter.ToUInt16(table, o + 2);
                // 0xFFFF marks sector padding, which also encodes an empty directory.
                if (left == 0xFFFF) continue;
                uint entrySector = BitConverter.ToUInt32(table, o + 4);
                uint entrySize = BitConverter.ToUInt32(table, o + 8);
                byte attributes = table[o + 12];
                int nameLength = table[o + 13];
                if (nameLength == 0 || o + 14 + nameLength > table.Length)
                    throw new InvalidDataException("Corrupt directory entry name in the disc image.");
                string name = Encoding.ASCII.GetString(table, o + 14, nameLength);
                ValidateName(name);
                string path = prefix.Length == 0 ? name : prefix + "/" + name;
                bool isDirectory = (attributes & 0x10) != 0;
                XdvdfsEntry entry = new XdvdfsEntry();
                entry.Path = path;
                entry.Offset = partitionOffset + (long)entrySector * SectorSize;
                entry.Size = entrySize;
                entry.IsDirectory = isDirectory;
                result.Add(entry);
                if (isDirectory) ReadDirectory(entrySector, entrySize, path, depth + 1, result);
                if (left != 0) pending.Push(left * 4);
                if (right != 0) pending.Push(right * 4);
            }
        }

        static string Hex(byte[] hash)
        {
            StringBuilder text = new StringBuilder(hash.Length * 2);
            foreach (byte b in hash) text.Append(b.ToString("X2"));
            return text.ToString();
        }

        void CheckRange(XdvdfsEntry entry)
        {
            if (entry.IsDirectory) throw new ArgumentException("Directories have no file data: " + entry.Path);
            if (entry.Offset < 0 || entry.Size < 0 || entry.Offset + entry.Size > stream.Length)
                throw new InvalidDataException("A file extends past the end of the disc image: " + entry.Path);
        }

        // SHA-256 of a file's bytes inside the image, without writing anything.
        public string HashEntry(XdvdfsEntry entry)
        {
            return Copy(entry, null, null);
        }

        // Writes the entry to a new file, then re-reads it and compares hashes.
        // Returns the SHA-256 of the data.
        public string Extract(XdvdfsEntry entry, string targetPath, Action<long> progress)
        {
            string sourceHash;
            using (FileStream output = new FileStream(targetPath, FileMode.CreateNew, FileAccess.Write,
                                                      FileShare.None, 1 << 20))
            {
                sourceHash = Copy(entry, output, progress);
            }
            if (HashFile(targetPath) != sourceHash)
                throw new IOException("Verification failed after writing " + entry.Path);
            return sourceHash;
        }

        string Copy(XdvdfsEntry entry, Stream output, Action<long> progress)
        {
            CheckRange(entry);
            byte[] buffer = new byte[4 << 20];
            using (SHA256 sha = SHA256.Create())
            {
                stream.Position = entry.Offset;
                long remaining = entry.Size;
                long done = 0;
                long reported = 0;
                while (remaining > 0)
                {
                    int read = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                    if (read <= 0) throw new EndOfStreamException("Unexpected end of the disc image: " + entry.Path);
                    sha.TransformBlock(buffer, 0, read, null, 0);
                    if (output != null) output.Write(buffer, 0, read);
                    remaining -= read;
                    done += read;
                    if (progress != null && done - reported >= (64L << 20))
                    {
                        progress(done);
                        reported = done;
                    }
                }
                sha.TransformFinalBlock(buffer, 0, 0);
                return Hex(sha.Hash);
            }
        }

        public static string HashFile(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                                                     1 << 20, FileOptions.SequentialScan))
            {
                return Hex(sha.ComputeHash(input));
            }
        }
    }
}
'@

# Moves a fully written and verified staging folder into place as game.
function Complete-Import([string]$Staging) {
    if ((Get-FileHash -LiteralPath (Join-Path $Staging 'default.xex')).Hash -ne $expectedHash) { throw 'Executable changed during import.' }
    # Both absolute paths were constructed directly inside this workspace.
    $workspacePrefix = [IO.Path]::GetFullPath($workspace).TrimEnd('\', '/') + '\'
    foreach ($path in @($Staging, $destination)) {
        if (-not [IO.Path]::GetFullPath($path).StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Import path escaped workspace.' }
        Assert-OrdinaryPath $path
    }
    if (Test-Path -LiteralPath $destination) { throw 'Another import created game while this import was running.' }
    # Fail atomically if another process created game; never nest inside it.
    [IO.Directory]::Move($Staging, $destination)
    Write-Host 'Game files imported and verified. Open Launch Skate 2.cmd.'
}

if ($SourceDirectory -and $IsoPath) { throw 'Supply either -SourceDirectory or -IsoPath, not both.' }
if (-not $SourceDirectory -and -not $IsoPath) {
    if ($CheckOnly) { throw 'Supply -SourceDirectory or -IsoPath when using -CheckOnly.' }
    Add-Type -AssemblyName System.Windows.Forms
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Import from an Xbox 360 disc image (.iso)?`n`nYes: select the ISO file.`nNo: select an extracted folder containing default.xex and data.",
        'Import Skate 2 game files', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = 'Select your Skate 2 Xbox 360 disc image'
        $picker.Filter = 'Xbox 360 disc image (*.iso)|*.iso|All files (*.*)|*.*'
        $picker.CheckFileExists = $true
        try {
            if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $IsoPath = $picker.FileName
        } finally { $picker.Dispose() }
    } else {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Select your extracted Skate 2 folder containing default.xex and data.'
        $picker.ShowNewFolderButton = $false
        try {
            if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $SourceDirectory = $picker.SelectedPath
        } finally { $picker.Dispose() }
    }
}

if ($IsoPath) {
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw 'Select the ISO file itself, not a folder.' }
    Assert-OrdinaryPath $IsoPath
    Assert-OrdinaryPath $destination
    if (Test-Path -LiteralPath $destination) { throw 'The game folder already exists. Import uses a fresh folder and never overwrites an existing installation.' }
    if (-not ('Skate2Import.XdvdfsImage' -as [type])) { Add-Type -TypeDefinition $xdvdfsSource -Language CSharp }
    try { $image = [Skate2Import.XdvdfsImage]::new($IsoPath) }
    catch { throw $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) }
    try {
        $entries = @($image.ListEntries())
        $xex = $entries | Where-Object { -not $_.IsDirectory -and $_.Path -eq 'default.xex' } | Select-Object -First 1
        if (-not $xex -or -not ($entries | Where-Object { $_.IsDirectory -and $_.Path -eq 'data' })) {
            throw 'This disc image does not contain default.xex and data. Select a Skate 2 Xbox 360 ISO.'
        }
        if ($image.HashEntry($xex) -ne $expectedHash) {
            throw 'Unsupported executable revision. No files were copied. See docs/INSTALL.md for the supported SHA-256.'
        }
        # The game executable and its data folder are the supported file set.
        # Disc extras such as the console system update are not used.
        $files = @($entries | Where-Object { -not $_.IsDirectory -and ($_.Path -eq 'default.xex' -or $_.Path -like 'data/*') })
        $bytes = [long]($files | Measure-Object Size -Sum).Sum
        if ($CheckOnly) { return [pscustomobject]@{ Source=$IsoPath; Destination=$destination; Files=$files.Count; Bytes=$bytes; ExecutableVerified=$true; CopiesPerformed=$false } }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($workspace)))
        if ($drive.AvailableFreeSpace -lt $bytes + 256MB) {
            throw ('Not enough free space: the import needs {0:N1} GB on {1}.' -f (($bytes + 256MB) / 1GB), $drive.Name)
        }

        # Stage beside the destination. Interrupted imports never look like a complete game.
        $staging = Join-Path $workspace ('game-import-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging | Out-Null
        try {
            $done = [long]0
            $activity = 'Importing Skate 2 from ' + (Split-Path -Leaf $IsoPath)
            foreach ($file in $files) {
                $relative = $file.Path -replace '/', '\'
                $target = Join-Path $staging $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                $before = $done
                $progress = [Action[long]] ({
                    param([long]$written)
                    Write-Progress -Activity $activity -Status ('{0:N1} of {1:N1} GB' -f (($before + $written) / 1GB), ($bytes / 1GB)) -PercentComplete ([int](100 * ($before + $written) / $bytes))
                }.GetNewClosure())
                Write-Progress -Activity $activity -Status $relative -PercentComplete ([int](100 * $done / $bytes))
                [void]$image.Extract($file, $target, $progress)
                $done += $file.Size
            }
            Write-Progress -Activity $activity -Completed
            Complete-Import $staging
        } catch {
            Write-Warning "Import incomplete. The partial copy is preserved at $staging. The ISO was not changed."
            throw
        }
    } finally { $image.Dispose() }
    return
}

$SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath.TrimEnd('\', '/')
if (Test-Path -LiteralPath $SourceDirectory -PathType Leaf) { throw 'For a disc image, use -IsoPath or answer Yes when asked for an ISO.' }
Assert-OrdinaryPath $SourceDirectory
Assert-OrdinaryPath $destination
if (Test-Path -LiteralPath $destination) { throw 'The game folder already exists. Import uses a fresh folder and never overwrites an existing installation.' }
$sourceXex = Join-Path $SourceDirectory 'default.xex'
$sourceData = Join-Path $SourceDirectory 'data'
if (-not (Test-Path -LiteralPath $sourceXex -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceData -PathType Container)) {
    throw 'Select the extracted folder containing default.xex and data, not its parent or an archive.'
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
    Complete-Import $staging
} catch {
    Write-Warning "Import incomplete. The partial copy is preserved at $staging. Original files were not changed."
    throw
}
