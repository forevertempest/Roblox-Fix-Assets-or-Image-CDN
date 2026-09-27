@echo off
setlocal
set "SCRIPT=%~dp0Roblox-CDN-AutoFix.ps1"
if not exist "%SCRIPT%" (
  echo Roblox-CDN-AutoFix.ps1 was not found next to this launcher.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
