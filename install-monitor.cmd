@echo off
setlocal DisableDelayedExpansion
set "SCRIPT=%~dp0Manage-AutoFixTask.ps1"
if not exist "%SCRIPT%" (
  echo Manage-AutoFixTask.ps1 was not found next to this launcher.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Install
set "RESULT=%errorlevel%"

echo.
if not "%RESULT%"=="0" goto install_failed

echo Installation completed successfully.
goto install_done

:install_failed
echo Installation failed with exit code %RESULT%.

:install_done
pause
endlocal & exit /b %RESULT%
