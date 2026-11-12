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
) else if "%RC%"=="2" (
  echo Administrator rights were declined - nothing was changed.
  echo Run uninstall.cmd again and click Yes on the UAC prompt.
) else (
  echo Something went wrong - exit code %RC%.
)
pause >nul
