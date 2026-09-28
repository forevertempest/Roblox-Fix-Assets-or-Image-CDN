@echo off
setlocal DisableDelayedExpansion

set "SCRIPT=%~dp0Manage-AutoFixTask.ps1"
if not exist "%SCRIPT%" (
  echo Manage-AutoFixTask.ps1 was not found next to this launcher.
  pause
  exit /b 1
)

echo This removes the task, installed program and AutoFix hosts block.
echo Backups, logs and your repository will be preserved.
echo The project files themselves will not be deleted.
echo.

"%SystemRoot%\System32\choice.exe" /C YN /N /M "Continue? [Y/N] "
if errorlevel 2 exit /b 0

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Reset
set "RESULT=%errorlevel%"

echo.
if not "%RESULT%"=="0" goto reset_failed

echo Reset completed successfully.
goto reset_done

:reset_failed
echo Reset failed with exit code %RESULT%.

:reset_done
pause
endlocal & exit /b %RESULT%
