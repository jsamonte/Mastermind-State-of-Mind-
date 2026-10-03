@echo off
REM ---------------------------------------------------------------------------
REM Start the Mastermind sidecar in a window YOU control.
REM
REM Double-click this, or run it from a terminal. Ctrl-C stops it; run it again
REM to restart. That matters: the Presage SDK can wedge the process during a
REM real measurement - still bound to the port, still LISTENING, but answering
REM nothing - and the only cure is a restart. A sidecar started from somewhere
REM you cannot reach turns a five-second recovery into a hunt through Task
REM Manager for a PID.
REM
REM   run_sidecar.bat          -> port 8799 (what the current web build expects)
REM   run_sidecar.bat 8787     -> once 8787 is free again
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

set PORT=%1
if "%PORT%"=="" set PORT=8799

echo.
echo   Mastermind sidecar  ^|  port %PORT%
echo   Ctrl-C to stop. Run this again to restart.
echo.

REM A wedged sidecar still holds its port, so a bare EADDRINUSE would be the
REM confusing symptom rather than the explanation. Say which it is.
netstat -ano | findstr ":%PORT% " | findstr LISTENING >nul 2>&1
if %ERRORLEVEL%==0 (
  echo   Port %PORT% is already held by another process:
  echo.
  netstat -ano | findstr ":%PORT% " | findstr LISTENING
  echo.
  echo   If that is a healthy sidecar, you are done - leave it running.
  echo   Check with:  curl http://127.0.0.1:%PORT%/health
  echo   If it answers nothing, it is wedged: end that PID in Task Manager,
  echo   then run this again.
  echo.
  pause
  exit /b 1
)

node start-real.mjs --port=%PORT%

REM Only reached when the sidecar exits. Hold the window open so whatever it
REM printed on the way out is readable.
echo.
echo   Sidecar exited.
pause
