@echo off
setlocal DisableDelayedExpansion
set "SCRIPT=%~dp0Roblox-CDN-AutoFix.ps1"
if not exist "%SCRIPT%" (
  echo Roblox-CDN-AutoFix.ps1 was not found next to this launcher.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%errorlevel%"
pause
endlocal & exit /b %RESULT%
