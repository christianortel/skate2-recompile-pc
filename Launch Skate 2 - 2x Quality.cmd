@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
rem Default profile: saved settings apply; without any, 2x rendering with unlimited FPS.
echo Starting the default profile with your saved settings.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1"
if errorlevel 1 (
    pause
    exit /b 1
)
exit /b 0
