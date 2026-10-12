@echo off
setlocal
echo Starting original render quality with the tested GPU synchronization profile.
powershell.exe -NoProfile -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 1
if errorlevel 1 (
    pause
    exit /b 1
)
