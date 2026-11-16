@echo off
setlocal
if "%~1"=="" (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Switch-FG.ps1"
) else (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Switch-FG.ps1" -GamePath "%~1"
)
set "BundleExit=%errorlevel%"
pause
exit /b %BundleExit%
