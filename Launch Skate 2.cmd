@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
rem Default profile: saved settings apply; without any, 2x rendering with unlimited FPS.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1"
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
