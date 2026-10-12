[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$GameProcessId,
    [ValidateRange(10, 600)][int]$DurationSeconds = 120,
    [ValidateRange(1, 10)][int]$IntervalSeconds = 2
)

# Bounded read-only system sampling. GPU figures describe the entire adapter,
# not just Skate 2. This does not alter clock speeds or power settings.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $workspace 'reports\performance'
[IO.Directory]::CreateDirectory($destination) | Out-Null
$file = Join-Path $destination ('load-{0}-{1}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $GameProcessId)
if (Test-Path -LiteralPath $file) { throw 'A capture with this name already exists.' }
$gameProcess = Get-Process -Id $GameProcessId
if ($gameProcess.ProcessName -ne 'skate2') { throw 'The selected process is not Skate 2.' }
$expectedStart = $gameProcess.StartTime
$lastCpu = $gameProcess.TotalProcessorTime.TotalSeconds
$timer = [Diagnostics.Stopwatch]::StartNew()
$lastElapsed = 0.0
$nvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
Write-Host "Recording process load and adapter-wide GPU load to $file"
while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Seconds $IntervalSeconds
    $gameProcess = Get-Process -Id $GameProcessId -ErrorAction SilentlyContinue
    if (-not $gameProcess -or $gameProcess.StartTime -ne $expectedStart) { break }
    $elapsed = $timer.Elapsed.TotalSeconds
    $cpu = $gameProcess.TotalProcessorTime.TotalSeconds
    $cores = ($cpu - $lastCpu) / ($elapsed - $lastElapsed)
    $row = [ordered]@{
        time_utc = [DateTime]::UtcNow.ToString('o')
        elapsed_seconds = $elapsed
        cpu_core_equivalents = $cores
        cpu_percent_machine = 100 * $cores / [Environment]::ProcessorCount
        working_set_mb = $gameProcess.WorkingSet64 / 1MB
        gpu_sample = ''
    }
    if ($nvidia) {
        $queryProcess = New-Object Diagnostics.Process
        try {
            $queryProcess.StartInfo.FileName = $nvidia.Source
            $queryProcess.StartInfo.Arguments = '--query-gpu=timestamp,name,utilization.gpu,memory.used,temperature.gpu,power.draw,clocks.current.graphics --format=csv,noheader,nounits'
            $queryProcess.StartInfo.UseShellExecute = $false
            $queryProcess.StartInfo.CreateNoWindow = $true
            $queryProcess.StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $queryProcess.StartInfo.RedirectStandardOutput = $true
            $queryProcess.StartInfo.RedirectStandardError = $true
            if ($queryProcess.Start()) {
                if ($queryProcess.WaitForExit(1000)) {
                    if ($queryProcess.ExitCode -eq 0) {
                        $row.gpu_sample = $queryProcess.StandardOutput.ReadToEnd().Trim() -replace '\r?\n', ' | '
                    } else { $row.gpu_sample = 'unavailable' }
                } else {
                    # Only stop this sampler's own timed-out query process.
                    $queryProcess.Kill()
                    $row.gpu_sample = 'query timeout'
                }
            }
        } catch { $row.gpu_sample = 'query unavailable' }
        finally { $queryProcess.Dispose() }
    }
    [pscustomobject]$row | Export-Csv -LiteralPath $file -NoTypeInformation -Append
    $lastCpu = $cpu
    $lastElapsed = $elapsed
}
Write-Host "Capture complete: $file"
