@echo off
chcp 65001 >nul
setlocal
set "SCRIPT=%~dp0Manage-AutoFixTask.ps1"
if not exist "%SCRIPT%" (
  echo Файл Manage-AutoFixTask.ps1 не найден рядом с установщиком.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Install
pause
endlocal
