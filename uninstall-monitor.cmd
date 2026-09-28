@echo off
setlocal DisableDelayedExpansion
set "SCRIPT=%~dp0Manage-AutoFixTask.ps1"
if not exist "%SCRIPT%" (
  echo Manage-AutoFixTask.ps1 was not found next to this launcher.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Uninstall
set "RESULT=%errorlevel%"

echo.
if not "%RESULT%"=="0" goto uninstall_failed

echo Uninstallation completed successfully.
goto uninstall_done

:uninstall_failed
echo Uninstallation failed with exit code %RESULT%.

:uninstall_done
pause
endlocal & exit /b %RESULT%
