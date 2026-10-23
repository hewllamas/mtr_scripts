@echo off
setlocal EnableExtensions
title MTR Windows standardisation (network)

:: ---------------------------------------------------------------------------
::  Run this straight off the share on an MTR NUC:
::      \\<ShareHost>\<ToolShare>\run-mtr_setup.bat
::
::  It stages the .ps1 and its settings file to C:\Scripts first, then elevates
::  and runs the LOCAL copy. That order matters: an elevated token is a different
::  logon session and does not inherit the share credentials of the desktop
::  session, so anything read from the share must be copied down BEFORE the UAC
::  prompt.
::
::  Ignore the "CMD does not support UNC paths as current directories"
::  warning - the script uses absolute paths and works regardless.
::
::  Optional: add -noprompt (run-mtr_setup.bat -noprompt) to skip the software tick-box
::  window and install the default selection (Splashtop Streamer, and on Yealink
::  MTRs Extron Control and Logitech Sync, are left out).
::
::  Optional: add -debug (run-mtr_setup.bat -debug) to turn on extra [diag]
::  console lines in the .ps1 (e.g. the MSI ProductCode lookup). Off by
::  default - these are noisy and only meant for chasing a specific bug.
:: ---------------------------------------------------------------------------

set "PS1=mtr-windows-settings.ps1"
set "CFG=network-settings.psd1"
set "STAGE=C:\Scripts"
set "SELF=%~nx0"
set "DEBUGARG="
set "NOPROMPTARG="

for %%A in (%*) do (
    if /i "%%~A"=="-debug"    set "DEBUGARG=-debug"
    if /i "%%~A"=="-noprompt" set "NOPROMPTARG=-noprompt"
)

if /i "%~1"=="/elevated" goto :run


:: --- stage from the share to local disk -------------------------------------
echo.
echo Source : %~dp0
echo Staging: %STAGE%
echo.

if not exist "%~dp0%PS1%" (
    echo ERROR: %PS1% not found next to this batch file.
    echo Check you are connected to the share and run it from there.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0%CFG%" (
    echo ERROR: %CFG% not found next to this batch file.
    echo Copy network-settings.example.psd1 to %CFG% and fill in the share details.
    echo.
    pause
    exit /b 1
)

if not exist "%STAGE%" mkdir "%STAGE%"

copy /y "%~dp0%PS1%" "%STAGE%\%PS1%" >nul
if errorlevel 1 (
    echo ERROR: could not copy %PS1% to %STAGE%.
    echo.
    pause
    exit /b 1
)
copy /y "%~dp0%CFG%" "%STAGE%\%CFG%" >nul
if errorlevel 1 (
    echo ERROR: could not copy %CFG% to %STAGE%.
    echo.
    pause
    exit /b 1
)
copy /y "%~f0" "%STAGE%\%SELF%" >nul


:: --- elevate, then re-launch the local copy ---------------------------------
net session >nul 2>&1
if %errorlevel% equ 0 (
    call "%STAGE%\%SELF%" /elevated %DEBUGARG% %NOPROMPTARG%
    exit /b
)

echo Requesting administrator rights...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%STAGE%\%SELF%' -ArgumentList '/elevated %DEBUGARG% %NOPROMPTARG%' -WorkingDirectory '%STAGE%' -Verb RunAs"
exit /b


:: --- elevated pass ----------------------------------------------------------
:run
cd /d "%STAGE%"
set "PSFLAGS="
if defined DEBUGARG set "PSFLAGS=%PSFLAGS% -Debug"
if defined NOPROMPTARG set "PSFLAGS=%PSFLAGS% -NoPrompt"
if defined DEBUGARG echo [DEBUG MODE ENABLED]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%STAGE%\%PS1%"%PSFLAGS%
set "PSEXIT=%errorlevel%"

:: The script exits 2 before changing anything: the share details are missing
:: (fill in %CFG%), or Cancel was pressed in the setup prompt. No log-off, no restart.
if "%PSEXIT%"=="2" (
    echo.
    echo Stopped - nothing was changed. If the share details are missing, fill in %CFG% and run it again.
    pause
    exit /b 2
)

echo.
echo ---------------------------------------------------------------------
echo Finished on %COMPUTERNAME% as %USERNAME%.
echo Explorer has been restarted - check Start and Taskbar look right.
echo.
:: The script exits 3010 (Windows' "restart required") when a restart is
:: pending - e.g. a hostname change - so restart rather than log off.
if "%PSEXIT%"=="3010" (
    echo A restart is pending - restarting in 120 seconds instead of logging off...
    timeout /t 120
    shutdown /r /f /t 0
) else (
    echo Logging off in 120 seconds...
    timeout /t 120
    shutdown /l /f
)
exit /b
