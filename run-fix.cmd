@echo off
chcp 65001 >nul
setlocal
set "SCRIPT=%~dp0Roblox-CDN-AutoFix.ps1"
if not exist "%SCRIPT%" (
  echo Файл Roblox-CDN-AutoFix.ps1 не найден рядом с запускатором.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
