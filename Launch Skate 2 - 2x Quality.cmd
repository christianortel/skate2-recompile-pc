@echo off
setlocal
rem Let Windows PowerShell use its native module defaults, including when called from PS7.
set "PSModulePath="
echo Experimental 2x render quality. Higher GPU cost; game camera remains 16:9.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launch-Skate2.ps1" -FrameRate unlimited -RenderScale 2
if errorlevel 1 (
    pause
    exit /b 1
)
exit /b 0
