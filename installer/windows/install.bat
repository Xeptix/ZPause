@echo off
rem ---------------------------------------------------------------------
rem  ZPause Manager -- launcher.
rem
rem  Everything lives in install.ps1 beside this file. This exists so the
rem  installer can be started with a double click, which is what a .ps1
rem  cannot do: Windows opens those in Notepad.
rem
rem  -ExecutionPolicy Bypass applies to this one run only. It does not
rem  change any setting on your machine.
rem ---------------------------------------------------------------------
setlocal

if not exist "%~dp0install.ps1" (
    echo.
    echo   install.ps1 is missing from this folder.
    echo   Extract the whole download and run install.bat from there.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"

rem Keep the window open when it was started by double clicking, and only
rem then -- Explorer launches a .bat through "cmd /c", a console does not,
rem so the command line says which happened. No pipe to find here: under a
rem Unix-style PATH that resolves to the wrong program entirely.
if not "%cmdcmdline%"=="%cmdcmdline:/c=%" pause

exit /b %RC%
