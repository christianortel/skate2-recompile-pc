@echo off
setlocal
powershell.exe -NoProfile -STA -File "%~dp0scripts\Import-Skate2Data.ps1"
echo.
pause
