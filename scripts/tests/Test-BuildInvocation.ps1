[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $workspace 'scripts/Build-Skate2.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw 'Build script failed to parse.' }
$function = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Checked'
}, $true)
if (-not $function) { throw 'Production native-command runner was not found.' }
. ([scriptblock]::Create($function.Extent.Text))
$fixture = Join-Path $workspace ('reports/build-invocation-' + [guid]::NewGuid().ToString('N'))
$first = Join-Path $fixture 'first'; $second = Join-Path $fixture 'second'
New-Item -ItemType Directory -Path $first,$second -Force | Out-Null
'@exit /b 11' | Set-Content -LiteralPath (Join-Path $first 'skate-native-choice.cmd') -Encoding ascii
'@exit /b 22' | Set-Content -LiteralPath (Join-Path $second 'skate-native-choice.cmd') -Encoding ascii
$previousPath = $env:PATH
try {
    $env:PATH = $first + ';' + $second + ';' + $previousPath
    $matches = @(Get-Command skate-native-choice.cmd -CommandType Application)
    if ($matches.Count -lt 2) { throw 'Fixture did not expose two competing executables.' }
    $firstSelected = $false
    try { Invoke-Checked 'skate-native-choice.cmd' @() }
    catch { $firstSelected = $_.Exception.Message -match 'exit code 11$' }
    if (-not $firstSelected) { throw 'Native lookup did not execute the first PATH match and reject its exit status.' }
    Invoke-Checked $env:ComSpec @('/d', '/c', 'echo synthetic-warning 1>&2')
    $failedExitRejected = $false
    try { Invoke-Checked $env:ComSpec @('/d', '/c', 'exit 7') }
    catch { $failedExitRejected = $_.Exception.Message -match 'exit code 7$' }
    if (-not $failedExitRejected) { throw 'Native nonzero exit code was accepted.' }
    Write-Output 'PASS: first PATH match selected; native warning accepted; nonzero exit rejected.'
} finally { $env:PATH = $previousPath }
