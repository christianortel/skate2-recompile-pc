[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReferenceDirectory,
    [Parameter(Mandatory)][string]$RebuiltDirectory,
    [string]$ApplicationPath,
    [string]$LLVMReadObject = 'llvm-readobj',
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Read-Exports([string]$Path) {
    $raw=@(& $LLVMReadObject --coff-exports $Path)
    if($LASTEXITCODE -ne 0) { throw 'Could not inspect exports.' }
    $exports=@([regex]::Matches(($raw -join "`n"),'(?m)^Export \{\s+Ordinal: (\d+)\s+Name: ([^\r\n]*)') | ForEach-Object {
        [pscustomobject]@{Name=$_.Groups[2].Value; Ordinal=[int]$_.Groups[1].Value}
    })
    if(-not $exports.Count) { throw 'No exports found.' }
    return $exports
}
$rows=@(); $runtimeExports=@(); $passed=$true
foreach($name in @('rexruntime.dll','rexgpu-xenos.dll')) {
    $reference=Join-Path $ReferenceDirectory $name; $rebuilt=Join-Path $RebuiltDirectory $name
    $a=@(Read-Exports $reference); $b=@(Read-Exports $rebuilt)
    $names=@(Compare-Object @($a.Name | Sort-Object) @($b.Name | Sort-Object) -CaseSensitive)
    $ordinals=@(Compare-Object @($a | ForEach-Object { "$($_.Ordinal):$($_.Name)" } | Sort-Object) @($b | ForEach-Object { "$($_.Ordinal):$($_.Name)" } | Sort-Object) -CaseSensitive)
    $same=($names.Count -eq 0 -and $ordinals.Count -eq 0)
    if(-not $same) { $passed=$false }
    $rows += [ordered]@{Name=$name;ReferenceSHA256=(Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash;RebuiltSHA256=(Get-FileHash -LiteralPath $rebuilt -Algorithm SHA256).Hash;ReferenceExportCount=$a.Count;RebuiltExportCount=$b.Count;NamesAndOrdinalsMatch=$same;NameDifferences=@($names);OrdinalDifferences=@($ordinals)}
    if($name -eq 'rexruntime.dll') { $runtimeExports=$b }
}
$imports=$null
if($ApplicationPath) {
    $raw=@(& $LLVMReadObject --coff-imports $ApplicationPath)
    if($LASTEXITCODE -ne 0) { throw 'Could not inspect application imports.' }
    $block=[regex]::Match(($raw -join "`n"),'(?s)Import \{\s+Name: rexruntime\.dll\s+(.*?)\n\}')
    if(-not $block.Success) { throw 'Application does not import rexruntime.dll.' }
    $symbols=@([regex]::Matches($block.Groups[1].Value,'(?m)^\s+Symbol: (.*?) \((\d+)\)') | ForEach-Object { [pscustomobject]@{Name=$_.Groups[1].Value;Ordinal=[int]$_.Groups[2].Value} })
    $missing=@($symbols | Where-Object { if($_.Name) { $_.Name -cnotin $runtimeExports.Name } else { $_.Ordinal -notin $runtimeExports.Ordinal } })
    if($missing.Count) { $passed=$false }
    $imports=[ordered]@{ApplicationSHA256=(Get-FileHash -LiteralPath $ApplicationPath -Algorithm SHA256).Hash;RuntimeImports=$symbols.Count;AllNamed=(@($symbols | Where-Object {-not $_.Name}).Count -eq 0);AllSatisfied=($missing.Count -eq 0);Missing=$missing}
}
$report=[ordered]@{SchemaVersion=1;Passed=$passed;RuntimeDLLs=$rows;Application=$imports;Limitations=@('Export-name/ordinal and import compatibility checks; not a full C++ layout or behavioral ABI proof.','No game launched; modified source can change semantics without changing exports.')}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if(-not $passed) { throw 'Runtime interface comparison failed; see report.' }
Write-Host 'Runtime export names and ordinals match; requested application imports are satisfied.'
