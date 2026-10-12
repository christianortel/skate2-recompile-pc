@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
echo Starting unlimited FPS with the tested GPU synchronization profile.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 2
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
