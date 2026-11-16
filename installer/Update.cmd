@echo off
setlocal
if "%~1"=="" (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Update
) else (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Update -GamePath "%~1"
)
set "BundleExit=%errorlevel%"
pause
exit /b %BundleExit%
