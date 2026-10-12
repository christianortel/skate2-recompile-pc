[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sdkPrefix = Join-Path $workspace 'tools\rexglue-sdk-source\out\install\win-amd64'
$sdkBin = Join-Path $sdkPrefix 'bin'
$driver = Join-Path $PSScriptRoot 'cvar_init_main.cpp'
$report = Join-Path $workspace ('reports\cvar-init-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$project = Join-Path $report 'project'
$build = Join-Path $report 'build'
[IO.Directory]::CreateDirectory($project) | Out-Null
foreach ($file in @($driver, (Join-Path $sdkBin 'rexruntime.dll'), (Join-Path $sdkBin 'rexgpu-xenos.dll'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required installed SDK fixture input missing: $file" }
}
$beforeHashes = @($driver, (Join-Path $sdkBin 'rexruntime.dll'), (Join-Path $sdkBin 'rexgpu-xenos.dll')) | ForEach-Object { Get-FileHash -LiteralPath $_ }
@'
cmake_minimum_required(VERSION 3.25)
project(Skate2CvarInit LANGUAGES CXX)
find_package(rexglue CONFIG REQUIRED)
add_executable(cvar-init "${FIXTURE_SOURCE}")
target_compile_features(cvar-init PRIVATE cxx_std_23)
# Deliberately link the installed implementation. Do not compile cvar.cpp or
# a substitute parser into this test.
target_link_libraries(cvar-init PRIVATE rex::runtime)
'@ | Set-Content -LiteralPath (Join-Path $project 'CMakeLists.txt') -Encoding utf8
. (Join-Path $workspace 'tools\Enter-BuildEnvironment.ps1')
function Invoke-CheckedFixture([string]$Program, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Fixture command failed with exit ${code}: $Program" }
}
Invoke-CheckedFixture cmake @('-S', $project, '-B', $build, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=clang-cl', "-DCMAKE_PREFIX_PATH=$sdkPrefix", "-DFIXTURE_SOURCE=$driver")
Invoke-CheckedFixture cmake @('--build', $build)
$fixtureExe = Join-Path $build 'cvar-init.exe'
$results = @()
foreach ($case in @('explicit-capture', 'omitted-capture-saved-config', 'trailing-empty-control')) {
    $caseReport = Join-Path $report $case
    [IO.Directory]::CreateDirectory($caseReport) | Out-Null
    $child = [Diagnostics.Process]::new()
    try {
        $child.StartInfo.FileName = $fixtureExe
        $child.StartInfo.Arguments = '"' + $case + '" "' + $sdkBin + '" "' + $caseReport + '"'
        $child.StartInfo.WorkingDirectory = $caseReport
        $child.StartInfo.UseShellExecute = $false
        $child.StartInfo.CreateNoWindow = $true
        $child.StartInfo.RedirectStandardOutput = $true
        $child.StartInfo.RedirectStandardError = $true
        $child.StartInfo.EnvironmentVariables['PATH'] = $sdkBin + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
        foreach ($key in @($child.StartInfo.EnvironmentVariables.Keys)) {
            if ($key -like 'REX_*') { $child.StartInfo.EnvironmentVariables.Remove($key) }
        }
        [void]$child.Start()
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) { $child.Kill(); throw 'Harmless cvar fixture timed out.' }
        $child.WaitForExit()
        $output = $stdout.Result
        $errors = $stderr.Result
        [IO.File]::WriteAllText((Join-Path $caseReport 'stdout.txt'), $output)
        [IO.File]::WriteAllText((Join-Path $caseReport 'stderr.txt'), $errors)
        $resultLine = @($output -split '\r?\n' | Where-Object { $_ -match '^\{"case":' }) | Select-Object -Last 1
        if (-not $resultLine) { throw "Fixture produced no result ($($child.ExitCode)): $case. $errors" }
        $result = $resultLine | ConvertFrom-Json
        if ($child.ExitCode -ne 0 -or -not $result.pass) { throw "Fixture failed: $case. $errors" }
        $parserError = $errors -match 'cvar: CLI11\s+parse error:.*perf_log_csv'
        if ($parserError -ne ($case -eq 'trailing-empty-control')) { throw "Unexpected parser diagnostic in $case`: $errors" }
        $results += $result
    } finally { $child.Dispose() }
}
foreach ($before in $beforeHashes) {
    if ((Get-FileHash -LiteralPath $before.Path).Hash -ne $before.Hash) { throw 'An installed SDK binary or driver changed during verification.' }
}
[ordered]@{
    Passed=$true
    Checks=($results | Measure-Object checks -Sum).Sum
    Results=$results
    InputHashes=$beforeHashes
    FixtureHash=(Get-FileHash -LiteralPath $fixtureExe)
    ActualInstalledDllsUsed=$true
    GameLaunched=$false
    GpuInitialized=$false
    Limits='Tests actual SDK parsing, config precedence and real GPU DLL flag registration; not rendering or gameplay. The application capture guard is preserved but not executed by this console fixture.'
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $report 'verification.json') -Encoding utf8
Write-Output "PASS: actual installed SDK cvar::Init; $(($results | Measure-Object checks -Sum).Sum) checks across three cases. Evidence: $report"
