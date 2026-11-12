@echo off
setlocal
cd /d "%~dp0"
echo Removing the fingerprint power fix...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo Done. Press any key to close this window.
) else (
  echo Something went wrong - exit code %RC%.
)
pause >nul
