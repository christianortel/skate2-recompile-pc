[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$KeyboardTest,
    [switch]$Diagnostics,
    [switch]$InputDiagnostics,
    [switch]$PerformanceCapture,
    [ValidateSet('original', '60', '120', '144', '165', '200', '240', 'unlimited')]
    [string]$FrameRate,
    [ValidateSet('default', 'synchronous-shaders', 'synchronous-memexport')]
    [string]$GraphicsTest = 'synchronous-shaders',
    [switch]$PresentIdleCleanSync = $true,
    [ValidateSet(1, 2, 3, 4)][int]$RenderScale,
    [ValidateRange(0, 16)][int]$Monitor,
    [switch]$Windowed,
    [ValidateRange(-2, 32)][int]$Adapter = -1
)

$ErrorActionPreference = 'Stop'
$launchRoot = Split-Path -Parent $PSScriptRoot

try {
    $candidates = @(
        (Join-Path $launchRoot 'skate2.exe'),
        (Join-Path $launchRoot 'bin\skate2.exe'),
        (Join-Path $launchRoot 'skate2\out\build\win-amd64-release\skate2.exe')
    )
    $executable = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $executable) {
        throw 'skate2.exe is missing. If you downloaded the source, follow docs/BUILD.md. If you have a player package, extract all of its files before launching.'
    }

    $appRoot = $launchRoot
    if ($executable -eq $candidates[2]) { $appRoot = Join-Path $launchRoot 'skate2' }
    $gameCandidates = @(
        (Join-Path $launchRoot 'game'),
        (Join-Path $appRoot 'game')
    )
    # Optional developer-only locator, excluded from source and packages.
    $localGamePath = Join-Path $launchRoot '.local\game-directory.txt'
    if (Test-Path -LiteralPath $localGamePath -PathType Leaf) {
        $gameCandidates += (Get-Content -LiteralPath $localGamePath -Raw).Trim()
    }
    $gameRoot = $gameCandidates | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_ 'default.xex') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_ 'data') -PathType Container)
    } | Select-Object -First 1
    if (-not $gameRoot) {
        throw 'Game data is missing. Run Import Game Files.cmd and select your extracted folder containing default.xex and data. See docs/INSTALL.md.'
    }

    $expectedHash = '116BA3EE37FCF0D8DB60B7D47C971FDB6D3EB2A7A4D3CFC3611A06704A588AE5'
    if ((Get-FileHash -LiteralPath (Join-Path $gameRoot 'default.xex') -Algorithm SHA256).Hash -ne $expectedHash) {
        throw 'Unsupported game executable. See docs/INSTALL.md for the required revision and SHA-256.'
    }
    $userRoot = Join-Path $appRoot 'userdata'
    $cacheRoot = Join-Path $appRoot 'cache'
    $arguments = @(
        "--game_data_root=$gameRoot", "--user_data_root=$userRoot", "--cache_root=$cacheRoot",
        '--gpu_plugin=xenos', '--input_backend=sdl', '--render_target_path_d3d12=rov'
    )
    if ($KeyboardTest) { $arguments += '--mnk_mode=true' }
    if ($InputDiagnostics) { $arguments += '--input_diag=true' }
    if ($PSBoundParameters.ContainsKey('FrameRate')) { $arguments += "--skate2_frame_rate=$($FrameRate.ToLowerInvariant())" }
    # Each diagnostic changes one graphics option, without saving a preference.
    # Keep frame mode and the existing cache constant for a controlled comparison.
    if ($GraphicsTest -eq 'synchronous-shaders') { $arguments += '--async_shader_compilation=false' }
    if ($GraphicsTest -eq 'synchronous-memexport') { $arguments += '--readback_memexport_fast=false' }
    # Reproduce the successful run020 profile. Explicit false is available for
    # controlled comparisons and must override a previously saved true value.
    $arguments += '--d3d12_present_idleclean_sync=' + ([bool]$PresentIdleCleanSync).ToString().ToLowerInvariant()
    if ($PSBoundParameters.ContainsKey('RenderScale')) {
        $arguments += @('--resolution_scale=1', "--draw_resolution_scale_x=$RenderScale", "--draw_resolution_scale_y=$RenderScale")
    }
    if ($PSBoundParameters.ContainsKey('Monitor')) { $arguments += "--monitor=$Monitor" }
    if ($Windowed) { $arguments += '--fullscreen=false' }
    if ($PerformanceCapture) {
        $performanceRoot = Join-Path (Split-Path -Parent $executable) 'logs\performance'
        $performanceName = 'frames-{0}-{1}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $performancePath = Join-Path $performanceRoot $performanceName
        if (-not $CheckOnly) { [IO.Directory]::CreateDirectory($performanceRoot) | Out-Null }
        $arguments += "--perf_log_csv=$performancePath"
    }
    # Omit the disabled capture option: this CLI parser rejects a trailing
    # empty --perf_log_csv= before applying ordinary startup flags. The app
    # already ignores saved capture paths unless explicitly passed on the CLI.
    if ($PSBoundParameters.ContainsKey('Adapter')) { $arguments += "--d3d12_adapter=$Adapter" }
    if ($Diagnostics) { $arguments += @('--log_level=debug', '--log_flush_interval=1') }
    if ($CheckOnly) {
        [pscustomobject]@{ Executable = $executable; GameData = $gameRoot; UserData = $userRoot; Cache = $cacheRoot; Arguments = $arguments }
        exit 0
    }
    Write-Host 'Starting Skate 2...'
    # Windows GUI programs must be waited on explicitly so their exit status is
    # reported correctly by both Windows PowerShell and PowerShell 7. These
    # arguments contain fixed switches and Windows paths (no embedded quotes).
    $quotedArguments = $arguments | ForEach-Object { '"' + $_ + '"' }
    $gameProcess = Start-Process -FilePath $executable -ArgumentList $quotedArguments `
        -WorkingDirectory (Split-Path -Parent $executable) -PassThru -Wait
    $exitCode = $gameProcess.ExitCode
    if ($exitCode -ne 0) { throw "Skate 2 exited with code $exitCode. Check the logs folder beside the executable." }
} catch {
    Write-Host ("Skate 2 could not start: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
