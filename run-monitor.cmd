@echo off
setlocal

set "TASKLIST=%SystemRoot%\System32\tasklist.exe"
set "FIND=%SystemRoot%\System32\find.exe"
set "MONITOR=%~dp0Roblox-CDN-Monitor.ps1"
set "SCHEDULED="

if /i "%~1"=="--scheduled" set "SCHEDULED=1"

if not exist "%TASKLIST%" goto run_monitor
if not exist "%FIND%" goto run_monitor

"%TASKLIST%" /FI "IMAGENAME eq RobloxPlayerBeta.exe" /NH 2>nul | "%FIND%" /I "RobloxPlayerBeta.exe" >nul
if not errorlevel 1 goto run_monitor

"%TASKLIST%" /FI "IMAGENAME eq RobloxPlayerLauncher.exe" /NH 2>nul | "%FIND%" /I "RobloxPlayerLauncher.exe" >nul
if not errorlevel 1 goto run_monitor

if defined SCHEDULED exit /b 0

echo Roblox is not running. There is nothing to check right now.
echo Use install-monitor.cmd to enable automatic background monitoring.
pause
exit /b 0

:run_monitor
if exist "%MONITOR%" goto start_monitor

if defined SCHEDULED exit /b 2

echo Roblox-CDN-Monitor.ps1 was not found next to this launcher.
pause
exit /b 2

:start_monitor
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%MONITOR%"
set "RESULT=%errorlevel%"

if defined SCHEDULED exit /b %RESULT%

echo.
if not "%RESULT%"=="0" goto monitor_failed

echo CDN monitor finished successfully.
goto monitor_done

:monitor_failed
echo CDN monitor failed with exit code %RESULT%.

:monitor_done
pause
exit /b %RESULT%
