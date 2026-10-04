@echo off
REM Starts the public measurement service and keeps it up.
REM
REM Double-click this, or put a shortcut to it in your Startup folder so it
REM survives a reboot without anyone remembering to start it:
REM
REM   1. Press Win+R, type  shell:startup  and press Enter
REM   2. Drag this file in while holding Alt (that makes a shortcut)
REM
REM Remove the shortcut from that folder to stop it starting automatically.
REM
REM The window it opens must stay open - closing it stops the service and marks
REM the published address offline, which is deliberate: a published address
REM pointing at a machine that has stopped is worse than none, because the app
REM would stop looking elsewhere and simply fail.

cd /d "%~dp0"

REM The SmartSpectra runtime is x64-only. On an ARM machine the stock Node is
REM ARM64 and cannot load it, so prefer an x64 build if one is installed.
set "NODE_X64=%USERPROFILE%\node-x64\node.exe"
if exist "%NODE_X64%" (
  set "CASING_NODE=%NODE_X64%"
  "%NODE_X64%" run_public.mjs
) else (
  node run_public.mjs
)

REM Only reached if it exits. Keep the window open so the reason is readable
REM rather than vanishing with the window.
echo.
echo The measurement service has stopped. The message above says why.
pause
