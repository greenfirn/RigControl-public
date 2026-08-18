@echo off
setlocal
title Strip Flightsheet '0' Column

REM ================================================================
REM  EDIT THE NEXT LINE: path to the flightsheets DB you copied over
REM  from the Pi/rig (see the scp command from earlier if you still
REM  need to pull it). Back up this file before running with --write.
REM ================================================================
set DB_PATH=%~dp0rigcloud_flightsheets.db

REM Same folder as this .bat by default - place strip_flightsheet_zero.py
REM here too, or edit this if it lives somewhere else.
set SCRIPT_PATH=%~dp0strip_flightsheet_zero.py

if not exist "%DB_PATH%" (
    echo ERROR: DB file not found at:
    echo   %DB_PATH%
    echo Edit DB_PATH at the top of this .bat to point at the right file.
    echo.
    pause
    exit /b 1
)

if not exist "%SCRIPT_PATH%" (
    echo ERROR: strip_flightsheet_zero.py not found at:
    echo   %SCRIPT_PATH%
    echo Put it in the same folder as this .bat, or edit SCRIPT_PATH above.
    echo.
    pause
    exit /b 1
)

echo ================================================================
echo  DRY RUN - showing what would change, nothing written yet
echo  DB:     %DB_PATH%
echo ================================================================
echo.

python "%SCRIPT_PATH%" "%DB_PATH%"

echo.
echo ================================================================
echo  Review the diff above carefully.
echo ================================================================
set /p CONFIRM="Apply these changes to the DB now? (y/N): "

if /i "%CONFIRM%"=="y" (
    echo.
    echo Writing changes...
    python "%SCRIPT_PATH%" "%DB_PATH%" --write
    echo.
    echo Done.
) else (
    echo.
    echo No changes written.
)

echo.
pause
