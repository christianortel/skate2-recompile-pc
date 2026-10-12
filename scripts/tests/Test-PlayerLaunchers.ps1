[CmdletBinding()]
param()

# Runs real CMD wrapper copies against harmless PowerShell stubs only.
# No game, importer, original save, or persistent execution policy is changed.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$commandProcessor = Join-Path $env:SystemRoot 'System32\cmd.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw 'Windows PowerShell 5.1 is required for this fixture.' }

$fixture = Join-Path $workspace ('reports\player-launchers-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
# Exercise quoting with spaces, an ampersand, an apostrophe, and a Unicode path.
$playerRoot = Join-Path $fixture ("Player & Tester''s " + [char]0x00D8)
$stubRoot = Join-Path $playerRoot 'scripts'
[IO.Directory]::CreateDirectory($stubRoot) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($true)
$policyBefore = Get-ExecutionPolicy -List | ConvertTo-Json -Compress
$modulePathBefore = $env:PSModulePath
$pathBefore = $env:PATH
$policyEnvironmentBefore = $env:PSExecutionPolicyPreference
$ps7ModulePath = $null
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $ps7ModulePath = Join-Path $PSHOME 'Modules'
} else {
    $ps7Command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ps7Command) { $ps7ModulePath = Join-Path (Split-Path -Parent $ps7Command.Source) 'Modules' }
}
if ($ps7ModulePath -and -not (Test-Path -LiteralPath (Join-Path $ps7ModulePath 'Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'))) {
    $ps7ModulePath = $null
}
$nativeUtilityPath = Join-Path (Split-Path -Parent $windowsPowerShell) 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
$hashFixture = Join-Path $fixture 'hash-input.txt'
$hashBytes = [Text.Encoding]::ASCII.GetBytes('Skate2 launcher hash fixture v1')
[IO.File]::WriteAllBytes($hashFixture, $hashBytes)
$hashAlgorithm = [Security.Cryptography.SHA256]::Create()
try { $expectedHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($hashBytes)).Replace('-', '') }
finally { $hashAlgorithm.Dispose() }
$script:launcherChecks = 0
$results = [Collections.Generic.List[object]]::new()

function Assert-LauncherCondition([bool]$Condition, [string]$Message) {
    $script:launcherChecks++
    if (-not $Condition) { throw $Message }
}

function Invoke-FixtureChild([string]$Executable, [string]$Arguments, [string]$ResultPath, [int]$StubExit = 0, [bool]$InjectPS7Modules = $true) {
    $child = [Diagnostics.Process]::new()
    try {
        $child.StartInfo.FileName = $Executable
        $child.StartInfo.Arguments = $Arguments
        $child.StartInfo.WorkingDirectory = $fixture
        $child.StartInfo.UseShellExecute = $false
        $child.StartInfo.CreateNoWindow = $true
        $child.StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $child.StartInfo.RedirectStandardInput = $true
        $child.StartInfo.RedirectStandardOutput = $true
        $child.StartInfo.RedirectStandardError = $true
        # Child-only environment: this intentionally hides the developer's
        # Unrestricted policy and non-system PowerShell installations.
        $child.StartInfo.EnvironmentVariables['PSExecutionPolicyPreference'] = 'Restricted'
        $child.StartInfo.EnvironmentVariables['PATH'] = (Split-Path -Parent $windowsPowerShell) + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
        $child.StartInfo.EnvironmentVariables['SKATE2_LAUNCHER_FIXTURE_RESULT'] = $ResultPath
        $child.StartInfo.EnvironmentVariables['SKATE2_LAUNCHER_FIXTURE_EXIT'] = [string]$StubExit
        $child.StartInfo.EnvironmentVariables['SKATE2_LAUNCHER_FIXTURE_HASH_FILE'] = $hashFixture
        $child.StartInfo.EnvironmentVariables['SKATE2_LAUNCHER_FIXTURE_EXPECTED_HASH'] = $expectedHash
        if ($ps7ModulePath -and $InjectPS7Modules) {
            # Reproduce PS7 -> CMD -> WindowsPS module contamination even when
            # this fixture itself is running under Windows PowerShell 5.1.
            $child.StartInfo.EnvironmentVariables['PSModulePath'] = $ps7ModulePath + ';' + $modulePathBefore
        } elseif (-not $InjectPS7Modules) {
            $child.StartInfo.EnvironmentVariables.Remove('PSModulePath')
        }
        if (-not $child.Start()) { throw 'Fixture child did not start.' }
        # A closed input pipe allows the wrappers' pause to finish unattended.
        $child.StandardInput.Close()
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(20000)) {
            # This is only our own harmless fixture process, never the game.
            $child.Kill()
            throw 'Harmless launcher fixture child timed out.'
        }
        $child.WaitForExit()
        return [pscustomobject]@{ ExitCode=$child.ExitCode; Stdout=$stdout.Result; Stderr=$stderr.Result }
    } finally { $child.Dispose() }
}

