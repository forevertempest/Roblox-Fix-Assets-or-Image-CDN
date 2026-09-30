@echo off
setlocal
set "app=%~dp0release\windows-x64.exe"
if not exist "%app%" set "app=%~dp0release\windows-arm64.exe"
if not exist "%app%" (
  echo Build version2 with build-release.ps1 first, or download the standalone release.
  pause
  exit /b 1
)
"%app%" monitor remove
set "result=%errorlevel%"
pause
exit /b %result%
