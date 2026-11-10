@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
echo Starting the RTV performance profile: 2x rendering with unlimited FPS.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 2 -RenderTargetPath rtv -SubmitDrawInterval 1024 -AsyncSubmission
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
