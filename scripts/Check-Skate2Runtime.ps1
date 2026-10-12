# Read-only prerequisite inspection. Dot-source this file to use the function.
function Get-Skate2RuntimeStatus {
    [CmdletBinding()]
    param()
    $minimumVersion = [version]'14.44.35211.0'
    $runtimeNames = @('msvcp140.dll', 'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
    # Sysnative exposes the actual 64-bit system directory to a 32-bit launcher.
    $systemDirectory = [Environment]::SystemDirectory
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $systemDirectory = Join-Path $env:SystemRoot 'Sysnative'
    }
    $files = @(foreach ($name in $runtimeNames) {
        $path = Join-Path $systemDirectory $name
        $version = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        }
        [pscustomobject]@{ Name=$name; Version=$version; Ready=($null -ne $version -and $version -ge $minimumVersion) }
    })
    [pscustomobject]@{
        Ready = ([Environment]::Is64BitOperatingSystem -and @($files | Where-Object { -not $_.Ready }).Count -eq 0)
        MinimumVersion = $minimumVersion.ToString()
        Download = 'https://aka.ms/vc14/vc_redist.x64.exe'
        Files = $files
    }
}
