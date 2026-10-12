@echo off
setlocal
echo Experimental 4x render quality. Very high GPU cost; game camera remains 16:9.
powershell.exe -NoProfile -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 4
if errorlevel 1 (
    pause
    exit /b 1
)
