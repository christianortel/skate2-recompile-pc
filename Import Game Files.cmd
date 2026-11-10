@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
rem Double-click to choose an ISO or extracted folder, or drop either onto this file.
set "importSource=%~1"
if not defined importSource (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\Import-Skate2Data.ps1"
) else if /i "%~x1"==".iso" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\Import-Skate2Data.ps1" -IsoPath "%~1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\Import-Skate2Data.ps1" -SourceDirectory "%~1"
)
set "importExitCode=%errorlevel%"
echo.
pause
exit /b %importExitCode%
