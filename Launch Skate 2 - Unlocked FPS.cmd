@echo off
setlocal
echo Starting unlimited FPS with the tested GPU synchronization profile.
powershell.exe -NoProfile -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 2
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