$stub = @'
[CmdletBinding()]
param([string]$FrameRate, [int]$RenderScale, [string]$GraphicsTest)
$ErrorActionPreference = 'Stop'
$received = @{}
foreach ($name in $PSBoundParameters.Keys) { $received[$name] = $PSBoundParameters[$name] }
$fileHash = Get-FileHash -LiteralPath $env:SKATE2_LAUNCHER_FIXTURE_HASH_FILE -Algorithm SHA256
if ($fileHash.Hash -ne $env:SKATE2_LAUNCHER_FIXTURE_EXPECTED_HASH) { throw 'Hash fixture content mismatch.' }
[ordered]@{
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    ProcessPolicy = [string](Get-ExecutionPolicy -Scope Process)
    EffectivePolicy = [string](Get-ExecutionPolicy)
    Apartment = [string][Threading.Thread]::CurrentThread.ApartmentState
    ScriptPath = $PSCommandPath
    FileHash = $fileHash.Hash
    HashModulePath = (Get-Command Get-FileHash).Module.Path
    Bound = $received
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:SKATE2_LAUNCHER_FIXTURE_RESULT -Encoding utf8
exit ([int]$env:SKATE2_LAUNCHER_FIXTURE_EXIT)
'@
foreach ($stubName in @('Launch-Skate2.ps1', 'Import-Skate2Data.ps1')) {
    $stubPath = Join-Path $stubRoot $stubName
    [IO.File]::WriteAllText($stubPath, $stub, $utf8)
    Set-Content -LiteralPath $stubPath -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ascii
    Assert-LauncherCondition ((Get-Content -LiteralPath $stubPath -Stream Zone.Identifier -Raw) -match 'ZoneId=3') "MOTW fixture was not created: $stubName"
}

$controlPath = Join-Path $fixture 'control.json'
$inherited = Invoke-FixtureChild $windowsPowerShell '-NoProfile -Command "[string](Get-ExecutionPolicy)"' $controlPath 0 $false
Assert-LauncherCondition ($inherited.ExitCode -eq 0 -and $inherited.Stdout.Trim() -eq 'Restricted') 'The child did not inherit Restricted policy; the positive cases would be inconclusive.'
$markedStub = Join-Path $stubRoot 'Launch-Skate2.ps1'
foreach ($control in @(
    @{ Name='inherited-restricted'; Extra='' },
    @{ Name='downloaded-remotesigned'; Extra=' -ExecutionPolicy RemoteSigned' }
)) {
    $result = Invoke-FixtureChild $windowsPowerShell ('-NoProfile' + $control.Extra + ' -File "' + $markedStub + '"') $controlPath 0 $false
    Assert-LauncherCondition ($result.ExitCode -ne 0) "Negative control unexpectedly ran: $($control.Name)"
    Assert-LauncherCondition (-not (Test-Path -LiteralPath $controlPath)) "Negative control wrote a stub result: $($control.Name)"
    Assert-LauncherCondition ($result.Stderr -match 'UnauthorizedAccess|PSSecurityException') "Negative control failed for a reason other than policy: $($control.Name)"
    $results.Add([pscustomobject]@{ Case=$control.Name; ExitCode=$result.ExitCode; Stdout=$result.Stdout; Stderr=$result.Stderr })
}

$moduleNegativeControls = 0
if ($ps7ModulePath) {
    $result = Invoke-FixtureChild $windowsPowerShell ('-NoProfile -ExecutionPolicy Bypass -File "' + $markedStub + '"') $controlPath
    Assert-LauncherCondition ($result.ExitCode -ne 0 -and $result.Stderr -match 'Get-FileHash') 'The PS7 module-path negative control did not reproduce missing Get-FileHash.'
    Assert-LauncherCondition (-not (Test-Path -LiteralPath $controlPath)) 'Contaminated module-path negative control unexpectedly completed.'
    $results.Add([pscustomobject]@{ Case='inherited-ps7-modules'; ExitCode=$result.ExitCode; Stdout=$result.Stdout; Stderr=$result.Stderr })
    $moduleNegativeControls = 1
}

$wrappers = @(
    @{ Name='Import Game Files.cmd'; Target='Import-Skate2Data.ps1'; Expected=@{} },
    @{ Name='Launch Skate 2.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='unlimited'; RenderScale=2 } },
    @{ Name='Launch Skate 2 - Unlocked FPS.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='unlimited'; RenderScale=2 } },
    @{ Name='Launch Skate 2 - 1x Performance.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='unlimited'; RenderScale=1 } },
    @{ Name='Launch Skate 2 - 2x Quality.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='unlimited'; RenderScale=2 } },
    @{ Name='Launch Skate 2 - 4x Quality.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='unlimited'; RenderScale=4 } },
    @{ Name='Launch Skate 2 - 60 FPS.cmd'; Target='Launch-Skate2.ps1'; Expected=@{ FrameRate='60'; GraphicsTest='synchronous-shaders' } }
)
$caseNumber = 0
foreach ($wrapper in $wrappers) {
    $source = Join-Path $workspace $wrapper.Name
    $copied = Join-Path $playerRoot $wrapper.Name
    Copy-Item -LiteralPath $source -Destination $copied
    Assert-LauncherCondition ((Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $copied).Hash) 'Wrapper fixture differs from production.'
    foreach ($stubExit in @(0, 23)) {
        $caseNumber++
        $resultPath = Join-Path $fixture ('case-{0:D2}.json' -f $caseNumber)
        $result = Invoke-FixtureChild $commandProcessor ('/d /s /c ""' + $copied + '""') $resultPath $stubExit
        Assert-LauncherCondition (Test-Path -LiteralPath $resultPath) "Stub never ran: $($wrapper.Name), requested exit $stubExit. $($result.Stderr)"
        $record = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        Assert-LauncherCondition ($record.PowerShellVersion -match '^5\.1\.') 'Wrapper did not select Windows PowerShell 5.1.'
        Assert-LauncherCondition ($record.ProcessPolicy -eq 'Bypass' -and $record.EffectivePolicy -eq 'Bypass') 'Wrapper did not confine its policy choice to the child process.'
        Assert-LauncherCondition ($record.ScriptPath -eq (Join-Path $stubRoot $wrapper.Target)) 'Wrapper targeted the wrong script or escaped its fixture directory.'
        Assert-LauncherCondition ($record.FileHash -eq $expectedHash) 'Wrapper child failed the Get-FileHash result check.'
        Assert-LauncherCondition ($record.HashModulePath -eq $nativeUtilityPath) 'Wrapper loaded Utility from outside the native Windows PowerShell module directory.'
        Assert-LauncherCondition (@($record.Bound.PSObject.Properties).Count -eq $wrapper.Expected.Count) "Unexpected wrapper arguments: $($wrapper.Name)"
        foreach ($name in $wrapper.Expected.Keys) {
            Assert-LauncherCondition ($record.Bound.$name -eq $wrapper.Expected[$name]) "Changed $name for $($wrapper.Name)"
        }
        if ($wrapper.Target -eq 'Import-Skate2Data.ps1') {
            Assert-LauncherCondition ($record.Apartment -eq 'STA') 'Importer lost its STA dialog requirement.'
            Assert-LauncherCondition ($result.ExitCode -eq $stubExit) 'Importer did not preserve the child exit code across pause.'
        } elseif ($stubExit -eq 0) {
            Assert-LauncherCondition ($result.ExitCode -eq 0) 'Successful launcher returned a failure.'
        } else {
            Assert-LauncherCondition ($result.ExitCode -ne 0) 'Launcher hid a child failure.'
        }
        $results.Add([pscustomobject]@{ Case=$wrapper.Name; StubExit=$stubExit; ExitCode=$result.ExitCode; SourceSHA256=(Get-FileHash -LiteralPath $source).Hash; Record=$record; Stdout=$result.Stdout; Stderr=$result.Stderr })
    }
}
Assert-LauncherCondition ((Get-ExecutionPolicy -List | ConvertTo-Json -Compress) -eq $policyBefore) 'Persistent or parent-process policy changed.'
Assert-LauncherCondition ($env:PSModulePath -ceq $modulePathBefore -and $env:PATH -ceq $pathBefore -and $env:PSExecutionPolicyPreference -ceq $policyEnvironmentBefore) 'The parent environment changed.'
$summary = [ordered]@{
    Passed=$true
    Checks=$script:launcherChecks
    WrapperCases=$caseNumber
    NegativeControls=(2 + $moduleNegativeControls)
    FixtureHostVersion=$PSVersionTable.PSVersion.ToString()
    InjectedPS7ModulePath=$ps7ModulePath
    ExpectedFixtureHash=$expectedHash
    GameLaunched=$false
    SaveDataTouched=$false
    PolicyBefore=($policyBefore | ConvertFrom-Json)
    PolicyAfter=(Get-ExecutionPolicy -List)
    Results=@($results.ToArray())
    Limits='Harmless fixture scripts only; no real game/import, GPU, clean-Windows installation, or organization-enforced policy acceptance was tested.'
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture 'verification.json') -Encoding utf8
Write-Output "PASS: $($script:launcherChecks) checks; $caseNumber real-wrapper cases, two policy controls, and $moduleNegativeControls module-path control. Evidence: $fixture"
