@echo off
setlocal
rem Paced alternative with GPU synchronization; target is not guaranteed FPS.
powershell.exe -NoProfile -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate 60 -GraphicsTest synchronous-shaders
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
