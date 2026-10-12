@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
rem Paced alternative with GPU synchronization; target is not guaranteed FPS.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate 60 -GraphicsTest synchronous-shaders
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
