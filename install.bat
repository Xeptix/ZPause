@echo off
setlocal enabledelayedexpansion
title ZPause installer

rem ---------------------------------------------------------------------
rem  ZPause -- optional installer.
rem
rem  Copies the Plutonium folder sitting next to this file into
rem  %LOCALAPPDATA%, merging with what is already there. It replaces
rem  ZPause's own files and touches nothing else -- no deletes, no
rem  registry, no downloads.
rem
rem  The same file ships in every ZPause download. It installs whatever
rem  the folder beside it contains, so it works for one game or all of
rem  them without knowing which it came with.
rem
rem  You do not need this. Dragging the Plutonium folder into
rem  %LOCALAPPDATA% yourself does exactly the same thing.
rem ---------------------------------------------------------------------

set "SRC=%~dp0Plutonium"
set "DEST=%LOCALAPPDATA%\Plutonium"

echo.
echo   ZPause installer
echo   ================
echo.

if not exist "%SRC%" (
    echo   No Plutonium folder next to this file.
    echo.
    echo   Extract the zip first, then run install.bat from the extracted
    echo   folder. Running it from inside Windows' zip viewer will not work.
    echo.
    pause
    exit /b 1
)

if not exist "%DEST%" (
    echo   Plutonium is not installed, or not where ZPause expects it:
    echo.
    echo     %DEST%
    echo.
    echo   Install Plutonium and run it once, then try again.
    echo.
    pause
    exit /b 1
)

echo   Installing to:
echo     %DEST%
echo.
echo   Files:
echo.

set "COUNT=0"
for /r "%SRC%" %%F in (*.gsc) do (
    set "REL=%%F"
    set "REL=!REL:%SRC%\=!"
    echo     !REL!
    set /a COUNT+=1
)

echo.
if "%COUNT%"=="0" (
    echo   Nothing to install -- no scripts found.
    echo.
    pause
    exit /b 1
)

echo   Any existing ZPause file at those paths is replaced. Nothing else
echo   in your Plutonium folder is touched.
echo.

set "GO="
set /p "GO=  Continue? [y/N] "
if /i not "%GO%"=="y" (
    echo.
    echo   Cancelled. Nothing was changed.
    echo.
    pause
    exit /b 0
)

echo.
xcopy "%SRC%" "%DEST%" /E /I /Y >nul
if errorlevel 1 (
    echo   Copy failed.
    echo.
    echo   If the game is running, close it and try again. If Plutonium is
    echo   installed somewhere unusual, copy the Plutonium folder into
    echo   %%LOCALAPPDATA%% by hand instead.
    echo.
    pause
    exit /b 1
)

echo   Installed %COUNT% file^(s^).
echo.
echo   Only the host needs ZPause. End the current match and start a new
echo   one to load it -- no need to restart the game.
echo.
pause
exit /b 0
