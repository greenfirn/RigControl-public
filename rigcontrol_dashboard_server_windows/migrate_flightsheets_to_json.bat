@echo off
setlocal
title Migrate Flightsheets to rig-gpu.json Format

REM ================================================================
REM  EDIT THE NEXT LINE: path to the flightsheets DB you copied over
REM  from the Pi/rig (copy it down, run this, copy it back up).
REM  Back up this file before running with --apply.
REM ================================================================
set DB_PATH=%~dp0rigcontrol_flightsheets.db

REM Same folder as this .bat by default - place
REM migrate_flightsheets_to_json.py here too, or edit this if it
REM lives somewhere else.
set SCRIPT_PATH=%~dp0migrate_flightsheets_to_json.py

if not exist "%DB_PATH%" (
    echo ERROR: DB file not found at:
    echo   %DB_PATH%
    echo Edit DB_PATH at the top of this .bat to point at the right file.
    echo.
    pause
    exit /b 1
)

if not exist "%SCRIPT_PATH%" (
    echo ERROR: migrate_flightsheets_to_json.py not found at:
    echo   %SCRIPT_PATH%
    echo Put it in the same folder as this .bat, or edit SCRIPT_PATH above.
    echo.
    pause
    exit /b 1
)

echo ================================================================
echo  Classifying flightsheets (json / legacy / not-a-flightsheet)
echo  DB:     %DB_PATH%
echo ================================================================
echo.

python "%SCRIPT_PATH%" --db "%DB_PATH%" --list

echo.
echo ================================================================
echo  DRY RUN - showing what would change, nothing written yet
echo ================================================================
echo.

python "%SCRIPT_PATH%" --db "%DB_PATH%" --show-diff

echo.
echo ================================================================
echo  Review the diff above carefully.
echo ================================================================
set /p CONFIRM="Apply these changes to the DB now? A timestamped .bak copy is made automatically. (y/N): "

if /i "%CONFIRM%"=="y" (
    echo.
    echo Writing changes...
    python "%SCRIPT_PATH%" --db "%DB_PATH%" --apply
    echo.
    echo Done.
) else (
    echo.
    echo No changes written.
)

echo.
pause
