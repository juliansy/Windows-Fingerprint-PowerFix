@echo off
setlocal
cd /d "%~dp0"
echo Installing the fingerprint power fix...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo Done. Press any key to close this window.
) else (
  echo Something went wrong - exit code %RC%.
  echo See C:\ProgramData\FpPowerFix\fix.log for details.
)
pause >nul
