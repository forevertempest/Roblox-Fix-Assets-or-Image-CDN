@echo off
setlocal

set "QPROCESS=%SystemRoot%\System32\qprocess.exe"
set "MONITOR=%~dp0Roblox-CDN-Monitor.ps1"

if not exist "%QPROCESS%" goto run_monitor

"%QPROCESS%" RobloxPlayerBeta.exe >nul 2>&1
if not errorlevel 1 goto run_monitor

"%QPROCESS%" RobloxPlayerLauncher.exe >nul 2>&1
if errorlevel 1 exit /b 0

:run_monitor
if not exist "%MONITOR%" exit /b 2

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%MONITOR%"
exit /b %errorlevel%
