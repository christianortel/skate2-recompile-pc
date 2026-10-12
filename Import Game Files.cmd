@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\Import-Skate2Data.ps1"
set "importExitCode=%errorlevel%"
echo.
pause
exit /b %importExitCode%
