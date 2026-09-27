@echo off
setlocal EnableExtensions
title MTR Windows standardisation

:: ---------------------------------------------------------------------------
::  Run this from the USB stick on an MTR NUC - double-click it.
::
::  Everything it needs is in this folder: mtr-windows-settings.ps1 plus the
::  wallpaper and installers under .\assets. Nothing is read from the network,
::  so there is no staging to C:\Scripts - a USB drive is a local volume and
::  stays visible after the UAC prompt, where a mapped network drive would not.
::
::  The per-host report is written to .\logs on the stick.
::
::  Optional: add -debug (run-mtr_setup.bat -debug) to turn on extra [diag]
::  console lines in the .ps1 (e.g. the MSI ProductCode lookup). Off by
::  default - these are noisy and only meant for chasing a specific bug.
::
::  Optional: add -noprompt to skip the software tick-box window and install
::  the default selection (Splashtop Streamer, and on Yealink MTRs Extron
::  Control and Logitech Sync, are left out - see the readme).
:: ---------------------------------------------------------------------------

set "PS1=mtr-windows-settings.ps1"
set "HERE=%~dp0"
set "SELF=%~f0"
set "DEBUGARG="
set "NOPROMPTARG="

for %%A in (%*) do (
    if /i "%%~A"=="-debug"    set "DEBUGARG=-debug"
    if /i "%%~A"=="-noprompt" set "NOPROMPTARG=-noprompt"
)

if /i "%~1"=="/elevated" goto :run

if not exist "%HERE%%PS1%" (
    echo ERROR: %PS1% not found next to this batch file.
    echo Run it from the mtr_setup_portable folder, not on its own.
    echo.
    pause
    exit /b 1
)


:: --- elevate, then re-launch this same file ---------------------------------
net session >nul 2>&1
if %errorlevel% equ 0 (
    call "%SELF%" /elevated %DEBUGARG% %NOPROMPTARG%
    exit /b
)

echo Requesting administrator rights...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/elevated %DEBUGARG% %NOPROMPTARG%' -WorkingDirectory '%HERE%' -Verb RunAs"
exit /b


:: --- elevated pass ----------------------------------------------------------
:run
cd /d "%HERE%"
set "PSFLAGS="
if defined DEBUGARG set "PSFLAGS=%PSFLAGS% -Debug"
if defined NOPROMPTARG set "PSFLAGS=%PSFLAGS% -NoPrompt"
if defined DEBUGARG echo [DEBUG MODE ENABLED]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%%PS1%"%PSFLAGS%
set "PSEXIT=%errorlevel%"
echo.
echo ---------------------------------------------------------------------
echo Finished on %COMPUTERNAME% as %USERNAME%.
echo Explorer has been restarted - check Start and Taskbar look right.
echo Report saved to %HERE%logs
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
